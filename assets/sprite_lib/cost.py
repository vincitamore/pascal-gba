"""sprite_lib.cost -- append-only USD-ticks ledger.

One JSON line per generation call. `cost_in_usd_ticks` is what the xAI Imagine
API returns natively (1 tick = 1e-9 USD, so a $0.20 call = 200_000_000 ticks).
Storing the raw int avoids float drift and matches the API's wire format.
"""
from __future__ import annotations
import json
import time
from pathlib import Path
from typing import Iterable

# API-native tick scale: response 200_000_000 ticks = $0.20.
USD_PER_TICK = 1e-9


# Resolved at call time relative to cwd. Run the CLI from your asset root
# so this lands where the consumer expects. Override per-call via the
# `ledger` kwarg or CLI `--ledger`.
def _default_ledger() -> Path:
    return Path.cwd() / "ledger.jsonl"


def append(entry: dict, ledger: Path | None = None) -> Path:
    """Append a single JSONL entry. Fills 'ts' if missing. Returns the ledger path."""
    p = Path(ledger) if ledger else _default_ledger()
    p.parent.mkdir(parents=True, exist_ok=True)
    entry = dict(entry)
    entry.setdefault("schema", "v1")
    entry.setdefault("ts", time.time())
    with open(p, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, sort_keys=False) + "\n")
    return p


def read_all(ledger: Path | None = None) -> list[dict]:
    p = Path(ledger) if ledger else _default_ledger()
    if not p.exists():
        return []
    rows = []
    with open(p, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                # tolerate a single corrupt tail line
                pass
    return rows


def summarize(rows: Iterable[dict]) -> dict:
    """Aggregate calls + ticks by op. Returns:
       { total_calls, total_ticks, total_usd, by_op: { op: {calls, ticks, usd} } }
    """
    rows = list(rows)
    by_op: dict[str, dict] = {}
    total_ticks = 0
    for r in rows:
        op = r.get("op", "?")
        t = int(r.get("cost_in_usd_ticks") or r.get("cost_usd_ticks") or 0)
        slot = by_op.setdefault(op, {"calls": 0, "ticks": 0})
        slot["calls"] += 1
        slot["ticks"] += t
        total_ticks += t
    for slot in by_op.values():
        slot["usd"] = round(slot["ticks"] * USD_PER_TICK, 4)
    return {
        "total_calls": len(rows),
        "total_ticks": total_ticks,
        "total_usd": round(total_ticks * USD_PER_TICK, 4),
        "by_op": by_op,
    }
