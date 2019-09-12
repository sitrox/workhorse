#!/usr/bin/env ruby

require './config/environment'

Workhorse::Daemon::ShellHandler.run do |daemon|
  5.times do
    daemon.worker do
      Workhorse::Worker.start_and_wait(pool_size: 1, logger: Rails.logger)
    end
  end
end
