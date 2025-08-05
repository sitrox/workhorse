module Workhorse
  # Scoped environment for method delegation.
  # Used internally to provide scoped access to daemon configuration methods.
  #
  # @private
  class ScopedEnv
    # Creates a new scoped environment.
    #
    # @param delegation_object [Object] Object to delegate method calls to
    # @param methods [Array<Symbol>] Methods that should be delegated
    # @param backup_binding [Object, nil] Fallback object for method resolution
    def initialize(delegation_object, methods, backup_binding = nil)
      @delegation_object = delegation_object
      @methods = methods
      @backup_binding = backup_binding
    end

    # Handles method delegation to the configured objects.
    #
    # @param symbol [Symbol] Method name
    # @param args [Array] Method arguments
    # @param block [Proc, nil] Block to pass to the method
    # @return [Object] Result of the delegated method call
    def method_missing(symbol, *args, &block)
      if @methods.include?(symbol)
        @delegation_object.send(symbol, *args, &block)
      elsif @backup_binding.try(:respond_to?, symbol)
        @backup_binding.send(symbol, *args, &block)
      else
        super
      end
    end

    # Checks if this object can respond to the given method.
    #
    # @param symbol [Symbol] Method name to check
    # @param include_private [Boolean] Whether to include private methods
    # @return [Boolean] True if method can be handled
    def respond_to_missing?(symbol, include_private = false)
      @methods.include?(symbol) || super
    end
  end
end
