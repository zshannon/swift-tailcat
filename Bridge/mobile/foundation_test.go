package mobile

import (
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"
)

type foundationListener struct {
	closed chan struct{}
	once   sync.Once
}

func (l *foundationListener) Accept() (net.Conn, error) { <-l.closed; return nil, net.ErrClosed }
func (l *foundationListener) Addr() net.Addr            { return &net.TCPAddr{} }
func (l *foundationListener) Close() error              { l.once.Do(func() { close(l.closed) }); return nil }

func TestAbortResourceSynchronouslyInterruptsListener(t *testing.T) {
	r := NewRuntime()
	listener := &foundationListener{closed: make(chan struct{})}
	r.resources[1] = &resource{value: &listenerResource{ln: listener}}
	r.AbortResource(1)
	select {
	case <-listener.closed:
	default:
		t.Fatal("listener was not interrupted synchronously")
	}
}

func TestAbortResourceInterruptsAlreadyClosingDescendants(t *testing.T) {
	r := NewRuntime()
	local, peer := net.Pipe()
	defer peer.Close()
	defer local.Close()
	r.resources[1] = &resource{close: func() error { return nil }}
	r.closing[2] = &closingResource{entry: &resource{parent: 1, value: &connectionResource{c: local}}}
	r.AbortResource(1)
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	_, err := peer.Read(make([]byte, 1))
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("already-closing child transport was not interrupted")
	}
}

func TestSynchronousRootGeneration(t *testing.T) {
	identity, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal([]byte(identity), &value); err != nil {
		t.Fatal(err)
	}
	if value["Private"] == nil || value["Public"] == nil {
		t.Fatal("identity fields missing")
	}
	key, err := GeneratePresharedKey()
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(key), &value); err != nil {
		t.Fatal(err)
	}
	if value["key"] == "" || value["isZero"] != false {
		t.Fatal("invalid generated key")
	}
}

func TestRequestShutdownDoesNotJoinBlockedCleanup(t *testing.T) {
	r := NewRuntime()
	entered := make(chan struct{})
	release := make(chan struct{})
	r.resources[1] = &resource{close: func() error { close(entered); <-release; return nil }}
	requested := make(chan struct{})
	go func() { r.RequestShutdown(); close(requested) }()
	select {
	case <-requested:
	case <-time.After(time.Second):
		t.Fatal("shutdown joined cleanup")
	}
	<-entered
	joined := make(chan struct{})
	go func() { _ = r.Close(); close(joined) }()
	select {
	case <-joined:
		t.Fatal("close returned before cleanup")
	default:
	}
	close(release)
	select {
	case <-joined:
	case <-time.After(time.Second):
		t.Fatal("close did not join cleanup")
	}
}
