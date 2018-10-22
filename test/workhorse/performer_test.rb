require 'test_helper'

class Workhorse::WorkerTest < WorkhorseTest
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
