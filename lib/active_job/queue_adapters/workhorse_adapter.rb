module ActiveJob
  module QueueAdapters
    # Workhorse adapter for ActiveJob.
    #
    # Workhorse is a multi-threaded job backend with database queuing for Ruby.
    # Jobs are persisted in the database using ActiveRecord.
    # Read more about Workhorse {here}[https://github.com/sitrox/workhorse].
    #
    # To use Workhorse, set the queue_adapter config to +:workhorse+.
    #
    #   Rails.application.config.active_job.queue_adapter = :workhorse
    #
    # @example Configuration
    #   Rails.application.config.active_job.queue_adapter = :workhorse
    class WorkhorseAdapter
      # Defines whether enqueuing should happen implicitly to after commit when called
      # from inside a transaction. Most adapters should return true, but some adapters
      # that use the same database as Active Record and are transaction aware can return
      # false to continue enqueuing jobs as part of the transaction.
      #
      # @return [Boolean] False because Workhorse is transaction-aware
      def enqueue_after_transaction_commit?
        false
      end

      # Enqueues a job for immediate execution.
      #
      # @param job [ActiveJob::Base] The job to enqueue
      # @return [Workhorse::DbJob] The created database job record
      # @api private
      def enqueue(job)
        Workhorse.enqueue_active_job(job)
      end

      # Enqueues a job for execution at a specific time.
      #
      # @param job [ActiveJob::Base] The job to enqueue
      # @param timestamp [Time] When to execute the job
      # @return [Workhorse::DbJob] The created database job record
      # @api private
      def enqueue_at(job, timestamp = Time.now)
        Workhorse.enqueue_active_job(job, perform_at: timestamp)
      end
    end
  end
end
