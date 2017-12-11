require 'socket'
require 'active_support/all'
require 'active_record'

module Workhorse
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
require 'workhorse/enqueuer'
require 'workhorse/performer'
require 'workhorse/poller'
require 'workhorse/worker'
require 'workhorse/jobs/run_rails_op'
