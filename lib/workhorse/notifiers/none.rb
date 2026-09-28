module Workhorse
  module Notifiers
    # Notifier that does nothing, leaving workers to discover jobs by polling.
    # This is the default.
    class None < Base
    end
  end
end
