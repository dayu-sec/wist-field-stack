#!/usr/bin/env python3
"""示例 5：数据面接入信息 + 资产拓扑（经 BFF 代理的 atlas 只读接口）。

    python3 05_integration_and_atlas.py
    python3 05_integration_and_atlas.py --path hosts --query limit=5

`GET /api/integration` 回的是**数据面视角**的写端点（BFF 到不了），
所以别拿它当“从这里能 POST 通”的证据；真正的写入示例见 `06_write_evidence.py`。
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


def unwrap(body: dict):
    """atlas 的统一信封：{status, data, code?, message?}。"""
    if body.get("status") != "ok" or "data" not in body:
        raise FieldApiError(
            200, body.get("code") or "atlas_error",
            body.get("message") or "atlas 返回了非 ok 的响应",
        )
    return body["data"]


def show_integration(info: dict) -> None:
    evidence = info.get("evidence") or {}
    print("证据写入 :", evidence.get("write_url"))
    print("客户     :", evidence.get("customer"))
    print("允许类型 :", ", ".join(evidence.get("allowed_kinds") or []))
    print("写入样板 :", json.dumps(evidence.get("record"), ensure_ascii=False))

    print("\nwparse 环境变量：")
    for key, value in ((info.get("warp_parse") or {}).get("env") or {}).items():
        print("  %-24s %s" % (key, value))

    metrics = info.get("metrics")
    if metrics:
        print("\n指标写入 :", metrics.get("write_url") + metrics.get("import_path", ""))
        print("环境变量 :", metrics.get("env"))
        print("BFF 读取 :", metrics.get("base_url"))
    else:
        print("\n指标写入 : (BFF 没配 [metrics] write_url)")

    atlas = info.get("atlas")
    if atlas:
        print("\nAtlas 写入:", atlas.get("write_url"))
        print("Atlas 客户:", atlas.get("customer"))
    else:
        print("\nAtlas 写入: (没配 atlas.sink_url)")


def show_atlas(client, path: str, query: dict) -> None:
    body = client.atlas(path, query=query)
    if path.endswith("openapi.json"):
        # OpenAPI 文档不是 atlas 的统一信封，直接就是 spec 本身。
        data = body
        print("Atlas OpenAPI:", data.get("info", {}).get("title"),
              "v%s" % data.get("info", {}).get("version"))
        print("路径数:", len(data.get("paths") or {}))
        for route in sorted((data.get("paths") or {}).keys())[:10]:
            print("  ", route)
        return

    data = unwrap(body)

    # 常用三个列表接口的 data 形状：{hosts: []} / {networkDomains: []} / {elasticIps: []}
    for key, rows in data.items():
        if not isinstance(rows, list):
            print("%s: %s" % (key, json.dumps(rows, ensure_ascii=False)[:300]))
            continue
        print("%s: %d 条" % (key, len(rows)))
        for row in rows[:5]:
            if not isinstance(row, dict):
                print("  ", row)
                continue
            name = row.get("hostName") or row.get("name") or row.get("id")
            extra = []
            for field in ("ip", "cidr", "address", "cloudAccount", "stale"):
                if row.get(field) is not None:
                    extra.append("%s=%s" % (field, row[field]))
            print("  %-42s %s" % (name, " ".join(extra)))
        if len(rows) > 5:
            print("  ...（还有 %d 条）" % (len(rows) - 5))


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-field：接入信息与资产拓扑")
    add_common_args(parser)
    parser.add_argument("--path", help="只调一个 atlas 路径（例如 hosts / network-domains）")
    parser.add_argument(
        "--query", action="append", default=[], metavar="K=V",
        help="atlas 查询参数，可重复（tenant 不要自己传，BFF 会加）",
    )
    args = parser.parse_args()

    query = {}
    for item in args.query:
        if "=" not in item:
            parser.error("--query 需要 K=V 形状：%s" % item)
        key, value = item.split("=", 1)
        query[key] = value

    client = client_from_args(args)
    if not require_auth(client):
        return 2
    try:
        if not args.path:
            show_integration(client.integration())

        if args.path:
            print()
            show_atlas(client, args.path, query)
            return 0

        print("\n资产拓扑（经 BFF /api/atlas/* 代理）：")
        show_atlas(client, "openapi.json", {})
        for path, params in (
            ("hosts", {"limit": 5}),
            ("network-domains", {"limit": 5}),
            ("elastic-ips", {"limit": 5}),
        ):
            print()
            try:
                show_atlas(client, path, params)
            except FieldApiError as err:
                # 老版本 atlas 没有这些接口时，别把整段示例打断。
                print("%s 不可用：%s" % (path, err))
        return 0

    except FieldApiError as err:
        print(explain(err), file=sys.stderr)
        if err.status == 404:
            print("说明：BFF 没配 [atlas] 时 /api/atlas/* 会回 404 atlas_not_configured。",
                  file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
