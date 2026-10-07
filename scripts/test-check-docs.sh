#!/usr/bin/env bash
# Self-test for check-docs.py.
#
# The check must go RED on a genuinely broken pointer and stay quiet on every
# thing that merely looks like one. A linter that reports phantoms is worse than
# no linter, because a phantom reads as a finding.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/docs/adr"
touch "$FIXTURE/docs/adr/0001-real.md"

cat > "$FIXTURE/probe.md" <<'EOF'
Never written: [a](./docs/adr/9999-ghost.md)
Mislabelled slug: [b](./docs/adr/0001-reel.md)
Genuine target: [c](./docs/adr/0001-real.md)
Existing directory: [d](./docs/adr)
With an anchor: [e](./docs/adr/0001-real.md#top)
Off-site: [f](https://example.invalid/gone) and [g](#anchor) and [h](mailto:a@b.c)

Fenced, so an example rather than a pointer:

```markdown
[i](./inside/a/fence.md)
```

Inline, so also not a pointer: `[j](./inside/inline.md)`
EOF

fail=0

expect() { # expect <want-exit> <label> <dir>
  local want="$1" label="$2" dir="$3" got
  set +e
  out="$(python3 "$HERE/check-docs.py" "$dir" 2>&1)"
  got=$?
  set -e
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$label"
  else
    printf 'FAIL  %s (exit %s, wanted %s)\n%s\n' "$label" "$got" "$want" "$out"
    fail=1
  fi
}

expect 1 "flags the two broken pointers, ignores fences/inline/external" "$FIXTURE"
expect 0 "the real repo is clean" "$ROOT"

# Exactly two findings, named. Guards against both false positives and a check
# that silently matches nothing at all.
set +e
out="$(python3 "$HERE/check-docs.py" "$FIXTURE" 2>&1)"
set -e
count="$(printf '%s\n' "$out" | grep -c 'broken link' || true)"
if [ "$count" = "2" ]; then
  printf 'ok    found exactly 2, not a number that drifted\n'
else
  printf 'FAIL  expected 2 broken links, counted %s\n%s\n' "$count" "$out"
  fail=1
fi

[ "$fail" = 0 ] && printf '\ncheck-docs self-test passed\n'
exit "$fail"