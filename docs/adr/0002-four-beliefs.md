# The pipeline holds four beliefs, not a cache of answers

A device is always in exactly one of four states: **Cold** (never asked),
**Known** (Registry reported it), **Unknown** (Registry reported it absent), or
**Unresolved** (Registry could not be reached). The cache stores the last three;
Cold is the absence of all three.

The design follows from two commitments. *Load on miss* means a message is the
only thing that can cause a load, so Cold is resolved by the message that needs
it. *Never block* means that message cannot wait, so it is delivered unenriched —
the behaviour recorded in ADR-0001.

Two consequences are worth stating because they are easy to mistake for bugs.
An **Unknown** device is a *settled verdict*, so its absence is cached rather
than re-asked on every message; without this, one mistyped device id turns the
plugin into a denial-of-service against our own Registry. **Unresolved** is
explicitly *not* a verdict — it lapses on a backoff, so an outage heals itself
without anyone intervening.

Timeouts and connection refusals are given *different* backoffs. A refusal
(`ECONNREFUSED`) means nothing is listening and retrying quickly is pointless; a
timeout means something accepted the connection and may be healthy. Collapsing
them would make recovery from a crashed Registry either as slow as a slow one,
or as aggressive as a crash.