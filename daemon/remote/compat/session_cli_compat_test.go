package compat

import (
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestSessionCLIListAndHistory(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "dev", "hello\n")

	listCmd := exec.Command(bin, "session", "ls", "--socket", socketPath)
	listCmd.Dir = daemonRemoteRoot()
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session ls failed: %v\n%s", err, listOutput)
	}
	if !strings.Contains(string(listOutput), "dev") {
		t.Fatalf("session ls missing dev: %s", listOutput)
	}

	historyCmd := exec.Command(bin, "session", "history", "dev", "--socket", socketPath)
	historyCmd.Dir = daemonRemoteRoot()
	historyOutput, err := historyCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session history failed: %v\n%s", err, historyOutput)
	}
	if !strings.Contains(string(historyOutput), "hello") {
		t.Fatalf("session history missing hello: %s", historyOutput)
	}
}

func openAndSeedCatSession(t *testing.T, socketPath, sessionID, text string) {
	t.Helper()

	client := newUnixJSONRPCClient(t, socketPath)
	defer func() {
		if err := client.Close(); err != nil {
			t.Fatalf("close unix client: %v", err)
		}
	}()

	open := client.Call(t, map[string]any{
		"id": "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": sessionID,
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	write := client.Call(t, map[string]any{
		"id": "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": sessionID,
			"data":       "aGVsbG8K",
		},
	})
	if ok, _ := write["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", write)
	}

	_ = client.Call(t, map[string]any{
		"id": "3",
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": sessionID,
			"offset":     0,
			"max_bytes":  len(text) * 2,
			"timeout_ms": int((2 * time.Second).Milliseconds()),
		},
	})
}
