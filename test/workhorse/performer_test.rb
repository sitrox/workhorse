require 'test_helper'

class Workhorse::PerformerTest < WorkhorseTest
  # This test makes sure that concurrent jobs always work in different database
  # connections.
  def test_db_connections
    2.times do
      Workhorse.enqueue DbConnectionTestJob.new
    end

    work 0.2, polling_interval: 0.2

    assert_equal 2, DbConnectionTestJob.db_connections.count
    assert_equal 2, DbConnectionTestJob.db_connections.uniq.count
  end

  def test_success
    Workhorse.enqueue BasicJob.new(sleep_time: 0.1)
    work 0.2, polling_interval: 0.2
    assert_equal 'succeeded', Workhorse::DbJob.first.state
  end

  def test_exception
    Workhorse.enqueue FailingTestJob.new
    work 0.2, polling_interval: 0.2
    assert_equal 'failed', Workhorse::DbJob.first.state
  end

  def test_syntax_exception
    Workhorse.enqueue SyntaxErrorJob
    work 0.2, polling_interval: 0.2
    assert_equal 'failed', Workhorse::DbJob.first.state
  end

  def test_on_exception
    old_callback = Workhorse.on_exception
    exception = nil

    Workhorse.on_exception = proc do |e|
      exception = e
    end

    Workhorse.enqueue FailingTestJob.new
    work 0.2, polling_interval: 0.2

    assert_equal exception.message, FailingTestJob::MESSAGE
  ensure
    Workhorse.on_exception = old_callback
  end
end
