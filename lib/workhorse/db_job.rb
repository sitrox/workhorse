module Workhorse
  class DbJob < ActiveRecord::Base
    STATE_WAITING   = :waiting
    STATE_LOCKED    = :locked
    STATE_STARTED   = :started
    STATE_SUCCEEDED = :succeeded
    STATE_FAILED    = :failed

    if respond_to?(:attr_accessible)
      attr_accessible :queue, :priority, :perform_at, :handler
    end

    self.table_name = 'jobs'

    def self.waiting
      where(state: STATE_WAITING)
    end

    def self.locked
      where(state: STATE_LOCKED)
    end

    def self.started
      where(state: STATE_STARTED)
    end

    def self.succeeded
      where(state: STATE_SUCCEEDED)
    end

    def self.failed
      where(state: STATE_FAILED)
    end

    # Resets job to state "waiting" and clears all meta fields
    # set by workhorse in course of processing this job.
    #
    # This is only allowed if the job is in a final state ("succeeded" or
    # "failed"), as only those jobs are safe to modify; workhorse will not touch
    # these jobs. To reset a job without checking the state it is in, set
    # "force" to true. Prior to doing so, ensure that the job is not still being
    # processed by a worker. If possible, shut down all workers before
    # performing a forced reset.
    #
    # After the job is reset, it will be performed again. If you reset a job
    # that has already been performed ("succeeded") or partially performed
    # ("failed"), make sure the actions performed in the job are repeatable or
    # have been rolled back. E.g. if the job already wrote something to an
    # external API, it may cause inconsistencies if the job is performed again.
    def reset!(force = false)
      unless force
        assert_state! STATE_SUCCEEDED, STATE_FAILED
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

    # @private Only to be used by workhorse
    def mark_locked!(worker_id)
      if changed?
        fail "Dirty jobs can't be locked."
      end

      # TODO: Remove this debug output
      # if Workhorse::DbJob.lock.find(id).locked_at
      #   puts "Already locked (with FOR UPDATE)"
      # end

      if locked_at
        # TODO: Remove this debug output
        # puts "Already locked. Job: #{self.id} Worker: #{worker_id}"
        fail "Job #{id} is already locked by #{locked_by.inspect}."
      end

      self.locked_at = Time.now
      self.locked_by = worker_id
      self.state     = STATE_LOCKED
      save!
    end

    # @private Only to be used by workhorse
    def mark_started!
      assert_state! STATE_LOCKED

      self.started_at = Time.now
      self.state      = STATE_STARTED
      save!
    end

    # @private Only to be used by workhorse
    def mark_failed!(exception)
      assert_state! STATE_LOCKED, STATE_STARTED

      self.failed_at  = Time.now
      self.last_error = %(#{exception.message}\n#{exception.backtrace.join("\n")})
      self.state      = STATE_FAILED
      save!
    end

    # @private Only to be used by workhorse
    def mark_succeeded!
      assert_state! STATE_STARTED

      self.succeeded_at = Time.now
      self.state        = STATE_SUCCEEDED
      save!
    end

    def assert_state!(*states)
      unless states.include?(state.to_sym)
        fail "Job #{id} is not in state #{states.inspect} but in state #{state.inspect}."
      end
    end
  end
end
