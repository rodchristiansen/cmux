#!/usr/bin/env bash
set -euo pipefail

# Export the current cmux workspace layout (sections + directories) to a portable JSON file.
# Usage: ./scripts/workspace-export.sh [output-file]
#   Default output: ~/.config/cmux/workspace-set.json

OUTPUT="${1:-$HOME/.config/cmux/workspace-set.json}"
SESSION_DIR="$HOME/Library/Application Support/cmux"
SESSION_FILE="$SESSION_DIR/session-com.cmuxterm.app.json"

if [ ! -f "$SESSION_FILE" ]; then
  echo "ERROR: No session file found at $SESSION_FILE" >&2
  echo "Make sure cmux (release build) has been run at least once." >&2
  exit 1
fi

python3 -c "
import json, sys, os

session = json.load(open(sys.argv[1]))
window = session.get('windows', [{}])[0]
tm = window.get('tabManager', {})
workspaces = tm.get('workspaces', [])
sections = tm.get('sections', [])

# Build workspace lookup: id -> portable info
ws_map = {}
for ws in workspaces:
    ws_id = ws.get('id', '')
    directory = ws.get('currentDirectory', '') or '~'
    # Collapse home directory to ~
    home = os.path.expanduser('~')
    if directory.startswith(home):
        directory = '~' + directory[len(home):]
    ws_map[ws_id] = {
        'name': ws.get('processTitle') or ws.get('customTitle') or os.path.basename(directory),
        'directory': directory,
    }
    if ws.get('customColor'):
        ws_map[ws_id]['color'] = ws['customColor']
    if ws.get('customDescription'):
        ws_map[ws_id]['description'] = ws['customDescription']
    if ws.get('isPinned'):
        ws_map[ws_id]['pinned'] = True

# Collect workspace IDs that belong to a section
sectioned_ids = set()
exported_sections = []
for section in sections:
    sec_workspaces = []
    for ws_id in section.get('workspaceIds', []):
        if ws_id in ws_map:
            sec_workspaces.append(ws_map[ws_id])
            sectioned_ids.add(ws_id)
    exported_sections.append({
        'name': section.get('name', 'Untitled'),
        'collapsed': section.get('isCollapsed', False),
        'workspaces': sec_workspaces,
    })

# Unsectioned workspaces
unsectioned = [ws_map[ws_id] for ws_id in ws_map if ws_id not in sectioned_ids]

result = {}
if exported_sections:
    result['sections'] = exported_sections
if unsectioned:
    result['workspaces'] = unsectioned

output_path = sys.argv[2]
os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, 'w') as f:
    json.dump(result, f, indent=2)
print(f'Exported {len(ws_map)} workspaces ({len(exported_sections)} sections) to {output_path}')
" "$SESSION_FILE" "$OUTPUT"
