#!/usr/bin/env python3
"""asana-scope-guard.py の判定を、架空の GID と一時的な HOME で確かめる。"""

import json
import os
import subprocess
import sys
import tempfile

HOOK = os.path.expanduser("~/.claude/hooks/asana-scope-guard.py")
P = "1111111111111111"
T = "mcp__claude_ai_Asana__"
HOME = tempfile.mkdtemp(prefix="asana-scope-guard-test-")
ENV = dict(os.environ, HOME=HOME)


CONFIG = os.path.join(HOME, ".claude", "asana-scope.json")
NAME = "テスト用プロジェクト"


def write_config(project):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    if project:
        with open(CONFIG, "w") as f:
            json.dump({"project_gid": project, "project_name": NAME}, f)
    elif os.path.exists(CONFIG):
        os.remove(CONFIG)


def run(mode, tool, args, response=None, project=P):
    write_config(project)
    event = {"tool_name": T + tool, "tool_input": args}
    if response is not None:
        event["tool_response"] = response
    argv = ["/usr/bin/python3", HOOK, mode]
    out = subprocess.run(argv, input=json.dumps(event), capture_output=True, text=True, env=ENV)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)["hookSpecificOutput"] if out.stdout.strip() else None


def pre(tool, args, **kwargs):
    result = run("pre", tool, args, **kwargs)
    return "deny" if result and result.get("permissionDecision") == "deny" else "pass"


def text(body):
    return [{"type": "text", "text": body}]


BEFORE_VERIFY = [
    ("get_me", {}, "pass"),
    ("get_project", {"project_id": P}, "pass"),
    ("get_project", {"project_id": "222"}, "deny"),
    ("get_tasks", {"project": P}, "pass"),
    ("get_tasks", {"project": P, "section": "333"}, "deny"),
    ("get_tasks", {"assignee": "me"}, "deny"),
    ("search_tasks", {"projects_any": P, "text": "foo"}, "pass"),
    ("search_tasks", {"projects_any": f"{P},222"}, "deny"),
    ("search_tasks", {"text": "foo"}, "deny"),
    ("search_objects", {"resource_type": "project", "query": "x"}, "deny"),
    ("get_projects", {}, "deny"),
    ("get_my_tasks", {}, "deny"),
    ("get_users", {}, "deny"),
    ("update_project", {"project_id": P}, "deny"),
    ("brand_new_tool", {}, "deny"),
    ("get_task", {"task_id": "9001"}, "pass"),
    ("get_task", {"task_id": "9001", "opt_fields": "name,notes"}, "deny"),
    ("get_task", {"task_id": "9001", "opt_fields": "name,projects"}, "pass"),
    ("add_comment", {"task_id": "9001", "text": "x"}, "deny"),
    ("create_tasks", {"default_project": P, "tasks": [{"name": "a"}]}, "pass"),
    ("create_tasks", {"tasks": [{"name": "a", "project_id": P}]}, "pass"),
    ("create_tasks", {"tasks": [{"name": "a"}]}, "deny"),
    ("create_tasks", {"default_project": P, "tasks": [{"name": "a", "project_id": "222"}]}, "deny"),
    ("create_tasks", {"default_project": P, "tasks": [{"name": "a", "parent": "9001"}]}, "deny"),
    ("create_task_from_template", {"project_id": P, "task_template_id": "5"}, "pass"),
    ("create_task_from_template", {"task_template_id": "5"}, "deny"),
    ("get_attachments", {"parent": P}, "pass"),
]

AFTER_VERIFY = [
    ("add_comment", {"task_id": "9001", "text": "x"}, "pass"),
    ("get_task_stories", {"task_ids": ["9001"]}, "pass"),
    ("get_task_stories", {"task_ids": ["9001", "9002"]}, "deny"),
    ("delete_task", {"task": "9001"}, "pass"),
    ("create_tasks", {"default_project": P, "tasks": [{"name": "a", "parent": "9001"}]}, "pass"),
    ("update_tasks", {"tasks": [{"task": "9001", "name": "b"}]}, "pass"),
    ("update_tasks", {"tasks": [{"task": "9002", "name": "b"}]}, "deny"),
    ("update_tasks", {"tasks": [{"task": "9001", "add_projects": [{"project_id": "222"}]}]}, "deny"),
    ("update_tasks", {"tasks": [{"task": "9001", "remove_projects": [P]}]}, "deny"),
    ("update_tasks", {"tasks": [{"task": "9001", "add_dependencies": ["9002"]}]}, "deny"),
    ("get_attachments", {"parent": "9001"}, "pass"),
]


def main():
    failures = []

    def expect(cases, label):
        for tool, args, want in cases:
            got = pre(tool, args)
            if got != want:
                failures.append(f"{label}: {tool} {args} want={want} got={got}")

    expect(BEFORE_VERIFY, "before verify")

    reason = (run("pre", "get_project", {"project_id": "222"}) or {}).get("permissionDecisionReason", "")
    if NAME not in reason or P not in reason:
        failures.append(f"deny reason does not name the configured project: {reason}")

    hidden = run("post", "get_task", {"task_id": "9001"}, response=text('{"gid":"9001","projects":[{"gid":"222"}]}'))
    if not (hidden and "updatedToolOutput" in hidden):
        failures.append("get_task without the project GID is not hidden")
    hidden = run("post", "get_task", {"task_id": "9001"}, response=text(f'{{"projects":[{{"gid":"{P}9"}}]}}'))
    if not (hidden and "updatedToolOutput" in hidden):
        failures.append("get_task with a longer number containing the GID is not hidden")
    if pre("add_comment", {"task_id": "9001", "text": "x"}) != "deny":
        failures.append("hidden get_task marked the task as verified")

    shown = run("post", "get_task", {"task_id": "9001"}, response=text(f'{{"gid":"9001","projects":[{{"gid":"{P}"}}]}}'))
    if shown is not None:
        failures.append("get_task with the project GID is hidden")
    expect(AFTER_VERIFY, "after verify")

    if pre("get_me", {}, project="") != "deny":
        failures.append("calls pass without a project GID")
    if run("post", "get_tasks", {"project": P}, response=text("x")) is not None:
        failures.append("post hook changed a tool other than get_task")
    hidden = run("post", "get_task", {"task_id": "9001"}, response=text(P), project="")
    if not (hidden and "updatedToolOutput" in hidden):
        failures.append("get_task is shown without a project GID")

    for failure in failures:
        print("NG", failure)
    print("ALL OK" if not failures else f"FAILED {len(failures)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
