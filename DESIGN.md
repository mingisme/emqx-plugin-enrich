# Enrichment Plugin — Design

An EMQX 5.8.8 plugin that enriches plant telemetry messages with fields looked
up from a **Device Registry**, loading entries on demand and never blocking a
publish.

This document records the settled design. The vocabulary is in
[GLOSSARY.md](./GLOSSARY.md); the decisions that are hard to reverse or
surprising are in [docs/adr/](./docs/adr/). Everything below was reached by
grilling, and the reasoning behind each choice is in the "why" columns and the
ADR it points at.

## What this is

Three parts, deliberately kept apart:

| Part | What it is | Owns |
|---|---|---|
| **EMQX 5.8.8** | The broker | MQTT. Nothing else. |
| **The plugin** | An EMQX plugin | Beliefs about devices, and the decision to enrich or not. |
| **The Registry** | A small standalone HTTP service | The authoritative device table. |

The plugin is a pure HTTP client of the Registry and the Registry is a pure
answerer of "what is this device?". Neither knows about telemetry readings.
Splitting them this way means pointing the plugin at a real device-management
system later is a config change, not a rewrite.

## Topic and payload contract

Topic filter: `plant/+/telemetry`

Inbound:

```json
{"device_id": "dev-0042", "temp_c": 21.5, "ts": 1730000000}
```

Outbound, enriched in place on the same topic:

```json
{"device_id": "dev-0042", "model": "TX-410", "site": "Gdansk-11",
 "temp_c": 21.5, "ts": 1730000000}
```

`fieldA` is `device_id`; the Registry contributes `site` and `model`. Registry
fields are merged *without* their own `device_id`, so a Registry cannot rewrite
the key a message arrived under.

Only the topic filter is configurable. The field names are fixed on purpose: a
configurable field path is a configuration surface with exactly one user, and
this context has one message shape.

## Where the plugin sits

The `message.publish` hook, at the highest priority, with a hook filter so
non-matching topics never reach the enrichment path at all.

Enrichment is a **modification of the message in place**, not a republish to a
new topic. In EMQX 5.8 the `message.publish` hookpoint is a fold whose
accumulator is the message itself; returning `{ok, Msg}` publishes your record
on its original topic to its original subscribers. Nothing is republished.

Two consequences worth carrying forward:

- The Rule Engine cannot do this. Its `on_message_publish` always returns
  `{ok, Message}` unchanged, so enrichment has to be a hand-written hook.
- Hook code runs **in the publishing client's own process**. Anything that
  blocks here stalls that client's TCP connection. This is the structural reason
  "never block" is not merely a preference.

Returning anything other than `{ok, Msg}` leaves the published message untouched,
which is exactly how a blip is expressed. And because EMQX wraps hook callbacks
in a try/catch, even an unexpected crash in this code degrades to a blip rather
than a failed publish.

## The Registry client

The plugin is an HTTP client and nothing more. Which client is **not** a free
choice, because it depends on the edition.

- **`hackney` is unavailable on Community Edition.** It is a build dependency of
  the source tree, but the only app that declares it is `emqx_s3`, which is
  EE-only. `lib/hackney-*` does not exist in `emqx/emqx:5.8.8`. A plugin
  calling `hackney:*` fails with `undef`, and declaring `hackney` in the plugin's
  `applications` is a hard startup failure. This design targets opensource, so
  `hackney` is off the table entirely.
- **`inets` is available and permanent.** `{inets, "9.1.0.2"}` appears in the
  shipped `emqx.rel` without a `load` wrapper, so it is a permanent system app
  — `httpc` is usable in-process without the plugin starting anything. EMQX
  itself calls `httpc:request/4` for CRL and OCSP.
- **`ehttpc` is available and has a true total deadline**, but it is an internal
  EMQX dependency with no API stability guarantee across versions.

**Chosen: `inets`/`httpc`.** Fewest moving parts and no coupling to an internal
library. Its one sharp edge is that `{timeout, N}` is armed *after* the connect
completes, so the real ceiling is `connect_timeout + timeout` rather than
`timeout` — which is exactly how our two timeouts in the config table are
budgeted. This is reversible: the Registry client sits behind one function, and
swapping it costs one module.

That edge is also a gift. Connect refusal, connect timeout and response timeout
are three distinguishable outcomes, which is more resolution than the
refusal-vs-timeout distinction in [ADR-0002](./docs/adr/0002-four-beliefs.md)
actually needs — map them onto the two backoff buckets and let the third fall
with whichever is closer.

## The belief state machine

A device is always in exactly one of four states. Full rationale in
[ADR-0002](./docs/adr/0002-four-beliefs.md).

| State | Meaning | On the next message |
|---|---|---|
| **Cold** | never asked | ask the Registry, publish unenriched |
| **Known** | Registry reported it | enrich, renew lifetime |
| **Unknown** | Registry reported it absent | publish unenriched, **do not ask again** |
| **Unresolved** | Registry could not be reached | publish unenriched; ask once the backoff elapses |

Three mechanisms keep this honest:

- **Single-flight.** While a lookup for a device is in flight, further messages
  for it do not start another. Without this, a fast-publishing device turns one
  pending lookup into hundreds.
- **Bounded concurrency.** Registry lookups run in a small pool, not in the
  publish path and not one unbounded process per message.
- **Asymmetric backoff.** A connection *refusal* backs off far longer than a
  *timeout*. A refusal means nothing is listening; a timeout means something
  accepted the connection and may well be healthy. Collapsing them makes
  recovery from a crashed Registry either as slow as a slow one or as
  aggressive as a crash.

There is deliberately **no "loading" state**. Whether a lookup is in flight is a
fact about the pipeline, not about the device, so it is tracked separately.
Adding it to the belief record would turn four documented states into five and
would let an in-flight marker be mistaken for a verdict.

## Configuration surface

Delivered by EMQX as a HOCON file validated against an Avro schema. Every value
has a default, and a malformed value falls back to the default rather than
refusing to start — a typo in `topic_filter` must not stop the broker booting.

| Key | Default | Why this default |
|---|---|---|
| `topic_filter` | `plant/+/telemetry` | The only topic considered. |
| `registry_url` | `http://registry:8080` | The plugin's sole outward dependency. |
| `connect_timeout_ms` | 2000 | Bounds how long a loader worker can be occupied. |
| `request_timeout_ms` | 2000 | |
| `known_lifetime_ms` | 3600000 | Long: a stale Known serves slightly old data. |
| `unknown_lifetime_ms` | 30000 | Short: a stale Unknown silently suppresses enrichment for a device that *does* exist. |
| `backoff_refused_ms` | 30000 | Nothing is listening; do not hurry. |
| `backoff_timeout_ms` | 5000 | Something answered slowly; it may be healthy. |
| `unresolved_horizon_ms` | 900000 | Garbage-collection horizon so a silent device cannot pin a connection state forever. |
| `sweep_interval_ms` | 10000 | |
| `max_concurrent_loads` | 8 | |

The two lifetime defaults are the asymmetry from [ADR-0003](./docs/adr/0003-cache-outlives-registry.md);
the two backoff defaults are the distinction from
[ADR-0002](./docs/adr/0002-four-beliefs.md).

## What a blip looks like on the wire

A blip is published **byte-identical to what arrived**. No `null` field, no
diagnostic field, no plugin-shaped anything. If the Registry is down or the
device is unknown, consumers see a message that is exactly what was published to
the broker.

The cause is logged on the broker side instead. This is deliberate: a `null`
would collide with a genuinely-null field, and a diagnostic field would leak
plugin internals into the domain payload.

**The first message for every device is a blip.** This is structural, not a
defect — see [ADR-0001](./docs/adr/0001-first-message-blips.md), which exists
because otherwise it reads as a bug.

## Seeing it work

Two log panes side by side, and nothing else:

- the Registry logs every lookup and its answer
- EMQX logs the belief transitions and throttled blip causes

The whole story is visible in one screen: a `404` next to a blip for the same
device id is self-explanatory in a way that no dashboard would be.

To exercise the two Unresolved paths live, the Registry takes two fault-injection
query parameters:

| Parameter | Produces |
|---|---|
| `?delay_ms=N` | a client **timeout** — something answered, slowly |
| `?refuse=1` | a connection **refusal** — nothing is listening |

Both exist because the timeout/refusal distinction is the most interesting
behaviour in the design and it would otherwise be untestable in a demo. A delay
knob alone only ever produces timeouts; seeing a refusal requires actually
stopping the container.

A CLI verb dumping current beliefs is the intended fallback if the log noise
proves insufficient — deliberately deferred rather than built, because it shows
only what the plugin believes, never what the Registry says.

## Constraints discovered while designing

Verified against the EMQX source at tag `v5.8.8`. These are load-bearing and
several are actively misleading in the available documentation.

- **The plugin template targets 5.9, not 5.8**, and pins Erlang 27 while 5.8.8
  ships **OTP 26.2.5.14-1**. The 5.8 install docs still claim OTP 24 or 25. All
  three are wrong; a plugin built on the template's OTP will produce BEAM files
  the OTP 26 loader rejects.
- **`emqx_cache` does not exist in any EMQX release.** A plugin owns its ETS
  table and its own expiry. There is no facility to piggyback on.
- **Plugin configuration is HOCON + Avro, not `emqx_conf_schema`.** The latter
  is a compile-time aggregator with a hardcoded app list that plugins cannot
  join. Config arrives as a map with **binary** keys.
- **`emqx_utils_json:safe_decode/1` does not apply `return_maps`**, though
  `emqx_utils_json:decode/1` does. That asymmetry is in 5.8.8 itself; using the
  safe variant silently yields proplists instead of maps.
- **The template's `on_health_check/1` callback is never called** by 5.8.8 —
  zero occurrences in the entire tree. It is copied from many tutorials and does
  nothing.
- **Plugin REST routes are a trap.** A route is discovered when the dashboard
  listener starts, and a plugin installed afterwards needs that listener
  restarted; no supported reload command was found. Happily, this design needs
  no plugin REST endpoint at all, since the plugin is an HTTP *client*.
- **The Rule Engine is a `message.publish` hook at priority 900** and cannot
  modify the message. A plugin at highest priority runs first, so a rule on an
  enriched topic sees the enriched payload.
- **`spawn_link` from a `message.publish` hook is fatal.** The connection
  process is itself `proc_lib:spawn_link`'d
  (`emqx_connection.erl:200-203`), so anything linked from the hook dies with
  the client. Note that `emqx_utils:nolink_apply/2` is a trap by name: it
  deliberately *kills* work when the caller dies. EMQX's own pattern for
  hook-triggered IO is a cast into a supervised worker
  (`emqx_resource_buffer_worker:async_query/3`), which is the shape the loader
  pool should take.

## Known limitations

Stated rather than smoothed over:

- **The first message per device is always unenriched** (ADR-0001).
- **Known entries keep serving through a Registry outage.** Staleness is
  invisible and bounded by the lifetime; nothing announces the outage's end
  (ADR-0003).
- **Recovery is discovered, never announced.** Unresolved beliefs retry only
  when a message arrives, so a device that has stopped publishing keeps its
  Unresolved belief indefinitely.
- **The cache is node-local.** A multi-node cluster holds one copy per node and
  makes that many Registry calls, with no coherence between them. Invisible at
  single-node; genuinely wrong at scale.
- **Field names and message shape are fixed.** One message shape, one Registry
  shape.

## Where each decision lives

| Decision | Where |
|---|---|
| Vocabulary | [GLOSSARY.md](./GLOSSARY.md) |
| First message always blips | [ADR-0001](./docs/adr/0001-first-message-blips.md) |
| Four beliefs; refusal vs timeout backoff | [ADR-0002](./docs/adr/0002-four-beliefs.md) |
| Cache outlives Registry; asymmetric lifetimes; lazy recovery | [ADR-0003](./docs/adr/0003-cache-outlives-registry.md) |
| Everything else (topic/payload shapes, in-place mutation, blip wire format, fault-injection knobs, verification approach) | this document |