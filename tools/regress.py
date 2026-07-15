#!/usr/bin/env python3
"""Replay regression runner: pin a cart's replay outputs, detect drift.

A case file describes one deterministic replay run and the artifacts it
must reproduce byte-for-byte:

    # kit_demo.case
    rom     test/kit_demo.gba
    replay  test/scripts/kit-demo.replay
    frames  300
    expect  bin/kitdemo_play.png     3f7a...c9   # sha256
    expect  bin/kitdemo_stamped.png  91d0...4e

Semantics:
  - The ROM's .sav sidecar is DELETED before the run: determinism
    includes save state, so every case starts from a cold cart.
  - The emulator runs headless with the given replay; each `expect`
    line names an output the replay produces (screenshot / dump-state
    paths inside the replay script) plus its pinned sha256.
  - Exit 0 when every hash matches, 1 on any mismatch or missing file.

Modes:
    python tools/regress.py case1.case [case2.case ...]     # verify
    python tools/regress.py --update case1.case             # (re)pin hashes

--update runs the case, hashes whatever the replay produced, and
rewrites the expect lines in place — review the diff before committing
a re-pin: an unexplained hash change IS the regression.

Requires bin/gbarun.exe (tools/build-host.ps1); run from the repo root.
"""

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

GBARUN = Path("bin/gbarun.exe")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def parse_case(path: Path) -> dict:
    case = {"rom": None, "replay": None, "frames": 600, "expect": []}
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        key = parts[0]
        if key == "rom":
            case["rom"] = Path(parts[1])
        elif key == "replay":
            case["replay"] = Path(parts[1])
        elif key == "frames":
            case["frames"] = int(parts[1])
        elif key == "expect":
            case["expect"].append((Path(parts[1]), parts[2] if len(parts) > 2 else None))
        else:
            raise SystemExit(f"{path}:{lineno}: unknown directive '{key}'")
    if not case["rom"]:
        raise SystemExit(f"{path}: no rom line")
    if not case["expect"]:
        raise SystemExit(f"{path}: no expect lines")
    return case


def run_case(case: dict) -> None:
    rom = case["rom"]
    if not rom.exists():
        raise SystemExit(f"rom not found: {rom} (build it first)")
    sav = rom.with_suffix(".sav")
    if sav.exists():
        sav.unlink()
    for out_path, _ in case["expect"]:
        if out_path.exists():
            out_path.unlink()

    argv = [str(GBARUN), "--rom", str(rom), "--headless",
            "--frames", str(case["frames"])]
    if case["replay"]:
        argv += ["--replay", str(case["replay"])]
    r = subprocess.run(argv, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"emulator exit {r.returncode} for {rom}:\n{r.stdout[-2000:]}")


def verify(path: Path) -> bool:
    case = parse_case(path)
    run_case(case)
    ok = True
    for out_path, want in case["expect"]:
        if not out_path.exists():
            print(f"  MISS  {out_path} (not produced)")
            ok = False
            continue
        got = sha256(out_path)
        if want is None:
            print(f"  UNPINNED  {out_path} {got[:16]}... (run --update)")
            ok = False
        elif got == want:
            print(f"  OK    {out_path}")
        else:
            print(f"  DRIFT {out_path}\n        pinned {want}\n        got    {got}")
            ok = False
    return ok


def update(path: Path) -> None:
    case = parse_case(path)
    run_case(case)
    hashes = {}
    for out_path, _ in case["expect"]:
        if not out_path.exists():
            raise SystemExit(f"{out_path} not produced; cannot pin")
        hashes[out_path.as_posix()] = sha256(out_path)

    lines = []
    for raw in path.read_text().splitlines():
        stripped = raw.split("#", 1)[0].strip()
        if stripped.startswith("expect"):
            target = stripped.split()[1]
            comment = raw.split("#", 1)[1] if "#" in raw else None
            new = f"expect  {target}  {hashes[Path(target).as_posix()]}"
            if comment:
                new += f"  #{comment}"
            lines.append(new)
        else:
            lines.append(raw)
    path.write_text("\n".join(lines) + "\n", newline="\n")
    for t, h in hashes.items():
        print(f"  PINNED {t} {h[:16]}...")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("cases", nargs="+", type=Path)
    ap.add_argument("--update", action="store_true",
                    help="run and (re)pin the expect hashes in place")
    args = ap.parse_args()

    if not GBARUN.exists():
        raise SystemExit("bin/gbarun.exe not found; run tools/build-host.ps1 (and run from the repo root)")

    failed = []
    for c in args.cases:
        print(f"--- {c} ---")
        if args.update:
            update(c)
        elif not verify(c):
            failed.append(str(c))
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        sys.exit(1)
    if not args.update:
        print(f"OK: {len(args.cases)} case(s) green")


if __name__ == "__main__":
    main()
