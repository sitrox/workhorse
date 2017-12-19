# Workhorse FAQ

## Why should I use workhorse over *X*?

There exist a variety of job backends for ruby,
[delayed_job](https://github.com/collectiveidea/delayed_job) probably being the
closest one to workhorse.

Some key advantages we feel workhorse has over other Gems:

- Workhorse is less than 500 lines of code at its core. The code is supposed to
  be easily readable, understandable, and modifiable.

- Workhorse allows you to run multiple jobs simultaneously *in the same
  process*.
  This capability is what inspired the creation of workhorse in the first place.

We encourage you to have a look at the other projects as well and carefully
figure out which one best suits your needs.

## My code is not thread safe. How can I use workhorse safely?

Job code that is not thread safe can not be executed safely in multiple threads
of the same process. In these cases, set the `pool_size` to `1` and, if you
still want to execute multiple jobs simultaneously, the daemon `count` to a
number greater than `1`:

```ruby
Workhorse::Daemon::ShellHandler.run count: 5 do
  Workhorse::Worker.start_and_wait(pool_size: 1)
end
```

## I'm using jRuby. How can I use the daemon handler?

As java processes in general can not be forked safely, the daemon handler
provided with this Gem does not support jRuby platforms.

If your jRuby application consists of one single application process, it is
recommended to just start the job backend in the same process:

```ruby
worker = Workhorse::Worker.new(pool_size: 5)
worker.start
```

This code is non-blocking, which means that it will run as long as the process
is up. Make sure to trap `INT` and `TERM` and call `worker.shutdown` when the
process stops.

If you have multiple application processes though, you may want to start the
worker in a separate process. For this purpose, adapt the startup script
`bin/workhorse.rb` so that it is blocking:

```ruby
Workhorse::Worker.start_and_wait(pool_size: 5)
```

This can then be started and "daemonized" using standard linux tools.

## I'm getting random autoloading exeptions

Make sure to always start the worker in *production mode*, i.e.:

```bash
RAILS_ENV=production bin/workhorse.rb start
```

## Why does workhorse not support timeouts?

Generic timeout implementations are [a dangerous thing](http://www.mikeperham.com/2015/05/08/timeout-rubys-most-dangerous-api/) in Ruby. This is why we decided against providing this feature in Workhorse and recommend to implement the timeouts inside of your jobs - i.e. via network timeouts.
