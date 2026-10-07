# Payload Enrichment

Enriching outbound MQTT messages with fields looked up from a device registry,
served as a reference table the message pipeline consults but does not own.

## Language

**Telemetry message**:
A message published by a plant device, carrying a measurement. The unit of
work this context exists to enrich.
_Avoid_: Payload, data, event

**Device Registry**:
The authoritative fieldA-to-fieldB table, owned outside the message pipeline and
consulted over HTTP. It answers "what is this device?", never "what did it read?".
_Avoid_: Reference data, lookup table, cache, master data

**Enrichment**:
Augmenting a Telemetry message in place with fields obtained from the Device
Registry. Enrichment never changes the topic, the QoS, or the original
measurements.
_Avoid_: Transformation, decoration, lookup, annotation

**Load on miss**:
Populating a cache entry the first time a key is seen, driven by the arrival of
a message that needs it. Nothing is loaded until a message asks.
_Avoid_: Hot loading, warm-up, prefetch, lazy loading, cold start

**Blip**:
A Telemetry message that reaches subscribers unenriched. One observable outcome
with four distinct causes — a Cold key, an Unknown device, an Unresolved
registry, or a Telemetry message carrying no device identity at all. To a
subscriber the four are indistinguishable, and they call for opposite responses,
so never infer the cause from the blip alone.
_Avoid_: Error, drop, failure, gap, miss

**Cold**:
Absence of any belief about a device, before the Device Registry has been asked.
Resolved exactly once by the first Telemetry message that names the device.
_Avoid_: Uncached, empty, new, stale

**Known**:
A device the Device Registry positively reported, and the only state in which
Enrichment succeeds.
_Avoid_: Cached, hit, resolved, enriched, present

**Unknown**:
A device the Device Registry positively reported as absent. A settled verdict,
not a pending one, and never grounds for enriching later traffic.
_Avoid_: Missing, invalid, not found, unregistered

**Unresolved**:
A device the Device Registry could not be asked about, because it was
unreachable or slow. Explicitly *not* an answer: it lapses and will be asked
again.
_Avoid_: Error, unknown, failed, down

**Registry outage**:
A period during which the Device Registry cannot be consulted at all. It
distorts *every* belief at once, converting Known into a memory of what used to
be true and Cold into silence. Its end is not observable from the message
stream, so recovery must be discovered rather than announced.
_Avoid_: Error, downtime, incident

**Device entry lifetime**:
How long a belief about a device survives between uses, renewed each time it is
read, so a device in constant use is never forgotten. The lifetime is a property
of the *state*, not of the device: an Unknown belief lapses far sooner than a
Known one, because holding a wrong verdict costs more than holding an old fact.
_Avoid_: TTL, cache timeout, staleness window

## Deliberate exclusions

The **Cache** is an implementation detail, not a domain term. It exists to hold
a device's Registry belief for the length of a Device entry lifetime, and
nothing in this context should be designed around its shape.

**Cold**, **Known**, **Unknown**, and **Unresolved** are the four states of
belief the pipeline can hold about a device. The Cache stores the last three;
Cold is the absence of all three.