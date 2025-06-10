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

    spec.add_dependency 'activesupport'
    spec.add_dependency 'activerecord'
    spec.add_dependency 'concurrent-ruby'
  end

  File.write('workhorse.gemspec', gemspec.to_ruby.strip)
end

require 'rake/testtask'

Rake::TestTask.new do |t|
  t.pattern = 'test/**/*_test.rb'
  t.verbose = false
  t.libs << 'test/lib'
end
