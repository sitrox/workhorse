module Workhorse
  # Database poller that discovers and locks jobs for execution.
  # Handles job querying, global locking, and job distribution to workers.
  # Supports both MySQL and Oracle databases with database-specific optimizations.
  #
  # @example Basic usage (typically used internally)
  #   poller = Workhorse::Poller.new(worker, proc { true })
  #   poller.start
  class Poller
    MIN_LOCK_TIMEOUT = 0.1 # In seconds
    MAX_LOCK_TIMEOUT = 1.0 # In seconds

    ORACLE_LOCK_MODE   = 6           # X_MODE (exclusive)
    ORACLE_LOCK_HANDLE = 478_564_848 # Randomly chosen number

    # @return [Workhorse::Worker] The worker this poller serves
    attr_reader :worker

    # @return [Arel::Table] The jobs table for query building
    attr_reader :table

    # Creates a new poller for the given worker.
    #
    # @param worker [Workhorse::Worker] The worker to serve
    # @param before_poll [Proc] Callback executed before each poll (should return boolean)
    def initialize(worker, before_poll = proc { true })
      @worker = worker
      @running = false
      @table = Workhorse::DbJob.arel_table
      @is_oracle = ActiveRecord::Base.connection.adapter_name == 'OracleEnhanced'
      @instant_repoll = Concurrent::AtomicBoolean.new(false)
      @global_lock_fails = 0
      @max_global_lock_fails_reached = false
      @before_poll = before_poll
    end

    # Checks if the poller is currently running.
    #
    # @return [Boolean] True if poller is running
    def running?
      @running
    end

    # Starts the poller in a background thread.
    #
    # @return [void]
    # @raise [RuntimeError] If poller is already running
    def start
      fail 'Poller is already running.' if running?
      @running = true

      clean_stuck_jobs! if Workhorse.clean_stuck_jobs

      @thread = Thread.new do
        loop do
          break unless running?

          begin
            unless @before_poll.call
              Thread.new { worker.shutdown }
              sleep
              next
            end

            poll
            sleep
          rescue Exception => e
            worker.log %(Poll encountered exception:\n#{e.message}\n#{e.backtrace.join("\n")})
            worker.log 'Worker shutting down...'
            Workhorse.on_exception.call(e) unless Workhorse.silence_poller_exceptions
            @running = false
            worker.instance_variable_get(:@pool).shutdown
            break
          end
        end
      end
    end

    # Shuts down the poller and waits for completion.
    #
    # @return [void]
    # @raise [RuntimeError] If poller is not running
    def shutdown
      fail 'Poller is not running.' unless running?
      @running = false
      wait
    end

    # Waits for the poller thread to complete.
    #
    # @return [void]
    def wait
      @thread.join
    end

    # Interrupts current sleep and performs the next poll immediately.
    # After the poll, resumes normal polling interval.
    #
    # @return [void]
    def instant_repoll!
      worker.log 'Aborting next sleep to perform instant repoll', :debug
      @instant_repoll.make_true
    end

    private

    # Cleans up jobs stuck in locked or started states from dead processes.
    # Only cleans jobs from the current hostname.
    #
    # @return [void]
    # @private
    def clean_stuck_jobs!
      with_global_lock timeout: MAX_LOCK_TIMEOUT do
        Workhorse.tx_callback.call do
          # Basic relation: Fetch jobs locked by current host in state 'locked' or
          # 'started'
          rel = Workhorse::DbJob.select('*').from(<<~SQL)
            (#{Workhorse::DbJob.with_split_locked_by.to_sql}) #{Workhorse::DbJob.table_name}
          SQL
          rel.where!(
            locked_by_host: worker.hostname,
            state:          [Workhorse::DbJob::STATE_LOCKED, Workhorse::DbJob::STATE_STARTED]
          )

          # Select all pids
          job_pids = rel.distinct.pluck(:locked_by_pid).to_set(&:to_i)

          # Get pids without active process
          orphaned_pids = job_pids.select do |pid|
            begin # rubocop:disable Style/RedundantBegin
              Process.getpgid(pid)
              false
            rescue Errno::ESRCH
              true
            end
          end

          # Reset jobs in state 'locked'
          rel.where(locked_by_pid: orphaned_pids.to_a, state: Workhorse::DbJob::STATE_LOCKED).each do |job|
            worker.log(
              "Job ##{job.id} has been locked but not yet startet by PID #{job.locked_by_pid} on host " \
              "#{job.locked_by_host}, but the process is not running anymore. This job has therefore been " \
              "reset (set to 'waiting') by the Workhorse cleanup logic.",
              :warn
            )
            job.reset!(true)
          end

          # Mark jobs in state 'started' as failed
          rel.where(locked_by_pid: orphaned_pids.to_a, state: Workhorse::DbJob::STATE_STARTED).each do |job|
            worker.log(
              "Job ##{job.id} has been started by PID #{job.locked_by_pid} on host #{job.locked_by_host} " \
              'but the process is not running anymore. This job has therefore been marked as ' \
              'failed by the Workhorse cleanup logic.',
              :warn
            )
            exception = Exception.new(
              "Job has been started by PID #{job.locked_by_pid} on host #{job.locked_by_host} " \
              'but the process is not running anymore. This job has therefore been marked as ' \
              'failed by the Workhorse cleanup logic.'
            )
            exception.set_backtrace []
            job.mark_failed!(exception)
          end
        end
      end
    end

    # Sleeps for the configured polling interval with instant repoll support.
    #
    # @return [void]
    # @private
    def sleep
      remaining = worker.polling_interval

      while running? && remaining > 0 && @instant_repoll.false?
        Kernel.sleep 0.1
        remaining -= 0.1
      end
    end

    # Executes a block with a global database lock.
    # Supports both MySQL GET_LOCK and Oracle DBMS_LOCK.
    #
    # @param name [Symbol] Lock name identifier
    # @param timeout [Integer] Lock timeout in seconds
    # @yield Block to execute while holding the lock
    # @return [void]
    # @private
    def with_global_lock(name: :workhorse, timeout: 2, &_block)
      begin # rubocop:disable Style/RedundantBegin
        if @is_oracle
          result = Workhorse::DbJob.connection.select_all(
            "SELECT DBMS_LOCK.REQUEST(#{ORACLE_LOCK_HANDLE}, #{ORACLE_LOCK_MODE}, #{timeout}) FROM DUAL"
          ).first.values.last

          success = result == 0
        else
          result = Workhorse::DbJob.connection.select_all(
            "SELECT GET_LOCK(CONCAT(DATABASE(), '_#{name}'), #{timeout})"
          ).first.values.last
          success = result == 1
        end

        if success
          @global_lock_fails = 0
          @max_global_lock_fails_reached = false
        else
          @global_lock_fails += 1

          unless @max_global_lock_fails_reached
            worker.log 'Could not obtain global lock, retrying with next poll.', :warn
          end

          if @global_lock_fails > Workhorse.max_global_lock_fails && !@max_global_lock_fails_reached
            @max_global_lock_fails_reached = true

            worker.log 'Could not obtain global lock, retrying with next poll. ' \
                       'This will be the last such message for this worker until ' \
                       'the issue is resolved.', :warn

            message = "Worker reached maximum number of consecutive times (#{Workhorse.max_global_lock_fails}) " \
                      "where the global lock could no be acquired within the specified timeout (#{timeout}). " \
                      'A worker that obtained this lock may have crashed without ending the database ' \
                      'connection properly. On MySQL, use "show processlist;" to see which connection(s) ' \
                      'is / are holding the lock for a long period of time and consider killing them using ' \
                      "MySQL's \"kill <Id>\" command. This message will be issued only once per worker " \
                      'and may only be re-triggered if the error happens again *after* the lock has ' \
                      'been solved in the meantime.'

            worker.log message
            exception = StandardError.new(message)
            Workhorse.on_exception.call(exception)
          end
        end

        return unless success

        yield
      ensure
        if success
          if @is_oracle
            Workhorse::DbJob.connection.execute("SELECT DBMS_LOCK.RELEASE(#{ORACLE_LOCK_HANDLE}) FROM DUAL")
          else
            Workhorse::DbJob.connection.execute("SELECT RELEASE_LOCK(CONCAT(DATABASE(), '_#{name}'))")
          end
        end
      end
    end

    # Performs a single poll cycle to discover and lock jobs.
    #
    # @return [void]
    # @private
    def poll
      @instant_repoll.make_false

      timeout = [MIN_LOCK_TIMEOUT, [MAX_LOCK_TIMEOUT, worker.polling_interval].min].max
      with_global_lock timeout: timeout do
        job_ids = []

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
              job_ids << job.id
            end
          end

          unless running?
            worker.log 'Rolling back transaction to unlock jobs, as worker has been shut down in the meantime'
            fail ActiveRecord::Rollback
          end
        end

        # This needs to be outside the above transaction because it runs the job
        # in a new thread which opens a new connection. Even though it would be
        # non-blocking and thus directly conclude the block and the transaction,
        # there would still be a risk that the transaction is not committed yet
        # when the job starts.
        job_ids.each { |job_id| worker.perform(job_id) } if running?
      end
    end

    # Returns an array of {Workhorse::DbJob}s that can be started.
    # Uses complex SQL with UNIONs to respect queue ordering and limits.
    #
    # @param limit [Integer] Maximum number of jobs to return
    # @return [Array<Workhorse::DbJob>] Jobs ready for execution
    # @private
    def queued_db_jobs(limit)
      # ---------------------------------------------------------------
      # Select jobs to execute
      # ---------------------------------------------------------------

      # Construct selects for each queue which then are UNIONed for the final
      # set. This is required because we only want the first job of each queue
      # to be posted.
      union_parts = []
      valid_queues.each do |queue|
        # Start with a fresh select, as we now know the allowed queues
        select = valid_ordered_select_id
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
      # subselects. The parentheses are necessary because of the order clauses
      # contained within.
      # Additionally, each of the subselects and the final union select is given
      # an alias to comply with MySQL requirements.
      # These aliases are added directly instead of using Arel `as`, because it
      # uses the keyword 'AS' in SQL generated for Oracle, which is invalid for
      # table aliases.
      union_query_sql = '('
      union_query_sql += "SELECT * FROM (#{union_parts.shift.to_sql}) union_0"
      union_parts.each_with_index do |part, idx|
        union_query_sql += " UNION SELECT * FROM (#{part.to_sql}) union_#{idx + 1}"
      end
      union_query_sql += ') subselect'

      # Create a new SelectManager to work with, using the UNION as data source
      if AREL_GTE_7
        select = Arel::SelectManager.new(Arel.sql(union_query_sql))
      else
        select = Arel::SelectManager.new(ActiveRecord::Base, Arel.sql(union_query_sql))
      end
      select = table.project(Arel.star).where(table[:id].in(select.project(:id)))
      select = order(select)

      # Limit number of records
      select = agnostic_limit(select, limit)

      return Workhorse::DbJob.find_by_sql(select.to_sql).to_a
    end

    # Returns a fresh Arel select manager containing the id of all waiting jobs.
    #
    # @return [Arel::SelectManager] the select manager
    def valid_select_id
      select = table.project(table[:id])
      select = select.where(table[:state].eq(:waiting))
      select = select.where(table[:perform_at].lteq(Time.now).or(table[:perform_at].eq(nil)))
      return select
    end

    # Returns a fresh Arel select manager containing the id of all waiting jobs,
    # ordered with {#order}.
    #
    # @return [Arel::SelectManager] the select manager
    def valid_ordered_select_id
      return order(valid_select_id)
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
      return select.where(Arel.sql('ROWNUM').lteq(number)) if @is_oracle
      return select.take(number)
    end

    # Returns an Array of queue names for which a job may be posted
    #
    # This is done in multiple steps. First, all queues with jobs that are in
    # progress are removed, with the exception of the nil queue. Second, we
    # restrict to only queues for which we may post jobs. Third, we extract the
    # queue names of the remaining queues and return them in an Array.
    #
    # @return [Array] an array of unique queue names
    def valid_queues
      select = valid_select_id

      # Restrict queues that are currently in progress, except for the nil
      # queue, where jobs may run in parallel
      bad_states = [Workhorse::DbJob::STATE_LOCKED, Workhorse::DbJob::STATE_STARTED]
      bad_queues_select = table.project(table[:queue])
                               .where(table[:queue].not_eq(nil))
                               .where(table[:state].in(bad_states))
      # .distinct is not chainable in older Arel versions
      bad_queues_select.distinct
      select = select.where(table[:queue].not_in(bad_queues_select).or(table[:queue].eq(nil)))

      # Restrict queues to valid ones as indicated by the options given to the
      # worker
      unless worker.queues.empty?
        if worker.queues.include?(nil)
          where = table[:queue].eq(nil)
          remaining_queues = worker.queues.compact
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
      select.projections = []
      queues = select.project(:queue)

      return Workhorse::DbJob.connection.execute(queues.distinct.to_sql).to_a.flatten
    end
  end
end
