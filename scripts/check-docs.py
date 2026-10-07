#!/usr/bin/env python3
"""Check the docs for broken relative links.

Mechanically catches the class of mistake where a pointer names a file that was
renamed, moved, or never written. Written as a script rather than a grep|sed
pipeline because pipelines fail *silently and plausibly*: a regex that misses
the closing paren reports phantom results, which is worse than no check at all
because it looks like a finding.

Exit 0 when every relative link resolves, 1 otherwise. Absolute URLs, anchors,
and mailto: are ignored -- this checks that we point at files that exist, not
that the internet is up.

Usage:  scripts/check-docs.sh [root]
"""

import os
import re
import sys

# [text](target) — target is optional; an empty target is an in-page anchor.
LINK = re.compile(r"\[[^\]]*\]\(\s*([^)\s]+)(?:\s+\"[^\"]*\")?\s*\)")

# Fenced code blocks are examples, not pointers.
FENCE = re.compile(r"^\s*(?:```|~~~)")

# Inline code spans too: [`foo`](./x.md) is a link, `[foo](./x.md)` is not.
INLINE_CODE = re.compile(r"`[^`]*`")


def rel_links(text: str):
    """Yield (lineno, target) for relative links, skipping code fences."""
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # Strip inline code so an example inside backticks is not read as a
        # pointer. A link whose *text* contains code still parses: only the
        # backticked span is removed, leaving the target intact.
        for target in LINK.findall(INLINE_CODE.sub("", line)):
            yield lineno, target


def is_external(target: str) -> bool:
    return (
        target.startswith(("http://", "https://", "mailto:", "#", "tel:"))
        or target.startswith("//")
    )


def main(argv) -> int:
    root = argv[1] if len(argv) > 1 else "."
    docs = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {".git", "_build", "node_modules"}]
        docs += [os.path.join(dirpath, f) for f in filenames if f.endswith(".md")]

    if not docs:
        print(f"check-docs: no markdown found under {root}", file=sys.stderr)
        return 0

    broken, checked = [], 0
    for path in sorted(docs):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        base = os.path.dirname(path)
        for lineno, target in rel_links(text):
            if is_external(target):
                continue
            checked += 1
            # Strip any #anchor, then resolve against the containing file.
            resolved = target.split("#", 1)[0]
            if not resolved:
                continue
            if not os.path.exists(os.path.normpath(os.path.join(base, resolved))):
                broken.append((path, lineno, target))

    for path, lineno, target in broken:
        print(f"{path}:{lineno}: broken link -> {target}", file=sys.stderr)

    print(
        f"check-docs: {checked} relative link(s) across {len(docs)} file(s), "
        f"{len(broken)} broken"
    )
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))