module Workhorse
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    source_root File.expand_path('templates', __dir__)

    def self.next_migration_number(_dir)
      Time.now.utc.strftime('%Y%m%d%H%M%S')
    end

    def install_migration
      migration_template 'create_table_jobs.rb', 'db/migrate/create_table_jobs.rb'
    end

    def install_daemon_script
      template 'bin/workhorse.rb'
      chmod 'bin/workhorse.rb', 0o755
    end

    def install_initializer
      template 'config/initializers/workhorse.rb'
    end
  end
end
