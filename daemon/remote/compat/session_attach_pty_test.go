package compat

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestSessionAttachRoundTripAndReattach(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	openAndSeedCatSession(t, socketPath, "dev", "")

	cmd := exec.Command(bin, "session", "attach", "dev", "--socket", socketPath)
	cmd.Dir = daemonRemoteRoot()
	ptmx, err := pty.Start(cmd)
	if err != nil {
		t.Fatalf("pty start attach: %v", err)
	}
	defer ptmx.Close()

	writePTY(t, ptmx, "hello\n")
	read1 := readUntilContains(t, ptmx, "hello", 3*time.Second)
	if !strings.Contains(read1, "hello") {
		t.Fatalf("attach output missing hello: %q", read1)
	}

	writePTY(t, ptmx, "\x1c")
	_ = cmd.Wait()

	second := exec.Command(bin, "session", "attach", "dev", "--socket", socketPath)
	second.Dir = daemonRemoteRoot()
	ptmx2, err := pty.Start(second)
	if err != nil {
		t.Fatalf("pty start reattach: %v", err)
	}
	defer ptmx2.Close()

	read2 := readUntilContains(t, ptmx2, "hello", 3*time.Second)
	if !strings.Contains(read2, "hello") {
		t.Fatalf("reattach missing prior output: %q", read2)
	}
}

func writePTY(t *testing.T, ptmx *os.File, text string) {
	t.Helper()
	if _, err := ptmx.WriteString(text); err != nil {
		t.Fatalf("write pty: %v", err)
	}
}

func readUntilContains(t *testing.T, ptmx *os.File, want string, timeout time.Duration) string {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var out strings.Builder
	buf := make([]byte, 4096)
	for time.Now().Before(deadline) {
		_ = ptmx.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, err := ptmx.Read(buf)
		if n > 0 {
			out.Write(buf[:n])
			if strings.Contains(out.String(), want) {
				return out.String()
			}
		}
		if err != nil {
			if n == 0 {
				continue
			}
		}
	}

	return out.String()
}
