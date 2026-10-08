# emqx-plugin-enrich (POC)

EMQX 5.8.8 plugin that enriches plant telemetry in place via a sidecar **Device Registry**.
The cache-hit path completes in microseconds; the publish path never blocks.

## Hypothesis (what this POC validates)

A `message.publish` hook on EMQX 5.8.8 can rewrite the payload
in place, and the cache-hit enrichment path completes in microseconds — so
subscribers experience no perceptible overhead.

> The hook is registered at priority `100`. In EMQX a higher integer runs
> earlier, so `100` is a *low* priority: the built-in publish hooks
> (`emqx_retainer`, `emqx_delayed`) run before it. Raise the number if
> enrichment must precede them. The latency claim holds regardless of
> priority.

The hook itself is measured and logged (`hook_us=N`) on every publish. Look for
those lines in `docker compose logs emqx`.

## What's deliberately out of scope (deferred to product)

- Loader pool (POC: one query at a time)
- Cache eviction / TTL sweep (POC: no expiry, no sweep)
- Refusal-vs-timeout backoff distinction (POC: any error → next message retries)
- HOCON schema for plugin configuration (hardcoded for POC)
- Multi-node cluster behaviour
- Belief-state-machine vocabulary (cold / known / unknown / unresolved)

The 10 design decisions recorded in this conversation are unchanged — they describe
the product. This spike only proves the central latency claim.

## Layout

| Path | Container | What it is |
|---|---|---|
| `emqx-plugin/` | `emqx` | Plugin source. Compiled and enabled in the broker image. |
| `registry/` | `registry` | HTTP-side Device Registry. Fault-injection knobs: `?delay_ms=N`, `?refuse=1`. |
| `publisher/` | `publisher` | Test rig. Sends to `plant/+/telemetry`. |
| `subscriber/` | `subscriber` | Test rig. Subscribes to `plant/+/telemetry`. |

## How to run

```bash
docker compose up --build
```

You'll see four services come up:
- `emqx` (broker, port 1883 for MQTT, 18083 for the dashboard)
- `registry` (Python HTTP server, port 8080)
- `publisher` (one-shot; publishes messages and exits)
- `subscriber` (long-running; prints whatever it receives)

## Test plan

| # | Action | Expected |
|---|---|---|
| 1 | Publisher sends `dev-001` (first) | Subscriber receives *without* `org_id`. EMQX log: `hook_us=N` (cache miss, async lookup fired). |
| 2 | Publisher sends `dev-001` (second) | Subscriber receives *with* `org_id=GDANSK-11`. EMQX log: `hook_us=N` < 100µs (cache hit). |
| 3 | Publisher sends `dev-002`, `dev-003` | First message for each is unenriched; subsequent are enriched with their `org_id`. |
| 4 | Publisher sends `dev-999` | Always unenriched (404 from registry). Cache marks Unknown; no retry storms. |
| 5 | Inject fault: edit `registry/app.py` to take a `?delay_ms=10000` query, restart registry | EMQX's hook stays microsecond (does not block). Messages for cold-cache keys blip. |

The microsecond check is line 5 of the EMQX log: `emqx_plugin_enrich hook_us=...`
should be in the tens of microseconds for cache hits, and single-digit to low-tens
for cache misses (because the hook returns immediately without waiting for HTTP).