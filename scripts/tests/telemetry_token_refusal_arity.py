"""Every argument the token refusal is given has a placeholder to print it.

Split out of `telemetry-token-agreement.sh` rather than inlined as a heredoc,
because a `.py` sidecar is readable and lintable — and because
`pyyaml-preflight.bats` now covers `.py` files in this directory, so a sidecar
here is inside the class rule rather than outside it (backend#2626).

WHAT THIS CATCHES. `telemetryCollectorState` refuses with
`fail (printf "<format>" <args>)`, and the args include one `include` per Secret
name the lookup accepted. printf SILENTLY DROPS an argument with no placeholder,
so removing a `%q` from the format string leaves the name searched and unreported
— and the operator is told to create a Secret that may already exist under a name
the message never mentions.

WHY NOT A SUBSTRING CHECK. That was the first cut, and it was vacuous: the format
string and its arguments are on ONE line, so `case $msg in *telemetryTokenName*`
matched the ARGUMENT even after the placeholder was deleted. Counting is the only
form that separates "given" from "printed".

Prints a reason on mismatch and NOTHING on agreement, so the caller can treat any
output as the finding. Exits 0 either way: the caller decides, and a non-zero here
would be indistinguishable from "the interpreter is missing".
"""

from __future__ import annotations

import re
import sys

MARKER = "telemetryCollector.enabled is true but its token Secret"
#: An argument that supplies a value: a helper include, a values read, or a
#: release field. Counted rather than named, so a fourth accepted name is covered.
ARGUMENT = re.compile(r'\(include "|\.Values\.|\.Release\.')
PLACEHOLDER = re.compile(r"%[qsvd]")


def check(path: str) -> str:
    """`""` when the refusal can print everything it is given, else the reason."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        return f"cannot read {path} ({exc}) — refusing to report agreement"
    line = next((l for l in text.splitlines() if MARKER in l), "")
    if not line:
        return "could not isolate the token refusal line; this check proves nothing"
    m = re.search(r'printf\s+"((?:[^"\\]|\\.)*)"(.*)$', line)
    if not m:
        return "could not parse the refusal's printf format string"
    fmt, args = m.group(1), m.group(2)
    placeholders = len(PLACEHOLDER.findall(fmt))
    supplied = len(ARGUMENT.findall(args))
    if not placeholders or not supplied:
        return (
            f"parsed {placeholders} placeholder(s) and {supplied} argument(s) — one of "
            "them is zero, so the comparison would be vacuous"
        )
    if placeholders != supplied:
        return (
            f"the refusal has {placeholders} placeholder(s) for {supplied} argument(s). "
            "printf drops the extras, so a Secret name the lookup searched is not "
            "reported — and the operator is told to create one that may already exist"
        )
    return ""


if __name__ == "__main__":
    reason = check(sys.argv[1])
    if reason:
        print(reason)
