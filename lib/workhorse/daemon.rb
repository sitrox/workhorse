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

    def start
      code = 0

      for_each_worker do |worker|
        pid_file, pid = read_pid(worker)

        if pid_file && pid
          warn "Worker ##{worker.id} (#{worker.name}): Already started (PID #{pid})"
          code = 1
        elsif pid_file
          File.delete pid_file
          puts "Worker ##{worker.id} (#{worker.name}): Starting (stale pid file)"
          start_worker worker
        else
          warn "Worker ##{worker.id} (#{worker.name}): Starting"
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
          code = 1
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
          code = 1
        else
          warn "Worker ##{worker.id} (#{worker.name}): Not running" unless quiet
          code = 1
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
        return start
      else
        return 0
      end
    end

    def restart
      stop
      return start
    end

    private

    def for_each_worker(&block)
      @workers.each(&block)
    end

    def start_worker(worker)
      pid = fork do
        $0 = process_name(worker)
        worker.block.call
      end
      IO.write(pid_file_for(worker), pid)
    end

    def stop_worker(pid_file, pid, kill = false)
      signal = kill ? 'KILL' : 'TERM'

      loop do
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          break
        end

        sleep 1
      end

      File.delete(pid_file)
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
        pid = IO.read(file).to_i
        return file, process?(pid) ? pid : nil
      else
        return nil, nil
      end
    end
  end
end
