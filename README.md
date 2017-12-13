[![Build Status](https://travis-ci.org/sitrox/workhorse.svg?branch=master)](https://travis-ci.org/sitrox/workhorse)
[![Gem Version](https://badge.fury.io/rb/workhorse.svg)](https://badge.fury.io/rb/workhorse)

# Workhorse

**This Gem is still in an early stage of development. Please not use this in production yet.**

Multi-threaded job backend with database queuing for ruby.

## Introduction

What it is:

* Jobs are instances of classes that support the `perform` method.
* Jobs are persisted in the database using ActiveRecord.
* You can start one or more worker processes.
* Each worker is configurable as to which queue(s) it processes.
* Each worker polls the database and spawns a number of threads to execute jobs
  of different queues simultaneously.

What it isn't:

* It cannot spawn new processes. Jobs are run in separate threads but not in
  separate processes (unless you start multiple worker processes manually).
* It does not support retries.

## Installation

### Requirements

* A database and table handler that properly supports row-level locking (such as
  MySQL with InnoDB, PostgreSQL or Oracle).
* An operating system and file system that supports file locking.

### Installing under Rails

1. Add `workhorse` to your `Gemfile`:

   ```ruby
   gem 'workhorse'
   ```

2. Run the install generator:

   ```bash
   bin/rails generate workhorse:install
   ```

   This generates:

   * A database migration for creating the `jobs` table
   * An initializer `config/initializers/workhorse.rb` for global configuration
   * A daemon worker script under `bin/workhorse.rb`

   Please customize the configuration files to your liking.

3. If running Rails, create an initializer under
   `config/initializers/workhorse.rb`:

   ```ruby
   Workhorse.setup do |config|
     # Use `tx_callback` to specify an alternate block that handels
     # transactions. This defaults to the following.
     # config.tx_callback = proc do |&block|
     #   ActiveRecord::Base.transaction&(&block)
     # end

     # Set this to false in order to prevent jobs from being automatically
     # wrapped into a transaction. The built-in workhorse logic will still run
     # in transactions.
     config.perform_jobs_in_tx = true
   end
   ```

## Queuing jobs

### Basic jobs

Workhorse can handle any jobs that support the `perform` method and are
serializable. To queue a basic job, use the static method `Workhorse.enqueue`:

```ruby
class MyJob
  def perform
    puts "Hello world"
  end
end

Workhorse.enqueue MyJob.new, queue: :test
```

In the above example, we also specify a queue named `:test`. This means that
this job will never run simoultaneously with other jobs in the same queue. If no
queue is given, the job can always be executed simoultaneously with any other
job.

### RailsOps operations

Workhorse allows you to easily queue
[RailsOps](https://github.com/sitrox/rails_ops) operations using the static
method `Workhorse.enqueue_op`:

```ruby
Workhorse.enqueue Operations::Jobs::CleanUpDatabase, quiet: true
```

Params passed using the second argument will be used for operation instantiation
at job execution.

You can also specify a queue:

```ruby
Workhorse.enqueue Operations::Jobs::CleanUpDatabase, { quiet: true }, queue: :maintenance
```

## Configuring and starting workers

Workers poll the database for new jobs and execute them in one or more threads.
Typically, one worker is started per process. While you can start workers
manually, either in your main application process(es) or in a separate one,
workhorse also provides you with a convenient way of starting one or multiple
worker processes as a daemon.

### Start workers manually

Workers are created by instantiatating, configuring and starting a new
`Workhorse::Worker` instance.

```ruby
Workhorse::Worker.start_and_wait(
  pool_size: 5,                           # Processes 5 jobs concurrently
  quiet:     false,                       # Logs to STDOUT
  logger:    Rails.logger                 # Logs to Rails log. You can also
                                          # provide any custom logger.
)
```

See [code
documentation](http://www.rubydoc.info/github/sitrox/workhorse/Workhorse%2FWorker:initialize)
for more information on the arguments.

### Start workers using a daemon script

Using `Workhorse::Daemon` (`Workhorse::Daemon::ShellHandler`), you can spawn one
multiple worker processes automatically. This is useful for cases where you want
the workers to exist in separate processes as opposed to in your main
application process(es).

For this case, the workhorse install routine automatically creates a file called
`bin/workhorse.rb` which can be used to start one or more worker processes.

The daemon-part allows you to run arbitrary code as a daemon:

```ruby
Workhorse::Daemon::ShellHandler.run count: 5 do
  # This runs as a daemon and will be started 5 times
end
```

Within this shell handler, you can now instantiate, configure and start a worker
as described under *Start workers manually*:

```ruby
Workhorse::Daemon::ShellHandler.run count: 5 do
  # This will be run 5 times, each time in a separate process. Per process, it
  # will be able to process 3 jobs concurrently.
  Workhorse::Worker.start_and_wait(pool_size: 3, logger: Rails.logger)
end
```

## Roadmap

* [ ] ActiveJob integration for Rails
* [ ] Job timeouts
* [ ] Daemon, generator
* [ ] Migration generator (+ data migration from `delayed_job`)

## Copyright

Copyright (c) 2017 Sitrox. See `LICENSE` for further details.
