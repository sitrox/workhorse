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
