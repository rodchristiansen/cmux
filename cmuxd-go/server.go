package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/coder/websocket"
)

// Client represents a connected WebSocket client.
type Client struct {
	conn *websocket.Conn
	mu   sync.Mutex
	id   uint32
}

// SendText sends a JSON text message to the client.
func (c *Client) SendText(ctx context.Context, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.conn.Write(ctx, websocket.MessageText, data)
}

// SendBinary sends a binary message to the client.
func (c *Client) SendBinary(ctx context.Context, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.conn.Write(ctx, websocket.MessageBinary, data)
}

// SendPtyData sends PTY output with a 4-byte LE session ID prefix.
func (c *Client) SendPtyData(ctx context.Context, sessionID uint32, data []byte) {
	buf := make([]byte, 4+len(data))
	binary.LittleEndian.PutUint32(buf[:4], sessionID)
	copy(buf[4:], data)
	c.SendBinary(ctx, buf)
}

// Server holds all shared state.
type Server struct {
	mu             sync.Mutex
	sessions       *SessionManager
	clients        []*Client
	nextClientID   uint32
	terminalConfig json.RawMessage // pre-serialized JSON
}

func NewServer() *Server {
	return &Server{
		sessions:     NewSessionManager(),
		clients:      nil,
		nextClientID: 1,
	}
}

func (s *Server) AddClient(c *Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clients = append(s.clients, c)
}

func (s *Server) RemoveClient(c *Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, cl := range s.clients {
		if cl == c {
			s.clients = append(s.clients[:i], s.clients[i+1:]...)
			return
		}
	}
}

// Broadcast sends a text message to all connected clients.
// Must be called with s.mu held.
func (s *Server) Broadcast(ctx context.Context, msg []byte) {
	for _, c := range s.clients {
		c.SendText(ctx, msg)
	}
}

// BroadcastPtyOutput sends PTY data to all connected clients.
func (s *Server) BroadcastPtyOutput(ctx context.Context, sessionID uint32, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.clients {
		c.SendPtyData(ctx, sessionID, data)
	}
}

// CreateSession creates a new session and starts its reader goroutine.
func (s *Server) CreateSession(cols, rows uint16) (*Session, error) {
	sess, err := s.sessions.Create(cols, rows)
	if err != nil {
		return nil, err
	}
	// Start PTY reader goroutine with background context so it outlives
	// the initial client's request context.
	go s.ptyReader(sess)
	return sess, nil
}

// DestroySession removes and kills a session.
func (s *Server) DestroySession(sessionID uint32) {
	sess := s.sessions.Remove(sessionID)
	if sess != nil {
		sess.Kill()
	}
}

// BuildWorkspaceJSON builds the workspace JSON from current sessions.
func (s *Server) BuildWorkspaceJSON() string {
	ids := s.sessions.IDs()
	return BuildWorkspaceJSON(ids)
}

// BroadcastWorkspaceUpdate sends a workspace_update to all clients.
func (s *Server) BroadcastWorkspaceUpdate(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	wj := BuildWorkspaceJSON(s.sessions.IDs())
	msg, _ := json.Marshal(map[string]interface{}{
		"type":      "workspace_update",
		"workspace": json.RawMessage(wj),
	})
	s.Broadcast(ctx, msg)
}

// ptyReader reads from a PTY and broadcasts output to all mux clients.
func (s *Server) ptyReader(sess *Session) {
	ctx := context.Background()
	buf := make([]byte, 8192)
	for sess.alive.Load() {
		n, err := sess.ptmx.Read(buf)
		if err != nil || n == 0 {
			break
		}
		data := buf[:n]
		// Store in ring buffer for attach snapshots
		sess.ring.Write(data)
		// Broadcast to all clients
		s.BroadcastPtyOutput(ctx, sess.ID, data)
	}
	// Session died — notify clients
	msg := fmt.Sprintf(`{"type":"session_exited","sessionId":%d}`, sess.ID)
	s.mu.Lock()
	s.Broadcast(ctx, []byte(msg))
	s.mu.Unlock()
}
