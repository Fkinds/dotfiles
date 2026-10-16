#!/usr/bin/env python3
"""PR の行数を micro-pr の数え方で数える。

使い方:
    count_pr_lines.py <base> [<head>] [--exclude GLOB ...] [-v]

<head> を渡すと <base>...<head>(PR の差分と同じ、分岐点からの差分)を数える。
省くと、<base> との分岐点から作業ツリーまで(未追跡のファイルを含む)を数える。

数えるのは追加と削除の合計。次は数えずに一覧へ出す。
lock ファイル、スナップショット、RunPython / RunSQL を含まない migration、
テスト用ディレクトリの中のデータファイル、バイナリ、--exclude に一致するもの。

終了コード: 0 = 500 行以下、1 = 500 行超え、2 = 使い方の誤り。
"""

from __future__ import annotations

import argparse
import fnmatch
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

LOWER, UPPER = 300, 500

LOCKFILES = {
    "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "poetry.lock",
    "uv.lock", "Pipfile.lock", "Cargo.lock", "Gemfile.lock", "composer.lock", "go.sum",
    "lazy-lock.json",
}
TEST_DIRS = {"tests", "test", "__tests__", "fixtures", "testdata"}
DATA_SUFFIXES = {".json", ".jsonl", ".ndjson", ".csv", ".tsv", ".yaml", ".yml", ".xml", ".txt", ".sql"}
MIGRATION_MARKERS = ("RunPython", "RunSQL")


@dataclass(frozen=True)
class FileStat:
    path: str
    added: int
    deleted: int
    binary: bool = False

    @property
    def total(self) -> int:
        return self.added + self.deleted


def git(*args: str) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"git {' '.join(args)} が失敗した: {result.stderr.strip()}")
    return result.stdout


def numstat(rev_args: list[str]) -> list[FileStat]:
    tokens = git("diff", "--numstat", "-z", "-M", *rev_args).split("\0")
    stats, i = [], 0
    while i < len(tokens):
        if not tokens[i]:
            i += 1
            continue
        added, deleted, path = tokens[i].split("\t", 2)
        if path == "":                      # rename: 次の 2 つが旧パスと新パス
            path = tokens[i + 2]
            i += 3
        else:
            i += 1
        binary = added == "-"
        stats.append(FileStat(path, 0 if binary else int(added), 0 if binary else int(deleted), binary))
    return stats


def untracked() -> list[FileStat]:
    stats = []
    for path in git("ls-files", "--others", "--exclude-standard", "-z").split("\0"):
        if not path:
            continue
        data = Path(path).read_bytes()
        if b"\0" in data:
            stats.append(FileStat(path, 0, 0, binary=True))
        else:
            stats.append(FileStat(path, len(data.decode(errors="replace").splitlines()), 0))
    return stats


def file_content(path: str, revs: list[str]) -> str:
    """最初に読めた版の中身。作業ツリーを先に見る指定は revs に "" を入れる。"""
    for rev in revs:
        if rev == "":
            p = Path(path)
            if p.exists():
                return p.read_text(errors="replace")
            continue
        result = subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout
    return ""


def exclusion_reason(stat: FileStat, extra: list[str], content_revs: list[str]) -> str | None:
    p = PurePosixPath(stat.path)
    if stat.binary:
        return "バイナリ"
    if any(fnmatch.fnmatch(stat.path, pattern) for pattern in extra):
        return "--exclude"
    if p.name in LOCKFILES:
        return "lock ファイル"
    if "__snapshots__" in p.parts or p.suffix == ".snap":
        return "スナップショット"
    if "migrations" in p.parts and p.suffix == ".py" and p.name != "__init__.py":
        content = file_content(stat.path, content_revs)
        if not any(marker in content for marker in MIGRATION_MARKERS):
            return "自動生成の migration"
    if TEST_DIRS & set(p.parts[:-1]) and p.suffix in DATA_SUFFIXES:
        return "テストのデータ"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="PR の行数を micro-pr の数え方で数える")
    parser.add_argument("base", help="1 つ下のブランチ。一番下の PR なら trunk")
    parser.add_argument("head", nargs="?", help="省くと作業ツリーを数える")
    parser.add_argument("--exclude", action="append", default=[], metavar="GLOB",
                        help="生成された型定義など、数えないファイルのパターン")
    parser.add_argument("-v", "--verbose", action="store_true", help="数えたファイルも一覧に出す")
    args = parser.parse_args()

    if args.head:
        stats = numstat([f"{args.base}...{args.head}"])
        content_revs = [args.head, args.base]
    else:
        merge_base = git("merge-base", args.base, "HEAD").strip()
        stats = numstat([merge_base]) + untracked()
        content_revs = ["", merge_base]

    counted: list[FileStat] = []
    excluded: list[tuple[FileStat, str]] = []
    for stat in stats:
        reason = exclusion_reason(stat, args.exclude, content_revs)
        if reason:
            excluded.append((stat, reason))
        else:
            counted.append(stat)

    total = sum(s.total for s in counted)
    print(f"数える行: {total}(追加 {sum(s.added for s in counted)} / 削除 {sum(s.deleted for s in counted)})")
    if args.verbose:
        for s in sorted(counted, key=lambda s: -s.total):
            print(f"  {s.total:>6}  {s.path}")
    if excluded:
        print(f"数えない行: {sum(s.total for s, _ in excluded)}(PR 本文に一覧を書く)")
        for s, reason in sorted(excluded, key=lambda e: -e[0].total):
            size = "-" if s.binary else str(s.total)
            print(f"  {size:>6}  {s.path}  [{reason}]")

    if total > UPPER:
        print(f"判定: {UPPER} 行を超えている。分け直す")
        return 1
    if total < LOWER:
        print(f"判定: {LOWER} 行未満。同じ層の同じ機能の単位を足すか、例外の理由を PR 本文に書く")
    else:
        print(f"判定: 範囲内({LOWER}〜{UPPER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
