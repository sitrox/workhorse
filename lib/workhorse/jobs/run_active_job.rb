module Workhorse::Jobs
  class RunActiveJob
    def initialize(job_data)
      @job_data = job_data
    end

    def perform
      ActiveJob::Base.execute(@job_data)
    end
  end
end
