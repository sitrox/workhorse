module Workhorse
  # Extension module for ActiveJob integration.
  module ActiveJobExtension
    extend ActiveSupport::Concern

    included do
      class_attribute :_skip_tx
      self._skip_tx = false
    end

    module ClassMethods
      # Marks this job class to skip database transactions during execution.
      # Use this for jobs that manage their own transactions or have long-running
      # operations that should not be wrapped in a transaction.
      #
      # @return [void]
      def skip_tx
        self._skip_tx = true
      end

      # Checks if this job class should skip database transactions.
      #
      # @return [Boolean] True if transactions should be skipped
      def skip_tx?
        _skip_tx
      end
    end
  end
end
