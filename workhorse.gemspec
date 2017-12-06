# -*- encoding: utf-8 -*-
# stub: workhorse 0.0.1 ruby lib

Gem::Specification.new do |s|
  s.name = "workhorse".freeze
  s.version = "0.0.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Sitrox".freeze]
  s.date = "2017-12-06"
  s.files = [".gitignore".freeze, "Gemfile".freeze, "LICENSE".freeze, "README.md".freeze, "RUBY_VERSION".freeze, "Rakefile".freeze, "VERSION".freeze, "lib/workhorse.rb".freeze, "lib/workhorse/db_job.rb".freeze, "lib/workhorse/enqueuer.rb".freeze, "lib/workhorse/jobs/run_rails_op.rb".freeze, "lib/workhorse/performer.rb".freeze, "lib/workhorse/poller.rb".freeze, "lib/workhorse/worker.rb".freeze, "workhorse.gemspec".freeze]
  s.rubygems_version = "2.6.14".freeze
  s.summary = "Multi-threaded job backend with database queuing for ruby.".freeze

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<bundler>.freeze, ["~> 1.3"])
      s.add_development_dependency(%q<rake>.freeze, [">= 0"])
      s.add_development_dependency(%q<rubocop>.freeze, ["= 0.51.0"])
      s.add_development_dependency(%q<minitest>.freeze, [">= 0"])
      s.add_runtime_dependency(%q<activerecord>.freeze, [">= 0"])
      s.add_runtime_dependency(%q<schemacop>.freeze, ["~> 2.0"])
    else
      s.add_dependency(%q<bundler>.freeze, ["~> 1.3"])
      s.add_dependency(%q<rake>.freeze, [">= 0"])
      s.add_dependency(%q<rubocop>.freeze, ["= 0.51.0"])
      s.add_dependency(%q<minitest>.freeze, [">= 0"])
      s.add_dependency(%q<activerecord>.freeze, [">= 0"])
      s.add_dependency(%q<schemacop>.freeze, ["~> 2.0"])
    end
  else
    s.add_dependency(%q<bundler>.freeze, ["~> 1.3"])
    s.add_dependency(%q<rake>.freeze, [">= 0"])
    s.add_dependency(%q<rubocop>.freeze, ["= 0.51.0"])
    s.add_dependency(%q<minitest>.freeze, [">= 0"])
    s.add_dependency(%q<activerecord>.freeze, [">= 0"])
    s.add_dependency(%q<schemacop>.freeze, ["~> 2.0"])
  end
end