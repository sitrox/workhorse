# Workhorse FAQ

## Why should I use workhorse over *x*?

There is a variety of job backends for ruby,
[delayed_job](https://github.com/collectiveidea/delayed_job) probably being the
closest one to workhorse.

Some key advantages we feel workhorse has over other Gems:

- Workhorse is less than 500 lines of code at its core. The code is supposed to
  be easily readable, understandable and modifyable.

- Workhorse allows to run multiple jobs simultaneously *in the same process*.

We encourage you to have a look at the other projects as well and carefully
figuring out which one is best for you.
