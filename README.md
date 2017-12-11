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

To install this gem using bundler, add it to your `Gemfile`:

```ruby
gem 'workhorse'
```

## Usage

Usage of this Gem is divided into two sections: Queuing jobs (inserting them
into the database queue) and starting workers that process this queue.

### Queuing jobs

#### Basic jobs

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

#### RailsOps operations

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

### Configuring and starting workers

Workers poll the database for new jobs and execute them in one or more threads.
Workers can be started in a separate process or in your main application
process. Typically only one worker is started per process as it does not make
sense to have multiple workers per process.

```ruby
# Instantiate a new worker with a maximal thread pool size of 5 and enabled
# logging to STDOUT.
w = Workhorse::Worker.new(pool_size: 5, quiet: false)

# Assign a logger so that logs are saved to a file. You can also assign
# `Rails.logger` to it if you are inside of Rails.
w.logger = Logger.new('workhorse.log')

# Start the worker so that it polls the database and performs jobs. This call is
# not blocking. Make sure to call `wait` to prevent the process from ending
# right away.
w.start

# This waits until the process receives an interrupt and then shuts down the
w.wait
```

## Roadmap

* [ ] ActiveJob integration for Rails
* [ ] Job timeouts
* [ ] Daemon, generator
* [ ] Migration generator (+ data migration from `delayed_job`)

## Copyright

Copyright (c) 2017 Sitrox. See `LICENSE` for further details.
