require 'test_helper'

class Workhorse::PollerTest < WorkhorseTest
  def test_interruptable_sleep
    w = Workhorse::Worker.new(polling_interval: 60)
    w.start
    sleep 0.1

    Timeout.timeout(0.15) do
      w.shutdown
    end
  end
end
