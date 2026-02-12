package main

import "encoding/json"

// --- Client → Server messages ---

type CreateSessionMsg struct {
	Type string `json:"type"` // "create_session"
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

type DestroySessionMsg struct {
	Type      string `json:"type"` // "destroy_session"
	SessionID uint32 `json:"sessionId"`
}

type ResizeMsg struct {
	Type      string `json:"type"` // "resize"
	SessionID uint32 `json:"sessionId"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
}

type AttachSessionMsg struct {
	Type      string `json:"type"` // "attach_session"
	SessionID uint32 `json:"sessionId"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
}

type DetachSessionMsg struct {
	Type      string `json:"type"` // "detach_session"
	SessionID uint32 `json:"sessionId"`
}

type SetSessionModeMsg struct {
	Type      string `json:"type"` // "set_session_mode"
	SessionID uint32 `json:"sessionId"`
	Mode      string `json:"mode"` // "shared" or "single_driver"
}

type RequestDriverMsg struct {
	Type      string `json:"type"` // "request_driver"
	SessionID uint32 `json:"sessionId"`
}

type ReleaseDriverMsg struct {
	Type      string `json:"type"` // "release_driver"
	SessionID uint32 `json:"sessionId"`
}

// --- Server → Client messages ---

type WorkspaceSnapshotMsg struct {
	Type             string           `json:"type"` // "workspace_snapshot"
	Workspace        json.RawMessage  `json:"workspace"`
	InitialSessionID uint32           `json:"initialSessionId"`
	ClientID         uint32           `json:"clientId"`
	TerminalConfig   *json.RawMessage `json:"terminalConfig,omitempty"`
}

type WorkspaceUpdateMsg struct {
	Type      string          `json:"type"` // "workspace_update"
	Workspace json.RawMessage `json:"workspace"`
}

type SessionCreatedMsg struct {
	Type      string `json:"type"` // "session_created"
	SessionID uint32 `json:"sessionId"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
}

type SessionDestroyedMsg struct {
	Type      string `json:"type"` // "session_destroyed"
	SessionID uint32 `json:"sessionId"`
}

type SessionExitedMsg struct {
	Type      string `json:"type"` // "session_exited"
	SessionID uint32 `json:"sessionId"`
}

type SessionAttachedMsg struct {
	Type      string `json:"type"` // "session_attached"
	SessionID uint32 `json:"sessionId"`
}

type SessionResizedMsg struct {
	Type      string `json:"type"` // "session_resized"
	SessionID uint32 `json:"sessionId"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
}

type ClientJoinedMsg struct {
	Type     string `json:"type"` // "client_joined"
	ClientID uint32 `json:"clientId"`
}

type ClientLeftMsg struct {
	Type     string `json:"type"` // "client_left"
	ClientID uint32 `json:"clientId"`
}

type DriverChangedMsg struct {
	Type      string  `json:"type"` // "driver_changed"
	SessionID uint32  `json:"sessionId"`
	DriverID  *uint32 `json:"driverId"` // null = no driver
	Mode      string  `json:"mode,omitempty"`
}

type ErrorMsg struct {
	Type      string `json:"type"` // "error"
	Message   string `json:"message"`
	SessionID uint32 `json:"sessionId,omitempty"`
}

// GenericMsg is used to extract just the type field for dispatch.
type GenericMsg struct {
	Type string `json:"type"`
}

// LegacyResizeMsg is the resize message in legacy mode (no sessionId).
type LegacyResizeMsg struct {
	Type string `json:"type"`
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}
