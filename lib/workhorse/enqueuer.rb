module Workhorse
  module Enqueuer
    # Enqueue any object that is serializable and has a `perform` method
    def enqueue(job, queue: nil)
      return DbJob.create!(
        queue: queue,
        handler: Marshal.dump(job)
      )
    end

    # Enqueue an ActiveJob job
    def enqueue_active_job(job)
      enqueue job, queue: job.queue_name
    end

    # Enqueue the execution of an operation by its class and params
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
      enqueue job, workhorse_args
    end
  end
end
