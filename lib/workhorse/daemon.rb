module Workhorse
  class Daemon
    class Worker
      attr_reader :id
      attr_reader :name
      attr_reader :block
      attr_accessor :pid

      def initialize(id, name, &block)
        @id = id
        @name = name
        @block = block
      end
    end

    # @private
    attr_reader :workers

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

    def worker(name = 'Job Worker', &block)
      @workers << Worker.new(@workers.size + 1, name, &block)
    end

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

    def restart
      stop
      return start
    end

    def restart_logging
      code = 0

      for_each_worker do |worker|
        _pid_file, pid, active = read_pid(worker)

        next unless pid && active

        begin
          Process.kill 'HUP', pid
          puts "Worker (#{worker.name}) ##{worker.id}: Sent signal for restart-logging"
        rescue Errno::ESRCH
          warn "Worker (#{worker.name}) ##{worker.id}: Could not send signal for restart-logging, process not found"
          code = 2
        end
      end

      return code
    end

    private

    def for_each_worker(&block)
      @workers.each(&block)
    end

    def start_worker(worker)
      pid = fork do
        $0 = process_name(worker)
        # Reopen pipes to prevent #107576
        $stdin.reopen File.open('/dev/null', 'r')
        null_out = File.open '/dev/null', 'w'
        $stdout.reopen null_out
        $stderr.reopen null_out

        worker.block.call
      end
      worker.pid = pid
      File.write(pid_file_for(worker), pid)
      Process.detach(pid)
    end

    def stop_worker(pid_file, pid, kill: false)
      signals = kill ? %w[KILL] : %w[TERM INT]

      loop do
        begin
          signals.each { |signal| Process.kill(signal, pid) }
        rescue Errno::ESRCH
          break
        end

        sleep 1
      end

      File.delete(pid_file)
    end

    def hup_worker(pid)
      Process.kill('HUP', pid)
    end

    def process_name(worker)
      if defined?(Rails)
        path = Rails.root
      else
        path = $PROGRAM_NAME
      end

      return "Workhorse #{worker.name} ##{worker.id}: #{path}"
    end

    def process?(pid)
      return begin
        Process.kill(0, pid)
        true
      rescue Errno::EPERM, Errno::ESRCH
        false
      end
    end

    def pid_file_for(worker)
      @pidfile % worker.id
    end

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
  end
end
