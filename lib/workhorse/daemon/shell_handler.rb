module Workhorse
  class Daemon::ShellHandler
    def self.run(**options, &block)
      unless ARGV.count == 1
        usage
        exit 99
      end

      if Workhorse.lock_shell_commands
        lockfile_path = options.delete(:lockfile) || 'workhorse.lock'
        lockfile = File.open(lockfile_path, 'a')
        lockfile.flock(File::LOCK_EX || File::LOCK_NB)
      else
        lockfile = nil
      end

      daemon = Workhorse::Daemon.new(**options, &block)

      begin
        case ARGV.first
        when 'start'
          exit daemon.start
        when 'stop'
          exit daemon.stop
        when 'kill'
          exit daemon.stop(true)
        when 'status'
          exit daemon.status
        when 'watch'
          exit daemon.watch
        when 'restart'
          exit daemon.restart
        when 'restart-logging'
          exit daemon.restart_logging
        when 'usage'
          usage
          exit 99
        else
          usage
        end

        exit 0
      rescue StandardError => e
        warn "#{e.message}\n#{e.backtrace.join("\n")}"
        exit 99
      ensure
        lockfile&.flock(File::LOCK_UN)
      end
    end

    def self.usage
      warn <<~USAGE
        Usage: #{$PROGRAM_NAME} start|stop|status|watch|restart|usage

        Options:

          start
            Start the daemon

          stop
            Stop the daemon

          kill
            Kill the daemon

          status
            Query the status of the daemon. Exit with status 1 if any worker is
            not running.

          watch
            Checks the status (running or stopped) and whether it is as
            expected. Starts the daemon if it is expected to run but is not.

          restart
            Shortcut for consecutive 'stop' and 'start'.

          restart-logging
            Re-opens log files, useful e.g. after the log files have been moved or
            removed by log rotation.

          usage
            Show this message

        Exit status:
         0 if OK,
         1 on fatal errors outside of workhorse,
         2 if at least one worker has an unexpected status,
         99 on all other errors.
      USAGE
    end
  end
end
