module Workhorse::Jobs
  # Wrapper job for executing ActiveJob instances within Workhorse.
  # This job handles the deserialization and execution of ActiveJob jobs
  # that have been enqueued through the Workhorse adapter.
  #
  # @example Internal usage
  #   wrapper = RunActiveJob.new(job.serialize)
  #   wrapper.perform
  class RunActiveJob
    # @return [Hash] Serialized ActiveJob data
    attr_reader :job_data

    # Creates a new ActiveJob wrapper.
    #
    # @param job_data [Hash] Serialized ActiveJob data from job.serialize
    def initialize(job_data)
      @job_data = job_data
    end

    # Returns the ActiveJob class for this job.
    #
    # @return [Class, nil] The job class or nil if not found
    def job_class
      @job_data['job_class'].safe_constantize
    end

    # Executes the wrapped ActiveJob.
    #
    # @return [void]
    def perform
      ActiveJob::Base.execute(@job_data)
    end
  end
end
