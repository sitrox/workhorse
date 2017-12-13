module Workhorse
  class Daemon
    def initialize(count: 1, pidfile: nil, quiet: false, &block)
      @count = count
      @pidfile = pidfile
      @quiet = quiet
      @block = block

      fail 'Count must be an integer > 0.' unless count.is_a?(Integer) && count > 0

      if @pidfile.nil?
        @pidfile = count > 1 ? 'tmp/pids/workhorse.%i.pid' : 'tmp/pids/workhorse.pid'
      elsif @count > 1 && !@pidfile.include?('%s')
        fail 'Pidfile must include placeholder "%s" for worker id when specifying a count > 1.'
      end
    end

    def start
      code = 0

      for_each_worker do |worker_id|
        pid_file, pid = read_pid(worker_id)

        if pid_file && pid
          warn "Worker ##{worker_id}: Already running (PID #{pid})"
          code = 1
        elsif pid_file
          File.delete pid_file
          puts "Worker ##{worker_id}: Startup (stale pid file)"
          start_worker worker_id
        else
          warn "Worker ##{worker_id}: Starting"
          start_worker worker_id
        end
      end

      return code
    end

    def stop
      code = 0

      for_each_worker do |worker_id|
        pid_file, pid = read_pid(worker_id)

        if pid_file && pid
          puts "Worker ##{worker_id}: Shutdown"
          stop_worker pid_file, pid
        elsif pid_file
          File.delete pid_file
          puts "Worker ##{worker_id}: Already shut down (stale PID file)"
        else
          warn "Worker ##{worker_id}: Already shut down"
          code = 1
        end
      end

      return code
    end

    def status(quiet: false)
      code = 0

      for_each_worker do |worker_id|
        pid_file, pid = read_pid(worker_id)

        if pid_file && pid
          puts "Worker ##{worker_id}: Running" unless quiet
        elsif pid_file
          warn "Worker ##{worker_id}: Not running (stale PID file)" unless quiet
          code = 1
        else
          warn "Worker ##{worker_id}: Not running" unless quiet
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
      1.upto(@count, &block)
    end

    def start_worker(worker_id)
      pid = fork do
        $0 = process_name(worker_id)
        @block.call
      end
      IO.write(pid_file_for(worker_id), pid)
    end

    def stop_worker(pid_file, pid)
      loop do
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
          break
        end

        sleep 1
      end

      File.delete(pid_file)
    end

    def process_name(worker_id)
      if defined?(Rails)
        path = Rails.root
      else
        path = $PROGRAM_NAME
      end

      return "Workhorse Worker ##{worker_id}: #{path}"
    end

    def process?(pid)
      return begin
        Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    def pid_file_for(worker_id)
      @pidfile % worker_id
    end

    def read_pid(worker_id)
      file = pid_file_for(worker_id)

      if File.exist?(file)
        pid = IO.read(file).to_i
        return file, process?(pid) ? pid : nil
      else
        return nil, nil
      end
    end
  end
end
