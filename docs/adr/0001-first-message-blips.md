# The first Telemetry message per device is delivered unenriched

The plugin loads a Device Registry entry on the message that needs it (Load on
miss) and never blocks the publish path. Taken together these mean the very
message that triggers a load cannot be enriched: **every device blips exactly
once**, by construction rather than by fault. This is deliberate.

The alternative — block once per key until the load resolves, with a timeout —
satisfies "the first published message arrives enriched" at the cost of putting
a registry round trip on the publish path for every newly seen device. We chose
unconditional non-blocking over a bounded one-time stall, because a publish path
that can be held open by a dependency is the failure mode that hurts during an
outage, when it matters most.

The demo therefore publishes each device twice: the first is a blip, the second
is enriched. Consumers that require every message enriched must not rely on
this plugin's guarantees.