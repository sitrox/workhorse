# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "workhorse"
  s.version = "0.0.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Sitrox"]
  s.date = "2017-12-12"
  s.files = [".gitignore", ".releaser_config", ".rubocop.yml", ".travis.yml", "Gemfile", "LICENSE", "README.md", "RUBY_VERSION", "Rakefile", "VERSION", "bin/rubocop", "lib/generators/workhorse/install_generator.rb", "lib/generators/workhorse/templates/bin/workhorse.rb", "lib/generators/workhorse/templates/create_table_jobs.rb", "lib/workhorse.rb", "lib/workhorse/db_job.rb", "lib/workhorse/enqueuer.rb", "lib/workhorse/jobs/run_rails_op.rb", "lib/workhorse/performer.rb", "lib/workhorse/poller.rb", "lib/workhorse/worker.rb", "test/lib/db_schema.rb", "test/lib/jobs.rb", "test/lib/test_helper.rb", "test/workhorse/enqueuer_test.rb", "test/workhorse/performer_test.rb", "test/workhorse/worker_test.rb", "workhorse.gemspec"]
  s.require_paths = ["lib"]
  s.rubygems_version = "2.0.14.1"
  s.summary = "Multi-threaded job backend with database queuing for ruby."
  s.test_files = ["test/lib/db_schema.rb", "test/lib/jobs.rb", "test/lib/test_helper.rb", "test/workhorse/enqueuer_test.rb", "test/workhorse/performer_test.rb", "test/workhorse/worker_test.rb"]

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<bundler>, ["~> 1.3"])
      s.add_development_dependency(%q<rake>, [">= 0"])
      s.add_development_dependency(%q<rubocop>, ["= 0.51.0"])
      s.add_development_dependency(%q<minitest>, [">= 0"])
      s.add_development_dependency(%q<mysql2>, ["~> 0.3.13"])
      s.add_development_dependency(%q<benchmark-ips>, [">= 0"])
      s.add_runtime_dependency(%q<activesupport>, [">= 0"])
      s.add_runtime_dependency(%q<activerecord>, [">= 0"])
      s.add_runtime_dependency(%q<schemacop>, ["~> 2.0"])
      s.add_runtime_dependency(%q<concurrent-ruby>, [">= 0"])
    else
      s.add_dependency(%q<bundler>, ["~> 1.3"])
      s.add_dependency(%q<rake>, [">= 0"])
      s.add_dependency(%q<rubocop>, ["= 0.51.0"])
      s.add_dependency(%q<minitest>, [">= 0"])
      s.add_dependency(%q<mysql2>, ["~> 0.3.13"])
      s.add_dependency(%q<benchmark-ips>, [">= 0"])
      s.add_dependency(%q<activesupport>, [">= 0"])
      s.add_dependency(%q<activerecord>, [">= 0"])
      s.add_dependency(%q<schemacop>, ["~> 2.0"])
      s.add_dependency(%q<concurrent-ruby>, [">= 0"])
    end
  else
    s.add_dependency(%q<bundler>, ["~> 1.3"])
    s.add_dependency(%q<rake>, [">= 0"])
    s.add_dependency(%q<rubocop>, ["= 0.51.0"])
    s.add_dependency(%q<minitest>, [">= 0"])
    s.add_dependency(%q<mysql2>, ["~> 0.3.13"])
    s.add_dependency(%q<benchmark-ips>, [">= 0"])
    s.add_dependency(%q<activesupport>, [">= 0"])
    s.add_dependency(%q<activerecord>, [">= 0"])
    s.add_dependency(%q<schemacop>, ["~> 2.0"])
    s.add_dependency(%q<concurrent-ruby>, [">= 0"])
  end
end