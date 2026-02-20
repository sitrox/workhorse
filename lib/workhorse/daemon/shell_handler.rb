module Workhorse
  class Daemon::ShellHandler
    class LockNotAvailableError < StandardError; end

    def self.run(**options, &block)
      unless ARGV.one?
        usage
        exit 99
      end

      lockfile_path = options.delete(:lockfile) || 'workhorse.lock'
      daemon = Workhorse::Daemon.new(**options, &block)

      lockfile = nil

      begin
        case ARGV.first
        when 'start'
          Workhorse.debug_log('ShellHandler: start command invoked')
          lockfile = acquire_lock(lockfile_path, File::LOCK_EX)
          Workhorse.debug_log('ShellHandler: lock acquired for start')
          daemon.lockfile = lockfile
          status = daemon.start
        when 'stop'
          Workhorse.debug_log('ShellHandler: stop command invoked')
          lockfile = acquire_lock(lockfile_path, File::LOCK_EX)
          Workhorse.debug_log('ShellHandler: lock acquired for stop')
          daemon.lockfile = lockfile
          status = daemon.stop
        when 'kill'
          Workhorse.debug_log('ShellHandler: kill command invoked')
          begin
            lockfile = acquire_lock(lockfile_path, File::LOCK_EX | File::LOCK_NB)
            Workhorse.debug_log('ShellHandler: lock acquired for kill')
            daemon.lockfile = lockfile
            status = daemon.stop(true)
          rescue LockNotAvailableError
            Workhorse.debug_log('ShellHandler: lock not available for kill')
            status = 1
          end
        when 'status'
          Workhorse.debug_log('ShellHandler: status command invoked')
          lockfile = acquire_lock(lockfile_path, File::LOCK_EX)
          Workhorse.debug_log('ShellHandler: lock acquired for status')
          daemon.lockfile = lockfile
          status = daemon.status
        when 'watch'
          Workhorse.debug_log('ShellHandler: watch command invoked')
          begin
            lockfile = acquire_lock(lockfile_path, File::LOCK_EX | File::LOCK_NB)
            Workhorse.debug_log('ShellHandler: lock acquired for watch')
            daemon.lockfile = lockfile
            status = daemon.watch
          rescue LockNotAvailableError
            Workhorse.debug_log('ShellHandler: lock not available for watch')
            status = 1
          end
        when 'restart'
          Workhorse.debug_log('ShellHandler: restart command invoked')
          lockfile = acquire_lock(lockfile_path, File::LOCK_EX)
          Workhorse.debug_log('ShellHandler: lock acquired for restart')
          daemon.lockfile = lockfile
          status = daemon.restart
        when 'restart-logging'
          Workhorse.debug_log('ShellHandler: restart-logging command invoked')
          lockfile = acquire_lock(lockfile_path, File::LOCK_EX)
          Workhorse.debug_log('ShellHandler: lock acquired for restart-logging')
          daemon.lockfile = lockfile
          status = daemon.restart_logging
        when 'soft-restart'
          Workhorse.debug_log('ShellHandler: soft-restart command invoked')
          lockfile = acquire_lock(lockfile_path, File::LOCK_EX)
          Workhorse.debug_log('ShellHandler: lock acquired for soft-restart')
          daemon.lockfile = lockfile
          status = daemon.soft_restart
        when 'usage'
          usage
          status = 0
        else
          usage
          status = 99
        end
      rescue StandardError => e
        warn "#{e.message}\n#{e.backtrace.join("\n")}"
        status = 99
      ensure
        if lockfile
          Workhorse.debug_log("ShellHandler: releasing lock for #{ARGV.first}")
          lockfile.flock(File::LOCK_UN)
        end
        exit! status
      end
    end

    def self.usage
      warn <<~USAGE
        Usage: #{$PROGRAM_NAME} start|stop|status|watch|restart|soft-restart|usage

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

          soft-restart
            Signals workers to restart gracefully. Idle workers restart
            immediately; busy workers finish their current job first. Returns
            immediately (fire-and-forget).
            NOTE: Requires 'watch' (typically via cron) to start fresh workers.
            Without 'watch', this behaves like a graceful stop with no automatic
            recovery.

          usage
            Show this message

        Exit status:
         0 if OK,
         1 on fatal errors outside of workhorse,
         2 if at least one worker has an unexpected status,
         99 on all other errors.
      USAGE
    end

    def self.acquire_lock(lockfile_path, flags)
      if Workhorse.lock_shell_commands
        lockfile = File.open(lockfile_path, 'a')
        result = lockfile.flock(flags)

        if result == false
          lockfile.close
          fail LockNotAvailableError, 'Could not acquire lock. Is another workhorse command already running?'
        end

        return lockfile
      end

      return nil
    end
    private_class_method :acquire_lock
  end
end
