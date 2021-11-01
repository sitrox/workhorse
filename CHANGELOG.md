# Workhorse Changelog

## 1.2.5 - 2021-11-01

* Add config settings for configuring {Workhorse::Jobs::DetectStaleJobsJob}:

  * `config.stale_detection_locked_to_started_threshold`
  * `config.stale_detection_run_time_threshold`

## 1.2.4 - 2021-06-08

* Add `workhorse_db_job` load hook

## 1.2.3 - 2021-02-09

* Fix warning with ruby 2.7

## 1.2.2 - 2021-01-27

* Remove unused gem dependency to `schemacop`

## 1.2.1 - 2021-01-27

* Log job description (if given) when performing job

## 1.2.0 - 2021-01-27

* `Workhorse.enqueue_active_job`
  * Change `perform_at` to a keyword arument
  * Allow passing `:description` and `:queue`

Note that when upgrading, change:

```ruby
# From
Workhorse.enqueue_active_job MyJob, 5.minutes.from_now

# To
Workhorse.enqueue_active_job MyJob, perform_at: 5.minutes.from_now
```

## 1.1.1 - 2021-01-19

* Remove deprecation warnings with Ruby 2.7

## 1.1.0 - 2020-12-24

* Add `description` column to `DbJob`.

If you're upgrading from a previous version, add the `description` column
to your `DbJob` table, e.g. with such a migration:

```ruby
class AddDescriptionToWorkhorseDbJobs < ActiveRecord::Migration[6.0]
  def change
    add_column :jobs, :description, :string, after: :perform_at, null: true
  end
end
```

## 1.0.1 - 2020-12-15

* Fix handling of empty pid files

## 1.0.0 - 2020-09-21

* Stable release, identical to 1.0.0.beta2 but now extensively battle-tested

## 1.0.0.beta2 - 2020-08-27

* Add option `config.silence_poller_exceptions` (default `false`)

* Add option `config.silence_watcher` (default `false`)

## 1.0.0.beta1 - 2020-08-20

This is a stability release that is still experimental and has to be tested in
battle before it can be considered stable.

* Stop passing ActiveRecord job objects between polling and worker threads to
  avoid AR race conditions. Now only IDs are passed between threads.

## 1.0.0.beta0 - 2020-08-19

This is a stability release that is still experimental and has to be tested in
battle before it can be considered stable.

* Simplify locking during polling. Other than locking individual jobs, pollers
  now acquire a global lock. While this can lead to many pollers waiting for
  each others locks, performing a poll is usually done very quickly and the
  performance drawback is to be considered neglegible. This change should work
  around some deadlock issues as well as an issue where a job was obtained by
  more than one poller.

* Shut down worker if polling encountered any kind of error (running jobs will
  be completed whenever possible). This leads to potential watcher jobs being
  able to restore the failed process.

* Make unit test database connection configurable using environment variables
  `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD` and `DB_HOST`. This is only relevant
  if you are working on workhorse and need to run the unit tests.

* Fix misbehaviour where queueless jobs were not picked up by workers as long as
  a named queue was in a locked state.

* Add built-in job `Workhorse::Jobs::DetectStaleJobsJob` which you can schedule.
  It picks up jobs that remained `locked` or `started` (running) for more than a
  certain amount of time. If any of these jobs are found, an exception is thrown
  (which may cause a notification if you configured `on_exception` accordingly).
  See the job's API documentation for more information.

**If using oracle:** Make sure to grant execute permission to the package
`DBMS_LOCK` for your oracle database schema:

```GRANT execute ON DBMS_LOCK TO <schema-name>;```

## 0.6.9 - 2020-04-22

* Fix error where processes may have mistakenly been detected as running (add a
  further improvement to the fix in 0.6.7).

## 0.6.8 - 2020-04-07

* Fix bug introduced in 0.6.7 where all processes were detected as running

## 0.6.7 - 2020-04-07

* Fix error where processes may have mistakenly been detected as running

## 0.6.6 - 2020-04-06

* Fix error `No workers are defined.` when definining exactly 1 worker.

## 0.6.5 - 2020-03-18

* Call `on_exception` callback on errors during polling.

## 0.6.4 - 2019-10-12

* Fix #22 where an exception with message `No live threads left. Deadlock?`
  could be thrown in the worker processes.

## 0.6.3 - 2019-09-02

* Fix examples in changelog, readme and generator for starting workers. Some of
  the examples were non-functional after the changes introduced by 0.6.0.

## 0.6.2 - 2019-07-10

* Make compatible with older ruby versions.

## 0.6.1 - 2019-07-09

* Allow calling `Workhorse.setup` multiple times.

## 0.6.0 - 2019-07-03

* Adapt {Workhorse::Daemon} to support a specific block for each worker. This
  allows, for example, to run a scheduler like Rufus in a separate worker
  process.

  If you're using the daemon class, you will need to restructure your workhorse
  starting script.

  Since there is no `count` attribute anymore, transfer this:

  ```ruby
  Workhorse::Daemon::ShellHandler.run count: 5 do
    Workhorse::Worker.start_and_wait(pool_size: 1, logger: Rails.logger)
  end
  ```

  into this:

  ```ruby
  Workhorse::Daemon::ShellHandler.run do |daemon|
    5.times do
      daemon.worker do
        Workhorse::Worker.start_and_wait(pool_size: 1, logger: Rails.logger)
      end
    end
  end
  ```

  See readme for more information.

## 0.5.1 - 2019-06-27

* Add daemon command `kill`

## 0.5.0 - 2019-05-22

* Added support for ActiveJob

## 0.4.0 - 2019-05-15

* Added instruments for clearing DbJob data. (PR #17)

* Added instant repolling feature. (#PR18)

## 0.3.9 – 2019-03-09

* Fixed error where jobs without queue were blocked by a locked/running job
  that also was without a queue

## 0.3.8 – 2018-12-19

* Fixed incompatibility in the combination of Oracle DB and Arel < 7.0.0

## 0.3.7 – 2018-12-17

* Fixed Oracle DB compatibility issues for jobs in multiple queues

## 0.3.6 – 2018-11-14

* Makes sure all exceptions are caught and handled properly, not only exceptions
  deriving from `StandardError`. In previous releases, this prevented some
  exceptions like syntax errors to be handled properly.

## 0.3.5 – 2018-10-22

* Adds global callback `on_exception` that allows custom exception handling /
  exception notification.

## 0.3.4 – 2018-09-24

* Fixes #14

* Fixes crucial bug where multiple jobs of the same queue could be executed
  simultaneously.

* Makes `Workhorse::DbJob` attributes accessible for earlier versions of rails.

## 0.3.3 – 2018-02-26

* Adds missing require for `concurrent` library that is required in some
  versions of Rails

## 0.3.2 – 2018-02-23

* Fixes a migration bug

## 0.3.1 – 2018-02-22

* Adds support for Ruby >= 2.0.0 / Rails >= 3.2

## 0.3.0 – 2017-12-27

### Added

* Option `perform_at` to set earliest execution time of a job
* Stock job for clean-up of succeeded jobs
* Example for safe scheduling of repeating jobs

### Changed

* Improved help text output for the daemon
* Polling intervals can now be multiples of 0.1 instead of integers

### Fixed

* Respect queues even when no job of that queue is running
* Initial migration now works for both Oracle and MySQL

## 0.2.0 – 2017-12-19

* Adds support for job-level priorities

## 0.1.0 – 2017-12-18

* First feature-complete production release
