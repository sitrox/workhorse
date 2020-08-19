module Workhorse::Jobs
  class DetectStaleJobsJob
    # Instantiates a new stale detection job.
    #
    # @param locked_to_started_threshold [Integer] The maximum number of seconds
    #   a job is allowed to stay 'locked' before this job throws an exception.
    #   Set this to 0 to skip this check.
    # @param run_time_threshold [Integer] The maximum number of seconds
    #   a job is allowed to run before this job throws an exception. Set this to
    #   0 to skip this check.
    def initialize(locked_to_started_threshold: 3 * 60, run_time_threshold: 12 * 60)
      @locked_to_started_threshold = locked_to_started_threshold
      @run_time_threshold = run_time_threshold
    end

    def perform
      messages = []

      # Detect jobs that are locked for too long #
      if @locked_to_started_threshold != 0
        rel = Workhorse::DbJob.locked
        rel = rel.where('locked_at < ?', @locked_to_started_threshold.seconds.ago)
        ids = rel.pluck(:id)

        if ids.size > 0
          messages << "Detected #{ids.size} jobs that were locked more than "\
                      "#{@locked_to_started_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      # Detect jobs that are running for too long #
      if @run_time_threshold != 0
        rel = Workhorse::DbJob.started
        rel = rel.where('started_at < ?', @run_time_threshold.seconds.ago)
        ids = rel.pluck(:id)

        if ids.size > 0
          messages << "Detected #{ids.size} jobs that are running for longer than "\
                      "#{@run_time_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      if messages.any?
        fail messages.join(' ')
      end
    end
  end
end
