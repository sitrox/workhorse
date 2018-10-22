Workhorse.setup do |config|
  # Set this to false in order to prevent jobs from being automatically
  # wrapped into a transaction. The built-in workhorse logic will still run
  # in transactions.
  #
  # config.perform_jobs_in_tx = true

  # Enable and configure this to specify an alternative callback for handling
  # transactions.
  #
  # config.tx_callback = proc do |&block|
  #   ActiveRecord::Base.transaction&(&block)
  # end

  # Enable and configure this to specify a callback for handling worker
  # exceptions:
  #
  # config.on_exception = proc do |exception|
  #   # Do something with exception, i.e.
  #   # ExceptionNotifier.notify_exception(exception)
  # end
end
