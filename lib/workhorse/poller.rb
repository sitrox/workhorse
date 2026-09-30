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

    # Most jobs one poll expires, see {#expire_due_jobs}.
    MAX_EXPIRIES_PER_POLL = 100

    # Length of one slice of the poller's sleep, in seconds. The poller sleeps
    # in slices rather than for the whole polling interval so that it stays
    # responsive to shutdown, to instant repolling and to notifications.
    SLEEP_SLICE = 0.1

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

      Workhorse.debug_log("[Job worker #{worker.id}] Poller starting")

      begin
        Workhorse.notifier.start
      rescue StandardError => e
        worker.log "Starting the notifier failed, falling back to polling: #{e.class}: #{e.message}", :warn
      end

      # Only jobs announced from now on concern this worker; anything enqueued
      # earlier is found by the poll that follows.
      @last_notification = notifier_token

      reconcile_schedules!

      clean_stuck_jobs! if Workhorse.clean_stuck_jobs

      @thread = Thread.new do
        Workhorse.debug_log("[Job worker #{worker.id}] Poller thread started")
        loop do
          break unless running?

          begin
            unless @before_poll.call
              Workhorse.debug_log("[Job worker #{worker.id}] before_poll returned false, triggering worker shutdown")
              Thread.new { worker.shutdown }
              sleep
              next
            end

            poll
            sleep
          rescue Exception => e
            Workhorse.debug_log("[Job worker #{worker.id}] Poller exception, shutting down: #{e.class}: #{e.message}")
            worker.log %(Poll encountered exception:\n#{e.message}\n#{e.backtrace.join("\n")})
            worker.log 'Worker shutting down...'
            Workhorse.on_exception.call(e) unless Workhorse.silence_poller_exceptions
            @running = false
            worker.instance_variable_get(:@pool).shutdown
            break
          end
        end
        Workhorse.debug_log("[Job worker #{worker.id}] Poller thread exiting")
      end
    end

    # Shuts down the poller and waits for completion.
    #
    # @return [void]
    # @raise [RuntimeError] If poller is not running
    def shutdown
      fail 'Poller is not running.' unless running?
      Workhorse.debug_log("[Job worker #{worker.id}] Poller shutting down")
      @running = false
      wait

      begin
        Workhorse.notifier.stop
      rescue StandardError => e
        worker.log "Stopping the notifier failed: #{e.class}: #{e.message}", :warn
      end

      Workhorse.debug_log("[Job worker #{worker.id}] Poller shut down")
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

    # Brings the schedules table in line with the registry, see
    # {Workhorse::Schedule.reconcile!}.
    #
    # A worker that cannot reconcile still works through the queue, so this
    # reports rather than raises.
    #
    # @return [void]
    # @private
    def reconcile_schedules!
      @schedules_available = Workhorse::Schedule.table_exists?

      unless @schedules_available
        if Workhorse::Schedules.any?
          message = 'Schedules are declared but the workhorse_schedules table does not exist. ' \
                    'Run the migration that creates it; no scheduled job will run until then.'
          worker.log message, :error

          begin
            Workhorse.on_exception.call(StandardError.new(message))
          rescue Exception => e
            # Reported through the rescue below would feed the callback its
            # own failure; escaping leaves the worker half-started.
            Workhorse.debug_log("on_exception failed: #{e.class}: #{e.message}")
          end
        end

        return
      end

      with_global_lock timeout: MAX_LOCK_TIMEOUT do
        Workhorse::Schedule.reconcile!
      end
    rescue Exception => e
      worker.log %(Could not reconcile schedules: #{e.message}), :error
      Workhorse.on_exception.call(e)
    end

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

    # Sleeps for the configured polling interval, returning early for an
    # instant repoll, for shutdown, or as soon as a notification announces a
    # newly enqueued job.
    #
    # @return [void]
    # @private
    def sleep
      remaining = worker.polling_interval

      while running? && remaining > 0 && @instant_repoll.false?
        Kernel.sleep SLEEP_SLICE
        remaining -= SLEEP_SLICE

        next unless notified?

        worker.log 'Job was announced, polling ahead of the interval', :debug
        break
      end

      # Time left on the clock means the sleep was cut short, which #poll
      # passes on as `count_failures: false`.
      @poll_brought_forward = remaining > 0
    end

    # Returns whether a job has been announced since this poller last looked,
    # and records what it saw.
    #
    # A worker with no idle thread deliberately leaves the token untouched, so
    # that the notification is still pending once it has capacity again.
    #
    # @return [Boolean]
    # @private
    def notified?
      return false unless worker.accepting_jobs?
      return false if worker.idle.zero?

      token = notifier_token

      return false if token.nil? || token == @last_notification

      @last_notification = token

      return true
    end

    # Reads the notifier's token, returning nil if it cannot be read.
    #
    # A notifier is an accelerator, so a broken one must cost latency rather
    # than take the worker down: anything raised here would reach the poller's
    # own rescue, which shuts the worker down. As this runs on every sleep
    # slice, the failure is reported once rather than many times a second.
    #
    # @return [Object, nil]
    # @private
    def notifier_token
      return Workhorse.notifier.token
    rescue StandardError => e
      message = "Reading the notifier failed, falling back to polling: #{e.class}: #{e.message}"

      if @notifier_failed
        worker.log message, :debug
      else
        @notifier_failed = true
        worker.log message, :warn
      end

      return nil
    end

    # Executes a block with a global database lock.
    # Supports both MySQL GET_LOCK and Oracle DBMS_LOCK.
    #
    # @param name [Symbol] Lock name identifier
    # @param timeout [Integer] Lock timeout in seconds
    # @param count_failures [Boolean] Whether a failure to obtain the lock
    #   counts towards {Workhorse.max_global_lock_fails}
    # @yield Block to execute while holding the lock
    # @return [void]
    # @private
    def with_global_lock(name: :workhorse, timeout: 2, count_failures: true, &_block)
      # Whole seconds, rounded up: MySQL and Oracle both take the timeout as an
      # integer and round a fraction of a second down to not waiting at all -
      # only MariaDB honours one. A poll finding the lock taken would then give
      # up at once, and count towards max_global_lock_fails for mere contention.
      timeout = timeout.ceil

      begin
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
        elsif !count_failures
          # Losing the race for the lock is the expected outcome when several
          # workers were woken by the same announcement, and says nothing about
          # a crashed worker. Counting it would let the alarm below fire within
          # seconds rather than after the polling intervals it is calibrated
          # for.
          worker.log 'Could not obtain global lock for a poll that was brought forward, skipping it.', :debug
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
      return unless worker.accepting_jobs?

      @instant_repoll.make_false

      # A poll the sleep cut short is not the scheduled one the lock-failure
      # alarm is calibrated against, see #with_global_lock.
      brought_forward = @poll_brought_forward
      @poll_brought_forward = false

      expired = []

      timeout = worker.polling_interval.clamp(MIN_LOCK_TIMEOUT, MAX_LOCK_TIMEOUT)
      with_global_lock timeout: timeout, count_failures: !brought_forward do
        job_ids = []

        materialize_schedules if Workhorse::Schedules.any? && @schedules_available
        expired = expire_due_jobs

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

          unless running? && worker.accepting_jobs?
            worker.log 'Rolling back transaction to unlock jobs, as worker is no longer accepting jobs'
            fail ActiveRecord::Rollback
          end
        end

        # This needs to be outside the above transaction because it runs the job
        # in a new thread which opens a new connection. Even though it would be
        # non-blocking and thus directly conclude the block and the transaction,
        # there would still be a risk that the transaction is not committed yet
        # when the job starts.
        # Also check accepting_jobs? to prevent posting if soft restart was requested
        # while we were acquiring the lock or querying jobs.
        job_ids.each { |job_id| worker.perform(job_id) } if running? && worker.accepting_jobs?
      end

      # Deliberately outside the global lock: the callback is the application's
      # and may do something slow, such as sending mail, which would otherwise
      # block every other worker's poll.
      notify_expired(expired)

      # Record that this worker successfully polled. Done at the very end so it
      # only advances when the poll actually completed (a poll that raises never
      # reaches here). Skipped on the early return above when the worker is no
      # longer accepting jobs, so a soft-restarting worker correctly ages out.
      worker.heartbeat!
    end

    # Materialises the occurrences that have come due into jobs.
    #
    # A failing schedule must not take the worker down with it, nor stop the
    # other schedules, so each is handled on its own.
    #
    # @return [void]
    # @private
    def materialize_schedules
      Workhorse::Schedule.due.to_a.each do |schedule|
        next if schedule.definition.nil?

        occurrences, next_at = schedule.pending_occurrences

        # The claim advances the schedule past these occurrences, so
        # committing it before the jobs exist would lose them for good if
        # enqueuing then failed - the schedule would move on and
        # DetectLateSchedulesJob would see nothing wrong.
        Workhorse.tx_callback.call do
          next unless schedule.claim!(next_at)

          occurrences.each do |occurrence|
            db_job = schedule.enqueue!(occurrence)
            worker.log "Materialized schedule #{schedule.key.inspect} for #{occurrence} as job #{db_job.id}", :debug
          end
        end

        @failed_schedules&.delete(schedule.key)
      rescue Exception => e
        report_schedule_failure(schedule, e)
      end

      return
    rescue Exception => e
      # The query itself failed, so no individual schedule can be blamed. This
      # must not reach the poller's own rescue, which shuts the worker down.
      worker.log %(Could not query due schedules: #{e.message}), :error
      Workhorse.on_exception.call(e)
    end

    # Reports a schedule that could not be materialized.
    #
    # Reported once per schedule per worker: a schedule that can never enqueue
    # - a renamed job class, params its constructor rejects - fails on every
    # poll, and one typo must not turn into a notification every polling
    # interval for as long as the worker runs.
    #
    # @param schedule [Workhorse::Schedule]
    # @param exception [Exception]
    # @return [void]
    # @private
    def report_schedule_failure(schedule, exception)
      message = %(Could not materialize schedule #{schedule.key.inspect}: #{exception.message})
      @failed_schedules ||= Set.new

      if @failed_schedules.include?(schedule.key)
        worker.log message, :debug
        return
      end

      @failed_schedules << schedule.key
      worker.log message, :error
      Workhorse.on_exception.call(exception)

      return
    end

    # Marks jobs that passed their deadline before any worker got to them.
    #
    # @return [Array<Workhorse::DbJob>] The jobs that were expired
    # @private
    def expire_due_jobs
      return [] unless expiry_supported?

      expired = []

      Workhorse.tx_callback.call do
        rel = Workhorse::DbJob.waiting.where(Workhorse::DbJob.arel_table[:expires_at].lteq(Time.now))

        # Bounded, as this runs while the poller holds the global lock: a
        # backlog of jobs that all expired at once - workers down over a
        # weekend, or a bulk enqueue - would otherwise turn one poll into
        # thousands of updates that block every other worker. The rest is
        # expired by the following polls, most overdue first.
        rel.order(:expires_at).limit(MAX_EXPIRIES_PER_POLL).each do |db_job|
          db_job.mark_expired!
          expired << db_job
          worker.log "Job #{db_job.id} passed its deadline of #{db_job.expires_at} and was not run", :warn
        end
      end

      return expired
    end

    # Calls {Workhorse.on_job_expired} for each expired job, keeping a failing
    # callback away from the poller's own error handling, which would shut the
    # worker down.
    #
    # @param expired [Array<Workhorse::DbJob>]
    # @return [void]
    # @private
    def notify_expired(expired)
      expired.each do |db_job|
        Workhorse.on_job_expired.call(db_job)
      rescue Exception => e
        worker.log %(on_job_expired failed for job #{db_job.id}: #{e.message}), :error
        Workhorse.on_exception.call(e)
      end

      return
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

        union_parts << limited_sql(select, record_number)
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
      union_query_sql += "SELECT * FROM (#{union_parts.shift}) union_0"
      union_parts.each_with_index do |part, idx|
        union_query_sql += " UNION SELECT * FROM (#{part}) union_#{idx + 1}"
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

      return Workhorse::DbJob.find_by_sql(limited_sql(select, limit)).to_a
    end

    # Returns a fresh Arel select manager containing the id of all waiting jobs.
    #
    # @return [Arel::SelectManager] the select manager
    def valid_select_id
      now = Time.now

      select = table.project(table[:id])
      select = select.where(table[:state].eq(:waiting))
      select = select.where(table[:perform_at].lteq(now).or(table[:perform_at].eq(nil)))

      # The deadline is enforced here and not only by #expire_due_jobs, which
      # expires at most MAX_EXPIRIES_PER_POLL jobs per poll: a larger backlog
      # would otherwise leave the surplus selectable and performed in the very
      # same poll, past the deadline the caller set.
      if expiry_supported?
        select = select.where(table[:expires_at].gt(now).or(table[:expires_at].eq(nil)))
      end

      return select
    end

    # Returns whether this installation has the columns the expiry feature
    # needs. They are absent until the migration adding them has been run.
    #
    # @return [Boolean]
    # @private
    def expiry_supported?
      return Workhorse::DbJob.column_names.include?('expires_at')
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

    # Returns the SQL of a select, limited to the given number of records.
    #
    # On Oracle this is `FETCH FIRST`, which applies after `ORDER BY`. Filtering
    # on `ROWNUM` instead - the only option before 12c - numbers the rows
    # before they are sorted, so it returned an arbitrary subset and ignored
    # the priority order altogether.
    #
    # @param select [Arel::SelectManager] the select manager to limit
    # @param number [Integer] the maximum number of records to return
    # @return [String] the resultant SQL
    def limited_sql(select, number)
      return "#{select.to_sql} FETCH FIRST #{Integer(number)} ROWS ONLY" if @is_oracle
      return select.take(number).to_sql
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

      # Note that `select_values` is used here on purpose: `execute` does not
      # return a result set on every adapter (the Oracle enhanced adapter, for
      # instance, returns `true` for queries), while `select_values` is
      # implemented in terms of `exec_query` and thus behaves the same on the
      # mysql2, trilogy and Oracle enhanced adapters.
      return Workhorse::DbJob.connection.select_values(queues.distinct.to_sql)
    end
  end
end
