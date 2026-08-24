#!/usr/bin/env python3
"""層をまたぐ import を検出する。標準ライブラリのみ。

    python check_layers.py src/
    python check_layers.py src/ --layer-root sales --layer-root shipping

違反を `file:line: 説明` で出し、1 件でもあれば終了コード 1 を返す。
層の名前と依存の向きは下の LAYERS / FORBIDDEN_PACKAGES を編集して合わせる。
"""

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

# 各層が import してよい層。domain は空 = 他のどの層も見ない。
LAYERS: dict[str, set[str]] = {
    "domain": set(),
    "usecases": {"domain"},
    "infrastructure": {"domain", "usecases"},
    "interfaces": {"domain", "usecases", "infrastructure"},
}

# 各層が import してはいけない外部パッケージ(前方一致)。
FORBIDDEN_PACKAGES: dict[str, set[str]] = {
    "domain": {"django", "rest_framework"},
    "usecases": {"rest_framework"},  # django.db.transaction は境界のため許す
}


def layer_of(path: Path, roots: list[str]) -> str | None:
    """パスからこのファイルが属する層を返す。見つからなければ None。"""
    parts = path.parts
    for i, part in enumerate(parts):
        if part in LAYERS and (not roots or any(r in parts[:i] for r in roots)):
            return part
    return None


def context_of(path: Path, roots: list[str]) -> str | None:
    """パスからコンテキスト(app)名を返す。roots 未指定なら None。"""
    for part in path.parts:
        if part in roots:
            return part
    return None


def imported_names(tree: ast.AST) -> list[tuple[str, int]]:
    """(モジュール名, 行番号) を返す。相対 import は解決せず名前だけ拾う。"""
    out: list[tuple[str, int]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out += [(a.name, node.lineno) for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module:
            out.append((node.module, node.lineno))
    return out


def check_file(path: Path, roots: list[str]) -> list[str]:
    layer = layer_of(path, roots)
    if layer is None:
        return []
    my_context = context_of(path, roots)
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as e:
        return [f"{path}:{e.lineno}: 構文エラーで解析できない ({e.msg})"]

    allowed = LAYERS[layer]
    forbidden = FORBIDDEN_PACKAGES.get(layer, set())
    violations: list[str] = []

    for module, lineno in imported_names(tree):
        head = module.split(".")[0]
        if head in forbidden:
            violations.append(f"{path}:{lineno}: {layer} が {module} を import している")
            continue
        # コンテキストをまたぐ domain 同士の import(層名が同じなので下の判定を通り抜ける)
        if my_context and "domain" in module.split("."):
            other_ctx = next((r for r in roots if r in module.split(".")), None)
            if other_ctx and other_ctx != my_context:
                violations.append(
                    f"{path}:{lineno}: {my_context} が {other_ctx} の domain を "
                    f"import している(コンテキスト境界)"
                )
                continue

        for other in LAYERS:
            if other != layer and other in module.split(".") and other not in allowed:
                violations.append(
                    f"{path}:{lineno}: {layer} → {other} は許されていない依存"
                )
                break
    return violations


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("src", type=Path, help="走査するディレクトリ")
    p.add_argument(
        "--layer-root",
        action="append",
        default=[],
        dest="roots",
        help="層ディレクトリを探す親(app 名)。省略時はどこにあっても層とみなす",
    )
    args = p.parse_args()

    if not args.src.is_dir():
        print(f"ディレクトリがない: {args.src}", file=sys.stderr)
        return 2

    violations: list[str] = []
    for path in sorted(args.src.rglob("*.py")):
        violations += check_file(path, args.roots)

    for v in violations:
        print(v)
    if violations:
        print(f"\n{len(violations)} 件の層違反", file=sys.stderr)
        return 1
    print("層違反なし")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
