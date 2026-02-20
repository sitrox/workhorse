require 'active_record'
require 'active_support/all'
require 'concurrent'
require 'socket'
require 'uri'

require 'workhorse/enqueuer'
require 'workhorse/scoped_env'
require 'workhorse/active_job_extension'

# Main Gem module.
module Workhorse
  # Check if the available Arel version is greater or equal than 7.0.0
  AREL_GTE_7 = Gem::Version.new(Arel::VERSION) >= Gem::Version.new('7.0.0')

  extend Workhorse::Enqueuer

  # Returns the performer currently performing the active job.
  # This can only be called from within a job and the same thread.
  #
  # @return [Workhorse::Performer] The current performer instance
  # @raise [RuntimeError] If called outside of a job context
  def self.performer
    Thread.current[:workhorse_current_performer] \
      || fail('No performer is associated with the current thread. This method must always be called inside of a job.')
  end

  # Maximum number of consecutive global lock failures before triggering error handling.
  # A {Workhorse::Worker} will log an error and call the {.on_exception} callback if it can't
  # obtain the global lock for this many times in a row.
  #
  # @return [Integer] The maximum number of allowed consecutive lock failures
  mattr_accessor :max_global_lock_fails
  self.max_global_lock_fails = 10

  # Transaction callback used for database operations.
  # Defaults to ActiveRecord::Base.transaction.
  #
  # @return [Proc] The transaction callback
  mattr_accessor :tx_callback
  self.tx_callback = proc do |*args, &block|
    ActiveRecord::Base.transaction(*args, &block)
  end

  # Exception callback called when an exception occurs during job processing.
  # Override this to integrate with your error reporting system.
  #
  # @return [Proc] The exception callback
  mattr_accessor :on_exception
  self.on_exception = proc do |exception|
    # Do something with this exception, i.e.
    # ExceptionNotifier.notify_exception(exception)
  end

  # Controls whether {Workhorse::Daemon::ShellHandler} commands use lockfiles.
  # Set to false if you're handling locking yourself (e.g. in a wrapper script).
  #
  # @return [Boolean] Whether to lock shell commands
  mattr_accessor :lock_shell_commands
  self.lock_shell_commands = true

  # Controls whether to silence exception callbacks for {Workhorse::Poller} exceptions.
  # When true, {.on_exception} won't be called for poller failures, but exceptions
  # will still be logged.
  #
  # @return [Boolean] Whether to silence poller exception callbacks
  mattr_accessor :silence_poller_exceptions
  self.silence_poller_exceptions = false

  # Controls output verbosity for the watch command.
  # When true, the watch command won't produce output (warnings still shown).
  #
  # @return [Boolean] Whether to silence watcher output
  mattr_accessor :silence_watcher
  self.silence_watcher = false

  # Controls whether jobs are performed within database transactions.
  # Individual job classes can override this with skip_tx?.
  #
  # @return [Boolean] Whether to perform jobs in transactions
  mattr_accessor :perform_jobs_in_tx
  self.perform_jobs_in_tx = true

  # Controls automatic cleanup of stuck jobs on {Workhorse::Poller} startup.
  # When enabled, pollers will clean jobs stuck in 'locked' or 'running' states.
  #
  # @return [Boolean] Whether to clean stuck jobs on startup
  mattr_accessor :clean_stuck_jobs
  self.clean_stuck_jobs = false

  # This setting is for {Workhorse::Jobs::DetectStaleJobsJob} and specifies the
  # maximum number of seconds a job is allowed to stay 'locked' before this job
  # throws an exception. Set this to 0 to skip this check.
  mattr_accessor :stale_detection_locked_to_started_threshold
  self.stale_detection_locked_to_started_threshold = 3 * 60

  # This setting is for {Workhorse::Jobs::DetectStaleJobsJob} and specifies the
  # maximum number of seconds a job is allowed to run before this job throws an
  # exception. Set this to 0 to skip this check.
  mattr_accessor :stale_detection_run_time_threshold
  self.stale_detection_run_time_threshold = 12 * 60

  # Maximum memory usage per {Workhorse::Worker} process in MB.
  # When exceeded, the watch command will restart the worker. Set to 0 to disable.
  #
  # @return [Integer] Memory limit in megabytes
  mattr_accessor :max_worker_memory_mb
  self.max_worker_memory_mb = 0

  # Path to a debug log file for diagnosing log rotation and signal handling issues.
  # When set, Workhorse writes timestamped debug entries to this file at key points
  # (worker startup, HUP signal handling, restart-logging command flow).
  # Set to nil to disable (default).
  #
  # @return [String, nil] Path to debug log file
  mattr_accessor :debug_log_path
  self.debug_log_path = nil

  # Writes a debug message to the debug log file.
  # Does nothing if {.debug_log_path} is nil.
  # Silently ignores all exceptions to avoid interfering with normal operation.
  #
  # @param message [String] The message to log
  # @return [void]
  def self.debug_log(message)
    return unless debug_log_path

    File.open(debug_log_path, 'a') do |f|
      f.write("[#{Time.now.iso8601(3)}] [PID #{Process.pid}] #{message}\n")
      f.flush
    end
  rescue Exception # rubocop:disable Lint/SuppressedException
  end

  # Configuration method for setting up Workhorse options.
  #
  # @yield [self] Configuration block
  # @example
  #   Workhorse.setup do |config|
  #     config.max_global_lock_fails = 5
  #   end
  def self.setup
    yield self
  end
end

require 'workhorse/db_job'
require 'workhorse/performer'
require 'workhorse/poller'
require 'workhorse/pool'
require 'workhorse/worker'
require 'workhorse/jobs/run_rails_op'
require 'workhorse/jobs/run_active_job'
require 'workhorse/jobs/cleanup_succeeded_jobs'
require 'workhorse/jobs/detect_stale_jobs_job'

# Daemon functionality is not available on java platforms
if RUBY_PLATFORM != 'java'
  require 'workhorse/daemon'
  require 'workhorse/daemon/shell_handler'
end

if defined?(ActiveJob)
  require 'active_job/queue_adapters/workhorse_adapter'
end
