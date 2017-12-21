require 'socket'
require 'active_support/all'
require 'active_record'

require 'workhorse/enqueuer'

module Workhorse
  extend Workhorse::Enqueuer

  @set_up = false

  # Returns the performer currently performing the active job. This can only be
  # called from within a job and the same thread.
  def self.performer
    Thread.current[:workhorse_current_performer]\
      || fail('No performer is associated with the current thread. This method must always be called inside of a job.')
  end

  cattr_accessor :tx_callback
  self.tx_callback = proc do |&block|
    ActiveRecord::Base.transaction(&block)
  end

  cattr_accessor :perform_jobs_in_tx
  self.perform_jobs_in_tx = true

  def self.setup
    fail 'Workhorse is already set up.' if @set_up
    yield self
    @set_up = true
  end
end

require 'workhorse/db_job'
require 'workhorse/performer'
require 'workhorse/poller'
require 'workhorse/pool'
require 'workhorse/worker'
require 'workhorse/jobs/run_rails_op'
require 'workhorse/jobs/cleanup_succeeded_jobs'

# Daemon functionality is not available on java platforms
if RUBY_PLATFORM != 'java'
  require 'workhorse/daemon'
  require 'workhorse/daemon/shell_handler'
end
