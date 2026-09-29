module Workhorse::Jobs
  # Job for cleaning up old succeeded jobs from the database.
  # This maintenance job helps keep the jobs table from growing indefinitely
  # by removing successfully completed jobs older than a specified age.
  #
  # @example Schedule cleanup job
  #   Workhorse.enqueue(CleanupSucceededJobs.new(max_age: 30))
  #
  # @example Daily cleanup with cron
  #   # Clean up jobs older than 14 days every day at 2 AM
  #   Workhorse.enqueue(CleanupSucceededJobs.new, perform_at: 1.day.from_now.beginning_of_day + 2.hours)
  class CleanupSucceededJobs
    # States that are cleaned up unless told otherwise. Both are terminal and
    # will never run again; `expired` is included so that a schedule using
    # `expires_after` and regularly missing its window - the very case the
    # option exists for - cannot grow the table without bound.
    DEFAULT_STATES = [
      Workhorse::DbJob::STATE_SUCCEEDED,
      Workhorse::DbJob::STATE_EXPIRED
    ].freeze

    # Instantiates a new job.
    #
    # @param max_age [Integer] The maximal age of jobs to retain, in days. Will
    #   be evaluated at perform time.
    # @param states [Array<Symbol>] The job states to clean up. Defaults to
    #   {DEFAULT_STATES}. Pass `[Workhorse::DbJob::STATE_SUCCEEDED]` to keep
    #   expired jobs around.
    def initialize(max_age: 14, states: DEFAULT_STATES)
      @max_age = max_age
      @states = states
    end

    # Executes the cleanup by deleting old jobs in the configured states.
    #
    # @return [void]
    def perform
      age_limit = seconds_ago(@max_age)

      # An instance of this job enqueued before the upgrade unmarshals without
      # @states, and `where(state: nil)` would quietly match nothing - leaving
      # the table growing, which is what this job is for.
      Workhorse::DbJob.where(state: @states || DEFAULT_STATES)
                      .where('UPDATED_AT <= ?', age_limit)
                      .delete_all
    end

    private

    # Calculates a timestamp for the given number of days ago.
    #
    # @param days [Integer] Number of days in the past
    # @return [Time] Timestamp for the specified days ago
    # @private
    def seconds_ago(days)
      Time.now - (days * 24 * 60 * 60)
    end
  end
end
