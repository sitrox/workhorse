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
    # Instantiates a new job.
    #
    # @param max_age [Integer] The maximal age of jobs to retain, in days. Will
    #   be evaluated at perform time.
    def initialize(max_age: 14)
      @max_age = max_age
    end

    # Executes the cleanup by deleting old succeeded jobs.
    #
    # @return [void]
    def perform
      age_limit = seconds_ago(@max_age)
      Workhorse::DbJob.where(
        'STATE = ? AND UPDATED_AT <= ?', Workhorse::DbJob::STATE_SUCCEEDED, age_limit
      ).delete_all
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
