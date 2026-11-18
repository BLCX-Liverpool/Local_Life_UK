#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


LABEL_PATTERN = re.compile(r'(\w+)="((?:\\.|[^"\\])*)"')


def parse_cache_counters(path):
    counters = {}
    with path.open(encoding="utf-8") as stream:
        for raw_line in stream:
            line = raw_line.strip()
            if not line.startswith("hmdp_cache_requests_total{"):
                continue
            metric, value = line.rsplit(None, 1)
            labels_text = metric[metric.index("{") + 1 : metric.rindex("}")]
            labels = dict(LABEL_PATTERN.findall(labels_text))
            layer = labels.get("layer")
            result = labels.get("result")
            if layer and result:
                counters[(layer, result)] = float(value)
    return counters


def delta(before, after, layer, result):
    return max(0.0, after.get((layer, result), 0.0) - before.get((layer, result), 0.0))


def ratio(numerator, denominator):
    if denominator <= 0:
        return 0.0
    return numerator / denominator


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    before = parse_cache_counters(args.before)
    after = parse_cache_counters(args.after)
    scope_hits = delta(before, after, "scope", "hit")
    caffeine_hits = delta(before, after, "jvm", "hit")
    caffeine_misses = delta(before, after, "jvm", "miss")
    redis_hits = delta(before, after, "redis", "hit")
    redis_misses = delta(before, after, "redis", "miss")
    mysql_loads = delta(before, after, "mysql", "load")

    result = {
        "scope_hits": int(scope_hits),
        "caffeine_hits": int(caffeine_hits),
        "caffeine_misses": int(caffeine_misses),
        "caffeine_hit_ratio": round(ratio(caffeine_hits, caffeine_hits + caffeine_misses), 6),
        "redis_hits": int(redis_hits),
        "redis_misses": int(redis_misses),
        "redis_hit_ratio": round(ratio(redis_hits, redis_hits + redis_misses), 6),
        "mysql_loads": int(mysql_loads),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
