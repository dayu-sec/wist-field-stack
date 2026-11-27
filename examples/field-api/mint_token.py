#!/usr/bin/env python3
"""开发态辅助：用 wist-cred 的 web 口令签一把数据场读令牌（`wcr_…`）。

生产上令牌由 cred 的管理面 / 接入流程发放，不要用这个脚本。它只适合本地
stack 或现场验证，并且**不打印、不落盘**口令。

    # 口令直接从 cred 栈的 .wist/sec-value.yml 读；audience 默认从栈根 .env 的
    # FIELD_API_AUDIENCE 自动取（本目录在 <stack>/examples/field-api）。
    export WIST_FIELD_TOKEN=$(python3 mint_token.py \
        --secret-file /path/to/wist-cred-stack/.wist/sec-value.yml \
        --cred-url https://127.0.0.1:4444)

    # 也可以用环境变量（注意别进 shell history）
    WIST_CRED_PASSWORD=... python3 mint_token.py

参数对应关系：
  - `--cred-url` = wist-cred 的 HTTPS 入口（栈 README 示例里是 `https://cred.dev.wist.lab:4444`）；
  - `--audience` = 本栈 `FIELD_API_AUDIENCE`；不传时依次读环境变量、栈根 `.env`，
    最后才回退产品默认 `wist-field-api`；
  - `--role`     = field-api 的 `credentials.required_roles`（默认 read）。
"""

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request


def read_password(args) -> str:
    if args.password:
        return args.password
    value = os.environ.get("WIST_CRED_PASSWORD")
    if value:
        return value
    path = args.secret_file or os.environ.get("WIST_CRED_SECRET_FILE")
    if not path:
        raise SystemExit("需要口令：--password / WIST_CRED_PASSWORD / --secret-file")
    with open(path, "r", encoding="utf-8") as fp:
        for line in fp:
            if line.startswith("cred_web_password:"):
                value = line.split(":", 1)[1].strip().strip('"').strip("'")
                if value:
                    return value
    raise SystemExit("在 %s 里没找到 cred_web_password" % path)


def detect_audience() -> str:
    """环境变量 → 栈根 .env 的 FIELD_API_AUDIENCE → 产品默认值。"""
    value = os.environ.get("WIST_FIELD_AUDIENCE")
    if value and value.strip():
        return value.strip()
    stack_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    try:
        with open(os.path.join(stack_root, ".env"), "r", encoding="utf-8") as fp:
            for line in fp:
                if line.startswith("FIELD_API_AUDIENCE="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if value:
                        return value
    except OSError:
        pass
    return "wist-field-api"


def main() -> int:
    parser = argparse.ArgumentParser(description="开发态：从 wist-cred 签一把 field 读令牌")
    parser.add_argument(
        "--cred-url", default=os.environ.get("WIST_CRED_URL", "https://127.0.0.1:4444"),
        help="wist-cred HTTPS 入口（默认 WIST_CRED_URL 或 %(default)s）",
    )
    parser.add_argument("--password", help="cred_web_password（建议改用环境变量 / 文件）")
    parser.add_argument("--secret-file", help="cred 栈的 .wist/sec-value.yml 路径")
    parser.add_argument(
        "--audience", default=None,
        help="本栈 FIELD_API_AUDIENCE；不传则读 WIST_FIELD_AUDIENCE / 栈根 .env",
    )
    parser.add_argument("--subject", default="field-example", help="令牌主体")
    parser.add_argument(
        "--purpose", default="wist-field Python 示例", help="用途说明（审计可见）"
    )
    parser.add_argument(
        "--role", action="append", default=[], help="角色，可重复（默认 read）"
    )
    parser.add_argument("--ttl", type=int, default=3600, help="有效期秒数（默认 3600）")
    parser.add_argument(
        "--verify-tls", action="store_true",
        help="校验证书（默认跳过，只因为本地 cred 用自签）",
    )
    args = parser.parse_args()

    password = read_password(args)
    roles = args.role or ["read"]
    audience = args.audience or detect_audience()
    body = json.dumps({
        "audience": audience,
        "subject": args.subject,
        "purpose": args.purpose,
        "roles": roles,
        "ttl_seconds": args.ttl,
    }).encode("utf-8")

    url = args.cred_url.rstrip("/") + "/api/v1/credentials"
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Authorization": "Bearer " + password, "Content-Type": "application/json"},
        method="POST",
    )
    context = ssl.create_default_context()
    if not args.verify_tls:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        print("注意：跳过 TLS 校验（本地自签 cred）；生产请加 --verify-tls。", file=sys.stderr)

    try:
        with urllib.request.urlopen(request, timeout=20, context=context) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        print("签发失败 %s: %s" % (err.code, err.read().decode("utf-8", "replace")[:400]),
              file=sys.stderr)
        return 2
    except urllib.error.URLError as err:
        print("连不上 wist-cred（%s）：%s" % (url, err.reason), file=sys.stderr)
        return 2

    token = payload.get("token")
    if not token:
        print("响应里没有 token：%s" % json.dumps(payload, ensure_ascii=False),
              file=sys.stderr)
        return 2

    # 只把令牌写 stdout，方便 `export WIST_FIELD_TOKEN=$(...)`；元信息走 stderr。
    print(token)
    for key in ("credential_id", "audience", "expires_at", "roles"):
        if key in payload:
            print("%s: %s" % (key, payload[key]), file=sys.stderr)
    print("audience 必须等于 field-api 的 [verify].audience；否则访问会 401。",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
