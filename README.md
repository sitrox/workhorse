[![Build Status](https://travis-ci.org/sitrox/workhorse.svg?branch=master)](https://travis-ci.org/sitrox/workhorse)
[![Gem Version](https://badge.fury.io/rb/workhorse.svg)](https://badge.fury.io/rb/workhorse)

# Workhorse

Multi-threaded job backend with database queuing for ruby.

## Introduction

How it works:

* Jobs are instances of classes that support the `perform` method.
* Jobs are persisted in the database using ActiveRecord.
* Each job has a priority, the default being 0. Jobs with higher priorities
  (lower is higher, 0 the highest) get processed first.
* Each job can be set to execute after a certain date / time.
* You can start one or more worker processes.
* Each worker is configurable as to which queue(s) it processes. Jobs in the
  same queue never run simultaneously. Jobs with no queue can always run in
  parallel.
* Each worker polls the database and spawns a configurable number of threads to
  execute jobs of different queues simultaneously.

What it does not do:

* It does not spawn new processes on the fly. Jobs are run in separate threads
  but not in separate processes (unless you manually start multiple worker
  processes).
* It does not support
  [timeouts](FAQ.md#why-does-workhorse-not-support-timeouts) and timed execution.

## Installation

### Requirements

* A database and table handler that properly supports row-level locking (such as
  MySQL with InnoDB, PostgreSQL, or Oracle).
* If you are planning on using the daemons handler:
  * An operating system and file system that supports file locking.
  * MRI ruby (aka "CRuby") as jRuby does not support `fork`. See the
    [FAQ](FAQ.md#im-using-jruby-how-can-i-use-the-daemon-handler) for possible workarounds.

### Installing under Rails

1. Add `workhorse` to your `Gemfile`:

   ```ruby
   gem 'workhorse'
   ```

   Install it using `bundle install` as usual.

2. Run the install generator:

   ```bash
   bundle exec rails generate workhorse:install
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
You can optionally pass a queue name and a priority.

```ruby
class MyJob
  def initialize(name)
    @name = name
  end

  def perform
    puts "Hello #{@name}"
  end
end

Workhorse.enqueue MyJob.new('John'), queue: :test, priority: 2
```

### RailsOps operations

Workhorse allows you to easily queue
[RailsOps](https://github.com/sitrox/rails_ops) operations using the static
method `Workhorse.enqueue_op`:

```ruby
Workhorse.enqueue_op Operations::Jobs::CleanUpDatabase, { quiet: true }, queue: :maintenance, priority: 2
```

Params passed using the second argument will be used for operation instantiation
at job execution.

If you do not want to pass any params to the operation, just omit the second hash:

```ruby
Workhorse.enqueue_op Operations::Jobs::CleanUpDatabase, queue: :maintenance, priority: 2
```

### Scheduling

Workhorse has no out-of-the-box functionality to support scheduling of regular
jobs, such as maintenance or backup jobs. There are two primary ways of
achieving regular execution:

1. Rescheduling by the same job after successful execution and setting
   `perform_at`

   This is simple to set up and requires no additional dependencies. However,
   the time taken to execute a job and the time delay caused by the polling
   interval cannot easily be factored into the calculation of the interval,
   leading to a slight shift in effective execution date. (This can be mitigated
   by scheduling the job before knowing whether the current run will succeed.
   Proceed down this path at your own peril!)

   *Example:* A job that takes 5 seconds to run and is set to reschedule itself
   after 10 minutes is started at 12:00 sharp. After one hour it will be set to
   execute at 13:00:30 at the earliest.

   In its most basic form, the `perform` method of a job would look as follows:

   ```ruby
   class MyJob
     def perform
       # Do all the work

       # Perform again after 10 minutes (600 seconds)
       Workhorse.enqueue MyJob.new, perform_at: Time.now + 600
     end
   end
   ```

2. Using an external scheduler

   A more elaborate setup requires an external scheduler, but which can still be
   called from Ruby. One such scheduler is
   [rufus-scheduler](https://github.com/jmettraux/rufus-scheduler). A small
   example of an adapted `bin/workhorse.rb` to accommodate for the additional
   cog in the mechanism is given below:

   ```ruby
   #!/usr/bin/env ruby
   
   require './config/environment'
   
   Workhorse::Daemon::ShellHandler.run do
     worker = Workhorse::Worker.new(pool_size: 5, polling_interval: 10, logger: Rails.logger)
     scheduler = Rufus::Scheduler.new
   
     worker.start
   
     scheduler.cron '0/10 * * * *' do
       Workhorse.enqueue Workhorse::Jobs::CleanupSucceededJobs.new
     end
   
     Signal.trap 'TERM' do
       scheduler.shutdown
       Thread.new do
         worker.shutdown
       end.join
     end
   
     scheduler.join
     worker.wait
   end
   ```

   This allows starting and stopping the daemon with the usual interface.
   Note that the scheduler is handled like a Workhorse worker, the consequence
   of which is that only one 'worker' should be started by the ShellHandler.
   Otherwise there would be multiple jobs scheduled at the same time.

   Please refer to the documentation on
   [rufus-scheduler](https://github.com/jmettraux/rufus-scheduler) (or the
   scheduler of your choice) for further options concerning the timing of the
   jobs.

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
RAILS_ENV=production bundle exec bin/workhorse.rb start|stop|status|watch|restart|usage
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

## Copyright

Copyright © 2018 Sitrox. See `LICENSE` for further details.
