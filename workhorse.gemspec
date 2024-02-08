# -*- encoding: utf-8 -*-
# stub: workhorse 1.2.17.rc1 ruby lib

Gem::Specification.new do |s|
  s.name = "workhorse".freeze
  s.version = "1.2.17.rc1"

  s.required_rubygems_version = Gem::Requirement.new("> 1.3.1".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Sitrox".freeze]
  s.date = "2024-02-08"
  s.files = [".github/workflows/ruby.yml".freeze, ".gitignore".freeze, ".releaser_config".freeze, ".rubocop.yml".freeze, "CHANGELOG.md".freeze, "FAQ.md".freeze, "Gemfile".freeze, "LICENSE".freeze, "README.md".freeze, "RUBY_VERSION".freeze, "Rakefile".freeze, "VERSION".freeze, "bin/rubocop".freeze, "lib/active_job/queue_adapters/workhorse_adapter.rb".freeze, "lib/generators/workhorse/install_generator.rb".freeze, "lib/generators/workhorse/templates/bin/workhorse.rb".freeze, "lib/generators/workhorse/templates/config/initializers/workhorse.rb".freeze, "lib/generators/workhorse/templates/create_table_jobs.rb".freeze, "lib/workhorse.rb".freeze, "lib/workhorse/active_job_extension.rb".freeze, "lib/workhorse/daemon.rb".freeze, "lib/workhorse/daemon/shell_handler.rb".freeze, "lib/workhorse/db_job.rb".freeze, "lib/workhorse/enqueuer.rb".freeze, "lib/workhorse/jobs/cleanup_succeeded_jobs.rb".freeze, "lib/workhorse/jobs/detect_stale_jobs_job.rb".freeze, "lib/workhorse/jobs/run_active_job.rb".freeze, "lib/workhorse/jobs/run_rails_op.rb".freeze, "lib/workhorse/performer.rb".freeze, "lib/workhorse/poller.rb".freeze, "lib/workhorse/pool.rb".freeze, "lib/workhorse/scoped_env.rb".freeze, "lib/workhorse/worker.rb".freeze, "test/active_job/queue_adapters/workhorse_adapter_test.rb".freeze, "test/lib/db_schema.rb".freeze, "test/lib/jobs.rb".freeze, "test/lib/test_helper.rb".freeze, "test/workhorse/db_job_test.rb".freeze, "test/workhorse/enqueuer_test.rb".freeze, "test/workhorse/performer_test.rb".freeze, "test/workhorse/poller_test.rb".freeze, "test/workhorse/pool_test.rb".freeze, "test/workhorse/worker_test.rb".freeze, "workhorse.gemspec".freeze]
  s.rubygems_version = "3.4.6".freeze
  s.summary = "Multi-threaded job backend with database queuing for ruby.".freeze
  s.test_files = ["test/active_job/queue_adapters/workhorse_adapter_test.rb".freeze, "test/lib/db_schema.rb".freeze, "test/lib/jobs.rb".freeze, "test/lib/test_helper.rb".freeze, "test/workhorse/db_job_test.rb".freeze, "test/workhorse/enqueuer_test.rb".freeze, "test/workhorse/performer_test.rb".freeze, "test/workhorse/poller_test.rb".freeze, "test/workhorse/pool_test.rb".freeze, "test/workhorse/worker_test.rb".freeze]

  s.specification_version = 4

  s.add_development_dependency(%q<bundler>.freeze, [">= 0"])
  s.add_development_dependency(%q<rake>.freeze, [">= 0"])
  s.add_development_dependency(%q<rubocop>.freeze, ["~> 1.28.0"])
  s.add_development_dependency(%q<minitest>.freeze, [">= 0"])
  s.add_development_dependency(%q<mysql2>.freeze, [">= 0"])
  s.add_development_dependency(%q<colorize>.freeze, [">= 0"])
  s.add_development_dependency(%q<benchmark-ips>.freeze, [">= 0"])
  s.add_development_dependency(%q<activejob>.freeze, [">= 0"])
  s.add_development_dependency(%q<pry>.freeze, [">= 0"])
  s.add_runtime_dependency(%q<activesupport>.freeze, [">= 0"])
  s.add_runtime_dependency(%q<activerecord>.freeze, [">= 0"])
  s.add_runtime_dependency(%q<concurrent-ruby>.freeze, [">= 0"])
end