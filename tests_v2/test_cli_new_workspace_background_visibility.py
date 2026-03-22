#!/usr/bin/env python3
"""Regression: CLI new-workspace should background-prime without exposing its terminal."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: List[str]) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def _current_workspace(c: cmux) -> str:
    payload = c._call("workspace.current") or {}
    ws_id = str(payload.get("workspace_id") or "")
    if not ws_id:
        raise cmuxError(f"workspace.current returned no workspace_id: {payload}")
    return ws_id


def _resolve_workspace_handle(c: cmux, handle: str) -> str:
    normalized = handle.strip()
    if not normalized:
        return ""
    if normalized.startswith("workspace:"):
        payload = c._call("workspace.list") or {}
        for item in payload.get("workspaces") or []:
            if str(item.get("ref") or "") == normalized:
                return str(item.get("id") or "")
        return ""
    return normalized


def _debug_terminals(c: cmux) -> List[dict[str, Any]]:
    payload = c._call("debug.terminals") or {}
    terminals = payload.get("terminals") or []
    return [dict(item) for item in terminals]


def _wait_for_terminal(
    c: cmux,
    predicate: Callable[[dict[str, Any]], bool],
    *,
    timeout_s: float = 8.0,
) -> dict[str, Any]:
    deadline = time.time() + timeout_s
    last_terminals: List[dict[str, Any]] = []
    while time.time() < deadline:
        last_terminals = _debug_terminals(c)
        for item in last_terminals:
            if predicate(item):
                return item
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for matching terminal state: {last_terminals!r}")


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        baseline_ws = _current_workspace(c)
        created_ws = ""
        try:
            created = _run_cli(cli, ["new-workspace"])
            _must(created.startswith("OK "), f"new-workspace expected OK response, got: {created}")
            created_ws = created.removeprefix("OK ").strip()
            _must(bool(created_ws), f"new-workspace returned no workspace id: {created}")
            created_ws = _resolve_workspace_handle(c, created_ws)
            _must(bool(created_ws), f"new-workspace returned an unresolvable workspace handle: {created}")
            _must(_current_workspace(c) == baseline_ws, "new-workspace should not switch selected workspace")

            created_terminal = _wait_for_terminal(
                c,
                lambda item: (
                    str(item.get("workspace_id") or "") == created_ws
                    and bool(item.get("hosted_view_in_window"))
                ),
            )
            _must(
                not bool(created_terminal.get("hosted_view_visible_in_ui")),
                f"Background workspace terminal should not be visible_in_ui: {created_terminal!r}",
            )
            _must(
                bool(created_terminal.get("hosted_view_hidden_or_ancestor_hidden")),
                f"Background workspace terminal should stay hidden while priming: {created_terminal!r}",
            )

            visible_baseline = _wait_for_terminal(
                c,
                lambda item: (
                    str(item.get("workspace_id") or "") == baseline_ws
                    and bool(item.get("workspace_selected"))
                    and bool(item.get("hosted_view_visible_in_ui"))
                    and not bool(item.get("hosted_view_hidden_or_ancestor_hidden"))
                ),
            )
            _must(
                str(visible_baseline.get("workspace_id") or "") == baseline_ws,
                f"Selected workspace terminal should remain visible: {visible_baseline!r}",
            )
        finally:
            if created_ws:
                try:
                    c.close_workspace(created_ws)
                except Exception:
                    pass

    print("PASS: CLI new-workspace primes its terminal in the background without exposing it in the portal")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
