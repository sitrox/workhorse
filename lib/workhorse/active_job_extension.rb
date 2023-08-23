module Workhorse
  module ActiveJobExtension
    extend ActiveSupport::Concern

    included do
      class_attribute :_skip_tx
      self._skip_tx = false
    end

    module ClassMethods
      def skip_tx
        self._skip_tx = true
      end

      def skip_tx?
        _skip_tx
      end
    end
  end
end
