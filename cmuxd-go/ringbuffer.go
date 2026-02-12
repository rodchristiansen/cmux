package main

import "sync"

const defaultRingSize = 128 * 1024 // 128KB

// RingBuffer is a fixed-size circular buffer for capturing PTY output.
// On attach, the buffered data is replayed to the new client as a snapshot.
type RingBuffer struct {
	mu   sync.Mutex
	buf  []byte
	pos  int  // next write position
	full bool // true once we've wrapped around
}

func NewRingBuffer(size int) *RingBuffer {
	return &RingBuffer{buf: make([]byte, size)}
}

// Write appends data to the ring buffer.
func (r *RingBuffer) Write(data []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	for len(data) > 0 {
		n := copy(r.buf[r.pos:], data)
		data = data[n:]
		r.pos += n
		if r.pos >= len(r.buf) {
			r.pos = 0
			r.full = true
		}
	}
}

// Snapshot returns a copy of the buffered data in order.
func (r *RingBuffer) Snapshot() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.full {
		out := make([]byte, r.pos)
		copy(out, r.buf[:r.pos])
		return out
	}
	// Wrapped: [pos..end] then [0..pos]
	out := make([]byte, len(r.buf))
	n := copy(out, r.buf[r.pos:])
	copy(out[n:], r.buf[:r.pos])
	return out
}
