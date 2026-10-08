package mobile

import (
	"context"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// A resource-close operation must execute and join real cleanup even if its
// cancellation signal arrives before Begin or while cleanup is underway.
func TestResourceCloseReportsActualOutcomeAcrossCancellation(t *testing.T) {
	for _, timing := range []string{"before-begin", "during-close", "runtime-shutdown"} {
		for _, outcome := range []struct {
			name string
			err  error
		}{{"success", nil}, {"failure", errors.New("genuine cleanup failure")}, {"provider-cancellation", context.Canceled}} {
			t.Run(timing+"/"+outcome.name, func(t *testing.T) {
				r := NewRuntime()
				defer r.Close()
				entered, release := make(chan struct{}), make(chan struct{})
				defer func() {
					select {
					case <-release:
					default:
						close(release)
					}
				}()
				var calls atomic.Int32
				r.resources[1] = &resource{value: struct{}{}, close: func() error {
					calls.Add(1)
					close(entered)
					<-release
					return outcome.err
				}}
				op := r.NewOperation()
				if timing == "before-begin" {
					op.Cancel()
				}
				cb := make(callback, 1)
				op.Begin("resource.close", `{"handle":1}`, cb)
				select {
				case <-entered:
				case a := <-cb:
					t.Fatalf("close skipped its resource cleanup: %+v", a)
				case <-time.After(time.Second):
					t.Fatal("cleanup did not start")
				}
				switch timing {
				case "during-close":
					op.Cancel()
				case "runtime-shutdown":
					r.RequestShutdown()
				}
				select {
				case a := <-cb:
					t.Fatalf("close did not join cleanup: %+v", a)
				default:
				}
				close(release)
				wantCode, wantMessage := errorCode(outcome.err)
				if a := awaitPromptly(t, cb); a.code != wantCode || a.message != wantMessage {
					t.Fatalf("actual cleanup outcome lost: got %+v, want %d %q", a, wantCode, wantMessage)
				}
				first, second := r.Close(), r.Close()
				if outcome.err == nil && (first != nil || second != nil) {
					t.Fatalf("successful cleanup poisoned shutdown: %v / %v", first, second)
				}
				if errorText(first) != errorText(second) {
					t.Fatalf("joined shutdown changed outcome: %v / %v", first, second)
				}
				if calls.Load() != 1 {
					t.Fatalf("cleanup executed %d times", calls.Load())
				}
			})
		}
	}
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

type cleanupReadConn struct {
	net.Conn
	entered chan struct{}
}

func (c *cleanupReadConn) Read(p []byte) (int, error) { close(c.entered); return c.Conn.Read(p) }

type cleanupListener struct {
	foundationListener
	entered chan struct{}
}

func (l *cleanupListener) Accept() (net.Conn, error) {
	close(l.entered)
	return l.foundationListener.Accept()
}

func TestShutdownInterruptsIOWhileJoiningCleanup(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	r.resources[1] = &resource{value: struct{}{}, close: func() error { close(entered); <-release; return nil }}
	_, closing := begin(r, "resource.close", map[string]any{"handle": 1})
	<-entered
	localRead, peerRead := net.Pipe()
	defer peerRead.Close()
	reader := &cleanupReadConn{Conn: localRead, entered: make(chan struct{})}
	r.resources[2] = &resource{value: &connectionResource{c: reader}, close: reader.Close}
	localWrite, peerWrite := net.Pipe()
	defer peerWrite.Close()
	writer := &pendingWriteConn{Conn: localWrite, entered: make(chan struct{})}
	r.resources[3] = &resource{value: &connectionResource{c: writer}, close: writer.Close}
	listener := &cleanupListener{foundationListener: foundationListener{closed: make(chan struct{})}, entered: make(chan struct{})}
	r.resources[4] = &resource{value: &listenerResource{ln: listener}, close: listener.Close}
	_, read := begin(r, "connection.read", map[string]any{"handle": 2, "count": 1})
	_, write := begin(r, "connection.write", map[string]any{"handle": 3, "data": []byte("blocked")})
	_, accept := begin(r, "listener.accept", map[string]any{"handle": 4})
	for _, ready := range []chan struct{}{reader.entered, writer.entered, listener.entered} {
		select {
		case <-ready:
		case <-time.After(time.Second):
			t.Fatal("ordinary I/O did not enter")
		}
	}
	r.RequestShutdown()
	for _, cb := range []callback{read, write, accept} {
		if a := awaitPromptly(t, cb); a.code != 2 && !(a.code == 5 && a.message == io.ErrClosedPipe.Error()) {
			t.Fatalf("ordinary operation was not interrupted: %+v", a)
		}
	}
	select {
	case a := <-closing:
		t.Fatalf("cleanup escaped its barrier: %+v", a)
	default:
	}
	close(release)
	if a := awaitPromptly(t, closing); a.code != 0 {
		t.Fatalf("joined cleanup failed: %+v", a)
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
}
