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
            break unless running?
            poll
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
      wait
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
        # As we are the only thread posting into the worker pool, it is safe to
        # get the number of idle threads without mutex synchronization. The
        # actual number of idle workers at time of posting can only be larger
        # than or equal to the number we get here.
        idle = worker.idle

        worker.log "Polling DB for jobs (#{idle} available threads)...", :debug

        unless idle.zero?
          jobs = queued_db_jobs(idle)
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
      # Lock all queued jobs that are waiting
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
      unless worker.queues.empty?
        if worker.queues.include?(nil)
          where = table[:queue].eq(nil)
          remaining_queues = worker.queues.reject(&:nil?)
          unless remaining_queues.empty?
            where = where.or(table[:queue].in(remaining_queues))
          end
        else
          where = table[:queue].in(worker.queues)
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
