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
      # Check that no pid file exists
      @count.times do |worker_id|
        file = pid_file_for(worker_id)
        if File.exist?(file)
          fail "PID file #{file} already exists."
        end
      end

      # Start daemons
      @count.times do |worker_id|
        say "Starting worker #{worker_id}."
        pid = fork(&@block)
        IO.write(pid_file_for(worker_id), pid)
      end
    end

    def stop
      # Check that all pid files exist
      @count.times do |worker_id|
        file = pid_file_for(worker_id)
        unless File.exist?(file)
          fail "PID file #{file} not found."
        end
      end

      # Stop daemons
      @count.times do |worker_id|
        file = pid_file_for(worker_id)
        pid = IO.read(file).to_i
        say "Stopping worker #{worker_id}."

        loop do
          begin
            Process.kill('TERM', pid)
          rescue Errno::ESRCH
            break
          end

          sleep 1
        end

        File.delete(file)
      end
    end

    # Returns:
    #   0: All workers running
    #   3: One or more workers not running
    #  99: One or more workers not running but at least one pid file exists
    def status
      status = 0

      @count.times do |worker_id|
        file = pid_file_for(worker_id)
        if File.exist?(file)
          pid = IO.read(file).to_i

          if process?(pid)
            say "Worker #{worker_id} is running."
          else
            say "Worker #{worker_id} is not running, but PID file found."
            status = 99
          end
        else
          say "Worker #{worker_id} is not running."
          status = 3 unless status > 3
        end
      end

      return 3
    end

    def watchdog
      if defined?(Rails)
        should_be_running = !File.exist?(Rails.root.join('tmp/stop.txt'))
      else
        should_be_running = true
      end

      if should_be_running && status != 0
        start
      end
    end

    def restart
      stop
      start
    end

    private

    def say(text)
      unless @quiet
        warn text
      end
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
  end
end
