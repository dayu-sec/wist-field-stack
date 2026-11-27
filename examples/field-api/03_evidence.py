#!/usr/bin/env python3
"""示例 3：读证据（列表 → 详情 → 正文），以及两种读正文的通路。

    # 看某次调查的产物（发起调查的人手里只有 cmd_id）
    python3 03_evidence.py --cmd-id cmd-20261105-001

    # 看一条证据的索引行 + 正文
    python3 03_evidence.py --id art_xxx --content

    # 把命中的正文下载到目录（默认走 BFF 代理读，解压后原文）
    python3 03_evidence.py --cmd-id cmd-20261105-001 --download /tmp/evidence

正文有两条路：
  - `objects.kind = file`：BFF 代理读 `GET /api/evidence/{id}/content`（默认）；
  - `objects.kind = s3`：先 `POST .../{id}:presign` 换 60 秒 URL，再直连对象存储。
    注意预签名拿的是**存储里的对象**（zstd 压缩），BFF 的 `/content` 才是解压后的原文。
"""

import argparse
import json
import os
import sys

from field_client import (
    FieldApiError,
    add_common_args,
    client_from_args,
    explain,
    require_auth,
)


def show_artifact(artifact: dict) -> None:
    fields = [
        ("artifact_id", artifact.get("artifact_id")),
        ("command_id", artifact.get("command_id")),
        ("kind", artifact.get("kind")),
        ("subtype", artifact.get("subtype")),
        ("subject", "%s/%s" % (artifact.get("subject_type"), artifact.get("subject_id"))),
        ("tenant", artifact.get("tenant_id")),
        ("sensitivity", artifact.get("sensitivity")),
        ("verdict", artifact.get("verdict")),
        ("size", artifact.get("size_bytes")),
        ("stored_at", artifact.get("stored_at")),
        ("object_key", artifact.get("object_key")),
    ]
    for name, value in fields:
        print("  %-12s %s" % (name, value))


def printable(body: bytes) -> str:
    text = body.decode("utf-8", "replace")
    try:
        return json.dumps(json.loads(text), ensure_ascii=False, indent=2)
    except ValueError:
        return text


def download(
    client,
    artifact: dict,
    mode: str,
    dest_dir: str,
    presign_ok: bool,
) -> None:
    key = artifact.get("artifact_id") or artifact.get("command_id")
    if not key:
        print("  跳过：这条证据没有 artifact_id / command_id", file=sys.stderr)
        return
    os.makedirs(dest_dir, exist_ok=True)

    if mode == "presign" and presign_ok:
        result = client.presign_evidence(key)
        url = result.get("url")
        if not url:
            raise FieldApiError(502, "presign_no_url", "预签名响应里没有 url")
        headers, body = client.fetch_url(url)
        # 预签名 URL 直接拿对象存储里的对象：这里是 zstd 压缩后的字节。
        path = os.path.join(dest_dir, key + ".obj.zst")
        with open(path, "wb") as fp:
            fp.write(body)
        print("  已下载（预签名原始对象）: %s  %d bytes" % (path, len(body)))
        content_type = headers.get("Content-Type") or headers.get("content-type")
        if content_type:
            print("  content-type: %s" % content_type)
        return

    if mode == "presign" and not presign_ok:
        print("  这个部署不支持预签名（objects.kind != s3），回落到 BFF 代理读")

    body = client.evidence_content(key)
    path = os.path.join(dest_dir, key + ".json")
    with open(path, "wb") as fp:
        fp.write(body)
    print("  已下载（BFF 代理读，解压后原文）: %s  %d bytes" % (path, len(body)))


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-field：读证据")
    add_common_args(parser)
    parser.add_argument("--id", help="证据 id（art_…）或调查命令 id；给了就只看这一条")
    parser.add_argument("--cmd-id", help="按调查命令 id 筛选列表")
    parser.add_argument("--kind", help="按证据类型筛选（如 investigation_report）")
    parser.add_argument("--subject-id", help="按主体筛选（客户 / 资产）")
    parser.add_argument("--since", help="只看该时间之后（RFC 3339，例如 2026-11-01T00:00:00Z）")
    parser.add_argument("--limit", type=int, default=20, help="每页条数（1–200，默认 20）")
    parser.add_argument("--all", action="store_true", help="自动翻页（受 --max-pages 限制）")
    parser.add_argument("--max-pages", type=int, default=5, help="--all 时最多翻几页")
    parser.add_argument("--content", action="store_true", help="打印正文（截断到 --max-chars）")
    parser.add_argument("--max-chars", type=int, default=4000)
    parser.add_argument("--download", metavar="DIR", help="把正文下载到目录")
    parser.add_argument(
        "--mode", choices=("content", "presign"), default="content",
        help="下载通路：content=BFF 代理读（默认），presign=签名 URL 直连对象存储",
    )
    args = parser.parse_args()

    client = client_from_args(args)
    if not require_auth(client):
        return 2
    try:
        capabilities = client.evidence_capabilities()
        print("capabilities:", json.dumps(capabilities, ensure_ascii=False))
        presign_ok = bool(capabilities.get("presign_supported"))
        if args.mode == "presign" and not presign_ok:
            print("注意：预签名不可用，下载会回落到 /content", file=sys.stderr)

        if args.id:
            artifacts = [client.get_evidence(args.id)]
        else:
            filters = {
                "cmd_id": args.cmd_id,
                "kind": args.kind,
                "subject_id": args.subject_id,
                "since": args.since,
            }
            if args.all:
                artifacts = list(
                    client.iter_evidence(
                        page_size=args.limit, max_pages=args.max_pages,
                        **{k: v for k, v in filters.items() if v is not None}
                    )
                )
            else:
                page = client.list_evidence(limit=args.limit, **filters)
                artifacts = page.get("artifacts") or []
                if page.get("next_cursor"):
                    print("next_cursor:", page["next_cursor"], "（加 --all 自动翻页）")

        print("\n命中 %d 条：" % len(artifacts))
        for index, artifact in enumerate(artifacts, 1):
            print("[%d] %s" % (index, artifact.get("artifact_id")))
            show_artifact(artifact)
            if args.content:
                key = artifact.get("artifact_id") or artifact.get("command_id")
                if not key:
                    continue
                text = printable(client.evidence_content(key))
                print("  content:")
                print(_indent(text[: args.max_chars]))
                if len(text) > args.max_chars:
                    print("  ...（还有 %d 字符，加 --max-chars 或 --download）"
                          % (len(text) - args.max_chars))
            if args.download:
                download(client, artifact, args.mode, args.download, presign_ok)
            print()

        if not args.id and not args.content and not args.download and not artifacts:
            print("没有命中。检查 --tenant / --cmd-id / --since；空列表也可能是客户选错了。")

        # 顺便演示预签名响应形状（不下载时也可以解一道）。
        if args.mode == "presign" and presign_ok and artifacts and not args.download:
            first = artifacts[0].get("artifact_id")
            if first:
                result = client.presign_evidence(first)
                print("presign:", json.dumps(result, ensure_ascii=False))
        return 0

    except FieldApiError as err:
        print(explain(err), file=sys.stderr)
        return 2


def _indent(text: str) -> str:
    return "\n".join("    " + line for line in text.splitlines())


if __name__ == "__main__":
    raise SystemExit(main())
