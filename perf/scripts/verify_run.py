#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def check(condition, message, failures):
    if not condition:
        failures.append(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--users", type=int, required=True)
    parser.add_argument("--stock", type=int, required=True)
    parser.add_argument("--http", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    http = json.loads(args.http.read_text(encoding="utf-8"))
    state = json.loads(args.state.read_text(encoding="utf-8"))
    failures = []

    boundary = args.scenario in {"L4B", "LIMIT"}
    check(http["target_achievement_ratio"] >= 0.95, "achieved throughput is below 95%", failures)
    if args.scenario != "SMOKE":
        check(
            http["target_achievement_ratio"] <= 1.05,
            "achieved throughput is above 105%; load profile is invalid",
            failures,
        )
    check(
        http.get("peak_to_target_ratio", float("inf")) <= 1.5,
        "one-second arrival peak exceeds 150% of target RPS",
        failures,
    )
    check(http["timeouts"] == 0, "timeouts must be zero", failures)
    check(http["unexpected_5xx"] == 0, "unexpected HTTP 5xx must be zero", failures)
    check(http["p95_ms"] <= 200, "P95 exceeds 200ms", failures)
    check(http["p99_ms"] <= 500, "P99 exceeds 500ms", failures)
    if not boundary:
        check(http["rate_limited"] == 0, "normal capacity tiers must not be rate-limited", failures)

    check(state["initial_stock"] == args.stock, "initial stock differs from fixture", failures)
    check(
        state["initial_stock"] == state["database_remaining"] + state["successful_orders"],
        "database inventory reconciliation failed",
        failures,
    )
    check(state["database_remaining"] >= 0, "database inventory is negative", failures)
    check(state["redis_remaining"] >= 0, "Redis inventory is negative", failures)
    check(
        state["database_remaining"] - state["redis_remaining"] - state["unresolved_reservations"] == 0,
        "Redis inventory difference is not zero",
        failures,
    )
    for key in (
        "unresolved_reservations",
        "stream_lag",
        "stream_pending",
        "stream_review",
        "outbox_pending_or_inflight",
        "outbox_review",
        "rabbit_ready",
        "rabbit_unacked",
        "seckill_dead_letters",
        "message_failures",
        "one_user_multiple_order_violations",
        "failed_reservations",
        "review_reservations",
    ):
        check(float(state[key]) == 0, f"{key} must be zero", failures)

    if args.scenario == "STOCK":
        check(state["successful_orders"] == args.stock, "stock scenario must sell all stock", failures)
        check(
            http["inventory_exhausted"] == args.users - args.stock,
            "stock scenario inventory-exhausted count is incorrect",
            failures,
        )
    elif args.scenario == "DUPLICATE":
        check(state["successful_orders"] == args.users, "duplicate scenario must create one order per user", failures)
        check(http["duplicate_requests"] >= args.users, "duplicate requests were not observed", failures)
    elif boundary:
        check(
            state["successful_orders"] == http["unique_order_ids"],
            "boundary scenario final orders differ from unique admissions",
            failures,
        )
    else:
        check(state["successful_orders"] == args.users, "normal tier did not complete every user", failures)

    result = {
        "scenario": args.scenario,
        "passed": not failures,
        "failures": failures,
        "http": http,
        "state": state,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if not failures else 1)


if __name__ == "__main__":
    main()

