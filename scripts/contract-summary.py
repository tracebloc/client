#!/usr/bin/env python3
"""Print `<contract_version>|<cpu>m / <mem> MiB` for an envelope contract.

Exists so the pin-staleness job in envelope-contract-drift.yml can compare two
copies of client-runtime/envelope_contract.json without a nested heredoc inside
a YAML block scalar -- which is how the first attempt at that job broke, and is
unreadable even when it works.

FAILS LOUDLY on anything it cannot read. A summary that silently degrades to
"unknown" would let the comparison report two unknowns as equal, which is the
"cannot tell reads as agreement" trap (CLAUDE.md rule 3).

stdlib only: it runs on a bare runner before any pip install.
"""

from __future__ import annotations

import json
import sys

MIB = 1024 * 1024


def summarise(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    version = document["contract_version"]
    overhead = document["overhead"]
    cpu = overhead["cpu_millicores"]
    memory = overhead["memory_bytes"]
    if (
        not isinstance(version, int)
        or not isinstance(cpu, int)
        or not isinstance(memory, int)
    ):
        raise TypeError(
            f"{path}: contract_version, overhead.cpu_millicores and "
            f"overhead.memory_bytes must all be integers"
        )
    return f"{version}|{cpu}m / {memory // MIB} MiB"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(
            f"usage: {argv[0] if argv else 'contract-summary.py'} <envelope_contract.json>",
            file=sys.stderr,
        )
        return 2
    print(summarise(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
