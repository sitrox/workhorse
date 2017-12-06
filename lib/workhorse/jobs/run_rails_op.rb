module Workhorse::Jobs
  class RunRailsOp
    def initialize(cls, params = {})
      @cls = cls
      @params = params
    end

    def perform
      @cls.constantize.run!(@params)
    end
  end
end
