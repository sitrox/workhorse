module Workhorse
  class Performer
    attr_reader :worker

    def initialize(db_job_id, worker)
      @db_job = Workhorse::DbJob.find(db_job_id)
      @worker = worker
      @started = false
    end

    def perform
      begin
        fail 'Performer can only run once.' if @started
        @started = true
        perform!
      rescue Exception => e
        Workhorse.on_exception.call(e)
      end
    end

    private

    def perform!
      begin
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

    def log(text, level = :info)
      text = "[#{@db_job.id}] #{text}"
      worker.log text, level
    end

    def deserialized_job
      # The source is safe as long as jobs are always enqueued using
      # Workhorse::Enqueuer so it is ok to use Marshal.load.
      # rubocop: disable Security/MarshalLoad
      Marshal.load(@db_job.handler)
      # rubocop: enable Security/MarshalLoad
    end
  end
end
