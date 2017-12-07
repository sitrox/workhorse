module Workhorse::Jobs
  class RunRailsOp
    def initialize(cls, params = {})
      @cls = cls
      @params = params
    end

    def perform
      @cls.run!(@params)
    end
  end
end
