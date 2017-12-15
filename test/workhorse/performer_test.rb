require 'test_helper'

class Workhorse::WorkerTest < WorkhorseTest
  # This test makes sure that concurrent jobs always work in different database
  # connections.
  def test_db_connections
    w = Workhorse::Worker.new polling_interval: 1, pool_size: 5
    5.times do
      Workhorse::Enqueuer.enqueue DbConnectionTestJob.new
    end
    w.start
    sleep 1
    w.shutdown

    assert_equal 5, DbConnectionTestJob.db_connections.count
    assert_equal 5, DbConnectionTestJob.db_connections.uniq.count
  end
end
