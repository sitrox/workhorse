module Workhorse
  module Notifiers
    # Notifier that announces an enqueued job by touching a single file, which
    # waiting workers stat once per sleep slice.
    #
    # This costs no database work at all and roughly a microsecond of local CPU
    # per check, on a tick the poller performs anyway, so a worker can react
    # within {Workhorse::Poller::SLEEP_SLICE} rather than within its polling
    # interval.
    #
    # It requires that the enqueueing process and the workers share a
    # filesystem, which in practice means the same host. Where they do not -
    # workers on a machine of their own, a console on another host - the touch
    # simply never reaches those workers and they fall back to polling. Use
    # {Workhorse::Notifiers::Redis} if that case has to be fast as well.
    #
    # One file is used for every queue. A worker that serves a subset of queues
    # therefore wakes for jobs it cannot run and polls once for nothing; this
    # is cheaper than having such a worker scan a directory on every tick.
    #
    # Detection relies on the file's modification time, so the filesystem has
    # to keep sub-second mtimes - every current local filesystem does. On one
    # that does not, two touches within the same second may be seen as one, and
    # the worker waits for its regular poll instead.
    class FileSystem < Base
      # @return [String] Path of the file that is touched
      attr_reader :path

      # @param path [String, nil] Path of the file to touch. Defaults to
      #   {Workhorse.notification_path}.
      def initialize(path: nil)
        super()
        @path = (path || Workhorse.notification_path).to_s
      end

      # Touches the notification file, creating it and its directory if
      # necessary.
      #
      # @param queue [String, Symbol, nil] Ignored, see the class description
      # @return [void]
      def notify(queue: nil) # rubocop:disable Lint/UnusedMethodArgument
        FileUtils.mkdir_p(::File.dirname(path))
        FileUtils.touch(path)
      rescue StandardError => e
        # Best-effort by contract: a job must still be enqueued when it cannot
        # be announced. The worker finds it on its next poll.
        Workhorse.debug_log("Notification failed: #{e.class}: #{e.message}")
      end

      # Returns the notification file's modification time.
      #
      # @return [Time, nil] mtime, or nil if the file does not exist yet
      def token
        return ::File.mtime(path)
      rescue SystemCallError
        return nil
      end
    end
  end
end
