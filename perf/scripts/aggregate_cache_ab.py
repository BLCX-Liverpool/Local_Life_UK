#!/usr/bin/env python3
import argparse
import json
import statistics
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    grouped = {"A": [], "B": [], "C": []}
    for metadata_path in sorted(args.root.glob("*/metadata.json")):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        summary_path = metadata_path.parent / "http-summary.json"
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        grouped[metadata["mode"]].append(summary)

    failures = []
    modes = {}
    for mode, rows in grouped.items():
        if len(rows) != 5:
            failures.append(f"mode {mode} has {len(rows)} rounds instead of 5")
            continue
        modes[mode] = {
            "rounds": 5,
            "median_rps": statistics.median(row["achieved_rps"] for row in rows),
            "median_p50_ms": statistics.median(row["p50_ms"] for row in rows),
            "median_p95_ms": statistics.median(row["p95_ms"] for row in rows),
            "median_p99_ms": statistics.median(row["p99_ms"] for row in rows),
            "timeouts": sum(row["timeouts"] for row in rows),
            "unexpected_5xx": sum(row["unexpected_5xx"] for row in rows),
        }
        if modes[mode]["timeouts"] != 0:
            failures.append(f"mode {mode} has timeouts")
        if modes[mode]["unexpected_5xx"] != 0:
            failures.append(f"mode {mode} has unexpected HTTP 5xx")

    if "B" in modes and "C" in modes:
        b_to_c = modes["B"]["median_p95_ms"] / max(0.001, modes["C"]["median_p95_ms"])
        if b_to_c > 1.10:
            failures.append("Caffeine+Redis P95 regressed by more than 10% versus Memcached enabled")
    else:
        b_to_c = None

    result = {
        "passed": not failures,
        "modes": modes,
        "b_p95_to_c_p95_ratio": b_to_c,
        "failures": failures,
        "decision": (
            "Memcached can proceed to a separate removal review"
            if not failures
            else "Keep Memcached enabled"
        ),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if not failures else 1)


if __name__ == "__main__":
    main()

