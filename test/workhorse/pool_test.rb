require 'test_helper'

class Workhorse::PoolTest < ActiveSupport::TestCase
  def test_idle
    with_pool 5 do |p|
      assert_equal 5, p.idle

      4.times do |_i|
        p.post do
          sleep 1
        end
      end

      sleep 0.5
      assert_equal 1, p.idle

      sleep 1
      assert_equal 5, p.idle
    end
  end

  def test_overflow
    with_pool 5 do |p|
      5.times { p.post { sleep 1 } }

      exception = assert_raises do
        p.post { sleep 1 }
      end

      assert_equal 'All threads are busy.', exception.message
    end
  end

  def test_work
    with_pool 5 do |p|
      counter = Concurrent::AtomicFixnum.new(0)

      5.times do
        p.post do
          sleep 1
          counter.increment
        end
      end

      sleep 1.2

      assert_equal 5, counter.value

      2.times do
        p.post do
          sleep 1
          counter.increment
        end
      end

      sleep 1.2

      assert_equal 7, counter.value
    end
  end

  private

  def with_pool(size)
    p = Workhorse::Pool.new(size)
    begin
      yield(p)
    ensure
      p.shutdown
    end
  end
end
