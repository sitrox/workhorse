module Workhorse::Jobs
  # Job that detects and reports stale jobs in the system.
  # This monitoring job picks up jobs that remained `locked` or `started` (running) for
  # more than a certain amount of time. If any of these jobs are found, an
  # exception is thrown (which may cause a notification if you configured
  # {Workhorse.on_exception} accordingly).
  #
  # @example Schedule stale job detection with default thresholds
  #   Workhorse.enqueue(DetectStaleJobsJob.new)
  #
  # @example Schedule with custom thresholds
  #   Workhorse.enqueue(DetectStaleJobsJob.new(locked_to_started_threshold: 300, run_time_threshold: 3600))
  #
  # @example Only check specific queues
  #   Workhorse.enqueue(DetectStaleJobsJob.new(queues: ['mailer', 'reports']))
  class DetectStaleJobsJob
    # Creates a new stale job detection job.
    #
    # @param locked_to_started_threshold [Integer] Maximum number of seconds a job is
    #   allowed to stay 'locked' before an exception is raised. Set to 0 to skip this check.
    # @param run_time_threshold [Integer] Maximum number of seconds a job is allowed to
    #   run before an exception is raised. Set to 0 to skip this check.
    # @param queues [Array<String>, nil] If given, only check jobs in these queues.
    #   If `nil` (default), all queues are checked.
    def initialize(locked_to_started_threshold: 3 * 60, run_time_threshold: 12 * 60, queues: nil)
      @locked_to_started_threshold = locked_to_started_threshold
      @run_time_threshold          = run_time_threshold
      @queues                      = queues
    end

    # Executes the stale job detection.
    # Checks for jobs that have been locked or running too long and raises
    # an exception if any are found.
    #
    # @return [void]
    # @raise [RuntimeError] If stale jobs are detected
    def perform
      messages = []

      # Detect jobs that are locked for too long #
      if @locked_to_started_threshold != 0
        rel = Workhorse::DbJob.locked
        rel = rel.where('locked_at < ?', @locked_to_started_threshold.seconds.ago)
        rel = rel.where(queue: @queues) if @queues
        ids = rel.pluck(:id)

        unless ids.empty?
          messages << "Detected #{ids.size} jobs that were locked more than " \
                      "#{@locked_to_started_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      # Detect jobs that are running for too long #
      if @run_time_threshold != 0
        rel = Workhorse::DbJob.started
        rel = rel.where('started_at < ?', @run_time_threshold.seconds.ago)
        rel = rel.where(queue: @queues) if @queues
        ids = rel.pluck(:id)

        unless ids.empty?
          messages << "Detected #{ids.size} jobs that are running for longer than " \
                      "#{@run_time_threshold}s ago and might be stale: #{ids.inspect}."
        end
      end

      if messages.any?
        fail messages.join(' ')
      end
    end
  end
end
