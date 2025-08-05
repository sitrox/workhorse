module Workhorse::Jobs
  # Job wrapper for executing Rails operations (trailblazer-operation or similar).
  # This job allows enqueuing of operation classes with parameters for later execution.
  #
  # @example Enqueue an operation
  #   Workhorse.enqueue_op(MyOperation, { user_id: 123 })
  #
  # @example Manual instantiation
  #   job = RunRailsOp.new(MyOperation, { user_id: 123 })
  #   Workhorse.enqueue(job)
  class RunRailsOp
    # Creates a new Rails operation job.
    #
    # @param cls [Class] The operation class to execute
    # @param params [Hash] Parameters to pass to the operation
    def initialize(cls, params = {})
      @cls = cls
      @params = params
    end

    # Returns the operation class for this job.
    #
    # @return [Class] The operation class
    def job_class
      @cls
    end

    # Executes the Rails operation with the provided parameters.
    #
    # @return [void]
    def perform
      @cls.run!(@params)
    end
  end
end
