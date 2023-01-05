module Workhorse
  class Daemon
    class Worker
      attr_reader :id
      attr_reader :name
      attr_reader :block

      def initialize(id, name, &block)
        @id = id
        @name = name
        @block = block
      end
    end

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

      for_each_worker do |worker|
        pid_file, pid = read_pid(worker)

        if pid_file && pid
          warn "Worker ##{worker.id} (#{worker.name}): Already started (PID #{pid})" unless quiet
          code = 2
        elsif pid_file
          File.delete pid_file
          puts "Worker ##{worker.id} (#{worker.name}): Starting (stale pid file)" unless quiet
          start_worker worker
        else
          warn "Worker ##{worker.id} (#{worker.name}): Starting" unless quiet
          start_worker worker
        end
      end

      return code
    end

    def stop(kill = false)
      code = 0

      for_each_worker do |worker|
        pid_file, pid = read_pid(worker)

        if pid_file && pid
          puts "Worker (#{worker.name}) ##{worker.id}: Stopping"
          stop_worker pid_file, pid, kill
        elsif pid_file
          File.delete pid_file
          puts "Worker (#{worker.name}) ##{worker.id}: Already stopped (stale PID file)"
        else
          warn "Worker (#{worker.name}) ##{worker.id}: Already stopped"
          code = 2
        end
      end

      return code
    end

    def status(quiet: false)
      code = 0

      for_each_worker do |worker|
        pid_file, pid = read_pid(worker)

        if pid_file && pid
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
        _pid_file, pid = read_pid(worker)

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
        STDIN.reopen File.open('/dev/null', 'r')
        null_out = File.open '/dev/null', 'w'
        STDOUT.reopen null_out
        STDERR.reopen null_out

        worker.block.call
      end
      IO.write(pid_file_for(worker), pid)
      Process.detach(pid)
    end

    def stop_worker(pid_file, pid, kill = false)
      signals = kill ? %w[KILL] : %w[TERM INT]

      loop do
        begin
          puts "Sending signals #{signals.inspect}".red
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

      if File.exist?(file)
        raw_pid = IO.read(file)
        return nil, nil if raw_pid.blank?
        pid = Integer(raw_pid)
        return file, process?(pid) ? pid : nil
      else
        return nil, nil
      end
    end
  end
end
