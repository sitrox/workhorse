class BasicJob
  class_attribute :results
  self.results = Concurrent::Array.new

  def initialize(some_param: nil)
    @some_param = some_param
  end

  def perform
    results << @some_param
    sleep 1
  end
end

class DbConnectionTestJob
  class_attribute :db_connections
  self.db_connections = Concurrent::Array.new

  def perform
    db_connections << ActiveRecord::Base.connection.object_id
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
