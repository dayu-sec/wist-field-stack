#!/usr/bin/env python3
"""示例 2：看 BFF 自己怎么判断“这一片接没接上、通不通”。

    python3 02_health.py
    python3 02_health.py --strict   # 有 unavailable 就退出码 1（适合做探针）

`not_configured` 不是故障，只表示这个域还没接（例如没配 atlas / metrics）。
"""

import argparse
import json
import sys

from field_client import FieldApiError, add_common_args, client_from_args, explain, require_auth


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-field：健康与接口探活")
    add_common_args(parser)
    parser.add_argument(
        "--strict", action="store_true", help="任一接口 unavailable 时以退出码 1 结束"
    )
    args = parser.parse_args()

    client = client_from_args(args)
    if not require_auth(client):
        return 2

    try:
        # 经 web 入口时 `/healthz` 不是 BFF（被 nginx / 前端接管），这里只用 `/api/*`。
        # 客户清单来自 `/api/session`：它不是登录会话，只是当前令牌的 subject / roles / tenants。
        session = client.session()
        tenants = session.get("tenants") or []
        print("调用方     : %s roles=%s" % (
            session.get("subject") or "—", session.get("roles") or []
        ))
        print("可见客户   : %s" % (tenants or "（未配置）"))
        if len(tenants) > 1 and not client.tenant:
            print("提示       : 多客户站点，后续请求需要 --tenant / WIST_FIELD_TENANT")

        health = client.health()
        print("BFF 版本   : %s（站点栈 %s）" % (
            health.get("version") or "—", health.get("stack_version") or "—"
        ))

        print("\n数据源：")
        for name, state in sorted((health.get("sources") or {}).items()):
            detail = state.get("detail")
            line = "  %-10s %-15s" % (name, state.get("status"))
            if detail:
                line += " " + detail
            print(line)

        bad = []
        print("\n接口探活：")
        for item in health.get("interfaces") or []:
            status = item.get("status")
            if status == "unavailable":
                bad.append(item.get("id"))
            latency = item.get("latency_ms")
            latency_text = "—" if latency is None else "%dms" % latency
            print("  %-18s %-15s %-8s %s" % (
                item.get("id"), status, latency_text, item.get("label") or ""
            ))
            if item.get("url"):
                print("      url   : %s" % item["url"])
            if item.get("detail"):
                print("      detail: %s" % item["detail"])
            if item.get("covers"):
                # covers 说明这次探活到底验到了哪一层，别把“绿”理解成整条链路都通。
                print("      covers: %s" % item["covers"].replace("\n", " "))

        if args.strict and bad:
            print("\n不可用接口：%s" % ", ".join(bad), file=sys.stderr)
            return 1
        return 0

    except FieldApiError as err:
        print(explain(err), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
