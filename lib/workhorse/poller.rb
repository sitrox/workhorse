module Workhorse
  class Poller
    attr_reader :worker

    def initialize(worker)
      @worker = worker
      @running = false
    end

    def running?
      @running
    end

    def start
      fail 'Poller is already running.' if running?
      @running = true

      @thread = Thread.new do
        loop do
          poll

          if running?
            sleep worker.polling_interval
          else
            break
          end
        end
      end
    end

    def shutdown
      fail 'Poller is not running.' unless running?
      @running = false
    end

    def wait
      @thread.join
    end

    private

    def poll
      Tx.t do
        remaining_capacity = worker.remaining_capacity
        worker.log "Polling DB for jobs (#{remaining_capacity} available threads)...", :debug

        unless remaining_capacity.zero?
          jobs = queued_db_jobs(remaining_capacity)
          jobs.each do |job|
            worker.log "Marking job #{job.id} as locked", :debug
            job.mark_locked!(worker.id)
            worker.perform job
          end
        end
      end
    end

    def queued_db_jobs(limit)
      # ---------------------------------------------------------------
      # Lock all queued jobs that are not complete
      # ---------------------------------------------------------------
      Workhorse::DbJob.connection.execute(%(
        SELECT NULL FROM JOBS
        WHERE QUEUE IS NOT NULL
        AND STATE != 'succeeded' AND STATE != 'failed'
        FOR UPDATE
      ))

      # ---------------------------------------------------------------
      # Select jobs to execute
      # ---------------------------------------------------------------
      rel = Workhorse::DbJob.all
      rel.where!('LOCKED_AT IS NULL')

      if worker.queues.any?
        rel.where!(%(
          QUEUE IS NOT NULL OR QUEUE IN (
            SELECT DISTINCT QUEUE FROM JOBS WHERE STATE != ?
          )
        ), Workhorse::DbJob::STATE_WAITING)
        rel.where!('QUEUE IS NULL OR QUEUE IN (?)', worker.queues)
      else
        rel.where!('QUEUE IS NULL')
      end

      rel.order!(created_at: :asc)
      rel.lock!

      rel.where!('ROWNUM <= ?', limit)

      return rel
    end
  end
end
