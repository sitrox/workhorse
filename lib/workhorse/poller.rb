module Workhorse
  class Poller
    attr_reader :worker

    def initialize(worker)
      @worker = worker
      @running = false
    end

    def running?
      @running
    end

    def start
      fail 'Poller is already running.' if running?
      @running = true

      @thread = Thread.new do
        begin
          loop do
            poll
            break unless running?
            sleep
          end
        rescue => e
          worker.log %(Poller stopped with exception:\n#{e.message}\n#{e.backtrace.join("\n")})
        end
      end
    end

    def shutdown
      fail 'Poller is not running.' unless running?
      @running = false
    end

    def wait
      @thread.join
    end

    private

    def sleep
      remaining = worker.polling_interval

      while running? && remaining > 0
        Kernel.sleep 1
        remaining -= 1
      end
    end

    def poll
      Workhorse.tx_callback.call do
        remaining_capacity = worker.remaining_capacity
        worker.log "Polling DB for jobs (#{remaining_capacity} available threads)...", :debug

        unless remaining_capacity.zero?
          jobs = queued_db_jobs(remaining_capacity)
          jobs.each do |job|
            worker.log "Marking job #{job.id} as locked", :debug
            job.mark_locked!(worker.id)
            worker.perform job
          end
        end
      end
    end

    def queued_db_jobs(limit)
      table = Workhorse::DbJob.arel_table
      is_oracle = ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'

      # ---------------------------------------------------------------
      # Lock all queued jobs that are not complete
      # ---------------------------------------------------------------
      Workhorse::DbJob.connection.execute(
        Workhorse::DbJob.select('null').where(
          table[:queue].not_eq(nil)
          .and(table[:state].eq(:waiting))
        ).lock.to_sql
      )

      # ---------------------------------------------------------------
      # Select jobs to execute
      # ---------------------------------------------------------------

      # Fetch all waiting jobs of the correct queues
      select = table.project(Arel.sql('*')).where(table[:state].eq(:waiting))

      # Restrict queues that are currently in progress
      bad_queries_select = table.project(table[:queue])
                                .where(table[:state].in(%i[locked running]))
                                .distinct
      select = select.where(table[:queue].not_in(bad_queries_select))

      # Restrict queues to "open" ones
      if worker.queues.any?
        where = table[:queue].in(worker.queues.reject(&:nil?))
        if worker.queues.include?(nil)
          where = where.or(table[:queue].eq(nil))
        end
        select = select.where(where)
      end

      # Order by creation date
      select = select.order(table[:created_at].asc)

      # Limit number of records
      if is_oracle
        select = select.where(Arel.sql('ROWNUM').lteq(limit))
      else
        select = select.take(limit)
      end

      select = select.lock

      return Workhorse::DbJob.find_by_sql(select.to_sql)
    end
  end
end
