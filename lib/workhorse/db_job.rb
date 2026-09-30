module Workhorse
  # ActiveRecord model representing a job in the database.
  # This class manages the job lifecycle and state transitions within the Workhorse system.
  #
  # @example Creating a job
  #   job = DbJob.create!(
  #     queue: 'default',
  #     handler: Marshal.dump(job_instance),
  #     priority: 0
  #   )
  #
  # @example Querying jobs by state
  #   waiting_jobs = DbJob.waiting
  #   failed_jobs = DbJob.failed
  class DbJob < ActiveRecord::Base
    STATE_WAITING   = :waiting
    STATE_LOCKED    = :locked
    STATE_STARTED   = :started
    STATE_SUCCEEDED = :succeeded
    STATE_FAILED    = :failed
    STATE_EXPIRED   = :expired

    EXP_LOCKED_BY = /^(.*?)\.(\d+?)\.([^.]+)$/

    if respond_to?(:attr_accessible)
      attr_accessible :queue, :priority, :perform_at, :handler, :description,
                      :expires_at, :max_lateness
    end

    self.table_name = 'jobs'

    # Notifying before the commit would wake a worker that cannot see the row
    # yet, sending it back to sleep for a whole polling interval - the very
    # delay the notification exists to avoid.
    after_commit :notify_workers, on: :create

    # Returns jobs in waiting state.
    #
    # @return [ActiveRecord::Relation] Jobs waiting to be processed
    def self.waiting
      where(state: STATE_WAITING)
    end

    # Returns jobs in locked state.
    #
    # @return [ActiveRecord::Relation] Jobs currently locked by workers
    def self.locked
      where(state: STATE_LOCKED)
    end

    # Returns jobs in started state.
    #
    # @return [ActiveRecord::Relation] Jobs currently being executed
    def self.started
      where(state: STATE_STARTED)
    end

    # Returns jobs in succeeded state.
    #
    # @return [ActiveRecord::Relation] Jobs that completed successfully
    def self.succeeded
      where(state: STATE_SUCCEEDED)
    end

    # Returns jobs in failed state.
    #
    # @return [ActiveRecord::Relation] Jobs that failed during execution
    def self.failed
      where(state: STATE_FAILED)
    end

    # Returns jobs that passed their deadline and were therefore not run.
    #
    # @return [ActiveRecord::Relation] Jobs that expired before being started
    def self.expired
      where(state: STATE_EXPIRED)
    end

    # Marks the job as expired, having passed its deadline before any worker
    # got to it.
    #
    # @raise [RuntimeError] If the job is not in waiting state
    # @private Only to be used by workhorse
    def mark_expired!
      assert_state! STATE_WAITING

      self.state = STATE_EXPIRED
      save!
    end

    # Returns how much later than intended this job started, or nil if it has
    # not started or was not given an intended time.
    #
    # @return [Float, nil] Lateness in seconds
    def lateness
      return nil unless started_at && perform_at

      return started_at - perform_at
    end

    # Returns a relation with split locked_by field for easier querying.
    # Extracts host, PID, and random string components from locked_by.
    #
    # `locked_by` is "<host>.<pid>.<random>", and the host may itself contain
    # dots, so both dialects below work backwards from the last two.
    #
    # @return [ActiveRecord::Relation] Relation with additional computed columns
    # @private
    def self.with_split_locked_by
      return select(oracle? ? split_locked_by_sql_oracle : split_locked_by_sql_mysql)
    end

    # @return [Boolean] Whether the connection speaks Oracle
    # @private
    def self.oracle?
      return connection.adapter_name == 'OracleEnhanced'
    end

    # @return [String]
    # @private
    def self.split_locked_by_sql_mysql
      return <<~SQL
        #{table_name}.*,

        -- random string
        substring_index(locked_by, '.', -1) as locked_by_rnd,

        -- pid
        substring_index(
          substring_index(locked_by, '.', -2),
          '.',
          1
        ) as locked_by_pid,

        -- get host
        substring(
          locked_by,
          1,
          length(locked_by) -
          length(substring_index(locked_by, '.', -2)) - 1
        ) as locked_by_host
      SQL
    end

    # Oracle has no `substring_index`. `instr` with a negative position counts
    # occurrences from the right, which gives the two delimiters directly.
    #
    # @return [String]
    # @private
    def self.split_locked_by_sql_oracle
      return <<~SQL
        #{table_name}.*,

        -- random string
        substr(locked_by, instr(locked_by, '.', -1, 1) + 1) as locked_by_rnd,

        -- pid
        substr(
          locked_by,
          instr(locked_by, '.', -1, 2) + 1,
          instr(locked_by, '.', -1, 1) - instr(locked_by, '.', -1, 2) - 1
        ) as locked_by_pid,

        -- get host
        substr(locked_by, 1, instr(locked_by, '.', -1, 2) - 1) as locked_by_host
      SQL
    end

    # Resets job to state "waiting" and clears all meta fields
    # set by workhorse in course of processing this job.
    #
    # This is only allowed if the job is in a final state ("succeeded",
    # "failed" or "expired"), as only those jobs are safe to modify; workhorse
    # will not touch these jobs. To reset a job without checking the state it
    # is in, set
    # "force" to true. Prior to doing so, ensure that the job is not still being
    # processed by a worker. If possible, shut down all workers before
    # performing a forced reset.
    #
    # After the job is reset, it will be performed again. If you reset a job
    # that has already been performed ("succeeded") or partially performed
    # ("failed"), make sure the actions performed in the job are repeatable or
    # have been rolled back. E.g. if the job already wrote something to an
    # external API, it may cause inconsistencies if the job is performed again.
    #
    # @param force [Boolean] Whether to force reset without state validation
    # @raise [RuntimeError] If job is not in a final state and force is false
    def reset!(force = false)
      unless force
        assert_state! STATE_SUCCEEDED, STATE_FAILED, STATE_EXPIRED
      end

      self.state = STATE_WAITING
      self.locked_at = nil
      self.locked_by = nil
      self.started_at = nil
      self.succeeded_at = nil
      self.failed_at = nil
      self.last_error = nil

      save!
    end

    # Marks the job as locked by a specific worker.
    #
    # @param worker_id [String] The ID of the worker locking this job
    # @raise [RuntimeError] If the job is dirty or already locked
    # @private Only to be used by workhorse
    def mark_locked!(worker_id)
      if changed?
        fail "Dirty jobs can't be locked."
      end

      if locked_at
        fail "Job #{id} is already locked by #{locked_by.inspect}."
      end

      self.locked_at = Time.now
      self.locked_by = worker_id
      self.state     = STATE_LOCKED
      save!
    end

    # Marks the job as started.
    #
    # @raise [RuntimeError] If the job is not in locked state
    # @private Only to be used by workhorse
    def mark_started!
      assert_state! STATE_LOCKED

      self.started_at = Time.now
      self.state      = STATE_STARTED
      save!
    end

    # Marks the job as failed with the given exception.
    #
    # @param exception [Exception] The exception that caused the failure
    # @raise [RuntimeError] If the job is not in locked or started state
    # @private Only to be used by workhorse
    def mark_failed!(exception)
      assert_state! STATE_LOCKED, STATE_STARTED

      self.failed_at  = Time.now
      self.last_error = %(#{exception.message}\n#{exception.backtrace.join("\n")})
      self.state      = STATE_FAILED
      save!
    end

    # Marks the job as succeeded.
    #
    # @raise [RuntimeError] If the job is not in started state
    # @private Only to be used by workhorse
    def mark_succeeded!
      assert_state! STATE_STARTED

      self.succeeded_at = Time.now
      self.state        = STATE_SUCCEEDED
      save!
    end

    # Announces this job to waiting workers, see {Workhorse.notifier}.
    #
    # Jobs that are not due yet are not announced: a woken worker would find
    # nothing to do. They are picked up by the regular poll once their
    # `perform_at` has passed.
    #
    # @return [void]
    # @private
    def notify_workers
      return if perform_at && perform_at > Time.now

      Workhorse.notifier.notify(queue: queue)

      return
    end

    # Asserts that the job is in one of the specified states.
    #
    # @param states [Array<Symbol>] Valid states for the job
    # @raise [RuntimeError] If the job is not in any of the specified states
    def assert_state!(*states)
      unless states.include?(state.to_sym)
        fail "Job #{id} is not in state #{states.inspect} but in state #{state.inspect}."
      end
    end
  end

  ActiveSupport.run_load_hooks(:workhorse_db_job, DbJob)
end
