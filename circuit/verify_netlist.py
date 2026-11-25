#!/usr/bin/env python3
"""verify_netlist.py — independently verify the Yosys-synthesized NAND netlist.

Parses release_logic_netlist.v (Yosys `write_verilog` output) and
exhaustively evaluates all 16 input combinations against the expected
function:
    RELEASE = done AND (approved OR timeout) AND (NOT disputed)

Usage:
    python3 verify_netlist.py [netlist.v]
    (default: release_logic_netlist.v in this directory)

Exit code 0 = all 16 combinations match. Non-zero = mismatch found.
This is independent of iverilog: it reads the actual netlist file.

NOTE on netlist format: Yosys 0.33 `write_verilog` renders its internal
$_NAND_ / $_NOT_ cells as continuous assignments, NOT as cell instances:
    assign _11_ = ~(_08_ & _09_);   // NAND
    assign _08_ = ~_13_;            // NOT (= NAND with tied inputs)
    assign _13_ = timeout;          // wire alias / BUF
So this parser handles both the assign form (what Yosys actually emits)
and the $_NAND_ instance form (older/alternate Yosys output).
"""
import re
import sys
from pathlib import Path

INPUTS = ("done", "approved", "timeout", "disputed")
OUTPUT = "release_out"


def clean(name: str) -> str:
    """Strip Verilog escaping/whitespace from a net name."""
    name = name.strip()
    if name.startswith("\\"):
        name = name[1:]
    return name.strip()


def parse_netlist(text: str):
    """Return (ops, aliases) parsed from the netlist.

    ops: list of (kind, a, b, y) where kind is 'nand' or 'not'.
    aliases: dict y -> a for plain wire assignments (BUF).
    """
    ops = []
    aliases = {}

    # Form 1: $_NAND_ cell instances (alternate Yosys output).
    inst_pat = re.compile(
        r"\$_NAND_\s+\S+\s*\(\s*"
        r"\.A\s*\(\s*([^)]+?)\s*\)\s*,\s*"
        r"\.B\s*\(\s*([^)]+?)\s*\)\s*,\s*"
        r"\.Y\s*\(\s*([^)]+?)\s*\)\s*\)\s*;",
        re.DOTALL,
    )
    for a, b, y in inst_pat.findall(text):
        ops.append(("nand", clean(a), clean(b), clean(y)))

    # Form 2: continuous assignments (what Yosys 0.33 write_verilog emits).
    assign_pat = re.compile(
        r"assign\s+(\S+)\s*=\s*(.+?)\s*;", re.DOTALL
    )
    for y, expr in assign_pat.findall(text):
        y = clean(y)
        expr = expr.strip()
        m_nand = re.fullmatch(r"~\(\s*(\S+)\s*&\s*(\S+)\s*\)", expr)
        m_not = re.fullmatch(r"~\s*(\S+)", expr)
        m_buf = re.fullmatch(r"(\S+)", expr)
        if m_nand:
            ops.append(("nand", clean(m_nand.group(1)), clean(m_nand.group(2)), y))
        elif m_not:
            ops.append(("not", clean(m_not.group(1)), None, y))
        elif m_buf:
            aliases[y] = clean(m_buf.group(1))
        else:
            raise SystemExit(f"ERROR: unrecognized assign expression: assign {y} = {expr};")

    if not ops and not aliases:
        raise SystemExit("ERROR: no gates found in netlist — is this a NAND-only netlist?")
    return ops, aliases


def resolve(name, aliases, seen=None):
    """Follow BUF alias chains to the underlying net name."""
    seen = seen or set()
    while name in aliases:
        if name in seen:
            raise SystemExit(f"ERROR: alias cycle at net {name}")
        seen.add(name)
        name = aliases[name]
    return name


def evaluate(ops, aliases, values):
    """Evaluate the netlist for one input assignment dict (fixed-point)."""
    sig = dict(values)
    # Resolve aliases on input names first.
    pending = list(ops)
    progress = True
    while pending and progress:
        progress = False
        remaining = []
        for kind, a, b, y in pending:
            a = resolve(a, aliases)
            b = resolve(b, aliases) if b is not None else None
            if a in sig and (b is None or b in sig):
                if kind == "nand":
                    sig[resolve(y, aliases)] = not (sig[a] and sig[b])
                else:  # not
                    sig[resolve(y, aliases)] = not sig[a]
                progress = True
            else:
                remaining.append((kind, a, b, y))
        pending = remaining
    if pending:
        raise SystemExit(f"ERROR: could not resolve gates (missing nets): {pending}")
    out = resolve(OUTPUT, aliases)
    if out not in sig:
        raise SystemExit(f"ERROR: output net {OUTPUT} never driven")
    return sig[out]


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "release_logic_netlist.v"
    ops, aliases = parse_netlist(path.read_text())
    n_nand = sum(1 for k, _, _, _ in ops if k == "nand")
    n_not = sum(1 for k, _, _, _ in ops if k == "not")
    print(f"netlist: {path} — {n_nand} NAND + {n_not} NOT (+ {len(aliases)} wire aliases) = "
          f"{n_nand + n_not} NAND-equivalent gates")

    errors = 0
    for i in range(16):
        vals = {
            "done": bool((i >> 3) & 1),
            "approved": bool((i >> 2) & 1),
            "timeout": bool((i >> 1) & 1),
            "disputed": bool(i & 1),
        }
        expected = vals["done"] and (vals["approved"] or vals["timeout"]) and not vals["disputed"]
        got = evaluate(ops, aliases, vals)
        status = "PASS" if got == expected else "FAIL"
        if got != expected:
            errors += 1
        print(
            f"{status} i={i:2d} done={int(vals['done'])} approved={int(vals['approved'])} "
            f"timeout={int(vals['timeout'])} disputed={int(vals['disputed'])} -> {int(got)} (expected {int(expected)})"
        )

    if errors == 0:
        print("ALL 16 COMBINATIONS PASS")
        return 0
    print(f"FAILURES: {errors} / 16")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
