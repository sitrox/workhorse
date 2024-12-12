task :gemspec do
  gemspec = Gem::Specification.new do |spec|
    spec.name          = 'workhorse'
    spec.version       = File.read('VERSION').chomp
    spec.authors       = ['Sitrox']
    spec.summary       = %(
      Multi-threaded job backend with database queuing for ruby.
    )
    spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
    spec.executables   = []
    spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
    spec.require_paths = ['lib']

    spec.add_development_dependency 'bundler'
    spec.add_development_dependency 'rake'
    spec.add_development_dependency 'rubocop', '~> 1.28.0' # Latest version supported with Ruby 2.5
    spec.add_development_dependency 'minitest'
    spec.add_development_dependency 'mysql2'
    spec.add_development_dependency 'colorize'
    spec.add_development_dependency 'benchmark-ips'
    spec.add_development_dependency 'activejob'
    spec.add_development_dependency 'pry'
    spec.add_dependency 'activesupport'
    spec.add_dependency 'activerecord'
    spec.add_dependency 'concurrent-ruby'
  end

  File.write('workhorse.gemspec', gemspec.to_ruby.strip)
end

require_relative './test/lib/testbench'

require 'rake/testtask'

# Rake::TestTask.new do |t|
#   t.pattern = 'test/**/*_test.rb'
#   t.verbose = false
#   t.libs << 'test/lib'
# end

Testbench::Task.new do |t|
  t.libs << 'lib'
  t.libs << 'test/lib'
end
