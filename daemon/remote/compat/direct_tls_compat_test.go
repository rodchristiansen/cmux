package compat

import (
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/internal/auth"
)

func TestDirectTLSRejectsExpiredTicket(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(-time.Minute).Unix(),
		Nonce:        "expired-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign expired ticket: %v", err)
	}

	handshake := runDirectTLSHandshake(t, server, token)
	if ok, _ := handshake["ok"].(bool); ok {
		t.Fatalf("expected expired ticket handshake to fail: %+v", handshake)
	}
}

func TestDirectTLSRejectsReplayedNonce(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "replayed-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign replay ticket: %v", err)
	}

	first := runDirectTLSHandshake(t, server, token)
	if ok, _ := first["ok"].(bool); !ok {
		t.Fatalf("first handshake should succeed: %+v", first)
	}

	second := runDirectTLSHandshake(t, server, token)
	if ok, _ := second["ok"].(bool); ok {
		t.Fatalf("expected replayed nonce handshake to fail: %+v", second)
	}
}

func TestDirectTLSSessionScopeIsEnforced(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		Capabilities: []string{"session.open"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "scope-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign scope ticket: %v", err)
	}

	openReq := map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "printf READY; stty raw -echo -onlcr; exec cat",
			"cols":    120,
			"rows":    40,
		},
	}
	openResp, resizeResp := runDirectTLSHandshakeAndRequest(t, server, token, openReq, func(open map[string]any) map[string]any {
		result := open["result"].(map[string]any)
		return map[string]any{
			"id":     2,
			"method": "session.resize",
			"params": map[string]any{
				"session_id":    "sess-999",
				"attachment_id": result["attachment_id"].(string),
				"cols":          100,
				"rows":          30,
			},
		}
	})

	if ok, _ := openResp["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", openResp)
	}
	if ok, _ := resizeResp["ok"].(bool); ok {
		t.Fatalf("expected session scope escape to fail: %+v", resizeResp)
	}
}
