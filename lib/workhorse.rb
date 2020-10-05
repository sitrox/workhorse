require 'active_record'
require 'active_support/all'
require 'concurrent'
require 'socket'
require 'uri'

require 'workhorse/enqueuer'
require 'workhorse/scoped_env'

module Workhorse
  # Check if the available Arel version is greater or equal than 7.0.0
  AREL_GTE_7 = Gem::Version.new(Arel::VERSION) >= Gem::Version.new('7.0.0')

  extend Workhorse::Enqueuer

  # Returns the performer currently performing the active job. This can only be
  # called from within a job and the same thread.
  def self.performer
    Thread.current[:workhorse_current_performer]\
      || fail('No performer is associated with the current thread. This method must always be called inside of a job.')
  end

  mattr_accessor :tx_callback
  self.tx_callback = proc do |*args, &block|
    ActiveRecord::Base.transaction(*args, &block)
  end

  mattr_accessor :on_exception
  self.on_exception = proc do |exception|
    # Do something with this exception, i.e.
    # ExceptionNotifier.notify_exception(exception)
  end

  # If set to `true`, the defined `on_exception` will not be called when the
  # poller encounters an exception and the worker has to be shut down. The
  # exception will still be logged.
  mattr_accessor :silence_poller_exceptions
  self.silence_poller_exceptions = false

  # If set to `true`, the `watch` command won't produce any output. This does
  # not include warnings such as the "development mode" warning.
  mattr_accessor :silence_watcher
  self.silence_watcher = false

  mattr_accessor :perform_jobs_in_tx
  self.perform_jobs_in_tx = true

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
  require 'active_job/queue_adapters/workhorse_adapter.rb'
end
