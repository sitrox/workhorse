module Workhorse
  # Module providing job enqueuing functionality.
  # Extended by the main Workhorse module to provide enqueuing capabilities.
  # Supports plain Ruby objects, ActiveJob instances, and Rails operations.
  module Enqueuer
    # Enqueues any object that is serializable and has a `perform` method.
    #
    # @param job [Object] The job object to enqueue (must respond to #perform)
    # @param queue [String, Symbol, nil] The queue name
    # @param priority [Integer] Job priority (lower numbers = higher priority)
    # @param perform_at [Time] When to perform the job
    # @param description [String, nil] Optional job description
    # @return [Workhorse::DbJob] The created database job record
    def enqueue(job, queue: nil, priority: 0, perform_at: Time.now, description: nil)
      return DbJob.create!(
        queue:       queue,
        priority:    priority,
        perform_at:  perform_at,
        description: description,
        handler:     Marshal.dump(job)
      )
    end

    # Enqueues an ActiveJob job instance.
    #
    # @param job [ActiveJob::Base] The ActiveJob instance to enqueue
    # @param perform_at [Time] When to perform the job
    # @param queue [String, Symbol, nil] Optional queue override
    # @param description [String, nil] Optional job description
    # @return [Workhorse::DbJob] The created database job record
    def enqueue_active_job(job, perform_at: Time.now, queue: nil, description: nil)
      wrapper_job = Jobs::RunActiveJob.new(job.serialize)
      queue ||= job.queue_name if job.queue_name.present?
      db_job = enqueue(
        wrapper_job,
        queue:       queue,
        priority:    job.priority || 0,
        perform_at:  Time.at(perform_at),
        description: description
      )
      job.provider_job_id = db_job.id
      return db_job
    end

    # Enqueues the execution of a Rails operation by its class and parameters.
    #
    # @param cls [Class] The operation class to execute
    # @param args [Array] Variable arguments (workhorse_args, op_args)
    # @return [Workhorse::DbJob] The created database job record
    # @raise [ArgumentError] If wrong number of arguments provided
    def enqueue_op(cls, *args)
      case args.size
      when 0
        workhorse_args = {}
        op_args = {}
      when 1
        workhorse_args = args.first
        op_args = {}
      when 2
        workhorse_args, op_args = *args
      else
        fail ArgumentError, "wrong number of arguments (#{args.size + 1} for 2..3)"
      end

      job = Workhorse::Jobs::RunRailsOp.new(cls, op_args)
      enqueue job, **workhorse_args
    end
  end
end
