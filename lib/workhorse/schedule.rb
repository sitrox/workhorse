module Workhorse
  # A schedule's persisted state: which occurrence is next.
  #
  # This is what makes a scheduled job survive a process that is not running
  # when its time comes. An in-memory scheduler computes the next occurrence
  # from *now*, so an occurrence that passes while it is down never happens and
  # leaves no trace. Here the next occurrence is a row, so a worker that comes
  # back at any later point still sees that it is due and applies the
  # schedule's catch-up policy to it.
  #
  # Rows are reconciled from {Workhorse::Schedules} on worker startup and are
  # materialised into jobs during {Workhorse::Poller#poll}.
  class Schedule < ActiveRecord::Base
    self.table_name = 'workhorse_schedules'

    # Returns the schedules whose next occurrence has come.
    #
    # @param now [Time]
    # @return [ActiveRecord::Relation]
    def self.due(now = Time.now)
      return where(enabled: true).where(arel_table[:next_at].lteq(now))
    end

    # Brings the table in line with the registry: inserts schedules that are
    # new, recomputes the next occurrence of those whose cron expression or
    # timezone changed, and deletes those that are gone.
    #
    # Safe to call from several workers at once, as each step is idempotent
    # and a lost race leaves the table in the same state.
    #
    # @param now [Time]
    # @return [void]
    def self.reconcile!(now = Time.now)
      definitions = Workhorse::Schedules.definitions

      definitions.each_value do |definition|
        record = find_by(key: definition.key)

        if record.nil?
          # A new schedule does not fire immediately: its first occurrence is
          # the next one the expression produces.
          create!(
            key:      definition.key,
            cron:     definition.cron,
            timezone: definition.timezone,
            next_at:  definition.parsed_cron.next_time(now).to_t
          )
        elsif record.cron != definition.cron || record.timezone != definition.timezone
          record.update!(
            cron:     definition.cron,
            timezone: definition.timezone,
            next_at:  definition.parsed_cron.next_time(now).to_t
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # Another worker inserted the same schedule first, which is the
        # outcome this would have produced anyway.
        nil
      end

      obsolete = where.not(key: definitions.keys)
      obsolete = all if definitions.empty?
      obsolete.delete_all

      return
    end

    # @return [Workhorse::Schedules::Definition, nil] The registry entry
    def definition
      return Workhorse::Schedules[key]
    end

    # Returns the occurrences that are due, according to the schedule's
    # catch-up policy, together with the occurrence to wait for next.
    #
    # @param now [Time]
    # @return [Array(Array<Time>, Time)] Occurrences to enqueue and the new
    #   `next_at`.
    def pending_occurrences(now = Time.now)
      cron = definition.parsed_cron
      occurrences = []
      cursor = next_at

      # Walking occurrence by occurrence rather than jumping to the next one
      # after `now`, so that a policy can see how many were missed. Bounded by
      # the cap below, as a year-long outage of a per-minute schedule would
      # otherwise produce half a million timestamps.
      while cursor <= now && occurrences.size <= MAX_OCCURRENCE_SCAN
        occurrences << cursor
        cursor = cron.next_time(cursor).to_t
      end

      # The scan hit its cap, so skip ahead instead of walking the rest.
      cursor = cron.next_time(now).to_t if cursor <= now

      return [apply_catch_up(occurrences, now), cursor]
    end

    # Most occurrences {#pending_occurrences} walks before giving up and
    # skipping to the next one after now.
    MAX_OCCURRENCE_SCAN = 10_000

    # Claims this schedule by advancing it to `next_at`, and reports whether
    # the claim succeeded.
    #
    # Written as a compare-and-swap rather than a plain update so that exactly
    # one worker materializes an occurrence even if the claim is ever made
    # without the global lock the poller currently holds.
    #
    # @param new_next_at [Time]
    # @return [Boolean]
    # rubocop:disable Naming/PredicateMethod -- reports whether the mutation
    # took effect, which a predicate name would misrepresent as a question.
    def claim!(new_next_at)
      claimed = self.class
                    .where(id: id, next_at: next_at)
                    .update_all(next_at: new_next_at, updated_at: Time.now)

      return claimed == 1
    end
    # rubocop:enable Naming/PredicateMethod

    # Enqueues the job for the given occurrence.
    #
    # `perform_at` is the occurrence's own time rather than the current one,
    # so that the job carries the moment it was meant to run. The difference
    # to `started_at` is then the lateness of that occurrence, which is what
    # {Workhorse.on_job_late} and any reporting on the table can go by.
    #
    # @param occurrence [Time]
    # @return [Workhorse::DbJob]
    def enqueue!(occurrence)
      db_job = Workhorse.enqueue_job_class(
        definition.job,
        queue:        definition.queue,
        priority:     definition.priority,
        perform_at:   occurrence,
        description:  definition.description || "#{definition.job} (#{key})",
        params:       definition.params,
        max_lateness: definition.max_lateness,
        expires_at:   definition.expires_after ? occurrence + definition.expires_after : nil
      )

      update_columns(
        last_enqueued_at: Time.now,
        last_occurrence:  occurrence,
        last_job_id:      db_job.id,
        updated_at:       Time.now
      )

      return db_job
    end

    private

    # Applies the catch-up policy to the occurrences that are due.
    #
    # @param occurrences [Array<Time>]
    # @param now [Time]
    # @return [Array<Time>]
    def apply_catch_up(occurrences, now)
      return occurrences if occurrences.empty?

      case definition.catch_up
      when :run
        return occurrences.last(definition.max_catch_up)
      when :run_once
        return occurrences.last(1)
      when :skip
        return occurrences.last(1).select { |occurrence| now - occurrence <= definition.grace }
      else
        return []
      end
    end
  end
end
