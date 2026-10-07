# The Cache outlives the Registry, and is allowed to be wrong

Three related decisions about what the pipeline does when the Device Registry is
unhealthy. They are recorded together because they are one position: **cache
staleness is an accepted cost, and no cache-wide coordination is built to
detect an outage.**

**Known entries keep serving during a Registry outage.** A device cached one
second before the Registry dies continues to enrich for the rest of its Known
lifetime. The alternative — treating every belief as void once the Registry
looks unhealthy — converts a silent staleness problem into a mass-blip problem.
Staleness is invisible but bounded; mass blipping is visible and unbounded, and
it hits healthy devices to fix a problem with one dependency.

**Lifetimes are asymmetric: Unknown entries are short, Known entries are long.**
A stale `Known` entry serves slightly old data; a stale `Unknown` entry silently
blocks enrichment for a device that *does* exist. The former is a data-quality
problem, the latter is an outage that never announces itself. Short Unknown and
long Known puts the effort where the damage is.

**Recovery is discovered, never announced.** Unresolved entries retry only when
a Telemetry message arrives, and no background sweep re-asks them. A device that
has stopped publishing therefore keeps its Unresolved belief indefinitely — but
a silent plugin also does no work and generates no load, and we would rather
under-query a Registry nobody is reading from than keep asking on a timer.

Known limitation, stated plainly: the end of a Registry outage is not observable
from the message stream. Entries expire on their own schedule and the plugin
converges only as traffic arrives.