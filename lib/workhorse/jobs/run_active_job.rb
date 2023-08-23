module Workhorse::Jobs
  class RunActiveJob
    attr_reader :job_data

    def initialize(job_data)
      @job_data = job_data
    end

    def job_class
      @job_data['job_class'].safe_constantize
    end

    def perform
      ActiveJob::Base.execute(@job_data)
    end
  end
end
