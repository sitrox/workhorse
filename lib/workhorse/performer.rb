# rubocop: disable Lint/RescueWithoutErrorClass
module Workhorse
  class Performer
    def initialize(db_job)
      @db_job = db_job
    end

    def perform
      # ---------------------------------------------------------------
      # Mark job as started
      # ---------------------------------------------------------------
      ActiveRecord::Base.t do
        @db_job.mark_started!
      end

      # ---------------------------------------------------------------
      # Deserialize and perform job
      # ---------------------------------------------------------------
      deserialized_job.perform

      # ---------------------------------------------------------------
      # Mark job as succeeded
      # ---------------------------------------------------------------
      ActiveRecord::Base.t do
        @db_job.mark_succeeded!
      end
    rescue => e
      # ---------------------------------------------------------------
      # Mark job as failed
      # ---------------------------------------------------------------
      # TODO: Log exception
      puts e.message.inspect.red
      ActiveRecord::Base.t do
        @db_job.mark_failed!(e)
      end
    end

    private

    def deserialized_job
      # The source is safe as long as jobs are always enqueued using
      # Workhorse::Enqueuer so it is ok to use Marshal.load.
      # rubocop: disable Security/MarshalLoad
      Marshal.load(@db_job.handler)
      # rubocop: enable Security/MarshalLoad
    end
  end
end
