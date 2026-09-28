module Workhorse
  module Notifiers
    # Interface for notifiers, which let a worker start a job without waiting
    # for its next poll.
    #
    # Polling remains the floor: a notification that is never delivered costs
    # latency and nothing else, as the regular poll still happens after
    # `polling_interval` and picks the job up. Implementations must therefore
    # be best-effort and must never raise from {#notify}, which runs in the
    # process that enqueues a job.
    #
    # Workers do not consume notifications. Instead, {#token} returns a value
    # that changes whenever a notification has arrived, and each poller
    # remembers the last one it saw. This keeps several workers in one process
    # independent of one another, as none of them can take a notification away
    # from the others.
    #
    # @abstract Subclass and override {#notify} and {#token}.
    class Base
      # Announces that a job has been enqueued. Called in the enqueueing
      # process, after the surrounding transaction has committed.
      #
      # Must never raise: an enqueue may not fail because a notification could
      # not be delivered.
      #
      # @param queue [String, Symbol, nil] Queue the job was enqueued into
      # @return [void]
      def notify(queue: nil); end

      # Prepares this notifier for use by a worker in this process. Called
      # when a worker starts, and may be called several times per process.
      #
      # @return [void]
      def start; end

      # Releases what {#start} acquired. Called when a worker shuts down.
      #
      # @return [void]
      def stop; end

      # Returns a value that differs from the previously returned one whenever
      # at least one notification has arrived in between. Pollers compare it
      # with `!=` and hold their own last-seen value, so no ordering is implied
      # and nothing is consumed.
      #
      # Returns nil when nothing can be said, for instance because no
      # notification has ever been sent.
      #
      # @return [Object, nil] Comparable token, or nil
      def token
        return nil
      end
    end
  end
end
