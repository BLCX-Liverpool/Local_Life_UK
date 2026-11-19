#!/usr/bin/env python3
import argparse
import html
import json
from datetime import datetime
from pathlib import Path


COLORS = {
    "baseline": "#64748b",
    "optimized": "#2563eb",
    "caffeine": "#2563eb",
    "redis": "#7c3aed",
    "mysql": "#ea580c",
    "grid": "#e2e8f0",
    "text": "#334155",
    "muted": "#64748b",
}


def number(value, digits=2, suffix=""):
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "是" if value else "否"
    formatted = f"{float(value):.{digits}f}"
    if "." in formatted:
        formatted = formatted.rstrip("0").rstrip(".")
    return f"{formatted}{suffix}"


def safe(value):
    return html.escape(str(value), quote=True)


def mode_value(tier, mode, key, default=0):
    return tier.get("modes", {}).get(mode, {}).get(key, default)


def horizontal_compare_chart(tiers, key, title, unit="ms"):
    rows = []
    maximum = 0.0
    for name, tier in tiers.items():
        a = float(mode_value(tier, "A", key, 0) or 0)
        b = float(mode_value(tier, "B", key, 0) or 0)
        maximum = max(maximum, a, b)
        rows.append((name, tier.get("target_rps"), a, b))
    maximum = maximum or 1.0
    width = 920
    left = 110
    right = 90
    chart_width = width - left - right
    row_height = 68
    height = 50 + row_height * len(rows)
    parts = [
        f'<svg class="chart" viewBox="0 0 {width} {height}" role="img" '
        f'aria-label="{safe(title)}，灰色为无缓存，蓝色为Caffeine加Redis">',
        f"<title>{safe(title)}</title>",
        f'<text x="0" y="18" class="chart-title">{safe(title)}</text>',
    ]
    for index, (name, target, baseline, optimized) in enumerate(rows):
        y = 45 + index * row_height
        parts.append(
            f'<text x="0" y="{y + 21}" class="axis-label">{safe(name)} · {safe(target)} RPS</text>'
        )
        for offset, value, color, label in (
            (0, baseline, COLORS["baseline"], "A"),
            (24, optimized, COLORS["optimized"], "B"),
        ):
            bar_width = max(1.5, value / maximum * chart_width)
            bar_y = y + offset
            parts.append(
                f'<text x="{left - 22}" y="{bar_y + 11}" class="series-label">{label}</text>'
            )
            parts.append(
                f'<rect x="{left}" y="{bar_y}" width="{bar_width:.2f}" height="14" '
                f'rx="4" fill="{color}"><title>{label}: {number(value, 2, unit)}</title></rect>'
            )
            value_x = min(left + bar_width + 8, width - right + 5)
            parts.append(
                f'<text x="{value_x:.2f}" y="{bar_y + 11}" class="value-label">{number(value, 2, unit)}</text>'
            )
    parts.append("</svg>")
    return "".join(parts)


def qps_chart(tiers):
    rows = []
    maximum = 0.0
    for name, tier in tiers.items():
        baseline_mysql = float(mode_value(tier, "A", "median_mysql_qps", 0) or 0)
        caffeine = float(mode_value(tier, "B", "median_caffeine_hit_qps", 0) or 0)
        redis = float(mode_value(tier, "B", "median_redis_hit_qps", 0) or 0)
        optimized_mysql = float(mode_value(tier, "B", "median_mysql_qps", 0) or 0)
        maximum = max(maximum, baseline_mysql, caffeine + redis + optimized_mysql)
        rows.append((name, tier.get("target_rps"), baseline_mysql, caffeine, redis, optimized_mysql))
    maximum = maximum or 1.0
    width = 920
    left = 110
    right = 90
    chart_width = width - left - right
    row_height = 68
    height = 78 + row_height * len(rows)
    parts = [
        f'<svg class="chart" viewBox="0 0 {width} {height}" role="img" '
        'aria-label="请求每秒处理层级，A组为MySQL，B组分为Caffeine、Redis和MySQL">',
        "<title>请求处理层级 QPS</title>",
        '<text x="0" y="18" class="chart-title">请求处理层级 QPS</text>',
        f'<rect x="{left}" y="30" width="12" height="12" rx="3" fill="{COLORS["caffeine"]}"/>',
        f'<text x="{left + 18}" y="40" class="legend-label">Caffeine</text>',
        f'<rect x="{left + 110}" y="30" width="12" height="12" rx="3" fill="{COLORS["redis"]}"/>',
        f'<text x="{left + 128}" y="40" class="legend-label">Redis</text>',
        f'<rect x="{left + 200}" y="30" width="12" height="12" rx="3" fill="{COLORS["mysql"]}"/>',
        f'<text x="{left + 218}" y="40" class="legend-label">MySQL</text>',
    ]
    for index, (name, target, baseline_mysql, caffeine, redis, optimized_mysql) in enumerate(rows):
        y = 58 + index * row_height
        parts.append(
            f'<text x="0" y="{y + 21}" class="axis-label">{safe(name)} · {safe(target)} RPS</text>'
        )
        baseline_width = baseline_mysql / maximum * chart_width
        parts.append(f'<text x="{left - 22}" y="{y + 11}" class="series-label">A</text>')
        parts.append(
            f'<rect x="{left}" y="{y}" width="{max(1.5, baseline_width):.2f}" height="14" '
            f'rx="4" fill="{COLORS["mysql"]}"><title>MySQL: {number(baseline_mysql, 2)} QPS</title></rect>'
        )
        parts.append(
            f'<text x="{min(left + baseline_width + 8, width - right + 5):.2f}" y="{y + 11}" '
            f'class="value-label">{number(baseline_mysql, 2)}</text>'
        )
        parts.append(f'<text x="{left - 22}" y="{y + 35}" class="series-label">B</text>')
        x = left
        total = caffeine + redis + optimized_mysql
        for value, color, label in (
            (caffeine, COLORS["caffeine"], "Caffeine"),
            (redis, COLORS["redis"], "Redis"),
            (optimized_mysql, COLORS["mysql"], "MySQL"),
        ):
            if value <= 0:
                continue
            segment_width = value / maximum * chart_width
            parts.append(
                f'<rect x="{x:.2f}" y="{y + 24}" width="{max(1.5, segment_width):.2f}" height="14" '
                f'fill="{color}"><title>{label}: {number(value, 2)} QPS</title></rect>'
            )
            x += segment_width
        parts.append(
            f'<text x="{min(left + total / maximum * chart_width + 8, width - right + 5):.2f}" '
            f'y="{y + 35}" class="value-label">{number(total, 2)}</text>'
        )
    parts.append("</svg>")
    return "".join(parts)


def summary_card(label, value, note=""):
    return (
        '<div class="summary-card">'
        f'<div class="summary-label">{safe(label)}</div>'
        f'<div class="summary-value">{safe(value)}</div>'
        f'<div class="summary-note">{safe(note)}</div>'
        "</div>"
    )


def build_report(data, source_name):
    tiers = data.get("tiers", {})
    capacity = data.get("capacity", {})
    valid = bool(data.get("experiment_valid"))
    failures = data.get("failures", [])
    status_text = "实验有效" if valid else "存在无效负载档位"
    status_class = "status-ok" if valid else "status-warning"

    cards = "".join(
        (
            summary_card(
                "基线最高完整通过",
                f'{number(capacity.get("baseline_max_passing_rps"), 0)} RPS',
                "A：业务缓存关闭",
            ),
            summary_card(
                "缓存方案最高完整通过",
                f'{number(capacity.get("caffeine_redis_max_passing_rps"), 0)} RPS',
                "B：Caffeine + Redis",
            ),
            summary_card(
                "已验证档位差",
                number(capacity.get("capacity_improvement_percent"), 2, "%"),
                "无效档位存在时仅供参考",
            ),
            summary_card(
                "测试上限",
                f'{number(capacity.get("tested_ceiling_rps"), 0)} RPS',
                "容量上限不等于测试上限",
            ),
        )
    )

    failure_html = ""
    if failures:
        failure_items = "".join(f"<li>{safe(item)}</li>" for item in failures)
        failure_html = (
            '<section class="alert">'
            "<strong>严格结论限制</strong>"
            f"<ul>{failure_items}</ul>"
            "<p>C5中不可比的百分比只能作为观察性数据，不能用于严格同负载结论。</p>"
            "</section>"
        )

    detail_rows = []
    improvement_rows = []
    for tier_name, tier in tiers.items():
        target = tier.get("target_rps")
        comparison = tier.get("comparison") or {}
        comparable = comparison.get("comparable_at_target_rps", False)
        improvement_rows.append(
            "<tr>"
            f"<td>{safe(tier_name)}</td><td>{number(target, 0)}</td>"
            f'<td class="numeric">{number(comparison.get("p50_reduction_percent"), 2, "%")}</td>'
            f'<td class="numeric">{number(comparison.get("p95_reduction_percent"), 2, "%")}</td>'
            f'<td class="numeric">{number(comparison.get("p99_reduction_percent"), 2, "%")}</td>'
            f'<td class="numeric">{number(comparison.get("mysql_load_reduction_percent"), 2, "%")}</td>'
            f'<td><span class="pill {"pill-ok" if comparable else "pill-warning"}">'
            f'{"可比" if comparable else "观察性"}</span></td>'
            "</tr>"
        )
        for mode, mode_label in (("A", "无缓存"), ("B", "Caffeine + Redis")):
            values = tier.get("modes", {}).get(mode, {})
            detail_rows.append(
                "<tr>"
                f"<td>{safe(tier_name)}</td><td>{number(target, 0)}</td><td>{safe(mode)} · {safe(mode_label)}</td>"
                f'<td class="numeric">{number(values.get("median_rps"), 3)}</td>'
                f'<td class="numeric">{number(values.get("max_peak_to_target_ratio"), 3)}×</td>'
                f'<td class="numeric">{number(values.get("median_p50_ms"), 2)}</td>'
                f'<td class="numeric">{number(values.get("median_p95_ms"), 2)}</td>'
                f'<td class="numeric">{number(values.get("median_p99_ms"), 2)}</td>'
                f'<td class="numeric">{number(values.get("median_caffeine_hit_qps"), 3)}</td>'
                f'<td class="numeric">{number(values.get("median_redis_hit_qps"), 3)}</td>'
                f'<td class="numeric">{number(values.get("median_mysql_qps"), 3)}</td>'
                f'<td><span class="pill {"pill-ok" if values.get("sla_passed") else "pill-warning"}">'
                f'{"通过" if values.get("sla_passed") else "未通过"}</span></td>'
                "</tr>"
            )

    generated = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>缓存A/B压测统一报告</title>
  <style>
    :root {{ color-scheme: light; --bg:#f8fafc; --surface:#ffffff; --text:#0f172a; --muted:#64748b; --line:#e2e8f0; --blue:#2563eb; --orange:#ea580c; --purple:#7c3aed; --green:#15803d; --amber:#b45309; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; background:var(--bg); color:var(--text); font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif; }}
    main {{ max-width:1180px; margin:0 auto; padding:28px 20px 48px; }}
    h1,h2 {{ margin:0; font-weight:600; }}
    h1 {{ font-size:28px; }} h2 {{ font-size:19px; margin-bottom:14px; }}
    .header {{ display:flex; justify-content:space-between; align-items:flex-start; gap:20px; margin-bottom:22px; }}
    .subtitle {{ color:var(--muted); margin-top:5px; }}
    .status {{ padding:7px 12px; border-radius:999px; font-weight:600; white-space:nowrap; }}
    .status-ok {{ color:var(--green); background:#dcfce7; }} .status-warning {{ color:var(--amber); background:#fef3c7; }}
    .summary {{ display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:12px; margin-bottom:22px; }}
    .summary-card,.panel {{ background:var(--surface); border:1px solid var(--line); border-radius:12px; box-shadow:0 1px 2px rgba(15,23,42,.04); }}
    .summary-card {{ padding:16px; }} .summary-label,.summary-note {{ color:var(--muted); }}
    .summary-value {{ font-size:25px; font-weight:650; margin:4px 0 2px; font-variant-numeric:tabular-nums; }}
    .panel {{ padding:18px; margin-bottom:18px; }}
    .chart-grid {{ display:grid; grid-template-columns:1fr 1fr; gap:18px; }}
    .chart {{ display:block; width:100%; height:auto; overflow:visible; }}
    .chart-title {{ font-size:15px; font-weight:600; fill:{COLORS["text"]}; }}
    .axis-label,.legend-label,.series-label,.value-label {{ fill:{COLORS["muted"]}; font-size:12px; }}
    .series-label {{ font-weight:600; }} .value-label {{ font-variant-numeric:tabular-nums; }}
    .alert {{ border-left:4px solid var(--orange); background:#fff7ed; padding:14px 16px; margin-bottom:18px; border-radius:8px; }}
    .alert ul {{ margin:7px 0; padding-left:20px; }} .alert p {{ margin:0; color:#9a3412; }}
    .table-wrap {{ overflow-x:auto; }} table {{ width:100%; border-collapse:collapse; min-width:820px; }}
    th,td {{ padding:9px 10px; text-align:left; border-bottom:1px solid var(--line); white-space:nowrap; }}
    th {{ color:var(--muted); font-weight:600; background:#f8fafc; }} .numeric {{ text-align:right; font-variant-numeric:tabular-nums; }}
    .pill {{ display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; font-weight:600; }}
    .pill-ok {{ color:var(--green); background:#dcfce7; }} .pill-warning {{ color:var(--amber); background:#fef3c7; }}
    footer {{ color:var(--muted); margin-top:18px; font-size:12px; }}
    @media (max-width:820px) {{ .summary,.chart-grid {{ grid-template-columns:1fr 1fr; }} .header {{ flex-direction:column; }} }}
    @media (max-width:560px) {{ main {{ padding:18px 12px 36px; }} .summary,.chart-grid {{ grid-template-columns:1fr; }} h1 {{ font-size:23px; }} }}
    @media print {{ body {{ background:white; }} main {{ max-width:none; padding:0; }} .panel,.summary-card {{ box-shadow:none; break-inside:avoid; }} }}
  </style>
</head>
<body>
<main>
  <header class="header">
    <div><h1>缓存 A/B 压测统一报告</h1><div class="subtitle">A：MySQL基线 · B：Caffeine + Redis · Memcached关闭</div></div>
    <div class="status {status_class}">{safe(status_text)}</div>
  </header>
  <section class="summary">{cards}</section>
  {failure_html}
  <section class="chart-grid">
    <div class="panel">{horizontal_compare_chart(tiers, "median_p95_ms", "P95延迟对比")}</div>
    <div class="panel">{horizontal_compare_chart(tiers, "median_p99_ms", "P99延迟对比")}</div>
  </section>
  <section class="panel">{qps_chart(tiers)}</section>
  <section class="panel">
    <h2>优化幅度</h2>
    <div class="table-wrap"><table>
      <thead><tr><th>档位</th><th>目标RPS</th><th class="numeric">P50降低</th><th class="numeric">P95降低</th><th class="numeric">P99降低</th><th class="numeric">MySQL回源降低</th><th>结论级别</th></tr></thead>
      <tbody>{''.join(improvement_rows)}</tbody>
    </table></div>
  </section>
  <section class="panel">
    <h2>完整指标</h2>
    <div class="table-wrap"><table>
      <thead><tr><th>档位</th><th>目标</th><th>模式</th><th class="numeric">实际RPS</th><th class="numeric">峰值比例</th><th class="numeric">P50 ms</th><th class="numeric">P95 ms</th><th class="numeric">P99 ms</th><th class="numeric">Caffeine QPS</th><th class="numeric">Redis QPS</th><th class="numeric">MySQL QPS</th><th>SLA</th></tr></thead>
      <tbody>{''.join(detail_rows)}</tbody>
    </table></div>
  </section>
  <footer>生成时间：{safe(generated)} · 数据源：{safe(source_name)} · 本报告为离线单文件，可直接归档或打印为PDF。</footer>
</main>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("verification", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = json.loads(args.verification.read_text(encoding="utf-8"))
    report = build_report(data, args.verification.name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report, encoding="utf-8")
    print(f"HTML report: {args.output}")


if __name__ == "__main__":
    main()
