#!/usr/bin/env python3
"""PreToolUse / PostToolUse hook: Asana のツール呼び出しを 1 プロジェクトだけに絞る。

使い方: asana-scope-guard.py pre|post

対象プロジェクトは ~/.claude/asana-scope.json の project_gid / project_name で決める。
dotfiles は公開リポジトリなので、社内のプロジェクト名や GID はここにも settings.json にも書かない。

Asana のコネクタはユーザー本人の権限でワークスペース全体が見え、Asana 側では
プロジェクト単位に絞れないため、Claude Code 側で引数と結果を検査する。

- pre: 対象プロジェクト以外を指す呼び出し・ワークスペース全体を扱う呼び出し・
  一覧にないツールを deny する。問題がなければ何も出力せず、通常の権限確認に任せる
- post: get_task の結果に対象プロジェクトの GID が無ければ結果を差し替える。
  あれば、そのタスクを確認済みとして記録する(タスク GID だけを取るツールの許可に使う)
"""

import json
import os
import re
import sys
import tempfile
from pathlib import Path

CONFIG_FILE = Path.home() / ".claude" / "asana-scope.json"
STATE_FILE = Path.home() / ".claude" / "state" / "asana-scope-guard.json"
SCOPE_NAME = "対象プロジェクト"


class OutOfScope(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise OutOfScope(reason)


def as_ids(value):
    if value is None or value == "":
        return []
    if isinstance(value, list):
        return [i for v in value for i in as_ids(v)]
    if isinstance(value, dict):
        return as_ids(value.get("gid") or value.get("task") or value.get("task_id"))
    return [s.strip() for s in str(value).split(",") if s.strip()]


def load_verified(project):
    try:
        state = json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return set()
    if state.get("project") != project:
        return set()
    return set(state.get("tasks", []))


def save_verified(project, tasks):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_FILE.parent)
    with os.fdopen(fd, "w") as f:
        json.dump({"project": project, "tasks": sorted(tasks)}, f)
    os.replace(tmp, STATE_FILE)


def require_project(value, project, field):
    ids = as_ids(value)
    require(
        ids and all(i == project for i in ids),
        f"{field} に {SCOPE_NAME} ({project}) 以外が指定されています",
    )


def require_verified(value, verified):
    unknown = [i for i in as_ids(value) if i not in verified]
    require(
        not unknown,
        f"タスク {', '.join(unknown)} は {SCOPE_NAME} のタスクと確認できていません。"
        "先に get_task で開いてください",
    )


def check_get_tasks(args, project, verified):
    require_project(args.get("project"), project, "project")
    # project と一緒に section 等を渡すと、サーバー側でどちらが優先されるか保証がない
    other = [k for k in ("section", "tag", "user_task_list", "assignee") if args.get(k)]
    require(
        not other,
        f"get_tasks では {', '.join(other)} を使えません。"
        "絞り込みは search_tasks に projects_any を付けて行ってください",
    )


def check_get_task(args, project, verified):
    opt_fields = args.get("opt_fields")
    require(
        not opt_fields or "projects" in opt_fields or "memberships" in opt_fields,
        "opt_fields を指定するときは projects を含めてください(所属プロジェクトの確認に使います)",
    )


def check_get_task_stories(args, project, verified):
    ids = as_ids(args.get("task_id")) + as_ids(args.get("task_ids"))
    require(ids, "task_id か task_ids を指定してください")
    require_verified(ids, verified)


def check_get_attachments(args, project, verified):
    parent = str(args.get("parent", "")).strip()
    if parent != project:
        require_verified(parent, verified)


def check_create_tasks(args, project, verified):
    tasks = args.get("tasks") or []
    require(tasks, "tasks が空です")
    for task in tasks:
        require_project(
            task.get("project_id") or args.get("default_project"),
            project,
            "project_id / default_project",
        )
        if task.get("parent"):
            require_verified(task["parent"], verified)


def check_update_tasks(args, project, verified):
    tasks = args.get("tasks") or []
    require(tasks, "tasks が空です")
    for task in tasks:
        require_verified(task.get("task"), verified)
        require(not task.get("remove_projects"), "remove_projects は使えません")
        for added in task.get("add_projects") or []:
            require_project(added.get("project_id"), project, "add_projects.project_id")
        if task.get("parent"):
            require_verified(task["parent"], verified)
        for key in ("add_dependencies", "add_dependents", "remove_dependencies", "remove_dependents"):
            require_verified(task.get(key), verified)


CHECKS = {
    "get_me": lambda args, project, verified: None,
    "get_project": lambda args, project, verified: require_project(args.get("project_id"), project, "project_id"),
    "get_tasks": check_get_tasks,
    "search_tasks": lambda args, project, verified: require_project(args.get("projects_any"), project, "projects_any"),
    "get_task": check_get_task,
    "get_task_stories": check_get_task_stories,
    "get_attachments": check_get_attachments,
    "add_comment": lambda args, project, verified: require_verified(args.get("task_id"), verified),
    "delete_task": lambda args, project, verified: require_verified(args.get("task"), verified),
    "create_tasks": check_create_tasks,
    "create_task_from_template": lambda args, project, verified: require_project(args.get("project_id"), project, "project_id"),
    "update_tasks": check_update_tasks,
}


def pre(event, project):
    tool = event.get("tool_name", "").split("__")[-1]
    check = CHECKS.get(tool)
    if check is None:
        raise OutOfScope(f"{tool} は {SCOPE_NAME} 以外も扱うツールなので使えません")
    check(event.get("tool_input") or {}, project, load_verified(project))


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"[asana-scope-guard] {reason}",
        }
    }, ensure_ascii=False))


def post(event, project):
    if event.get("tool_name", "").split("__")[-1] != "get_task":
        return
    response = json.dumps(event.get("tool_response"), ensure_ascii=False)
    task_id = str((event.get("tool_input") or {}).get("task_id", "")).strip()
    if project and task_id and re.search(rf"(?<!\d){re.escape(project)}(?!\d)", response):
        save_verified(project, load_verified(project) | {task_id})
        return
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "updatedToolOutput": (
                f"[asana-scope-guard] タスク {task_id} は {SCOPE_NAME} のタスクと確認できなかったため、"
                "結果を表示しません。"
            ),
        }
    }, ensure_ascii=False))


def load_config():
    try:
        config = json.loads(CONFIG_FILE.read_text())
    except (OSError, ValueError):
        return "", None
    return str(config.get("project_gid") or "").strip(), config.get("project_name")


def main():
    global SCOPE_NAME
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    project, name = load_config()
    SCOPE_NAME = name or SCOPE_NAME
    try:
        event = json.load(sys.stdin)
    except ValueError:
        event = {}
    if mode == "pre":
        try:
            require(project, f"{CONFIG_FILE} に project_gid が設定されていません")
            pre(event, project)
        except OutOfScope as e:
            deny(str(e))
        except Exception as e:  # noqa: BLE001  判定できない呼び出しは通さない
            deny(f"フックの内部エラーのため止めました: {e!r}")
    elif mode == "post":
        try:
            post(event, project)
        except Exception as e:  # noqa: BLE001
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "updatedToolOutput": f"[asana-scope-guard] フックの内部エラーのため結果を表示しません: {e!r}",
                }
            }, ensure_ascii=False))


if __name__ == "__main__":
    main()
