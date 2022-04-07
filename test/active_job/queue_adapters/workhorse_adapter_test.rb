require 'test_helper'

class ActiveJob::QueueAdapters::WorkhorseAdapterTest < WorkhorseTest
  class ApplicationJob < ActiveJob::Base; end
  class CustomException < StandardError; end

  class Job1 < ApplicationJob
    attr_reader :result

    class_attribute :results

    queue_as ''

    def perform(param)
      results << param
    end
  end

  class Job2 < Job1
    queue_as :queue1
  end

  class Job3 < Job1
    rescue_from CustomException do |e|
      results << e
    end

    def perform
      fail CustomException
    end
  end

  class Job4 < Job1
    after_enqueue do |job|
      results << job.provider_job_id
    end
  end

  def setup
    ActiveJob::Base.queue_adapter = :workhorse
    ActiveJob::Base.logger = nil
    Workhorse::DbJob.delete_all
    Job1.results = Concurrent::Array.new
  end

  def test_basic
    Job1.perform_later 'foo'
    work 0.5
    assert_equal ['foo'], Job1.results
    assert_nil Workhorse::DbJob.first.queue
  end

  def test_queue
    Job2.perform_later 'foo'
    work 0.5
    assert_equal ['foo'], Job2.results
    assert_equal 'queue1', Workhorse::DbJob.first.queue
  end

  def test_wait
    Job2.set(wait: 2.seconds).perform_later 'foo'

    work 1, polling_interval: 0.1
    assert_equal 'waiting', Workhorse::DbJob.first.state

    work 2.5, polling_interval: 0.1
    assert_equal 'succeeded', Workhorse::DbJob.first.reload.state
  end

  def test_wait_until
    Job2.set(wait_until: (Time.now + 2.seconds)).perform_later 'foo'

    work 0.5, polling_interval: 0.1
    assert_equal 'waiting', Workhorse::DbJob.first.state

    work 3, polling_interval: 0.1
    assert_equal 'succeeded', Workhorse::DbJob.first.reload.state
  end

  def test_rescue_from
    Job3.perform_later
    work 0.5
    assert_equal 'succeeded', Workhorse::DbJob.first.state
    assert Job3.results.first.is_a?(CustomException)
  end

  def test_provider_job_id
    job = Job4.perform_later
    db_job = Workhorse::DbJob.first
    assert_equal db_job.id, job.provider_job_id
    assert_equal [db_job.id], Job1.results
  end
end
