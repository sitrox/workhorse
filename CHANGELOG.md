# Workhorse Changelog

## unreleased - 2024-07-08

* Change `retry-on` in actions to `any`: also retry when the action hits a timeout

* Comply with RuboCop

## 1.2.21 - 2024-07-02

* Add active record release to `create_table_jobs` migration

  Sitrox reference: #126612.

## 1.2.20 - 2024-06-17

* Fix rails environment check

  Sitrox reference: #125593.

## 1.2.19 - 2024-05-07

* Fix further compatibility issues with `ruby < 2.5`

  Sitrox reference: #124538.

## 1.2.18 - 2024-05-07

* Fix compatibility with `ruby < 2.5`

  Sitrox reference: #124538.

## 1.2.17 - 2024-02-21

* Stable release based on previous RC releases.

## 1.2.17.rc2 - 2024-02-08

* Remove unnecessary output from `watch` command in certain cases.

  Sitrox reference: #121312.

* Fix, improve and extend automated tests.

## 1.2.17.rc1 - 2024-02-08

* Revamp memory handling:

  * Change memory handling for workers to automatically shut down themselves
    upon exceeding `config.max_worker_memory_mb` (if configured and > 0),
    triggering the creation of a shutdown file
    (`tmp/pids/workhorse.<pid>.shutdown`).
  * Have the `watch` command, if scheduled, silently restart the shutdown worker
    and remove the shutdown file.
  * The presence of the shutdown file informs the watcher to produce output or
    remain silent.
  * Implement this adjustment to limit `watch` command output to error cases,
    facilitating seamless cron integration for notification purposes.

  Sitrox reference: #121312.

## 1.2.17.rc0 - 2024-02-05

* Add option `config.max_worker_memory_mb` for automatic restart of workers
  exceeding the specified memory threshold using the `watch` command. Default is
  `0`, deactivating this feature. See [memory
  handling](README.md#memory-handling) for more information.

  Sitrox reference: #121312.

## 1.2.16 - 2023-09-18

* Add support for `--skip-initializer` flag to install generator.

  Sitrox reference: #114673.

* Add option `config.clean_stuck_jobs` that enabled automatic cleaning of stuck
  jobs whenever a worker starts up.

  Sitrox reference: #113708

* Add `retry-step` to actions such that failed unit tests are executed again

  Sitrox reference: #115888

## 1.2.15 - 2023-08-28

* Add capability to skip transactions for enqueued RailsOps operations.

## 1.2.14 - 2023-08-23

* Add documentation for transaction handling.

* Add support for skipping transactions on a per-job basis

## 1.2.13 - 2023-02-20

* Add the `config.max_global_lock_fails` setting (defaults to 10). If a
  worker's poller cannot acquire the global lock, an error is logged, and if
  `config.on_exception` is configured, the error is handled using this callback.

  This change allows you to be aware of essentially defunct worker processes due
  to a global lock that could not be obtained, for example, because of another
  worker that was killed without properly releasing the lock. However, this is
  an edge case because:

  1. The lock is released by Workhorse in an `ensure` block.
  2. At least MySQL is supposed to release global locks obtained in a connection
     when that connection is closed.

  Sitrox reference: #110339.

## 1.2.12 - 2023-01-18

* Call `on_exception` callback on failed `Performer` initialization (e.g. when
  DB connection is not established).

  Sitrox reference: #109126.21.

## 1.2.11 - 2023-01-06

* Remove debug output introduced in 1.2.10

## 1.2.10 - 2023-01-05

* Attempt to make shutdown of workers more robust by sending both `TERM` and
  `INT` signals.

  Sitrox reference: #108374.1-1.

## 1.2.9 - 2022-12-08

* Properly detach forked worker processes from parent process to prevent zombie
  processes

* Reopen STDIN, STDOUT and STDERR pipes to `/dev/null` after forking
  (daemonizing) worker processes. This detaches from the current TTY which
  prevents the issue that SSH connections sometimes could not be closed when
  having daemonized new worker processes.

  Sitrox reference: #107576.

## 1.2.8 - 2022-11-23

* Add configuration option `lock_shell_commands`. This defaults to `true` to
  retain backwards compatibility and allows turning off file locking for shell
  commands (e.g. for cases where the locking is done outside of workhorse like
  in a wrapper script).

  Sitrox reference: #106900.

## 1.2.7 - 2022-04-07

* Adapt exit status of shell handler to return with exit code `2` when a worker
  is in an unexpected status. Previously, this lead to exit code `1` and made it
  hard to distinguish from fatal errors.

## 1.2.6 - 2022-01-11

* Add daemon command `restart-logging`, which sends a `HUP` interrupt to all
  Workhorse processes which in turn reopen the log files. This is particularly
  useful to call after log files have been rotated, e.g. using `logrotate`.

  Sitrox reference: #64690.

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
  * Change `perform_at` to a keyword argument
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
