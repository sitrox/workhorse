source 'https://rubygems.org'

# Specify gem dependencies in the .gemspec file
gemspec

gem 'activejob', '~> 7.1.3'
gem 'activerecord', '~> 7.1.3'
gem 'benchmark-ips'
gem 'bundler'
gem 'minitest'
gem 'mysql2'
gem 'pry'
gem 'rake'

# Pinned to a patch range rather than given a floor: Gemfile.lock is not
# checked in, so CI resolves the newest version matching this line while a
# checkout keeps whatever it installed. With a floor, every rubocop release
# that adds a cop turns the build red for a reason nobody can reproduce
# locally.
gem 'rubocop', '~> 1.91.0'
gem 'trilogy'

# Only needed to run the suite against Oracle, which additionally requires the
# Oracle Instant Client to be installed - building ruby-oci8 fails without it.
# The group is optional, so a plain `bundle install` skips it; enable it with
# `bundle config set --local with oracle`.
group :oracle, optional: true do
  gem 'activerecord-oracle_enhanced-adapter', '~> 7.1'
  gem 'ruby-oci8'
end
