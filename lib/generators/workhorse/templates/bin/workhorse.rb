#!/usr/bin/env ruby

require 'bundler/setup'
require 'workhorse'

Workhorse::Daemon::ShellHandler.run do
  require './config/environment'
  Workhorse::Worker.start_and_wait(pool_size: 5, logger: Rails.logger)
end
