module Workhorse
  class DbJob < ActiveRecord::Base
    STATE_WAITING   = :waiting
    STATE_LOCKED    = :locked
    STATE_STARTED   = :started
    STATE_SUCCEEDED = :succeeded
    STATE_FAILED    = :failed

    self.table_name = 'jobs'

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

    def mark_started!
      assert_state! STATE_LOCKED

      self.started_at = Time.now
      self.state      = STATE_STARTED
      save!
    end

    def mark_failed!(exception)
      assert_state! STATE_LOCKED, STATE_STARTED

      self.failed_at  = Time.now
      self.last_error = %(#{exception.message}\n#{exception.backtrace.join("\n")})
      self.state      = STATE_FAILED
      save!
    end

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

    def assert_locked_by!(worker_id)
      assert_state! STATE_WAITING

      if locked_by.nil?
        fail "Job #{id} is not locked by any worker."
      elsif locked_by != worker_id
        fail "Job #{id} is locked by another worker (#{locked_by})."
      end
    end
  end
end
