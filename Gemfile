source 'https://rubygems.org'

# Specify gem dependencies in the .gemspec file
gemspec

gem 'activejob', '~> 7.1.3'
gem 'activerecord', '~> 7.1.3'
gem 'benchmark-ips'
gem 'bundler', '>= 2.5'
gem 'minitest'
gem 'mysql2'
gem 'pry'
gem 'rake'
gem 'rubocop', '~> 1.60'
gem 'trilogy'

# Only needed to run the suite against Oracle, which additionally requires the
# Oracle Instant Client to be installed - building ruby-oci8 fails without it.
# The group is optional, so a plain `bundle install` skips it; enable it with
# `bundle config set --local with oracle`.
group :oracle, optional: true do
  gem 'activerecord-oracle_enhanced-adapter', '~> 7.1'
  gem 'ruby-oci8'
end
