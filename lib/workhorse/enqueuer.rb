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
    # @param expires_at [Time, nil] Deadline after which the job is no longer
    #   worth running. It is then set to state `expired` instead of being
    #   performed, and {Workhorse.on_job_expired} is called.
    # @param max_lateness [Numeric, nil] Seconds the job may start after its
    #   `perform_at` before {Workhorse.on_job_late} is called.
    # @return [Workhorse::DbJob] The created database job record
    def enqueue(job, queue: nil, priority: 0, perform_at: Time.now, description: nil,
                expires_at: nil, max_lateness: nil)
      attributes = {
        queue:       queue,
        priority:    priority,
        perform_at:  perform_at,
        description: description,
        handler:     Marshal.dump(job)
      }

      # Only set when used, so that an installation that has not run the
      # migration adding these columns keeps working as before.
      attributes[:expires_at] = expires_at if expires_at
      attributes[:max_lateness] = max_lateness if max_lateness

      return DbJob.create!(**attributes)
    end

    # Enqueues an ActiveJob job instance.
    #
    # @param job [ActiveJob::Base] The ActiveJob instance to enqueue
    # @param perform_at [Time] When to perform the job
    # @param queue [String, Symbol, nil] Optional queue override
    # @param description [String, nil] Optional job description
    # @return [Workhorse::DbJob] The created database job record
    def enqueue_active_job(job, perform_at: Time.now, queue: nil, description: nil,
                           expires_at: nil, max_lateness: nil)
      wrapper_job = Jobs::RunActiveJob.new(job.serialize)
      queue ||= job.queue_name if job.queue_name.present?
      db_job = enqueue(
        wrapper_job,
        queue:        queue,
        priority:     job.priority || 0,
        perform_at:   Time.at(perform_at),
        description:  description,
        expires_at:   expires_at,
        max_lateness: max_lateness
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

    # Enqueues a job given by class name, working out how it wants to be
    # instantiated: as a RailsOps operation, as an ActiveJob job, or as a
    # plain object responding to `perform`.
    #
    # @param job_class [String, Class] The job class
    # @param params [Hash] Operation params for RailsOps operations, keyword
    #   arguments to the constructor otherwise
    # @param options [Hash] Passed on to {#enqueue}
    # @return [Workhorse::DbJob] The created database job record
    def enqueue_job_class(job_class, params: {}, **options)
      cls = job_class.is_a?(String) ? job_class.constantize : job_class

      if defined?(RailsOps::Operation) && cls < RailsOps::Operation
        return enqueue_op(cls, options, params)
      elsif defined?(ActiveJob::Base) && cls < ActiveJob::Base
        job = params.present? ? cls.new(**params) : cls.new
        return enqueue_active_job(job, **options)
      else
        job = params.present? ? cls.new(**params) : cls.new
        return enqueue(job, **options)
      end
    end
  end
end
