require 'active_support/all'
require 'rake/tasklib'
require 'colorize'

module Testbench
  class Config
    attr_accessor :pattern
    attr_accessor :libs

    def initialize(&block)
      self.pattern = 'test/**/*_test.rb'
      self.libs = []

      instance_exec(self, &block) if block_given?
    end
  end

  class Runner
    attr_reader :config
    attr_reader :reporter

    def initialize(&block)
      @config = Config.new(&block)
    end

    def run
      @reporter = Reporter.new

      config.libs.each do |lib|
        $LOAD_PATH.unshift File.expand_path(lib)
      end

      # Trap SIGINT (ctrl+c)
      trap('SIGINT') { exit 1 }

      # Load all test files
      Dir.glob(config.pattern).shuffle.each do |file|
        load file
      end

      # Determine test cases
      classes = Testbench::Test.descendants.reject(&:abstract?)

      # Run tests
      classes.each do |test_class|
        test_class.run(reporter)
      end
    end
  end

  class Task < Rake::TaskLib
    def initialize(&block)
      super()

      desc 'Run tests'
      task :foox do
        Runner.new(&block).run
      end
    end
  end

  class Reporter
    def initialize
      @current_class = nil
      @current_method = nil
      @method_started = false
    end

    def assert
      result = yield
      print '✓'.green
      return result
    rescue AssertionError
      print '❌'.red
      fail
    end

    def start_class(klass)
      @current_class = klass
      puts klass.name.blue.bold
      yield
    ensure
      @current_class = nil
    end

    def start_method(klass)
      @current_method = klass
      puts klass.name.light_blue
      puts "\n" unless @method_started
      @method_started = true
      yield
    rescue AssertionError => e
      puts "Assertion failed: #{e.message}"
    ensure
      @current_method = nil
    end
  end

  class AssertionError < StandardError
  end

  class Test
    class_attribute :_setup_blocks
    self._setup_blocks = [].freeze

    class_attribute :_teardown_blocks
    self._teardown_blocks = [].freeze

    def self.abstract
      @_abstract = true
    end

    def self.abstract?
      !!@_abstract
    end

    def self.setup(&block)
      self._setup_blocks = (_setup_blocks + [block]).freeze
    end

    def self.teardown(&block)
      self._teardown_blocks = (_teardown_blocks + [block]).freeze
    end

    def self.run(reporter)
      reporter.start_class self do
        methods = public_instance_methods.filter { |m| m.start_with?('test_') }.shuffle
        test = new(reporter)
        methods.each do |method|
          test.with_setup_and_teardown do
            reporter.start_method(method) do
              test.public_send(method)
            end
          end
        end
      end
    end

    attr_reader :reporter

    def initialize(reporter)
      @reporter = reporter
    end

    def with_setup_and_teardown
      self.class._setup_blocks.each { |b| instance_exec(&b) }
      setup
      yield
    ensure
      self.class._teardown_blocks.each { |b| instance_exec(&b) }
      teardown
    end

    def setup
    end

    def teardown
    end

    def assert_equal(expected, actual, message = nil)
      reporter.assert do
        if expected != actual
          message ||= "Unexpected value:\n  Expected: #{expected.inspect}\n  Actual: #{actual.inspect}"
          fail AssertionError, message
        end
      end
    end

    def refute_equal(expected, actual, message = nil)
      reporter.assert do
        if expected == actual
          message ||= "Expected value #{expected.inspect} not to equal #{actual.inspect}."
          fail AssertionError, message
        end
      end
    end

    def assert_match(exp, value, message = nil)
      reporter.assert do
        unless exp.match?(value)
          message ||= "Expected #{value.inspect} to match #{exp.inspect}."
          fail AssertionError, message
        end
      end
    end

    def assert_nil(actual, message = nil)
      reporter.assert do
        assert_equal nil, actual, message
      end
    end

    def assert_not_nil(actual, message = nil)
      reporter.assert do
        refute_equal nil, actual, message
      end
    end

    def assert_nothing_raised(message = nil)
      reporter.assert do
        begin
          yield
        rescue Exception => e
          message ||= 'Expected no exception, but an exception of type ' \
            "#{e.class.name.inspect} with message #{e.message.inspect} was raised."

          fail AssertionError, message
        end
      end
    end

    def assert_raises(klass = nil, message = nil, assertion_message = nil)
      reporter.assert do
        begin
          exception = nil
          yield
        rescue Exception => e
          exception = e
          next exception
        ensure
          if exception.nil? || (klass && !(exception.class < klass)) || (message && exception.message != message)
            unless assertion_message
              assertion_message = []

              assertion_message << 'Expected block to raise an exception'
              assertion_message << "of type #{klass.name.inspect}" if klass
              assertion_message << "with message #{message.inspect}" if message

              assertion_message = assertion_message.join(' ')
              assertion_message << ', but'

              if exception.nil?
                assertion_message << 'nothing was raised'
              elsif klass && !exception.class < klass
                assertion_message << "exception has type #{klass.name.inspect}"
              elsif message && exception.message != message
                assertion_message << "message is #{message}"
              end

              assertion_message << '.'
            end

            fail AssertionError, assertion_message
          end
        end
      end
    end

    def assert(value, message = nil)
      reporter.assert do
        unless value
          message ||= "Expected value #{value.inspect} value to be truthy"
          fail AssertionError, message
        end
      end
    end

    def refute(value, message = nil)
      reporter.assert do
        if value
          message ||= "Expected value #{value.inspect} value to be falsy"
          fail AssertionError, message
        end
      end
    end

    alias assert_not refute
    alias assert_not_equal refute_equal
  end
end
