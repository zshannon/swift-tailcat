package mobile

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"
)

type progressConn struct {
	net.Conn
	operation  *Operation
	writeError error
}

func (c *progressConn) Read(p []byte) (int, error)  { p[0] = 9; c.operation.Cancel(); return 1, nil }
func (c *progressConn) Write(p []byte) (int, error) { c.operation.Cancel(); return 2, c.writeError }

func TestConsumedReadWinsCancellation(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	local, peer := net.Pipe()
	defer peer.Close()
	c := &progressConn{Conn: local}
	r.resources[1] = &resource{value: &connectionResource{c: c}, close: local.Close}
	op := r.NewOperation()
	c.operation = op
	cb := make(callback, 1)
	op.Begin("connection.read", `{"handle":1,"count":4}`, cb)
	a := await(t, cb)
	if a.code != 0 {
		t.Fatalf("consumed bytes lost: %+v", a)
	}
}
func TestPartialWritePreservesProgressAndGenuineCause(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	local, peer := net.Pipe()
	defer peer.Close()
	c := &progressConn{Conn: local, writeError: errors.New("genuine write failure")}
	r.resources[1] = &resource{value: &connectionResource{c: c}, close: local.Close}
	op := r.NewOperation()
	c.operation = op
	cb := make(callback, 1)
	op.Begin("connection.write", `{"handle":1,"data":"YWJjZA=="}`, cb)
	a := await(t, cb)
	if a.code != 0 || a.result != `{"count":2,"writeErrorCode":5,"writeErrorMessage":"genuine write failure"}` {
		t.Fatalf("partial progress/cause lost: %+v", a)
	}
}

// The second primitive consumes no bytes after the first primitive's progress.
type laterWriteFailureConn struct {
	net.Conn
	operation *Operation
	writes    int
}

func (c *laterWriteFailureConn) Write(p []byte) (int, error) {
	c.writes++
	if c.writes == 1 {
		return 2, nil
	}
	c.operation.Cancel()
	return 0, errors.New("genuine second-write failure")
}

func TestCompleteWritePreservesLaterZeroProgressCause(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	local, peer := net.Pipe()
	defer peer.Close()
	c := &laterWriteFailureConn{Conn: local}
	r.resources[1] = &resource{value: &connectionResource{c: c}, close: local.Close}
	first := r.NewOperation()
	c.operation = first
	cb := make(callback, 1)
	first.Begin("connection.write", `{"handle":1,"data":"YWJjZA=="}`, cb)
	a := await(t, cb)
	if a.code != 0 || a.result != `{"count":2}` {
		t.Fatalf("first progress: %+v", a)
	}
	second := r.NewOperation()
	c.operation = second
	second.Begin("connection.write", `{"handle":1,"data":"Y2Q="}`, cb)
	a = await(t, cb)
	if a.code != 5 || a.message != "genuine second-write failure" {
		t.Fatalf("genuine error after earlier progress replaced: %+v", a)
	}
	if c.writes != 2 {
		t.Fatalf("write replayed: %d calls", c.writes)
	}
}

type pendingWriteConn struct {
	net.Conn
	entered     chan struct{}
	once        sync.Once
	wrapTimeout bool
}

func (c *pendingWriteConn) Write(p []byte) (int, error) {
	c.once.Do(func() { close(c.entered) })
	n, err := c.Conn.Write(p)
	if err != nil && c.wrapTimeout {
		return n, &net.OpError{Op: "write", Err: &writeDeadlineError{}}
	}
	return n, err
}

// Mirrors the custom net.Error deadline returned by the retained gVisor stream.
type writeDeadlineError struct{}

func (*writeDeadlineError) Error() string   { return "i/o timeout" }
func (*writeDeadlineError) Temporary() bool { return true }
func (*writeDeadlineError) Timeout() bool   { return true }

func TestCancellationOnlyWriteRestoresDeadline(t *testing.T) {
	t.Run("standard", func(t *testing.T) { cancellationOnlyWrite(t, false) })
	t.Run("custom", func(t *testing.T) { cancellationOnlyWrite(t, true) })
}

func cancellationOnlyWrite(t *testing.T, wrapTimeout bool) {
	r := NewRuntime()
	defer r.Close()
	local, peer := net.Pipe()
	defer peer.Close()
	c := &pendingWriteConn{Conn: local, entered: make(chan struct{}), wrapTimeout: wrapTimeout}
	r.resources[1] = &resource{value: &connectionResource{c: c}, close: local.Close}
	op, cb := begin(r, "connection.write", map[string]any{"handle": 1, "data": []byte("blocked")})
	select {
	case <-c.entered:
	case <-time.After(time.Second):
		t.Fatal("write did not enter provider")
	}
	op.Cancel()
	if a := await(t, cb); a.code != 2 {
		t.Fatalf("cancellation-only write: %+v", a)
	}
	received := make(chan error, 1)
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	go func() {
		data := make([]byte, 1)
		n, err := peer.Read(data)
		if err == nil && (n != 1 || data[0] != 'x') {
			err = errors.New("wrong post-cancellation byte")
		}
		received <- err
	}()
	result := successful(t, r, "connection.write", map[string]any{"handle": 1, "data": []byte("x")})
	if result["count"] != float64(1) {
		t.Fatalf("write deadline not restored: %+v", result)
	}
	if err := <-received; err != nil {
		t.Fatal(err)
	}
}
