Workhorse.setup do |config|
  # Set this to false in order to prevent jobs from being automatically
  # wrapped into a transaction. The built-in workhorse logic will still run
  # in transactions.
  #
  # config.perform_jobs_in_tx = true

  # Enable and configure this to specify an alternative callback for handling
  # transactions.
  #
  # self.tx_callback = proc do |*args, &block|
  #   ActiveRecord::Base.transaction(*args, &block)
  # end

  # Set this to false in order to disable file-based locking for the Workhorse
  # shell handlers (all the commands such as 'start', 'stop', ...).
  # config.lock_shell_commands = true

  # Enable and configure this to specify a callback for handling worker
  # exceptions:
  #
  # config.on_exception = proc do |exception|
  #   # Do something with exception, i.e.
  #   # ExceptionNotifier.notify_exception(exception)
  # end

  # Enable this to let an enqueued job start without waiting for the next
  # poll. Use :file where the workers share a filesystem with the application
  # and :redis where they do not. Polling stays the floor either way, so raise
  # the polling interval only as far as you are willing to wait when a
  # notification is missed.
  #
  # config.notifier = :file
  # config.notification_path = Rails.root.join('tmp', 'pids', 'workhorse.wake')
  #
  # config.notifier = :redis
  # config.notification_redis = -> { Redis.new(url: ENV['REDIS_URL']) }
  # config.notification_channel = 'workhorse:jobs'

  # Enable and configure these to be told about a job that passed its
  # `expires_at` before any worker got to it, and about one that started later
  # than its `max_lateness` allows. Neither can affect the worker or the job.
  #
  # config.on_job_expired = proc do |db_job|
  #   # Do something with the job, i.e.
  #   # ExceptionNotifier.notify_exception(
  #   #   StandardError.new("Job #{db_job.id} (#{db_job.description}) expired")
  #   # )
  # end
  #
  # config.on_job_late = proc do |db_job, lateness|
  #   # Do something with the job, i.e.
  #   # ExceptionNotifier.notify_exception(
  #   #   StandardError.new("Job #{db_job.id} started #{lateness.round}s late")
  #   # )
  # end
end

# Jobs that run on a schedule. Each of these owns a row in the
# `workhorse_schedules` table holding the next occurrence that has not been
# materialized yet, so an occurrence whose time passes while nothing is
# running is not lost. See the README for the catch-up policies.
#
# Workhorse.schedules do
#   schedule 'cleanup_jobs',
#            job:  'Workhorse::Jobs::CleanupSucceededJobs',
#            cron: '10 0 * * *'
#
#   schedule 'detect_stale_jobs',
#            job:  'Workhorse::Jobs::DetectStaleJobsJob',
#            cron: '30 * * * *'
# end
