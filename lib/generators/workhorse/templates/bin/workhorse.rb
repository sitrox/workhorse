#!/usr/bin/env ruby

require './config/environment'

Workhorse::Daemon::ShellHandler.run do
  Workhorse::Worker.start_and_wait(pool_size: 5, logger: Rails.logger)
end
