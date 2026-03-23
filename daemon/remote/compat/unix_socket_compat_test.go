package compat

import (
	"testing"
)

func TestHelloFixtureAgainstUnixSocketBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	client := newUnixJSONRPCClient(t, socketPath)
	resp := client.Call(t, map[string]any{
		"id":     "1",
		"method": "hello",
		"params": map[string]any{},
	})

	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("hello should succeed: %+v", resp)
	}
}

func TestTerminalEchoFixtureAgainstUnixSocketBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id": "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "dev",
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
			"session_id": "dev",
			"data":       "aGVsbG8K",
		},
	})
	if ok, _ := write["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", write)
	}
}

func TestUnixSocketAttachReportsNormalizedTinyTerminalWidth(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id": "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "dev",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	write1 := client.Call(t, map[string]any{
		"id": "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": "dev",
			"data":       "aGVsbG8K",
		},
	})
	if ok, _ := write1["ok"].(bool); !ok {
		t.Fatalf("initial terminal.write should succeed: %+v", write1)
	}

	read1 := client.Call(t, map[string]any{
		"id": "3",
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": "dev",
			"offset":     0,
			"max_bytes":  1024,
			"timeout_ms": 1000,
		},
	})
	if ok, _ := read1["ok"].(bool); !ok {
		t.Fatalf("initial terminal.read should succeed: %+v", read1)
	}

	attach := client.Call(t, map[string]any{
		"id": "4",
		"method": "session.attach",
		"params": map[string]any{
			"session_id":    "dev",
			"attachment_id": "cli-1",
			"cols":          1,
			"rows":          1,
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("session.attach should succeed: %+v", attach)
	}

	result, _ := attach["result"].(map[string]any)
	if got := int(result["effective_cols"].(float64)); got != 2 {
		t.Fatalf("effective_cols = %d, want 2 after clamping: %+v", got, attach)
	}
}
