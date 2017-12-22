module Workhorse
  class Poller
    attr_reader :worker
    attr_reader :table

    def initialize(worker)
      @worker = worker
      @running = false
      @table = Workhorse::DbJob.arel_table
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
        Kernel.sleep 0.1
        remaining -= 0.1
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

    # Returns an Array of #{Workhorse::DbJob}s that can be started
    def queued_db_jobs(limit)
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
      #
      # Construct selects for each queue which then are UNIONed for the final
      # set. This is required because we only want the first job of each queue
      # to be posted.
      union_parts = []
      valid_queues.each do |queue|
        # Start with a fresh select, as we now know the allowed queues
        select = valid_ordered_select
        select = select.where(table[:queue].eq(queue))

        # Get the maximum amount possible for no-queue jobs. This gives us the
        # smallest possible set from which to draw the final set of jobs without
        # any presumptions on the order.
        record_number = queue.nil? ? limit : 1

        union_parts << agnostic_limit(select, record_number)
      end

      return [] if union_parts.empty?

      # Combine the jobs of each queue in a giant UNION chain. Arel does not
      # support this directly, as it does not generate parentheses around the
      # subselects.
      union_query_sql = '('
      union_query_sql += '(' + union_parts.shift.to_sql + ')'
      union_parts.each do |part|
        union_query_sql += ' UNION (' + part.to_sql + ')'
      end
      union_query_sql += ')'

      # Create a new SelectManager to work with, using the UNION as data source
      select = Arel::SelectManager.new(Arel.sql(union_query_sql).as('subselect'))
      select = order(select.project(Arel.star))

      # Limit number of records
      select = agnostic_limit(select, limit)

      select = select.lock

      return Workhorse::DbJob.find_by_sql(select.to_sql)
    end

    # Returns a fresh Arel select manager containing all waiting jobs, ordered
    # with {#order}.
    #
    # @return [Arel::SelectManager] the select manager
    def valid_ordered_select
      select = table.project(Arel.star)
      select = select.where(table[:state].eq(:waiting))
      select = select.where(table[:perform_at].lteq(Time.now).or(table[:perform_at].eq(nil)))
      return order(select)
    end

    # Orders the records by execution order (first to last)
    #
    # @param select [Arel::SelectManager] the select manager to sort
    # @return [Arel::SelectManager] the passed select manager with sorting on
    #   top
    def order(select)
      select.order(Arel.sql('priority').asc).order(Arel.sql('created_at').asc)
    end

    # Limits the number of records
    #
    # @param select [Arel::SelectManager] the select manager on which to apply
    #   the limit
    # @param number [Integer] the maximum number of records to return
    # @return [Arel::SelectManager] the resultant select manager
    def agnostic_limit(select, number)
      is_oracle = ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'

      return select.where(Arel.sql('ROWNUM').lteq(number)) if is_oracle
      return select.take(number)
    end

    # Returns an Array of queue names for which a job may be posted
    #
    # This is done in multiple steps. First, all queues with jobs that are in
    # progress are removed. Second, restrict to only queues for which we may
    # post jobs. Third, extract the queue names of the remaining queues and
    # return them in an Array.
    #
    # @return [Array] an array of unique queue names
    def valid_queues
      select = valid_ordered_select

      # Restrict queues that are currently in progress
      bad_queries_select = table.project(table[:queue])
                                .where(table[:state].in(%i[locked running]))
                                .distinct
      select = select.where(table[:queue].not_in(bad_queries_select))

      # Restrict queues to valid ones as indicated by the options given to the
      # worker
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

      # Get the names of all valid queues. The extra project here allows
      # selecting the last value in each row of the resulting array and getting
      # the queue name.
      queues = select.project(:queue)
      return Workhorse::DbJob.connection.execute(queues.to_sql).map(&:last).uniq
    end
  end
end
