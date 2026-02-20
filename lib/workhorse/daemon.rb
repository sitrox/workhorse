module Workhorse
  # Daemon class for managing multiple worker processes.
  # Provides functionality to start, stop, restart, and monitor worker processes
  # through a simple Ruby DSL.
  class Daemon
    # Internal representation of a worker process.
    # Stores worker metadata and the block to execute.
    class Worker
      # @return [Integer] The worker's unique ID
      attr_reader :id

      # @return [String] The worker's display name
      attr_reader :name

      # @return [Proc] The block containing the worker's logic
      attr_reader :block

      # @return [Integer, nil] The worker's process ID when running
      attr_accessor :pid

      # Creates a new worker definition.
      #
      # @param id [Integer] Unique identifier for this worker
      # @param name [String] Display name for this worker
      # @param block [Proc] Code block to execute in the worker process
      def initialize(id, name, &block)
        @id = id
        @name = name
        @block = block
      end
    end

    # @return [Array<Worker>] Array of defined workers
    # @private
    attr_reader :workers

    # @return [File, nil] Lockfile handle to close in forked children
    # @private
    attr_accessor :lockfile

    # Creates a new daemon instance.
    #
    # @param pidfile [String, nil] Path template for PID files (use %i placeholder for worker ID)
    # @param quiet [Boolean] Whether to suppress output during operations
    # @yield [ScopedEnv] Configuration block for defining workers
    # @raise [RuntimeError] If no workers are defined or pidfile format is invalid
    def initialize(pidfile: nil, quiet: false, &_block)
      @pidfile = pidfile
      @quiet = quiet
      @workers = []

      yield ScopedEnv.new(self, [:worker])

      @count = @workers.count

      fail 'No workers are defined.' if @count < 1

      FileUtils.mkdir_p('tmp/pids')

      if @pidfile.nil?
        @pidfile = @count > 1 ? 'tmp/pids/workhorse.%i.pid' : 'tmp/pids/workhorse.pid'
      elsif @count > 1 && !@pidfile.include?('%s')
        fail 'Pidfile must include placeholder "%s" for worker id when specifying a count > 1.'
      elsif @count == 0 && @pidfile.include?('%s')
        fail 'Pidfile must not include placeholder "%s" for worker id when specifying a count of 1.'
      end
    end

    # Defines a worker process.
    #
    # @param name [String] Display name for the worker
    # @yield Block containing the worker's execution logic
    # @return [void]
    def worker(name = 'Job Worker', &block)
      @workers << Worker.new(@workers.size + 1, name, &block)
    end

    # Starts all defined workers.
    #
    # @param quiet [Boolean] Whether to suppress status output
    # @return [Integer] Exit code (0 = success, 2 = some workers already running)
    def start(quiet: false)
      code = 0

      # Holds messages in format [[<message>, <severity>]]
      messages = []

      for_each_worker do |worker|
        pid_file, pid, active = read_pid(worker)

        if pid_file && pid && active
          messages << ["Worker ##{worker.id} (#{worker.name}): Already started (PID #{pid})", 2] unless quiet
          code = 2
        elsif pid_file
          File.delete pid_file

          shutdown_file = pid ? Workhorse::Worker.shutdown_file_for(pid) : nil
          shutdown_file = nil if shutdown_file && !File.exist?(shutdown_file)

          messages << ["Worker ##{worker.id} (#{worker.name}): Starting (stale pid file)", 1] unless quiet || shutdown_file
          start_worker worker
          FileUtils.rm(shutdown_file) if shutdown_file
        else
          messages << ["Worker ##{worker.id} (#{worker.name}): Starting", 1] unless quiet
          start_worker worker
        end
      end

      if messages.any?
        min = messages.min_by(&:last)[1]

        # Only print messages if there is at least one message with severity 1
        if min == 1
          messages.each { |(message, _severity)| warn message }
        end
      end

      return code
    end

    # Stops all running workers.
    #
    # @param kill [Boolean] Whether to use KILL signal instead of TERM/INT
    # @param quiet [Boolean] Whether to suppress status output
    # @return [Integer] Exit code (0 = success, 2 = some workers already stopped)
    def stop(kill = false, quiet: false)
      code = 0

      for_each_worker do |worker|
        pid_file, pid, active = read_pid(worker)

        if pid_file && pid && active
          puts "Worker (#{worker.name}) ##{worker.id}: Stopping" unless quiet
          stop_worker pid_file, pid, kill: kill
        elsif pid_file
          File.delete pid_file
          puts "Worker (#{worker.name}) ##{worker.id}: Already stopped (stale PID file)" unless quiet
        else
          warn "Worker (#{worker.name}) ##{worker.id}: Already stopped" unless quiet
          code = 2
        end
      end

      return code
    end

    # Checks the status of all workers.
    #
    # @param quiet [Boolean] Whether to suppress status output
    # @return [Integer] Exit code (0 = all running, 2 = some not running)
    def status(quiet: false)
      code = 0

      for_each_worker do |worker|
        pid_file, pid, active = read_pid(worker)

        if pid_file && pid && active
          puts "Worker ##{worker.id} (#{worker.name}): Running" unless quiet
        elsif pid_file
          warn "Worker ##{worker.id} (#{worker.name}): Not running (stale PID file)" unless quiet
          code = 2
        else
          warn "Worker ##{worker.id} (#{worker.name}): Not running" unless quiet
          code = 2
        end
      end

      return code
    end

    # Watches workers and starts them if they're not running.
    # In Rails environments, respects the tmp/stop.txt file.
    #
    # @return [Integer] Exit code from start operation or 0 if no action needed
    def watch
      if defined?(Rails)
        should_be_running = !File.exist?(Rails.root.join('tmp/stop.txt'))
      else
        should_be_running = true
      end

      if should_be_running && status(quiet: true) != 0
        return start(quiet: Workhorse.silence_watcher)
      else
        return 0
      end
    end

    # Restarts all workers by stopping and then starting them.
    #
    # @return [Integer] Exit code from start operation
    def restart
      stop
      return start
    end

    # Sends HUP signal to all workers to restart their logging.
    # Useful for log rotation without full process restart.
    #
    # @return [Integer] Exit code (0 = success, 2 = some signals failed)
    def restart_logging
      code = 0

      Workhorse.debug_log("restart_logging: sending HUP to #{@workers.count} worker(s)")

      for_each_worker do |worker|
        _pid_file, pid, active = read_pid(worker)

        Workhorse.debug_log("restart_logging: worker ##{worker.id} (#{worker.name}): pid=#{pid.inspect}, active=#{active.inspect}")

        next unless pid && active

        begin
          Process.kill 'HUP', pid
          Workhorse.debug_log("restart_logging: HUP sent successfully to PID #{pid}")
          puts "Worker (#{worker.name}) ##{worker.id}: Sent signal for restart-logging"
        rescue Errno::ESRCH
          Workhorse.debug_log("restart_logging: HUP failed for PID #{pid}: process not found")
          warn "Worker (#{worker.name}) ##{worker.id}: Could not send signal for restart-logging, process not found"
          code = 2
        end
      end

      Workhorse.debug_log("restart_logging: done, exit code=#{code}")
      return code
    end

    # Sends USR1 signal to all workers to initiate a soft restart.
    # Workers will finish their current jobs before shutting down.
    # The watch mechanism will then start fresh workers.
    # This method returns immediately (fire-and-forget).
    #
    # @return [Integer] Exit code (0 = success, 2 = some signals failed)
    def soft_restart
      code = 0

      Workhorse.debug_log("Daemon: sending USR1 to #{@workers.count} worker(s)")

      for_each_worker do |worker|
        _pid_file, pid, active = read_pid(worker)

        Workhorse.debug_log("Daemon soft_restart: worker ##{worker.id} (#{worker.name}): pid=#{pid.inspect}, active=#{active.inspect}")

        next unless pid && active

        begin
          Process.kill 'USR1', pid
          Workhorse.debug_log("Daemon: USR1 sent successfully to PID #{pid}")
          puts "Worker (#{worker.name}) ##{worker.id}: Sent soft-restart signal"
        rescue Errno::ESRCH
          Workhorse.debug_log("Daemon: USR1 failed for PID #{pid}: process not found")
          warn "Worker (#{worker.name}) ##{worker.id}: Process not found"
          code = 2
        end
      end

      Workhorse.debug_log("Daemon soft_restart: done, exit code=#{code}")
      return code
    end

    private

    # Executes the given block for each defined worker.
    #
    # @yield [Worker] Each worker instance
    # @return [void]
    # @private
    def for_each_worker(&block)
      @workers.each(&block)
    end

    # Starts a single worker process.
    #
    # @param worker [Worker] The worker to start
    # @return [void]
    # @private
    def start_worker(worker)
      check_rails_env if defined?(Rails)

      Workhorse.debug_log("Daemon: forking worker ##{worker.id} (#{worker.name})")
      pid = fork do
        # Detach from the parent's session so that the worker is not killed by
        # SIGHUP when the parent (ShellHandler) exits. Without this, the kernel
        # sends SIGHUP to the foreground process group when the session leader
        # (e.g. a cron- or systemd-started ShellHandler) terminates.
        Process.setsid
        $0 = process_name(worker)
        # Close inherited lockfile fd to prevent holding the flock after parent exits
        @lockfile&.close
        # Reopen pipes to prevent #107576
        $stdin.reopen File.open(File::NULL, 'r')
        null_out = File.open File::NULL, 'w'
        $stdout.reopen null_out
        $stderr.reopen null_out

        worker.block.call
      end
      worker.pid = pid
      File.write(pid_file_for(worker), pid)
      Process.detach(pid)
      Workhorse.debug_log("Daemon: worker ##{worker.id} (#{worker.name}) forked with PID #{pid}")
    end

    # Stops a single worker process.
    #
    # @param pid_file [String] Path to the worker's PID file
    # @param pid [Integer] The worker's process ID
    # @param kill [Boolean] Whether to use KILL signal
    # @return [void]
    # @private
    def stop_worker(pid_file, pid, kill: false)
      signals = kill ? %w[KILL] : %w[TERM INT]

      Workhorse.debug_log("Daemon: stopping PID #{pid} with signals #{signals.join(', ')}")
      loop do
        begin
          signals.each { |signal| Process.kill(signal, pid) }
        rescue Errno::ESRCH
          break
        end

        sleep 1
      end

      Workhorse.debug_log("Daemon: PID #{pid} stopped")
      File.delete(pid_file)
    end

    # Sends HUP signal to a worker process.
    #
    # @param pid [Integer] The worker's process ID
    # @return [void]
    # @private
    def hup_worker(pid)
      Process.kill('HUP', pid)
    end

    # Generates a process name for a worker.
    #
    # @param worker [Worker] The worker instance
    # @return [String] Process name for ps output
    # @private
    def process_name(worker)
      if defined?(Rails)
        path = Rails.root
      else
        path = $PROGRAM_NAME
      end

      return "Workhorse #{worker.name} ##{worker.id}: #{path}"
    end

    # Checks if a process with the given PID is running.
    #
    # @param pid [Integer] Process ID to check
    # @return [Boolean] True if process is running
    # @private
    def process?(pid)
      return begin
        Process.kill(0, pid)
        true
      rescue Errno::EPERM, Errno::ESRCH
        false
      end
    end

    # Returns the PID file path for a worker.
    #
    # @param worker [Worker] The worker instance
    # @return [String] Path to the PID file
    # @private
    def pid_file_for(worker)
      @pidfile % worker.id
    end

    # Reads PID information for a worker.
    #
    # @param worker [Worker] The worker instance
    # @return [Array<String, Integer, Boolean>] PID file path, PID, and active status
    # @private
    def read_pid(worker)
      file = pid_file_for(worker)
      pid = nil
      active = false

      if File.exist?(file)
        raw_pid = File.read(file)

        unless raw_pid.blank?
          pid = Integer(raw_pid)
          active = process?(pid)
        end
      else
        return nil, nil
      end

      return file, pid, active
    end

    # Warns if not running in production environment.
    #
    # @return [void]
    # @private
    def check_rails_env
      unless Rails.env.production?
        warn 'WARNING: Always run workhorse workers in production environment. Other environments can lead to unexpected behavior.'
      end
    end
  end
end
