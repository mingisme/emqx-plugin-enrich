# Working in this repo

Design documents for an EMQX 5.8.8 plugin that enriches plant telemetry from a
Device Registry. No code yet — `DESIGN.md` is the entry point.

## Where things are

- `DESIGN.md` — the settled design: contracts, config surface, the belief state
  machine, known limitations, and the constraints verified against EMQX source.
  Read this first.
- `GLOSSARY.md` — the domain vocabulary. **Cold / Known / Unknown / Unresolved /
  Blip** are defined there, and those words mean precisely what they mean there.
- `docs/adr/` — the three decisions that met the ADR bar, each with its
  reasoning and its rejected alternatives.

## Verifying claims about EMQX

`DESIGN.md` § "Constraints discovered" is load-bearing and contradicts the
published EMQX docs. Re-verify against source, and prefer a local clone to
fetching whole files into context:

```sh
git clone --depth 1 --branch v5.8.8 https://github.com/emqx/emqx
```

A sparse clone greps in seconds; one `webfetch` per question does not, and the
answer is not reproducible without re-fetching.

## Scope

A skill names its deliverable, and the deliverable is the ceiling. Match it, and
read a user's "apply that" as scoped to it: `/grill-with-docs` produces
documents — glossary, design, ADRs — and `/implement` produces code. Each says
so in its own text; the sequence runs one to the other.

## Checks

`scripts/check-docs.py` verifies every relative link resolves, skipping fenced
and inline code examples. It runs automatically as a pre-commit hook; after
editing docs outside a commit, run it yourself:

```sh
python3 scripts/check-docs.py .
```

Set `SKIP_DOC_CHECK=1` to bypass deliberately.