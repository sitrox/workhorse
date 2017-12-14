[![Build Status](https://travis-ci.org/sitrox/workhorse.svg?branch=master)](https://travis-ci.org/sitrox/workhorse)
[![Gem Version](https://badge.fury.io/rb/workhorse.svg)](https://badge.fury.io/rb/workhorse)

# Workhorse

Multi-threaded job backend with database queuing for ruby.

## Introduction

How it works:

* Jobs are instances of classes that support the `perform` method.
* Jobs are persisted in the database using ActiveRecord.
* You can start one or more worker processes.
* Each worker is configurable as to which queue(s) it processes. Jobs in the
  same queue never run simultaneously. Jobs with no queue can always run in
  parallel.
* Each worker polls the database and spawns a number of threads to execute jobs
  of different queues simultaneously.

What it does not do:

* It does not spawn new processes on the fly. Jobs are run in separate threads
  but not in separate processes (unless you manually start multiple worker
  processes).
* It does not support retries, timeouts, and timed execution.

## Installation

### Requirements

* A database and table handler that properly supports row-level locking (such as
  MySQL with InnoDB, PostgreSQL, or Oracle).
* If you are planning on using the daemons handler:
  * An operating system and file system that supports file locking.
  * MRI ruby (aka "c ruby") as jRuby does not support `fork`.

### Installing under Rails

1. Add `workhorse` to your `Gemfile`:

   ```ruby
   gem 'workhorse'
   ```

   Install it using `bundle install` as usual.

2. Run the install generator:

   ```bash
   bin/rails generate workhorse:install
   ```

   This generates:

   * A database migration for creating a table named `jobs`
   * The initializer `config/initializers/workhorse.rb` for global configuration
   * The daemon worker script `bin/workhorse.rb`

   Please customize the initializer and worker script to your liking.

## Queuing jobs

### Basic jobs

Workhorse can handle any jobs that support the `perform` method and are
serializable. To queue a basic job, use the static method `Workhorse.enqueue`.
You can optionally pass a queue name.

```ruby
class MyJob
  def initialize(name)
    @name = name
  end

  def perform
    puts "Hello #{@name}"
  end
end

Workhorse.enqueue MyJob.new('John'), queue: :test
```

### RailsOps operations

Workhorse allows you to easily queue
[RailsOps](https://github.com/sitrox/rails_ops) operations using the static
method `Workhorse.enqueue_op`:

```ruby
Workhorse.enqueue_op Operations::Jobs::CleanUpDatabase, { quiet: true }, queue: :maintenance
```

Params passed using the second argument will be used for operation instantiation
at job execution.

If you do not want to pass any params to the operation, just omit the second hash:

```ruby
Workhorse.enqueue_op Operations::Jobs::CleanUpDatabase, queue: :maintenance
```

## Configuring and starting workers

Workers poll the database for new jobs and execute them in one or more threads.
Typically, one worker is started per process. While you can start workers
manually, either in your main application process(es) or in a separate one,
workhorse also provides you with a convenient way of starting one or multiple
worker processes as daemons.

### Start workers manually

Workers are created by instantiating, configuring, and starting a new
`Workhorse::Worker` instance:

```ruby
Workhorse::Worker.start_and_wait(
  pool_size: 5,                           # Processes 5 jobs concurrently
  quiet:     false,                       # Logs to STDOUT
  logger:    Rails.logger                 # Logs to Rails log. You can also
                                          # provide any custom logger.
)
```

See [code documentation](http://www.rubydoc.info/github/sitrox/workhorse/Workhorse%2FWorker:initialize)
for more information on the arguments. All arguments passed to `start_and_wait`
are passed to the initialize. All arguments passed to `start_and_wait` are
in turn passed to the initializer of `Workhorse::Worker`.

### Start workers using a daemon script

Using `Workhorse::Daemon::ShellHandler`, you can spawn one or multiple worker
processes automatically. This is useful for cases where you want the workers to
exist in separate processes as opposed to your main application process(es).

For this case, the workhorse install routine automatically creates the file
`bin/workhorse.rb`, which can be used to start one or more worker processes.

The script can be called as follows:

```bash
bin/workhorse.rb start|stop|status|watch|restart|usage
```

#### Background and customization

Within the shell handler, you can instantiate, configure, and start a worker as
described under [Start workers manually](#start-workers-manually):

```ruby
Workhorse::Daemon::ShellHandler.run count: 5 do
  # This will be run 5 times, each time in a separate process. Per process, it
  # will be able to process 3 jobs concurrently.
  Workhorse::Worker.start_and_wait(pool_size: 3, logger: Rails.logger)
end
```

## Frequently asked questions

Please consult the [FAQ](FAQ.md).

## Roadmap

* [ ] ActiveJob integration for Rails
* [ ] Job timeouts
* [ ] Job priorities

## Copyright

Copyright © 2017 Sitrox. See `LICENSE` for further details.
