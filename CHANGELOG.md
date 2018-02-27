# Workhorse Change log

## 0.3.4 - 2018-02-27

* Fixes crucial bug where multiple jobs of the same queue could be executed
  simultaneously.

* Makes `Workhorse::DbJob` attributes accessible for earlier versions of rails.

## 0.3.3 - 2018-02-26

* Adds missing require for `concurrent` library that is required in some
  versions of Rails

## 0.3.2 - 2018-02-23

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
