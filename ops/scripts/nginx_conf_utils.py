#!/usr/bin/env python3
"""
Small utilities for working with nginx config files in provisioning scripts.

Why this exists:
  nginx.conf is not always the same across distros, and we want provisioning to
  be deterministic without writing unreadable shell/awk parsers.

This module intentionally implements only what this repo needs:
  - detect if nginx.conf includes a snippets directory inside the `http {}` block

We keep the parsing "good enough" for vendor configs:
  - strip comments (`# ...`) naïvely (not quote-aware)
  - track brace depth to locate the `http { ... }` block
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


INCLUDE_RE = re.compile(r"^\s*include\s+([^;]+)\s*;\s*$")


def _strip_comments(line: str) -> str:
    return line.split("#", 1)[0]


def _count_char(text: str, char: str) -> int:
    return text.count(char)


def _unquote(value: str) -> str:
    value = value.strip()
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1].strip()
    return value


def _parse_include_path(line: str) -> str | None:
    """
    Return the include path for a line like:
      include conf.d/*.conf;
      include /etc/nginx/conf.d/*.conf;
      include "conf.d/*.conf";
    Otherwise return None.
    """
    cleaned = _strip_comments(line).rstrip("\n")
    match = INCLUDE_RE.match(cleaned)
    if not match:
        return None
    return _unquote(match.group(1))


@dataclass(frozen=True)
class HttpBlock:
    start_line_index: int
    end_line_index: int  # inclusive


def find_http_block(lines: list[str]) -> HttpBlock | None:
    """
    Locate the `http { ... }` block in nginx.conf.

    Supports either:
      http {
      }
    or
      http
      {
      }
    """
    http_open_index: int | None = None

    for index, raw in enumerate(lines):
        line = _strip_comments(raw)
        if re.match(r"^\s*http\s*\{", line):
            http_open_index = index
            break
        if re.match(r"^\s*http\s*$", line):
            if index + 1 < len(lines) and re.match(r"^\s*\{", _strip_comments(lines[index + 1])):
                http_open_index = index + 1
                break

    if http_open_index is None:
        return None

    depth = 0
    for index in range(http_open_index, len(lines)):
        line = _strip_comments(lines[index])
        depth += _count_char(line, "{")
        depth -= _count_char(line, "}")
        if depth == 0 and index > http_open_index:
            return HttpBlock(start_line_index=http_open_index, end_line_index=index)

    return None


def nginx_conf_includes_snippets(conf_path: Path, snippets_dir: str) -> bool:
    """
    Return True if `conf_path` includes `snippets_dir/*.conf` inside the `http {}` block.

    Matches either absolute or nginx-relative path:
      /etc/nginx/conf.d/*.conf
      conf.d/*.conf
    """
    lines = conf_path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    block = find_http_block(lines)
    if block is None:
        return False

    include_abs = f"{snippets_dir.rstrip('/') }/*.conf"
    include_rel = f"{snippets_dir.rstrip('/').removeprefix('/etc/nginx/')}/*.conf"
    targets = {include_abs, include_rel}

    for raw in lines[block.start_line_index : block.end_line_index + 1]:
        include_path = _parse_include_path(raw)
        if include_path and include_path in targets:
            return True

    return False


def _cmd_includes_snippets(args: argparse.Namespace) -> int:
    conf = Path(args.conf)
    if not conf.exists():
        print(f"ERROR: nginx config not found: {conf}", file=sys.stderr)
        return 2

    ok = nginx_conf_includes_snippets(conf, args.snippets_dir)
    if args.verbose:
        print("yes" if ok else "no")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="nginx_conf_utils.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    includes = sub.add_parser(
        "includes-snippets",
        help="Exit 0 if nginx.conf includes <snippets-dir>/*.conf inside http {}; else exit 1.",
    )
    includes.add_argument("--conf", required=True, help="Path to nginx.conf (example: /etc/nginx/nginx.conf)")
    includes.add_argument(
        "--snippets-dir",
        required=True,
        help="Snippets directory (example: /etc/nginx/conf.d)",
    )
    includes.add_argument("-v", "--verbose", action="store_true")
    includes.set_defaults(func=_cmd_includes_snippets)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

