class BasicJob
  class_attribute :results
  self.results = Concurrent::Array.new

  def initialize(some_param: nil, sleep_time: 1)
    @some_param = some_param
    @sleep_time = sleep_time
  end

  def perform
    results << @some_param
    sleep @sleep_time if @sleep_time > 0
  end
end

class DbConnectionTestJob
  class_attribute :db_connections
  self.db_connections = Concurrent::Array.new

  def perform
    db_connections << ActiveRecord::Base.connection.object_id
  end
end

class FailingTestJob
  MESSAGE = 'I fail all the time'.freeze

  def perform
    fail MESSAGE
  end
end

class DummyRailsOpsOp
  class_attribute :results
  self.results = Concurrent::Array.new

  def self.run!(params = {})
    new(params).run!
  end

  def initialize(params = {})
    @params = params
  end

  def run!
    perform
  end

  private

  def perform
    results << @params
  end
end
