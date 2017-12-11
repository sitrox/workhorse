module Workhorse
  class Performer
    attr_reader :worker

    def initialize(db_job, worker)
      @db_job = db_job
      @worker = worker
      @started = false
    end

    def perform
      fail 'Performer can only run once.' if @started
      @started = true
      perform!
    end

    private

    def perform!
      Thread.current[:workhorse_current_performer] = self

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

      if Workhorse.perform_jobs_in_tx
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
    rescue => e
      # ---------------------------------------------------------------
      # Mark job as failed
      # ---------------------------------------------------------------
      log %(#{e.message}\n#{e.backtrace.join("\n")}), :error

      Workhorse.tx_callback.call do
        log 'Mark failed', :debug
        @db_job.mark_failed!(e)
      end
    ensure
      Thread.current[:workhorse_current_performer] = nil
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
