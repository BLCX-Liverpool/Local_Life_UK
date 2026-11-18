#!/usr/bin/env python3
import argparse
import csv
import json
import math
from collections import Counter
from pathlib import Path


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return float(ordered[index])


def truthy(value):
    return str(value).strip().lower() == "true"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("jtl", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--target-rps", type=float, required=True)
    parser.add_argument("--planned-duration-seconds", type=float)
    parser.add_argument("--buckets-output", type=Path)
    parser.add_argument("--mode", choices=("seckill", "cache"), default="seckill")
    args = parser.parse_args()

    rows = []
    with args.jtl.open(newline="", encoding="utf-8") as stream:
        rows.extend(csv.DictReader(stream))
    if not rows:
        raise SystemExit("JTL file contains no samples")

    elapsed = [float(row.get("elapsed") or 0) for row in rows]
    timestamps = [int(row.get("timeStamp") or 0) for row in rows]
    ended = [stamp + int(float(row.get("elapsed") or 0)) for stamp, row in zip(timestamps, rows)]
    completion_span_seconds = max(0.001, (max(ended) - min(timestamps)) / 1000.0)
    arrival_span_seconds = max(0.001, (max(timestamps) - min(timestamps)) / 1000.0)
    codes = Counter((row.get("responseCode") or "unknown") for row in rows)

    timeouts = 0
    unexpected_5xx = 0
    business_accepted = 0
    inventory_exhausted = 0
    rate_limited = 0
    other_business_failures = 0
    successful_users = set()
    successful_order_ids = set()
    successful_rows_by_user = Counter()

    for row in rows:
        code = row.get("responseCode") or ""
        failure = (row.get("failureMessage") or "").lower()
        response = (row.get("responseMessage") or "").lower()
        error = row.get("business_error") or ""
        if "timeout" in failure or "timeout" in response or not code.isdigit():
            timeouts += 1
        if code.isdigit() and 500 <= int(code) <= 599:
            unexpected_5xx += 1
        if code == "429":
            rate_limited += 1
            continue
        if truthy(row.get("business_success")):
            business_accepted += 1
            user_id = (row.get("user_id") or "").strip()
            order_id = (row.get("business_data") or "").strip()
            if user_id:
                successful_users.add(user_id)
                successful_rows_by_user[user_id] += 1
            if order_id:
                successful_order_ids.add(order_id)
        elif "库存不足" in error:
            inventory_exhausted += 1
        elif code == "200":
            other_business_failures += 1

    duplicate_requests = sum(max(0, count - 1) for count in successful_rows_by_user.values())
    observed_active_window_rps = (
        (len(rows) - 1) / arrival_span_seconds
        if len(rows) > 1
        else len(rows) / completion_span_seconds
    )
    if args.planned_duration_seconds is not None:
        planned_duration_seconds = max(0.001, args.planned_duration_seconds)
        # A Poisson schedule normally leaves an idle gap before its first and
        # after its last arrival. Do not mistake that shorter active span for
        # throughput above the configured rate. If arrivals run late, retain
        # the longer observed span so generator saturation is still visible.
        load_window_seconds = max(planned_duration_seconds, arrival_span_seconds)
        achieved_rps = len(rows) / load_window_seconds
        completion_window_seconds = max(planned_duration_seconds, completion_span_seconds)
    else:
        planned_duration_seconds = None
        load_window_seconds = arrival_span_seconds
        achieved_rps = observed_active_window_rps
        completion_window_seconds = completion_span_seconds
    observed_active_window_completed_rps = len(rows) / completion_span_seconds
    completed_rps = len(rows) / completion_window_seconds
    summary = {
        "samples": len(rows),
        "duration_seconds": round(completion_span_seconds, 3),
        "arrival_span_seconds": round(arrival_span_seconds, 3),
        "planned_duration_seconds": (
            round(planned_duration_seconds, 3)
            if planned_duration_seconds is not None
            else None
        ),
        "load_window_seconds": round(load_window_seconds, 3),
        "completion_window_seconds": round(completion_window_seconds, 3),
        "target_rps": args.target_rps,
        "achieved_rps": round(achieved_rps, 3),
        "observed_active_window_rps": round(observed_active_window_rps, 3),
        "completed_rps": round(completed_rps, 3),
        "observed_active_window_completed_rps": round(observed_active_window_completed_rps, 3),
        "target_achievement_ratio": round(achieved_rps / args.target_rps, 4),
        "p50_ms": percentile(elapsed, 0.50),
        "p95_ms": percentile(elapsed, 0.95),
        "p99_ms": percentile(elapsed, 0.99),
        "timeouts": timeouts,
        "timeout_rate": round(timeouts / len(rows), 6),
        "unexpected_5xx": unexpected_5xx,
        "http_codes": dict(sorted(codes.items())),
        "business_accepted_responses": business_accepted,
        "other_business_failures": other_business_failures,
    }
    if args.mode == "seckill":
        summary.update({
            "unique_successful_users": len(successful_users),
            "unique_order_ids": len(successful_order_ids),
            "inventory_exhausted": inventory_exhausted,
            "duplicate_requests": duplicate_requests,
            "rate_limited": rate_limited,
        })
    if args.buckets_output:
        first_timestamp = min(timestamps)
        buckets = {}
        for timestamp, latency in zip(timestamps, elapsed):
            second = (timestamp - first_timestamp) // 1000
            buckets.setdefault(second, []).append(latency)
        args.buckets_output.parent.mkdir(parents=True, exist_ok=True)
        with args.buckets_output.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow(("second", "samples", "p50_ms", "p95_ms", "max_ms", "slow_ge_500ms"))
            for second, latencies in sorted(buckets.items()):
                writer.writerow((
                    second,
                    len(latencies),
                    percentile(latencies, 0.50),
                    percentile(latencies, 0.95),
                    max(latencies),
                    sum(latency >= 500 for latency in latencies),
                ))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

