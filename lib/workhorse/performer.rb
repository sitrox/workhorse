module Workhorse
  # Executes individual jobs within worker processes.
  # The Performer handles job lifecycle management, error handling,
  # and integration with Rails application executors.
  #
  # @example Basic usage (typically called internally)
  #   performer = Workhorse::Performer.new(job_id, worker)
  #   performer.perform
  class Performer
    # @return [Workhorse::Worker] The worker that owns this performer
    attr_reader :worker

    # Creates a new performer for a specific job.
    #
    # @param db_job_id [Integer] The ID of the {Workhorse::DbJob} to perform
    # @param worker [Workhorse::Worker] The worker instance managing this performer
    def initialize(db_job_id, worker)
      @db_job = Workhorse::DbJob.find(db_job_id)
      @worker = worker
      @started = false
    end

    # Executes the job with full error handling and state management.
    # This method can only be called once per performer instance.
    #
    # @return [void]
    # @raise [RuntimeError] If called more than once
    def perform
      begin # rubocop:disable Style/RedundantBegin
        fail 'Performer can only run once.' if @started
        @started = true
        perform!
      rescue Exception => e
        Workhorse.on_exception.call(e)
      end
    end

    private

    # Internal job execution with thread-local performer tracking.
    # Wraps the job execution with Rails application executor if available.
    #
    # @return [void]
    # @raise [Exception] Any exception raised during job execution
    # @private
    def perform!
      begin # rubocop:disable Style/RedundantBegin
        Thread.current[:workhorse_current_performer] = self

        ActiveRecord::Base.connection_pool.with_connection do
          if defined?(Rails) && Rails.respond_to?(:application) && Rails.application && Rails.application.respond_to?(:executor)
            Rails.application.executor.wrap do
              perform_wrapped
            end
          else
            perform_wrapped
          end
        end
      rescue Exception => e
        # ---------------------------------------------------------------
        # Mark job as failed
        # ---------------------------------------------------------------
        log %(#{e.message}\n#{e.backtrace.join("\n")}), :error

        Workhorse.tx_callback.call do
          log 'Mark failed', :debug
          @db_job.mark_failed!(e)
        end

        fail e
      ensure
        Thread.current[:workhorse_current_performer] = nil
      end
    end

    # Core job execution logic with state transitions.
    # Handles marking job as started, deserializing and executing the job,
    # and marking as succeeded.
    #
    # @return [void]
    # @raise [Exception] Any exception raised during job execution
    # @private
    def perform_wrapped
      # ---------------------------------------------------------------
      # Mark job as started
      # ---------------------------------------------------------------
      Workhorse.tx_callback.call do
        log 'Marking as started', :debug
        @db_job.mark_started!
      end

      # ---------------------------------------------------------------
      # Deserialize and perform job
      # ---------------------------------------------------------------
      log 'Performing', :info
      log "Description: #{@db_job.description}", :info unless @db_job.description.blank?

      inner_job_class = deserialized_job.try(:job_class) || deserialized_job.class
      skip_tx = inner_job_class.try(:skip_tx?)

      if Workhorse.perform_jobs_in_tx && !skip_tx
        Workhorse.tx_callback.call do
          deserialized_job.perform
        end
      else
        deserialized_job.perform
      end

      log 'Successfully performed', :info

      # ---------------------------------------------------------------
      # Mark job as succeeded
      # ---------------------------------------------------------------
      Workhorse.tx_callback.call do
        log 'Mark succeeded', :debug
        @db_job.mark_succeeded!
      end
    end

    # Logs a message with job ID prefix.
    #
    # @param text [String] The message to log
    # @param level [Symbol] The log level
    # @return [void]
    # @private
    def log(text, level = :info)
      text = "[#{@db_job.id}] #{text}"
      worker.log text, level
    end

    # Deserializes the job from the database handler field.
    # Uses Marshal.load which is safe as long as jobs are enqueued through
    # {Workhorse::Enqueuer}.
    #
    # @return [Object] The deserialized job instance
    # @private
    def deserialized_job
      # The source is safe as long as jobs are always enqueued using
      # Workhorse::Enqueuer so it is ok to use Marshal.load.
      # rubocop: disable Security/MarshalLoad
      Marshal.load(@db_job.handler)
      # rubocop: enable Security/MarshalLoad
    end
  end
end
