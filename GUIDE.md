# Manual verification guide

Step-by-step commands and expected outputs for verifying the POC.

## Prerequisites

- Docker with compose (Docker Desktop, colima, or podman-compose)
- 4 GB RAM free
- Ports **1883** (MQTT) and **18083** (EMQX dashboard) free on the host.
  Port **8080** (Device Registry) is also published so the §4 curl checks
  work from the host.
- About 5 minutes

## 1. Boot the stack

```bash
docker compose up --build
```

The first build takes 2–4 minutes (downloading images, installing `paho-mqtt`,
compiling Erlang). Subsequent runs are fast.

The four services come up in dependency order: `emqx` → `registry` →
`subscriber` → `publisher`.

## 2. Verify EMQX started with the plugin enabled

```bash
docker compose logs emqx 2>&1 | grep -i plugin
```

Expected: two startup lines on stdout —

```
emqx_plugin_enrich: starting
emqx_plugin_enrich: hook registered
```

— and, once you publish (step 5), a `hook_us` line per message. `hook_us` is
logged at **warning** level on purpose, because EMQX's default log level is
`warning` and this is the demo's key observable:

```
... [warning] <client>@<ip> emqx_plugin_enrich hook_us=32
```

If you see nothing, the plugin wasn't loaded. Jump to [§ Troubleshooting](#troubleshooting).

## 3. Verify the hook is registered

EMQX 5.8 has no `emqx ctl hooks list` command. Query the hook registry
through the node instead:

```bash
docker compose exec emqx /opt/emqx/bin/emqx eval "emqx_hooks:lookup('message.publish')."
```

Expected: a list of callbacks that includes our plugin at priority `100`:

```
{callback,{emqx_plugin_enrich,on_message_publish,[]},undefined,100}
```

The `100` is the priority. Note the callback is **arity 1**
(`on_message_publish/1`): for a `fold` hook EMQX passes the `#message{}`
record as the single argument.

> Priority note: in EMQX a *higher* integer runs *earlier*. The built-in
> publish hooks (`emqx_retainer` at 930, `emqx_delayed` at 860, etc.) run
> before this plugin, so for this POC enrichment happens after them. If you
> need enrichment to precede retain/delay, raise the priority above those
> numbers.

## 4. Verify the registry is up

```bash
curl -s http://localhost:8080/devices/dev-001
```

Expected: `{"org_id": "GDANSK-11"}`.

Then:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/devices/dev-999
```

Expected: `404`.

## 5. Run the publisher and watch the subscriber

The publisher is a one-shot. It publishes five messages:

| # | Device | Notes |
|---|---|---|
| 1 | `dev-001` | First message — expected unenriched (cache cold) |
| 2 | `dev-001` | Second message — expected enriched (cache hit) |
| 3 | `dev-002` | First message — expected unenriched |
| 4 | `dev-003` | First message — expected unenriched |
| 5 | `dev-999` | Expected always unenriched (Unknown cached) |

```bash
docker compose up publisher         # one-shot
docker compose logs subscriber      # tail in another terminal
```

Or watch all three at once:

```bash
docker compose logs -f subscriber
```

### Expected subscriber output

```
subscribed to plant/+/telemetry
[plant/dev-001/telemetry] {"device_id":"dev-001","temp_c":21.5,"ts":...}
[plant/dev-001/telemetry] {"ts":...,"temp_c":21.6,"org_id":"GDANSK-11","device_id":"dev-001"}
[plant/dev-002/telemetry] {"device_id":"dev-002","temp_c":21.7,"ts":...}
[plant/dev-003/telemetry] {"device_id":"dev-003","temp_c":21.8,"ts":...}
[plant/dev-999/telemetry] {"device_id":"dev-999","temp_c":21.9,"ts":...}
```

The second `dev-001` line carries `"org_id":"GDANSK-11"`. (Key order in the
enriched line is not significant — JSON re-encoding may reorder keys.) Lines
without `org_id` are blips (the first message per device, or a device not
found in the registry).

## 6. Verify microsecond enrichment

```bash
docker compose logs emqx | grep hook_us
```

Expected:

```
emqx_plugin_enrich hook_us=42   ← cache miss, async lookup fired (still µs because we don't block)
emqx_plugin_enrich hook_us=18   ← cache hit on dev-001 (merge + JSON encode)
emqx_plugin_enrich hook_us=8    ← cache miss, dev-002
emqx_plugin_enrich hook_us=14   ← cache hit on dev-001
emqx_plugin_enrich hook_us=9    ← cache miss, dev-003
emqx_plugin_enrich hook_us=11   ← dev-001.2 cache hit
emqx_plugin_enrich hook_us=8    ← dev-999 cache miss → 404, marked Unknown
emqx_plugin_enrich hook_us=7    ← dev-999, cache hit on Unknown, no HTTP fired
```

Numbers depend on host but should be **tens of microseconds or less**. If you see
millisecond values, something's wrong — see [§ Troubleshooting](#troubleshooting).

## 7. Verify never-block under HTTP fault

### Timeout (`?delay_ms`)

Stop the registry, edit its fault-injection to introduce a 5-second delay for
unknown devices:

```bash
# Stop the running registry
docker compose stop registry

# Edit registry/app.py: route ?delay_ms=N query to all unknown devices
# Or: just override the lookup to always sleep
docker compose run --rm registry python -c "
import time, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(5)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{\"org_id\":\"DELAYED\"}')

HTTPServer(('0.0.0.0', 8080), H).serve_forever()
" &
```

Then publish a message for a new device and watch `hook_us`:

```bash
docker compose logs -f emqx | grep hook_us
```

Expected: `hook_us` is still single-digit microseconds. The hook returns
immediately; the registry delay doesn't reach the publish path.

### Refusal (`?refuse=1`)

Same idea — restart registry with a permanent `503`. Verify the hook doesn't
block; `dev-999` (or any new device) blips; subsequent publishes for the same
device blip too, but the hook is still microsecond.

## 8. Restart and re-verify

```bash
docker compose restart emqx
docker compose logs emqx | grep -i enrich
```

The plugin's cache survives in-process only — restart empties it. So after
restart, the first message for `dev-001` will blip again, then subsequent
messages enrich. This is intentional for the POC (no persistence); product
should consider cluster-wide coherence.

## Troubleshooting

### "Plugin not loaded"

```bash
docker compose exec emqx ls /opt/emqx/plugins/emqx_plugin_enrich-0.1.0/emqx_plugin_enrich-0.1.0/ebin/
```

Expected: `emqx_plugin_enrich.app` and `emqx_plugin_enrich.beam`. If empty,
the multi-stage build didn't copy correctly — check `emqx-plugin/Dockerfile`.

### "Hook not registered"

```bash
docker compose exec emqx /opt/emqx/bin/emqx ctl plugins list
```

Expected JSON with `"running_status": "running"` and
`"config_status": "enabled"`. If it says `loaded`/`not_configured`, the plugin
app was never *started* — EMQX only ran if `plugins.states` in
`etc/base.hocon` lists it with `enable = true` (the Dockerfile adds this), and
if the `.app` file has a `{mod, {emqx_plugin_enrich, []}}` entry so OTP calls
`start/2`. Start it manually with (note the version suffix):

```bash
docker compose exec emqx /opt/emqx/bin/emqx ctl plugins start emqx_plugin_enrich-0.1.0
```

Expected: `emqx_plugin_enrich-0.1.0 ... running`. If stopped, restart:

```bash
docker compose exec emqx /opt/emqx/bin/emqx ctl plugins start emqx_plugin_enrich-0.1.0
```

### "Hook latency is milliseconds, not microseconds"

Look at *what's slow*, not just the number. Common causes:

- The Erlang VM is interpreting (`:erlang.system_flag(Schedulers, ...)` for SMP).
- EMQX is under heavy load from something else.
- The plugin file has grown large and the EMQX emulator is missing a beam asm.

Check:

```bash
docker compose exec emqx /opt/emqx/bin/emqx ctl status
docker compose exec emqx erl -noshell -eval 'erlang:system_info(schedulers), erlang:halt().'
```

### "Subscriber stays silent"

```bash
docker compose logs subscriber
```

If you see `subscribed to plant/+/telemetry` but no messages, the publisher
may have run before the subscriber connected. Restart the publisher:

```bash
docker compose restart publisher
```

## Production development notes

The .erl file contains `%% PROD-DEV` markers at the spots where the POC stops
short and product work begins. The minimum product-isation:

1. **Loader pool** — replace the single `emqx_plugin_enrich_loader` gen_server
   with a worker pool (`pool` module or custom supervisor). The hook stays
   microsecond; cold-cache throughput goes up.
2. **Cache lifetimes & sweep** — add `known_lifetime_ms`, `unknown_lifetime_ms`,
   and a periodic sweep timer that evicts expired entries.
3. **Refusal-vs-timeout backoff** — split `classify/1` outcomes into
   `Refused` and `TimedOut` buckets with different `backoff_refused_ms` and
   `backoff_timeout_ms`. Drop `cache_clear_in_flight` and replace with a
   per-bucket "Unresolved until backoff elapses" verdict.
4. **HOCON config schema** — move the four `?REGISTRY_*`, `?TOPIC_FILTER`,
   `?DEVICE_ID_FIELD`, and timeout macros into a `priv/emqx_plugin_enrich.conf`
   HOCON schema with the four "beliefs" vocabulary.
5. **Multi-node coherence** — the cache is per-node. Decide whether to use Mria
   replication, an external cache (Redis), or accept per-node divergence.

The full design record for these is in the conversation history of this repo
(10 settled decisions: lifecycle, plugin-vs-alternatives, cache shape, failure
modes, first-message behaviour, EMQX version, configuration defaults).