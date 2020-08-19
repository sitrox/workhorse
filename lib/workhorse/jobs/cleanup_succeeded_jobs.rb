module Workhorse::Jobs
  class CleanupSucceededJobs
    # Instantiates a new job.
    #
    # @param max_age [Integer] The maximal age of jobs to retain, in days. Will
    #   be evaluated at perform time.
    def initialize(max_age: 14)
      @max_age = max_age
    end

    def perform
      age_limit = seconds_ago(@max_age)
      Workhorse::DbJob.where(
        'STATE = ? AND UPDATED_AT <= ?', Workhorse::DbJob::STATE_SUCCEEDED, age_limit
      ).delete_all
    end

    private

    def seconds_ago(days)
      Time.now - days * 24 * 60 * 60
    end
  end
end
