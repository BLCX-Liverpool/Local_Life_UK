#!/usr/bin/env python3
import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path


TIER_ORDER = ("C1", "C2", "C3", "C4", "C5")
MODES = ("A", "B")
EXPECTED_ROUNDS = 5


def median(rows, key):
    return statistics.median(row[key] for row in rows)


def reduction_percent(baseline, optimized):
    if baseline <= 0:
        return None
    return round((baseline - optimized) / baseline * 100.0, 2)


def aggregate_mode(entries):
    summaries = [entry["summary"] for entry in entries]
    metrics = [entry["metrics"] for entry in entries]
    samples = [summary["samples"] for summary in summaries]
    mysql_load_ratios = [
        metric["mysql_loads"] / max(1, sample)
        for metric, sample in zip(metrics, samples)
    ]
    load_profile_passed = all(
        0.95 <= summary["target_achievement_ratio"] <= 1.05
        for summary in summaries
    )
    sla_failures = []
    if any(summary["target_achievement_ratio"] < 0.95 for summary in summaries):
        sla_failures.append("at least one round achieved less than 95% of target RPS")
    if any(summary["target_achievement_ratio"] > 1.05 for summary in summaries):
        sla_failures.append("at least one round exceeded 105% of target RPS")
    if any(summary["p95_ms"] > 200 for summary in summaries):
        sla_failures.append("at least one round exceeded P95 200ms")
    if any(summary["p99_ms"] > 500 for summary in summaries):
        sla_failures.append("at least one round exceeded P99 500ms")
    if sum(summary["timeouts"] for summary in summaries):
        sla_failures.append("timeouts were observed")
    if sum(summary["unexpected_5xx"] for summary in summaries):
        sla_failures.append("unexpected HTTP 5xx responses were observed")
    if sum(summary["other_business_failures"] for summary in summaries):
        sla_failures.append("business failures were observed")

    return {
        "rounds": len(entries),
        "load_profile_passed": load_profile_passed,
        "sla_passed": not sla_failures,
        "sla_failures": sla_failures,
        "median_rps": round(median(summaries, "achieved_rps"), 3),
        "median_p50_ms": median(summaries, "p50_ms"),
        "median_p95_ms": median(summaries, "p95_ms"),
        "median_p99_ms": median(summaries, "p99_ms"),
        "timeouts": sum(summary["timeouts"] for summary in summaries),
        "unexpected_5xx": sum(summary["unexpected_5xx"] for summary in summaries),
        "business_failures": sum(
            summary["other_business_failures"] for summary in summaries
        ),
        "median_caffeine_hits": median(metrics, "caffeine_hits"),
        "median_caffeine_hit_ratio": round(median(metrics, "caffeine_hit_ratio"), 6),
        "median_redis_hits": median(metrics, "redis_hits"),
        "median_redis_hit_ratio": round(median(metrics, "redis_hit_ratio"), 6),
        "median_mysql_loads": median(metrics, "mysql_loads"),
        "median_mysql_load_ratio": round(statistics.median(mysql_load_ratios), 6),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    grouped = defaultdict(lambda: defaultdict(list))
    failures = []
    for metadata_path in sorted(args.root.glob("*/metadata.json")):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        tier = metadata.get("tier")
        mode = metadata.get("mode")
        if tier not in TIER_ORDER or mode not in MODES:
            failures.append(f"unexpected cache result group: tier={tier}, mode={mode}")
            continue
        if metadata.get("memcache_enabled") is not False:
            failures.append(f"{tier}-{mode} unexpectedly enabled Memcached")
        summary_path = metadata_path.parent / "http-summary.json"
        metrics_path = metadata_path.parent / "cache-metrics.json"
        if not summary_path.exists() or not metrics_path.exists():
            failures.append(f"{metadata_path.parent.name} is missing summary or cache metrics")
            continue
        grouped[tier][mode].append({
            "metadata": metadata,
            "summary": json.loads(summary_path.read_text(encoding="utf-8")),
            "metrics": json.loads(metrics_path.read_text(encoding="utf-8")),
        })

    tiers = {}
    passing_capacity = {"A": [], "B": []}
    for tier in TIER_ORDER:
        if tier not in grouped:
            continue
        target_values = {
            entry["metadata"]["target_rps"]
            for mode_entries in grouped[tier].values()
            for entry in mode_entries
        }
        if len(target_values) != 1:
            failures.append(f"{tier} has inconsistent target RPS values")
            continue
        target_rps = target_values.pop()
        modes = {}
        for mode in MODES:
            entries = grouped[tier].get(mode, [])
            if len(entries) != EXPECTED_ROUNDS:
                failures.append(
                    f"{tier}-{mode} has {len(entries)} rounds instead of {EXPECTED_ROUNDS}"
                )
                continue
            modes[mode] = aggregate_mode(entries)
            if modes[mode]["sla_passed"]:
                passing_capacity[mode].append(target_rps)

        comparison = None
        if all(mode in modes for mode in MODES):
            baseline = modes["A"]
            optimized = modes["B"]
            if baseline["median_caffeine_hits"] or baseline["median_redis_hits"]:
                failures.append(f"{tier}-A recorded cache hits while cache was disabled")
            if baseline["median_mysql_load_ratio"] < 0.95:
                failures.append(f"{tier}-A did not route at least 95% of reads to MySQL")
            if not (optimized["median_caffeine_hits"] or optimized["median_redis_hits"]):
                failures.append(f"{tier}-B did not record Caffeine or Redis hits")
            comparison = {
                "comparable_at_target_rps": (
                    baseline["load_profile_passed"]
                    and optimized["load_profile_passed"]
                ),
                "p50_reduction_percent": reduction_percent(
                    baseline["median_p50_ms"], optimized["median_p50_ms"]
                ),
                "p95_reduction_percent": reduction_percent(
                    baseline["median_p95_ms"], optimized["median_p95_ms"]
                ),
                "p99_reduction_percent": reduction_percent(
                    baseline["median_p99_ms"], optimized["median_p99_ms"]
                ),
                "mysql_load_reduction_percent": reduction_percent(
                    baseline["median_mysql_loads"], optimized["median_mysql_loads"]
                ),
            }
        tiers[tier] = {
            "target_rps": target_rps,
            "modes": modes,
            "comparison": comparison,
        }

    if not tiers:
        failures.append("no cache A/B results were found")

    baseline_capacity = max(passing_capacity["A"], default=None)
    optimized_capacity = max(passing_capacity["B"], default=None)
    if baseline_capacity and optimized_capacity:
        capacity_improvement = round(
            (optimized_capacity / baseline_capacity - 1.0) * 100.0, 2
        )
    else:
        capacity_improvement = None
    tested_ceiling = max(
        (tier["target_rps"] for tier in tiers.values()),
        default=None,
    )

    result = {
        "experiment_valid": not failures,
        "configuration": {
            "A": "business cache disabled; MySQL baseline",
            "B": "Caffeine + Redis; Memcached disabled",
            "rounds_per_mode": EXPECTED_ROUNDS,
        },
        "tiers": tiers,
        "capacity": {
            "baseline_max_passing_rps": baseline_capacity,
            "caffeine_redis_max_passing_rps": optimized_capacity,
            "capacity_improvement_percent": capacity_improvement,
            "tested_ceiling_rps": tested_ceiling,
            "baseline_reached_test_ceiling": baseline_capacity == tested_ceiling,
            "caffeine_redis_reached_test_ceiling": optimized_capacity == tested_ceiling,
        },
        "failures": failures,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if not failures else 1)


if __name__ == "__main__":
    main()
