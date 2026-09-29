module Workhorse
  # Registry of scheduled jobs, populated through {Workhorse.schedules}.
  #
  # A schedule's job class and options live here, in code, and are addressed
  # from the database by key. Storing the class in the database instead would
  # turn renaming it into a data migration; keeping it here makes it a
  # reconciliation, which {Workhorse::Schedule.reconcile!} performs on worker
  # startup.
  #
  # @see Workhorse::Schedule
  module Schedules
    # Catch-up policies, deciding what happens to occurrences whose time
    # passed while nothing was materialising them.
    CATCH_UP_POLICIES = %i[run run_once skip].freeze

    # Default number of missed occurrences a `:run` schedule materialises at
    # once, so that a long outage cannot enqueue thousands of jobs.
    DEFAULT_MAX_CATCH_UP = 10

    # One entry of the registry.
    class Definition
      attr_reader :key
      attr_reader :job
      attr_reader :cron
      attr_reader :timezone
      attr_reader :queue
      attr_reader :priority
      attr_reader :description
      attr_reader :params
      attr_reader :catch_up
      attr_reader :grace
      attr_reader :max_catch_up
      attr_reader :max_lateness
      attr_reader :expires_after

      # @see Workhorse::Schedules::Dsl#schedule
      def initialize(key, job:, cron:, timezone: nil, queue: nil, priority: 0, description: nil,
                     params: {}, catch_up: :run_once, grace: nil, max_catch_up: DEFAULT_MAX_CATCH_UP,
                     max_lateness: nil, expires_after: nil)
        @key = key.to_s
        @job = job.to_s
        @cron = cron.to_s
        @timezone = timezone&.to_s
        @queue = queue
        @priority = priority
        @description = description
        @params = (params || {}).freeze
        @catch_up = catch_up.to_sym
        @grace = grace
        @max_catch_up = max_catch_up
        @max_lateness = max_lateness
        @expires_after = expires_after

        validate!
        freeze
      end

      # Returns the parsed cron expression.
      #
      # @return [Fugit::Cron]
      def parsed_cron
        return self.class.parse_cron(cron, timezone)
      end

      # Parses a cron expression, applying a timezone if one is given. Fugit
      # takes the zone as a trailing token of the expression.
      #
      # @param cron [String]
      # @param timezone [String, nil]
      # @return [Fugit::Cron, nil] nil if the expression cannot be parsed
      def self.parse_cron(cron, timezone = nil)
        return Fugit::Cron.parse(timezone ? "#{cron} #{timezone}" : cron)
      end

      private

      def validate!
        fail ArgumentError, 'Schedule key must not be blank.' if key.empty?
        fail ArgumentError, "Schedule #{key.inspect}: job must not be blank." if job.empty?

        unless CATCH_UP_POLICIES.include?(catch_up)
          fail ArgumentError, "Schedule #{key.inspect}: catch_up must be one of " \
                              "#{CATCH_UP_POLICIES.inspect}, got #{catch_up.inspect}."
        end

        # Without a grace period, ":skip" has no way of telling an occurrence
        # that is merely a moment late from one that is a day late, and would
        # silently drop every occurrence.
        if catch_up == :skip && grace.nil?
          fail ArgumentError, "Schedule #{key.inspect}: catch_up :skip requires a grace period, " \
                              'which is how late an occurrence may be and still run.'
        end

        if catch_up == :run && !(max_catch_up.is_a?(Integer) && max_catch_up >= 1)
          fail ArgumentError, "Schedule #{key.inspect}: max_catch_up must be an Integer >= 1, " \
                              "got #{max_catch_up.inspect}."
        end

        if parsed_cron.nil?
          zone = timezone ? " for timezone #{timezone.inspect}" : nil
          fail ArgumentError, "Schedule #{key.inspect}: #{cron.inspect} is not a valid cron " \
                              "expression#{zone}."
        end

        return
      end
    end

    # Evaluator for the {Workhorse.schedules} block.
    class Dsl
      # @private
      def initialize(definitions)
        @definitions = definitions
      end

      # Registers a scheduled job.
      #
      # @param key [String, Symbol] Stable name of this schedule. Occurrences
      #   are tracked under it, so renaming it starts a new schedule.
      # @param job [String, Class] Job class. May be a plain class responding
      #   to `perform`, an `ActiveJob::Base` subclass, or a
      #   `RailsOps::Operation`.
      # @param cron [String] Cron expression in crontab format.
      # @param timezone [String, nil] Timezone the expression is read in, e.g.
      #   `'Europe/Zurich'`. Defaults to the process's local time.
      # @param queue [String, Symbol, nil] Queue to enqueue into.
      # @param priority [Integer] Job priority, lower runs first.
      # @param description [String, nil] Description of the enqueued job.
      # @param params [Hash] Parameters for the job. Passed as operation
      #   params for RailsOps operations and splatted as keyword arguments
      #   otherwise.
      # @param catch_up [Symbol] What to do with occurrences whose time passed
      #   while nothing was materialising them:
      #   * `:run_once` (default) collapses them into a single job,
      #   * `:run` materialises each, up to `max_catch_up`,
      #   * `:skip` drops those older than `grace`.
      # @param grace [Numeric, nil] Seconds an occurrence may be late and
      #   still run. Required for `catch_up: :skip`.
      # @param max_catch_up [Integer] Most occurrences `catch_up: :run`
      #   materialises at once.
      # @param max_lateness [Numeric, nil] Seconds the job may start after its
      #   occurrence before {Workhorse.on_job_late} is called.
      # @param expires_after [Numeric, nil] Seconds after its occurrence at
      #   which the job is no longer worth running. It is then expired instead
      #   of performed, and {Workhorse.on_job_expired} is called.
      # @return [void]
      def schedule(key, **options)
        definition = Definition.new(key, **options)

        if @definitions.key?(definition.key)
          fail ArgumentError, "Schedule #{definition.key.inspect} is already defined."
        end

        @definitions[definition.key] = definition

        return
      end
    end

    class << self
      # @return [Hash{String => Definition}] The registered schedules by key
      def definitions
        return @definitions ||= {}
      end

      # Registers schedules, see {Workhorse::Schedules::Dsl#schedule}.
      #
      # @yield Block evaluated against the DSL
      # @return [void]
      def define(&block)
        Dsl.new(definitions).instance_eval(&block)

        return
      end

      # @param key [String, Symbol]
      # @return [Definition, nil] The schedule registered under `key`
      def [](key)
        return definitions[key.to_s]
      end

      # @return [Boolean] Whether any schedule is registered
      def any?
        return definitions.any?
      end

      # Empties the registry. Intended for testing.
      #
      # @return [void]
      def reset!
        @definitions = {}

        return
      end
    end
  end
end
