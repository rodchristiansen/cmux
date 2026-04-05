#!/usr/bin/env bash
set -euo pipefail

# Import a workspace set into cmux, creating workspaces and sidebar sections.
# Usage: ./scripts/workspace-import.sh [input-file]
#   Default input: ~/.config/cmux/workspace-set.json
#
# This replaces the current session file and restarts cmux.
# Your current workspaces will be replaced by the imported set.

INPUT="${1:-$HOME/.config/cmux/workspace-set.json}"
SESSION_DIR="$HOME/Library/Application Support/cmux"
SESSION_FILE="$SESSION_DIR/session-com.cmuxterm.app.json"

if [ ! -f "$INPUT" ]; then
  echo "ERROR: Workspace set file not found: $INPUT" >&2
  echo "Export one first with: ./scripts/workspace-export.sh" >&2
  exit 1
fi

# Back up existing session
if [ -f "$SESSION_FILE" ]; then
  cp "$SESSION_FILE" "$SESSION_FILE.bak"
  echo "Backed up existing session to session-com.cmuxterm.app.json.bak"
fi

python3 -c "
import json, sys, os, uuid, time

workspace_set = json.load(open(sys.argv[1]))
home = os.path.expanduser('~')

def expand_dir(d):
    if d.startswith('~'):
        return home + d[1:]
    return d

def make_panel_id():
    return str(uuid.uuid4()).upper()

def make_workspace(name, directory, color=None, description=None, pinned=False):
    ws_id = str(uuid.uuid4()).upper()
    panel_id = make_panel_id()
    full_dir = expand_dir(directory)
    ws = {
        'id': ws_id,
        'processTitle': name,
        'currentDirectory': full_dir,
        'isPinned': pinned,
        'focusedPanelId': panel_id,
        'layout': {
            'type': 'pane',
            'pane': {
                'panelIds': [panel_id],
                'selectedPanelId': panel_id,
            },
        },
        'panels': [{
            'id': panel_id,
            'type': 'terminal',
            'title': name,
            'isPinned': False,
            'isManuallyUnread': False,
            'listeningPorts': [],
            'directory': full_dir,
            'terminal': {
                'workingDirectory': full_dir,
            },
        }],
        'statusEntries': [],
        'logEntries': [],
    }
    if color:
        ws['customColor'] = color
    if description:
        ws['customDescription'] = description
    return ws_id, ws

all_workspaces = []
all_sections = []

# Process sections
for section in workspace_set.get('sections', []):
    ws_ids = []
    for ws_def in section.get('workspaces', []):
        ws_id, ws = make_workspace(
            ws_def['name'],
            ws_def['directory'],
            ws_def.get('color'),
            ws_def.get('description'),
            ws_def.get('pinned', False),
        )
        all_workspaces.append(ws)
        ws_ids.append(ws_id)
    all_sections.append({
        'id': str(uuid.uuid4()).upper(),
        'name': section['name'],
        'isCollapsed': section.get('collapsed', False),
        'workspaceIds': ws_ids,
    })

# Process unsectioned workspaces
for ws_def in workspace_set.get('workspaces', []):
    ws_id, ws = make_workspace(
        ws_def['name'],
        ws_def['directory'],
        ws_def.get('color'),
        ws_def.get('description'),
        ws_def.get('pinned', False),
    )
    all_workspaces.append(ws)

# Build session snapshot
session = {
    'version': 1,
    'createdAt': time.time(),
    'windows': [{
        'frame': {'x': 100, 'y': 100, 'width': 1400, 'height': 900},
        'display': {
            'displayID': 1,
            'frame': {'x': 0, 'y': 0, 'width': 2560, 'height': 1440},
            'visibleFrame': {'x': 0, 'y': 0, 'width': 2560, 'height': 1410},
        },
        'sidebar': {
            'isVisible': True,
            'width': 300,
            'selection': 'tabs',
        },
        'tabManager': {
            'selectedWorkspaceIndex': 0,
            'workspaces': all_workspaces,
            'sections': all_sections if all_sections else None,
        },
    }],
}

# Remove None values
if session['windows'][0]['tabManager']['sections'] is None:
    del session['windows'][0]['tabManager']['sections']

output_path = sys.argv[2]
os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, 'w') as f:
    json.dump(session, f, indent=2)

total_ws = len(all_workspaces)
total_sec = len(all_sections)
print(f'Imported {total_ws} workspaces ({total_sec} sections) into session file')
" "$INPUT" "$SESSION_FILE"

# Restart cmux to pick up the new session
echo "Restarting cmux..."
pkill -x cmux 2>/dev/null || true
sleep 1
open /Applications/cmux.app
echo "Done! cmux launched with imported workspace set."
