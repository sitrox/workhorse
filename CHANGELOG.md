# Workhorse Change log

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
