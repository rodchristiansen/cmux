#!/usr/bin/env python3
"""Regression test for workspace.create focus=false semantics.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_hidden_workspace_row(client: cmux, workspace_id: str, timeout_s: float = 8.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = client.panel_lifecycle()
        last_snapshot = snapshot
        row = next(
            (
                row
                for row in list(snapshot.get("records") or [])
                if row.get("workspaceId") == workspace_id and row.get("panelType") == "terminal"
            ),
            None,
        )
        if row and row.get("selectedWorkspace") is False and row.get("activeWindowMembership") is False:
            return dict(row)
        time.sleep(0.05)
    raise cmuxError(f"timed out waiting for hidden workspace row: {last_snapshot}")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        original_workspace_id = client.current_workspace()
        original_window_id = client.current_window()

        surfaces = client.list_surfaces()
        focused_surface = next((row for row in surfaces if row[2]), None)
        _must(focused_surface is not None, "missing focused surface")
        focused_surface_id = focused_surface[1]

        created = client._call(
            "workspace.create",
            {
                "window_id": original_window_id,
                "workspace_id": original_workspace_id,
                "surface_id": focused_surface_id,
                "focus": False,
            },
        ) or {}
        hidden_workspace_id = created.get("workspace_id")
        _must(isinstance(hidden_workspace_id, str) and hidden_workspace_id, f"workspace.create returned no workspace_id: {created}")

        _must(
            client.current_workspace() == original_workspace_id,
            f"workspace.create focus=false should keep original workspace selected, got {client.current_workspace()} expected {original_workspace_id}",
        )
        _must(
            client.current_window() == original_window_id,
            f"workspace.create focus=false should keep original window selected, got {client.current_window()} expected {original_window_id}",
        )

        hidden_row = _wait_for_hidden_workspace_row(client, hidden_workspace_id)
        _must(hidden_row.get("selectedWorkspace") is False, f"hidden workspace should not be selected: {hidden_row}")
        _must(hidden_row.get("activeWindowMembership") is False, f"hidden workspace should not be visible in active window: {hidden_row}")

    print("PASS: workspace.create focus=false preserves selected workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
