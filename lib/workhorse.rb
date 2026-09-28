require 'active_record'
require 'active_support/all'
require 'concurrent'
require 'fugit'
require 'socket'
require 'uri'

require 'workhorse/enqueuer'
require 'workhorse/scoped_env'
require 'workhorse/active_job_extension'

# Prevent YJIT from being enabled when RUBY_YJIT_ENABLE is explicitly set to 0.
# systemd's logrotate.service typically sets MemoryDenyWriteExecute=yes, which
# prevents mprotect(PROT_EXEC). Rails unconditionally calls
# RubyVM::YJIT.enable on boot, which triggers a fatal Ruby [BUG] in that
# environment. Set RUBY_YJIT_ENABLE=0 in the logrotate postrotate script
# to prevent this.
if ENV['RUBY_YJIT_ENABLE'] == '0' && defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?
  RubyVM::YJIT.define_singleton_method(:enable) { |**| nil }
end

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

  # Callback invoked when a job passed its `expires_at` before any worker got
  # to it. The job is in state `expired` and will not be performed.
  #
  # An expiry that nobody hears about is the failure this exists to prevent,
  # so workhorse logs it at `warn` regardless of this callback. Set the
  # callback to report it wherever failures belong, e.g.
  #
  # ```ruby
  # config.on_job_expired = proc do |db_job|
  #   ExceptionNotifier.notify_exception(
  #     StandardError.new("Job #{db_job.id} (#{db_job.description}) expired")
  #   )
  # end
  # ```
  #
  # Called outside the global lock, but on the poller thread: a slow callback
  # delays this worker's next poll. Anything it raises is passed to
  # {.on_exception} and does not affect the worker.
  #
  # @return [Proc] The expiry callback
  mattr_accessor :on_job_expired
  self.on_job_expired = proc do |db_job|
    # Do something with this job, i.e. notify about it
  end

  # Callback invoked when a job started later than its `max_lateness` allows.
  # In contrast to {.on_job_expired} the job does run; it was simply late.
  #
  # Called on the worker thread that performs the job, just before it starts,
  # and receives the job and its lateness in seconds. Anything it raises is
  # passed to {.on_exception}.
  #
  # @return [Proc] The lateness callback
  mattr_accessor :on_job_late
  self.on_job_late = proc do |db_job, lateness|
    # Do something with this job, i.e. notify about it
  end

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

  # Maximum memory usage per {Workhorse::Worker} process in MB.
  # When exceeded, the watch command will restart the worker. Set to 0 to disable.
  #
  # @return [Integer] Memory limit in megabytes
  mattr_accessor :max_worker_memory_mb
  self.max_worker_memory_mb = 0

  # Channel a {Workhorse::Notifiers::Redis} notifier publishes on. Defaults to
  # {Workhorse::Notifiers::Redis::DEFAULT_CHANNEL} when nil.
  #
  # @return [String, nil] Channel name
  mattr_accessor :notification_channel
  self.notification_channel = nil

  # Redis client used by a {Workhorse::Notifiers::Redis} notifier.
  #
  # @return [Object, nil] A Redis client
  mattr_accessor :notification_redis
  self.notification_redis = nil

  # Path of the file a {Workhorse::Notifiers::FileSystem} notifier touches.
  # Every process that enqueues jobs and every worker must agree on it.
  #
  # Defaults to `tmp/pids/workhorse.wake` below the Rails root, or below the
  # working directory outside of Rails.
  #
  # @return [String] Path of the notification file
  def self.notification_path
    return @notification_path if @notification_path

    root = defined?(Rails) ? Rails.root : Dir.pwd

    return ::File.join(root.to_s, 'tmp', 'pids', 'workhorse.wake')
  end

  # Sets the path of the notification file, see {.notification_path}.
  #
  # @param value [String, nil] Path, or nil to restore the default
  # @return [void]
  def self.notification_path=(value)
    @notification_path = value
  end

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

  # Notifier that lets a worker start an enqueued job without waiting for its
  # next poll. Polling stays the floor, so a notification that is not
  # delivered costs latency and nothing else.
  #
  # Set to `:none` (the default), `:file`, `:redis`, or an instance of a
  # {Workhorse::Notifiers::Base} subclass.
  #
  # @return [Workhorse::Notifiers::Base] The configured notifier
  def self.notifier
    return @notifier ||= Workhorse::Notifiers::None.new
  end

  # Sets the notifier, see {.notifier}.
  #
  # @param value [Symbol, Workhorse::Notifiers::Base] The notifier to use
  # @return [void]
  def self.notifier=(value)
    @notifier = case value
                when :none, nil then Workhorse::Notifiers::None.new
                when :file      then Workhorse::Notifiers::FileSystem.new
                when :redis     then Workhorse::Notifiers::Redis.new
                when Symbol     then fail(ArgumentError, "Unknown notifier #{value.inspect}, use :none, :file or :redis.")
                else value
                end
  end

  # Registers scheduled jobs, see {Workhorse::Schedules::Dsl#schedule}.
  #
  # ```ruby
  # Workhorse.schedules do
  #   schedule 'cleanup_jobs',
  #            job:  'Workhorse::Jobs::CleanupSucceededJobs',
  #            cron: '10 0 * * *'
  # end
  # ```
  #
  # @yield Block evaluated against {Workhorse::Schedules::Dsl}
  # @return [void]
  def self.schedules(&block)
    Workhorse::Schedules.define(&block)
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

require 'workhorse/notifiers/base'
require 'workhorse/notifiers/none'
require 'workhorse/notifiers/file_system'
require 'workhorse/notifiers/redis'
require 'workhorse/db_job'
require 'workhorse/schedules'
require 'workhorse/schedule'
require 'workhorse/performer'
require 'workhorse/poller'
require 'workhorse/pool'
require 'workhorse/worker'
require 'workhorse/jobs/run_rails_op'
require 'workhorse/jobs/run_active_job'
require 'workhorse/jobs/cleanup_succeeded_jobs'
require 'workhorse/jobs/detect_stale_jobs_job'
require 'workhorse/jobs/detect_late_schedules_job'

# Daemon functionality is not available on java platforms
if RUBY_PLATFORM != 'java'
  require 'workhorse/daemon'
  require 'workhorse/daemon/shell_handler'
end

if defined?(ActiveJob)
  require 'active_job/queue_adapters/workhorse_adapter'
end
