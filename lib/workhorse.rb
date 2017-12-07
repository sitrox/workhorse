module Workhorse
  @set_up = false

  # Returns the performer currently performing the active job. This can only be
  # called from within a job and the same thread.
  def self.performer
    Thread.current[:workhorse_current_performer]\
      || fail('No performer is associated with the current thread. This method must always be called inside of a job.')
  end

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
