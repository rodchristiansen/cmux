package main

import (
	"fmt"
	"sort"
	"strings"
)

// BuildWorkspaceJSON builds the workspace JSON tree from session IDs.
// Matches the Zig implementation's balanced binary tree format.
func BuildWorkspaceJSON(sessionIDs []uint32) string {
	sort.Slice(sessionIDs, func(i, j int) bool { return sessionIDs[i] < sessionIDs[j] })

	var b strings.Builder

	if len(sessionIDs) == 0 {
		b.WriteString(`{"root":{"type":"leaf","id":"g0"},`)
		b.WriteString(`"groups":{"g0":{"id":"g0","tabs":[],"activeTabId":""}},`)
		b.WriteString(`"focusedGroupId":"g0"}`)
		return b.String()
	}

	if len(sessionIDs) == 1 {
		sid := sessionIDs[0]
		b.WriteString(fmt.Sprintf(`{"root":{"type":"leaf","id":"g%d"},`, sid))
		b.WriteString(fmt.Sprintf(`"groups":{"g%d":{"id":"g%d","tabs":[{"id":"t%d","title":"Terminal","type":"terminal","sessionId":%d}],"activeTabId":"t%d"}},`, sid, sid, sid, sid, sid))
		b.WriteString(fmt.Sprintf(`"focusedGroupId":"g%d"}`, sid))
		return b.String()
	}

	// Multiple sessions: balanced binary tree of horizontal splits
	b.WriteString(`{"root":`)
	buildTreeJSON(&b, sessionIDs, 0)
	b.WriteString(`,"groups":{`)
	for i, sid := range sessionIDs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(fmt.Sprintf(`"g%d":{"id":"g%d","tabs":[{"id":"t%d","title":"Terminal","type":"terminal","sessionId":%d}],"activeTabId":"t%d"}`, sid, sid, sid, sid, sid))
	}
	b.WriteString(fmt.Sprintf(`},"focusedGroupId":"g%d"}`, sessionIDs[0]))
	return b.String()
}

func buildTreeJSON(b *strings.Builder, ids []uint32, splitID uint32) {
	if len(ids) == 1 {
		b.WriteString(fmt.Sprintf(`{"type":"leaf","id":"g%d"}`, ids[0]))
		return
	}
	mid := len(ids) / 2
	b.WriteString(fmt.Sprintf(`{"type":"split","id":"s%d","direction":"horizontal","ratio":0.5,"left":`, splitID))
	buildTreeJSON(b, ids[:mid], splitID*2+1)
	b.WriteString(`,"right":`)
	buildTreeJSON(b, ids[mid:], splitID*2+2)
	b.WriteByte('}')
}
