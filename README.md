[![Build](https://github.com/sitrox/workhorse/actions/workflows/ruby.yml/badge.svg)](https://github.com/sitrox/workhorse/actions/workflows/ruby.yml)
[![Gem Version](https://badge.fury.io/rb/workhorse.svg)](https://badge.fury.io/rb/workhorse)

# Workhorse

Multi-threaded job backend with database queuing for Ruby. Battle-tested and ready for production-use.

## Introduction

How it works:

* Jobs are instances of classes that support the `perform` method.
* Jobs are persisted in the database using ActiveRecord.
* Each job has a priority, the default being 0. Jobs with higher priorities
  (lower numbers have higher priority, with 0 being the highest) get processed first.
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
  [timeouts](FAQ.md#why-does-workhorse-not-support-timeouts).

## Installation

### Requirements

* Ruby `>= 3.0` (may work with earlier versions but is untested)
* Rails `>= 7.0`
* One of the supported databases (see [Database support](#database-support)):
  MySQL / MariaDB with InnoDB, or Oracle. **PostgreSQL is not supported.**
* If you are planning on using the daemons handler:
  * An operating system and file system that supports file locking.
  * MRI Ruby (aka "CRuby") as jRuby does not support `fork`. See the
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
     * This can be skipped using the `--skip-initializer` flag
   * The daemon worker script `bin/workhorse.rb`

   Please customize the initializer and worker script to your liking.

### Database support

Workhorse serialises job pickup using a database-level lock, which is
necessarily written against a specific database's dialect. Two families are
implemented:

| Database          | Supported | Lock used            | Covered by CI |
|-------------------|-----------|----------------------|---------------|
| MySQL / MariaDB   | Yes       | `GET_LOCK`           | Yes, against both the `mysql2` and the `trilogy` adapter |
| Oracle            | Yes       | `DBMS_LOCK`          | No, tested manually against `activerecord-oracle_enhanced-adapter` |
| PostgreSQL        | **No**    | —                    | — |
| Everything else   | **No**    | —                    | — |

There is no PostgreSQL implementation: workers emit `GET_LOCK` on every poll,
which PostgreSQL does not provide, so a worker fails on its first poll.
Supporting it would mean an advisory-lock dialect of its own
(`pg_advisory_lock`) and is not currently planned. Note that InnoDB is required
on MySQL / MariaDB, as MyISAM supports neither transactions nor row-level
locking.

When using Oracle, make sure your schema has access to the package `DBMS_LOCK`:

```
GRANT execute ON DBMS_LOCK TO <schema-name>;
```

## Queuing jobs

### Basic jobs

Workhorse can handle any jobs that support the `perform` method and are
serializable. To queue a basic job, use `Workhorse.enqueue`.
You can optionally pass a queue name, a priority, and a description.

```ruby
class MyJob
  def initialize(name)
    @name = name
  end

  def perform
    puts "Hello #{@name}"
  end
end

Workhorse.enqueue MyJob.new('John'), queue: :test, priority: 2, description: 'Basic Job'
```

### RailsOps operations

Workhorse allows you to easily queue
[RailsOps](https://github.com/sitrox/rails_ops) operations using the static
method `Workhorse.enqueue_op`:

```ruby
Workhorse.enqueue_op Operations::Jobs::CleanUpDatabase, { queue: :maintenance, priority: 2 }, quiet: true
```

The first argument of the method is the Operation you want to run. Parameters passed in
using the second argument will be used by Workhorse and parameters passed using the
third argument will be used for operation instantiation at job execution, i.e.:

```ruby
Workhorse.enqueue_op <Operation Class Name>, { <Workhorse Options> }, { <RailsOps Options> }
```

If you do not want to pass any parameters to the operation, just omit the third hash:

```ruby
Workhorse.enqueue_op Operations::Jobs::CleanUpDatabase, queue: :maintenance, priority: 2
```

## Scheduling

Workhorse runs jobs on a schedule itself, without an external scheduler
process. Schedules are declared in code and their state is kept in the
database:

```ruby
# config/initializers/workhorse.rb
Workhorse.schedules do
  schedule 'cleanup_jobs',
           job:  'Workhorse::Jobs::CleanupSucceededJobs',
           cron: '10 0 * * *'

  schedule 'morning_digest',
           job:          'Jobs::MorningDigest',
           cron:         '0 8 * * 1-5',
           timezone:     'Europe/Zurich',
           queue:        :reports,
           priority:     -10,
           catch_up:     :skip,
           grace:        15.minutes,
           max_lateness: 60.seconds
end
```

Each schedule owns a row in `workhorse_schedules` holding the next occurrence
that has not been materialised yet. Workers reconcile those rows against the
declarations above on startup, and materialise the occurrences that have come
due during their regular poll. There is no scheduler process to keep alive and
no single point of failure: any worker will do.

### Why the occurrence is a row

An in-memory scheduler computes the next occurrence from *now*, so an
occurrence whose time passes while it is not running never happens and leaves
no trace — a deployment, a restart or a crash at the wrong minute silently
skips a nightly job. Because the next occurrence is persisted here, a worker
coming back at any later point still sees that it is due, and the schedule
decides what to do about it.

### Catch-up

What should happen to an occurrence whose time has passed depends on the job,
so it is stated per schedule:

| `catch_up`  | Behaviour                                                | Suits                                   |
|-------------|----------------------------------------------------------|-----------------------------------------|
| `:run_once` | Collapse all missed occurrences into one (**default**)    | Cleanup, maintenance, idempotent work   |
| `:run`      | Materialise each, up to `max_catch_up` (default 10)       | Per-period reports that must all exist  |
| `:skip`     | Drop those older than `grace`                             | "Send the 08:00 digest"                 |

`:run_once` is the default deliberately: after a long outage it is the safe
behaviour. A schedule running every minute that was down for a day would
otherwise enqueue 1440 jobs at once, which `max_catch_up` also guards against.

`:skip` requires `grace`, as without one it has no way to tell an occurrence
that is a moment late from one that is a day late.

### Lateness and deadlines

A materialised job's `perform_at` is the occurrence's own time, not the moment
it was enqueued. The difference between it and `started_at` is therefore the
lateness of that occurrence, available on every job as
`Workhorse::DbJob#lateness` and as a column you can report on.

Two options act on it, and both work for hand-enqueued jobs as well:

* **`max_lateness`** — seconds the job may start late before
  {Workhorse.on_job_late} is called. The job still runs; it was just late.
* **`expires_after`** — seconds after the occurrence at which the job is no
  longer worth running. It is then set to state `expired` and
  `Workhorse.on_job_expired` is called instead of it being performed. For
  "send the 08:00 reminder", running it at 11:40 is often worse than not
  running it at all.

```ruby
Workhorse.setup do |config|
  config.on_job_expired = proc do |db_job|
    ExceptionNotifier.notify_exception(
      StandardError.new("Job #{db_job.id} (#{db_job.description}) expired")
    )
  end

  config.on_job_late = proc do |db_job, lateness|
    ExceptionNotifier.notify_exception(
      StandardError.new("Job #{db_job.id} started #{lateness.round}s late")
    )
  end
end
```

Both callbacks are best-effort: anything they raise goes to
`Workhorse.on_exception` and never affects the worker or the job. An expiry is
logged at `warn` whether or not a callback is configured.

### Detecting schedules that stopped

Neither callback can fire for a job that was never created, so if no worker is
polling or the global lock is stuck, occurrences simply stop being
materialised and nothing says so. `Workhorse::Jobs::DetectLateSchedulesJob`
covers that case by reporting schedules whose next occurrence lies well in the
past:

```ruby
Workhorse.schedules do
  schedule 'detect_late_schedules',
           job:  'Workhorse::Jobs::DetectLateSchedulesJob',
           cron: '*/30 * * * *'
end
```

It is itself performed by a worker, so it reports a stall only while at least
one worker is still running — use it alongside external monitoring rather than
instead of it.

### Timezones

Without `timezone`, a cron expression is read in the process's local time.
Given one, occurrences are computed in that zone, including across daylight
saving changes: a `30 2 * * *` schedule in `Europe/Zurich` has no occurrence
on the day the clocks go forward, because 02:30 does not exist that day.

### Disabling a schedule

Setting `enabled` to `false` on the row stops its occurrences from being
materialised, without a deployment:

```ruby
Workhorse::Schedule.find_by(key: 'morning_digest').update!(enabled: false)
```

Removing a schedule from the declarations deletes its row on the next worker
startup, which also discards the occurrence it was waiting for.

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
are passed to the initializer of `Workhorse::Worker`.

### Start workers using a daemon script

Using `Workhorse::Daemon::ShellHandler`, you can spawn one or multiple worker
processes automatically. This is useful for cases where you want the workers to
exist in separate processes as opposed to your main application process(es).

For this case, the workhorse install routine automatically creates the file
`bin/workhorse.rb`, which can be used to start one or more worker processes.

The script can be called as follows:

```bash
RAILS_ENV=production bundle exec bin/workhorse.rb start|stop|kill|status|watch|restart|soft-restart|usage
```

#### Background and customization

Within the shell handler, you can instantiate, configure, and start a worker as
described under [Start workers manually](#start-workers-manually):

```ruby
Workhorse::Daemon::ShellHandler.run do |daemon|
  5.times do
    daemon.worker do
      # This will be run 5 times, each time in a separate process. Per process, it
      # will be able to process 3 jobs concurrently.
      Workhorse::Worker.start_and_wait(pool_size: 3, logger: Rails.logger)
    end
  end
end
```

### Instant repolling

By default, each worker only polls in the given interval. This means that if
you schedule, for example, 50 jobs at once and have a polling interval of 1
minute with a queue size of 1, the poller would tackle the first job and then
wait for a whole minute until the next poll. This would mean that these 50 jobs
would take at least 50 minutes to be executed, even if they only take a few
seconds each.

This is where *instant repolling* comes into play: Using the worker option
`instant_repolling`, you can force the poller to automatically re-poll the
database whenever a job has been performed. It then goes back to the usual
polling interval.

This setting is recommended for all setups and may eventually be enabled by
default.

### Notifications

Instant repolling only helps *after* a job has been performed. A worker that is
idle and waiting for new work still sleeps out its entire polling interval, so
a job enqueued just after a poll waits almost a full interval before it starts.

Shortening the polling interval is the obvious remedy and a poor one: every
poll acquires a global database lock, so more frequent polling across several
workers increases contention, and a worker that fails to acquire the lock skips
its poll and waits another whole interval. Polling costs the same whether or
not anything is happening.

*Notifications* turn the question around. Enqueuing a job announces it, and a
waiting worker polls straight away instead of sleeping out its interval:

```ruby
# config/initializers/workhorse.rb
Workhorse.setup do |config|
  config.notifier = :file
end
```

Polling remains the floor. A notification that is never delivered — a worker
that was restarting, an enqueue from a host that cannot reach the others —
costs latency and nothing else, as the regular poll still finds the job. For
the same reason, raise `polling_interval` only as far as you are willing to
wait when a notification *is* missed.

Note what this does and does not do to database load. While nothing is
enqueued, workers stop polling almost entirely, which is where the saving is.
An announcement, on the other hand, wakes *every* idle worker, and all but the
one that wins the job take the global lock for nothing. So a workload that
enqueues jobs in bursts while many workers sit idle can take the lock more
often than plain polling would, rather than less. Workers that are performing a
job do not react to announcements, so the effect is bounded by how many are
idle.

Two notifiers ship with workhorse:

#### `:file`

Touches a single file, which waiting workers stat once per 0.1 seconds on a
tick the poller performs anyway. It costs no database work at all and around a
microsecond of CPU per check, and a job starts within roughly 100 milliseconds.

It requires that the processes enqueueing jobs and the workers share a
filesystem, which in practice means the same host. Where they do not, the
touch never reaches those workers and they fall back to polling.

The file defaults to `tmp/pids/workhorse.wake` below the Rails root and can be
moved with `config.notification_path`. Every process involved must agree on it.

#### `:redis`

Publishes on a Redis pub/sub channel, for deployments whose workers do not
share a filesystem with the application. Redis is a soft dependency: it is not
declared as a dependency of this gem and is only loaded when this notifier is
selected.

```ruby
Workhorse.setup do |config|
  config.notifier = :redis
  config.notification_redis = Redis.new(url: ENV['REDIS_URL'])
  config.notification_channel = 'workhorse:jobs' # optional
end
```

#### Writing your own

Subclass `Workhorse::Notifiers::Base` and assign an instance to
`config.notifier`. A notifier announces jobs with `notify` and exposes a
`token` that changes whenever a notification has arrived; workers compare it
against the last value they saw, so several workers in one process stay
independent of one another. `notify` must never raise — a job must still be
enqueued when it cannot be announced.

Note that jobs with a future `perform_at` are not announced, as a woken worker
would find nothing to do; they are picked up by the regular poll once they are
due.

## Transactions

By default, each job is run in an individual database transaction. An exception
to this is when performing ActiveJob jobs using `perform_now`, where no
transaction is created.

### Transaction callback

By default, transactions are created using `ActiveRecord::Base.transaction`.
You can customize this using the setting `config.tx_callback` in your
`config/initializers/workhorse.rb` (see commented out section in the generated
configuration file).

### Turning off transactions

You can turn off transaction wrapping in the following ways:

- Globally using the setting `config.perform_jobs_in_tx = false` in your
  `config/initializers/workhorse.rb`. This is not recommended as running jobs
  without transactions can potentially be harmful.

- On a per-job basis. This is the recommended approach for jobs that either open
  up their own transaction(s) or jobs that explicitly do not need a transaction
  for whatever reason.

  Usage of this feature depends on whether you are dealing with an ActiveJob
  job, an enqueued RailsOps operation or a plain Workhorse job class.

  For ActiveJob:

  1. Add the following mixin to your job class (usually `ApplicationJob`):

     ```ruby
     class ApplicationJob
       include Workhorse::ActiveJobExtension
     end
     ```

  2. Use the DSL-method `skip_tx` inside the job classes where you want to
     disable transaction wrapping, e.g.:

     ```ruby
     class MyJob < ApplicationJob
       skip_tx

       def perform
         # Something without transaction
       end
     end
     ```

  For enqueuable RailsOps operations:

  1. Add the following static method to your operation class:

     ```ruby
     class MyOp < RailsOps::Operation
       def self.skip_tx?
         true
       end
     end
     ```

  For plain Workhorse job classes:

  1. Add the following static method to your job class:

     ```ruby
     class MyJob
       def self.skip_tx?
         true
       end
     end
     ```

## Exception handling

By default, exceptions occurring in a worker thread will only be visible in the
respective log file, usually `production.log`. If you'd like to perform specific
actions when an exception arises, set the global option `on_exception` to a
callback of your liking, e.g.:

```ruby
# config/initializers/workhorse.rb
Workhorse.setup do |config|
  config.on_exception = proc do |e|
    # Use gem 'exception_notification' for notifying about exceptions
    ExceptionNotifier.notify_exception(e)
  end
end
```

Using the settings `config.silence_poller_exceptions` and
`config.silence_watcher`, you can silence certain exceptions / error outputs
(both are disabled by default).

## Handling database jobs

Jobs stored in the database can be accessed via the ActiveRecord model
{Workhorse::DbJob}. This is the model representing a specific job database entry
and is not to be confused with the actual job class you're enqueueing.

### Obtaining database jobs

DbJobs are returned to you when enqueuing new jobs:

```ruby
db_job = Workhorse.enqueue(MyJob.new)
```

You can also obtain a job via its ID that you either get from a returned job
(see example above) or else by manually querying the database table:

```ruby
db_job = Workhorse::DbJob.find(42)
```

Note that database job objects reflect the job at the point in time when the
database job object has been instantiated. To make sure you're looking at the
latest job info, use the in-place `reload` method:

```ruby
db_job.reload
```

You can also retrieve a list of jobs in a specific state using one of the
following methods:

```ruby
DbJob.waiting
DbJob.locked
DbJob.started
DbJob.succeeded
DbJob.failed
```
### Resetting jobs

Jobs in a state other than `waiting` are either being processed or else already
in a final state such as `succeeded` and won't be performed again. Workhorse
provides an API method for resetting jobs in the following cases:

* A job has succeeded or failed (states `succeeded` and `failed`) and needs to
  re-run. In these cases, perform a non-forced reset:

  ```ruby
  db_job.reset!
  ```

  This is always safe to do, even with workers running.

* A job is stuck in state `locked` or `started` and the corresponding worker
  (check the database field `locked_by`) is not running anymore, i.e. due to a
  database connection loss or an unexpected worker crash. In these cases, the
  job will never be processed, and, if the job is in a queue, the entire queue is
  considered to be locked and no further jobs will be processed in this queue.

  In these cases, make sure the worker is stopped and perform a forced reset:

  ```ruby
  db_job.reset!(true)
  ```

Performing a reset will reset the job state to `waiting` and it will be
processed again. All meta fields will be reset as well. See inline documentation
of `Workhorse::DbJob#reset!` for more details.

## Using workhorse with Rails / ActiveJob

While workhorse can be used though its custom interface as documented above, it
is also fully integrated into Rails using `ActiveJob`. See [documentation of
ActiveJob](https://edgeguides.rubyonrails.org/active_job_basics.html) for more
information on how to use it.

To use workhorse as your ActiveJob backend, set the `queue_adapter` to
`workhorse`, either using `config.active_job.queue_adapter` in your application
configuration or else using `self.queue_adapter` in a job class inheriting from
`ActiveJob`. See ActiveJob documentation for more details.

## Cleaning up jobs

Per default, jobs remain in the database, no matter in which state. This can
eventually lead to a very large jobs database. You are advised to clean your
jobs database on a regular interval. Workhorse provides the job
`Workhorse::Jobs::CleanupSucceededJobs` for this purpose that cleans up all
succeeded jobs. You can run this using your scheduler in a specific interval.

## Memory handling

When a worker exceeds the memory limit specified by
`config.max_worker_memory_mb` (assuming it is configured to a value greater than 0), it initiates
a graceful shutdown process by creating a shutdown file named
`tmp/pids/workhorse.<pid>.shutdown`.

Simultaneously, the `watch` command, if scheduled, monitors the presence of this
shutdown file. Upon detecting its existence, it silently triggers the restart of
the shutdown worker and removes the shutdown file to signify that the restart
process has begun.

This mechanism ensures that workers are automatically restarted without manual
intervention when memory limits are exceeded.

Example configuration:

```ruby
# config/initializers/workhorse.rb
Workhorse.setup do |config|
  config.max_worker_memory_mb = 512 # Set the memory threshold to 512 megabytes
end
```

## Soft restart

The `soft-restart` command provides a way to gracefully restart all worker
processes without interrupting jobs that are currently running. It sends a
`USR1` signal to each worker, which causes the worker to:

1. Stop accepting new jobs immediately.
2. Wait for any currently running job to complete.
3. Shut down and create a shutdown file (`tmp/pids/workhorse.<pid>.shutdown`).

The command returns immediately (fire-and-forget) and does not block the caller.

**Important:** The `soft-restart` command only *stops* workers gracefully. To
start fresh workers after shutdown, you need the `watch` command running
(typically via cron). Without `watch`, `soft-restart` behaves like a graceful
stop with no automatic recovery.

Example usage:

```bash
# Trigger soft restart
RAILS_ENV=production bundle exec bin/workhorse.rb soft-restart

# The watch command (e.g. via cron) will automatically start fresh workers
*/1 * * * * cd /my/app && RAILS_ENV=production bundle exec bin/workhorse.rb watch
```

## Load hooks

Using the load hook `:workhorse_db_job`, you can inject custom code into the
Gem-internal model class `Workhorse::DbJob`, for example:

```ruby
# config/initializers/workhorse.rb
ActiveSupport.on_load :workhorse_db_job do
  # Code within this block will be run inside of the model class
  # Workhorse::DbJob.
  belongs_to :user
end
```

## Running in systemd services

When running workhorse commands inside a systemd service that sets
`MemoryDenyWriteExecute=yes`, Ruby's YJIT cannot allocate executable memory and
will crash. To prevent this, set `RUBY_YJIT_ENABLE=0` before invoking the
workhorse command:

```bash
RUBY_YJIT_ENABLE=0 ./bin/workhorse restart-logging
```

## Debug logging

Workhorse includes an optional debug log for diagnosing issues with signal
handling, process lifecycle, log rotation, and daemon commands. To enable,
set `debug_log_path` to a writable file path:

```ruby
# config/initializers/workhorse.rb
Workhorse.setup do |config|
  config.debug_log_path = Rails.root.join('log', 'workhorse.debug.log')
end
```

The debug log is designed to be safe for production use: all writes are
best-effort and silently ignore errors to avoid interfering with normal
operation. Set `debug_log_path` to `nil` (the default) to disable.

## Caveats

### Errors during polling / crashed workers

Each worker process includes one thread that polls the database for jobs and
dispatches them to individual worker threads. In case of an error in the poller
(usually due to a database connection drop), the poller aborts and gracefully
shuts down the entire worker. Jobs still being processed by this worker are
attempted to be completed during this shutdown (which only works if the database
connection is still active).

This means that you should always have an external *watcher* (usually a
cronjob), that calls the `workhorse watch` command regularly. This would
automatically restart crashed worker processes.

### Unobtainable Locks

Each Workhorse worker uses a poller to check the database for new jobs. To
ensure that no job is obtained by more than one worker, a global database lock
is used. If a worker is killed, it may happen that the lock is not properly
released, which can cause all pollers to stop working because they cannot
acquire the lock. This is an edge case, as the locks should typically be
released properly, even if a worker process is killed using `SIGKILL`.

In the event that this still happens, Workhorse takes the following steps:

- Logs when a lock could not be obtained.
- Retries acquiring the lock on the next poll.
- Calls the `on_exception` callback (if configured) after a configurable number of consecutive failures to obtain the lock.

The maximum number of consecutive failures can be configured using
`config.max_global_lock_fails`, which defaults to 10.

### Stuck queues

Jobs in named queues (non-null queues) are always run sequentially. This means
that if a job in such a queue is stuck in states `locked` or `started` (i.e. due
to a database connection failure), no more jobs of this queue will be run as the
entire queue is considered locked to ensure that no jobs of the same queue run
in parallel.

For this purpose, Workhorse provides the built-in job
`Workhorse::Jobs::DetectStaleJobsJob` which you are advised schedule on a
regular basis. It picks up jobs that remained `locked` or `started` (running)
for more than a certain amount of time. If any of these jobs are found, an
exception is thrown (which may cause a notification if you configured
`on_exception` accordingly). See the job's API documentation for more
information.

Starting with Workhorse 1.2.16, there is also a feature that automatically
checks for stuck jobs (jobs in state `locked` or `started` running on the same
host where the corresponding PID does not have a process anymore) when starting
up the worker / poller. This feature can be turned on using the setting
`config.clean_stuck_jobs`. This is turned off by default.

## Frequently asked questions

Please consult the [FAQ](FAQ.md).

## Copyright

Copyright © 2017 - 2026 Sitrox. See `LICENSE` for further details.
