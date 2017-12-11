class BasicJob
  def perform
    sleep 1
  end
end

class DbConnectionTestJob
  def perform
    $workhorse_db_connections << ActiveRecord::Base.connection.object_id
  end
end
