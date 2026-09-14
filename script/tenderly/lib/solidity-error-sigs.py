#!/usr/bin/env python3
"""Print the canonical signature of every `error` declared in the given Solidity files.

`cast sig` needs `Foo(uint256,uint256)` — parameter NAMES must be stripped, not just whitespace.
Getting that wrong hashes to nothing and silently degrades every parameterised custom error to
"unknown" in a revert decoder, which is worse than having no decoder at all.
"""
import re
import sys

seen = []
for path in sys.argv[1:]:
    try:
        src = open(path).read()
    except OSError:
        continue
    for m in re.finditer(r"\berror\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)", src):
        name, params = m.group(1), m.group(2).strip()
        types = [p.strip().split()[0] for p in params.split(",") if p.strip()]
        sig = "{}({})".format(name, ",".join(types))
        if sig not in seen:
            seen.append(sig)
print("\n".join(sorted(seen)))
