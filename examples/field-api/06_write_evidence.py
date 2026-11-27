#!/usr/bin/env python3
"""示例 6：写一条证据（数据面视角），再从 BFF 读回来。

    python3 06_write_evidence.py --sink http://127.0.0.1:18800 --tenant t-001
    python3 06_write_evidence.py --from-integration --tenant t-001

写给谁：证据服务的**写监听** `POST /internal/evidence`（内网明文、无认证）。
读给谁：BFF 的 `/api/evidence`（Bearer + 客户选择 + 敏感度闸）。

注意 `--from-integration` 用的是 `/api/integration` 里**数据面视角**的地址，
从你这台机器不一定可达；生产上它通常是内网地址。
`cust_id` 必须已在证据服务站点登记（`[[storage.cell]]`），否则 400
`evidence_customer_unregistered`。
"""

import argparse
import json
import os
import sys
import time

from field_client import (
    FieldApiError,
    add_common_args,
    client_from_args,
    explain,
    require_auth,
    write_evidence,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-field：写一条证据并读回")
    add_common_args(parser)
    parser.add_argument(
        "--sink", help="证据服务写地址根（默认 EVIDENCE_SINK_URL，或用 --from-integration）"
    )
    parser.add_argument(
        "--from-integration", action="store_true",
        help="从 GET /api/integration 取 evidence.write_url（数据面视角）",
    )
    parser.add_argument("--cust-id", help="写入客户（默认取 --tenant / 站点唯一客户）")
    parser.add_argument("--cmd-id", help="幂等键（默认按时间生成）")
    parser.add_argument("--subject", help="可选：覆盖主体标识")
    parser.add_argument("--content", help="正文 JSON 字符串；不给就写一条演示记录")
    parser.add_argument("--show-content", action="store_true", help="写完后打印读回的正文")
    args = parser.parse_args()

    client = client_from_args(args)
    if not require_auth(client):
        return 2
    try:
        sink = args.sink
        if not sink and args.from_integration:
            info = client.integration()
            sink = (info.get("evidence") or {}).get("write_url")
            if sink:
                print("使用 /api/integration 的写端点:", sink)
        if not sink:
            sink = os.environ.get("EVIDENCE_SINK_URL")
        if not sink:
            parser.error("需要 --sink / EVIDENCE_SINK_URL，或加 --from-integration")

        cust_id = args.cust_id or client.tenant
        if not cust_id:
            cust_id = client.resolve_tenant()
        if not cust_id:
            parser.error("不知道写哪个客户：用 --cust-id 指定（写入的 cust_id 就是租户）")

        cmd_id = args.cmd_id or "cmd-demo-%d" % int(time.time() * 1000)
        if args.content:
            content = json.loads(args.content)
        else:
            content = {
                "report_schema": "demo.field-api/v1",
                "summary": {"overall": "ok", "note": "written by 06_write_evidence.py"},
                "findings": [
                    {"id": "f-1", "severity": "info", "title": "示例证据"}
                ],
            }

        response = write_evidence(
            sink, cust_id=cust_id, cmd_id=cmd_id, content=content,
            subject=args.subject,
        )
        print("写入响应:", json.dumps(response, ensure_ascii=False))

        # 写入 → 索引可见通常是同步的；给几次重试只是不把“刚好在切换”当成没写进去。
        artifact = None
        for attempt in range(6):
            page = client.list_evidence(cmd_id=cmd_id, limit=5)
            artifacts = page.get("artifacts") or []
            if artifacts:
                artifact = artifacts[0]
                break
            if attempt < 5:
                time.sleep(1)
        if not artifact:
            print("BFF 暂时没看到这条（检查客户是否选对、索引是否落到同一个 cell）。",
                  file=sys.stderr)
            return 1

        print("BFF 读回:", artifact.get("artifact_id"), artifact.get("command_id"),
              "sensitivity=%s" % artifact.get("sensitivity"))
        if args.show_content:
            key = artifact.get("artifact_id") or cmd_id
            body = client.evidence_content(key)
            try:
                print(json.dumps(json.loads(body.decode("utf-8")),
                                 ensure_ascii=False, indent=2))
            except ValueError:
                print(body.decode("utf-8", "replace"))
        return 0

    except FieldApiError as err:
        print(explain(err), file=sys.stderr)
        if err.code == "evidence_customer_unregistered":
            print("说明：cust_id 没在证据服务的 [[storage.cell]] 里登记。", file=sys.stderr)
        return 2
    except ValueError as err:
        print("参数错误：%s" % err, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
