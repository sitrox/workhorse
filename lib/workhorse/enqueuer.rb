module Workhorse
  class Enqueuer
    # Enqueue any object that is serializable and has a `perform` method
    def self.enqueue(job, queue: nil)
      return DbJob.create!(
        queue: queue,
        handler: Marshal.dump(job)
      )
    end

    # Enqueue an ActiveJob job
    def self.enqueue_active_job(job)
      enqueue job, queue: job.queue_name
    end

    # Enqueue the execution of an operation by its class and params
    def self.enqueue_op(cls, params, queue: nil)
      job = Workhorse::Jobs::RunRailsOp.new(cls, params)
      enqueue job, queue: queue
    end
  end
end