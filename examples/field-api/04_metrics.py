#!/usr/bin/env python3
"""示例 4：运行指标（主机 / agent / 业务单元 / 中间件 / 数据面接入量）。

    python3 04_metrics.py                     # 概览 + 中间件 + 接入量
    python3 04_metrics.py --section overview
    python3 04_metrics.py --agent agent-host-xxxx --json

数据来自**本栈**的 VictoriaMetrics（数据面镜像写入），不是网关栈那份：
后者多了 `wparse_*` 引擎统计，两份互不聚合。
"""

import argparse
import json
import sys

from field_client import (
    FieldApiError,
    add_common_args,
    client_from_args,
    explain,
    require_auth,
)


def fmt(value, suffix=""):
    if value is None:
        return "—"
    if isinstance(value, float):
        return "%.2f%s" % (value, suffix)
    return "%s%s" % (value, suffix)


def scaled(value, unit):
    return None if value is None else value / unit


def show_overview(data: dict, only_agent: str = None) -> None:
    totals = data.get("totals") or {}
    source = (data.get("source") or {}).get("base_url")
    print("storage :", source)
    print("window  :", data.get("window_seconds"), "s")
    print("totals  :", json.dumps(totals, ensure_ascii=False))

    business = data.get("business") or []
    if business:
        print("\n业务单元（归属记账，来自 field-api.toml）：")
        print("  %-16s %-18s %5s %5s %6s %8s %9s %8s" % (
            "id", "name", "主机", "在报", "序列", "进程", "核数", "内存GB"
        ))
        for unit in business:
            print("  %-16s %-18s %5s %5s %6s %8s %9s %8s" % (
                unit.get("id"),
                unit.get("name"),
                unit.get("agents_present"),
                unit.get("agents_reporting"),
                unit.get("series"),
                fmt(unit.get("processes")),
                fmt(unit.get("cpu_cores")),
                fmt(scaled(unit.get("memory_total_bytes"), 1024 ** 3)),
            ))
            missing = unit.get("agents_missing") or []
            if missing:
                print("     缺数据的主机: %s" % ", ".join(missing))

    unassigned = data.get("unassigned_agents") or []
    if unassigned:
        print("\n未归类主机:", ", ".join(unassigned))

    agents = data.get("agents") or []
    if only_agent:
        agents = [a for a in agents if a.get("agent_id") == only_agent]
        if not agents:
            print("\n没有这个 agent：%s" % only_agent, file=sys.stderr)
    print("\nagent（%d）：" % len(agents))
    print("  %-30s %7s %6s %6s %7s %7s %7s %7s" % (
        "agent_id", "CPU%", "核", "样本", "内存MB", "负载", "磁盘%", "进程"
    ))
    for agent in agents:
        host = agent.get("host") or {}
        print("  %-30s %7s %6s %6s %7s %7s %7s %7s" % (
            agent.get("agent_id"),
            fmt(agent.get("cpu_percent")),
            fmt(agent.get("cpu_cores")),
            agent.get("samples"),
            fmt(scaled(agent.get("memory_bytes"), 1024 ** 2)),
            fmt(host.get("load_1m")),
            fmt(host.get("disk_usage_percent")),
            fmt(host.get("processes")),
        ))
        if agent.get("samples") == 0:
            # 这不是“没接入”：宿主事实在写，但 agent 自观测停了（链路断 / agent 挂）。
            print("     ↑ 采集静默：窗口内没有 agent_cpu_ratio 样本")

    catalog = data.get("catalog") or []
    if catalog:
        print("\n指标目录（按名字前缀）：")
        groups = {}
        for entry in catalog:
            group = entry.get("group") or "?"
            groups[group] = groups.get(group, 0) + int(entry.get("series") or 0)
        for group, series in sorted(groups.items()):
            print("  %-12s %d 条序列" % (group, series))


def show_middleware(data: dict) -> None:
    families = data.get("families") or []
    print("中间件家族（%d）：" % len(families))
    for family in families:
        metrics = family.get("metrics") or []
        print("  %-10s %-24s prefix=%-12s %d 条读数" % (
            family.get("kind"), family.get("label"),
            family.get("prefix"), len(metrics),
        ))
        for sample in metrics[:5]:
            labels = sample.get("labels") or {}
            label_text = ",".join("%s=%s" % (k, v) for k, v in labels.items())
            print("      %-38s %s  {%s}" % (
                sample.get("metric"), fmt(sample.get("value")), label_text
            ))
        if len(metrics) > 5:
            print("      ...（还有 %d 条，用 --json 看全量）" % (len(metrics) - 5))


def show_ingest(data: dict) -> None:
    print("数据面接入（window=%ss）：" % data.get("window_seconds"))
    for channel in data.get("channels") or []:
        print("  %-9s %-12s total=%-10s received=%-10s last_at=%s" % (
            channel.get("id"), channel.get("unit"),
            fmt(channel.get("total")),
            fmt(channel.get("received")),
            fmt(channel.get("last_at_ms")),
        ))
        if channel.get("note"):
            print("      note: %s" % channel["note"])


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-field：运行指标")
    add_common_args(parser)
    parser.add_argument(
        "--section", choices=("all", "overview", "middleware", "ingest"), default="all"
    )
    parser.add_argument("--agent", help="只看这个 agent_id")
    parser.add_argument("--json", action="store_true", help="打印原始 JSON")
    args = parser.parse_args()

    client = client_from_args(args)
    if not require_auth(client):
        return 2
    try:
        if args.section in ("all", "overview"):
            overview = client.metrics()
            if args.json:
                print(json.dumps(overview, ensure_ascii=False, indent=2))
            else:
                show_overview(overview, args.agent)
            if args.section == "all":
                print()

        if args.section in ("all", "middleware"):
            middleware = client.metrics_middleware()
            if args.json:
                print(json.dumps(middleware, ensure_ascii=False, indent=2))
            else:
                show_middleware(middleware)
            if args.section == "all":
                print()

        if args.section in ("all", "ingest"):
            # 0 = 只看累计，服务端不做窗口 count（看板轮询走这条）。
            stats = client.ingest_stats(window_seconds=0)
            if args.json:
                print(json.dumps(stats, ensure_ascii=False, indent=2))
            else:
                show_ingest(stats)
        return 0

    except FieldApiError as err:
        print(explain(err), file=sys.stderr)
        if err.code == "metrics_not_configured":
            print("说明：这个部署没配 [metrics]，指标页本来就不该有数据。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
