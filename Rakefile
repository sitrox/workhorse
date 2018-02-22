task :gemspec do
  gemspec = Gem::Specification.new do |spec|
    spec.name          = 'workhorse'
    spec.version       = IO.read('VERSION').chomp
    spec.authors       = ['Sitrox']
    spec.summary       = %(
      Multi-threaded job backend with database queuing for ruby.
    )
    spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
    spec.executables   = []
    spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
    spec.require_paths = ['lib']

    spec.add_development_dependency 'bundler', '~> 1.3'
    spec.add_development_dependency 'rake'
    spec.add_development_dependency 'rubocop', '0.51.0'
    spec.add_development_dependency 'minitest'
    spec.add_development_dependency 'mysql2', '~> 0.3.13'
    spec.add_development_dependency 'benchmark-ips'
    spec.add_development_dependency 'appraisal'
    spec.add_dependency 'activesupport'
    spec.add_dependency 'activerecord'
    spec.add_dependency 'schemacop', '~> 2.0'
    spec.add_dependency 'concurrent-ruby'
  end

  File.open('workhorse.gemspec', 'w') { |f| f.write(gemspec.to_ruby.strip) }
end

require 'rake/testtask'

Rake::TestTask.new do |t|
  t.pattern = 'test/workhorse/**/*_test.rb'
  t.verbose = false
  t.libs << 'test/lib'
end
