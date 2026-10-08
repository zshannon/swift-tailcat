package mobile

import (
	"encoding/base64"
	"encoding/json"
	relayfixture "github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"os"
	"os/exec"
	"sync"
	"testing"
	"time"
)

type incoming struct {
	handle                 int64
	network, local, remote string
	forwarded              bool
}
type testHandler struct {
	calls  chan incoming
	accept bool
}

func (h *testHandler) Select(network, destination string, forwarded bool) bool { return h.accept }
func (h *testHandler) Connection(id int64, n, l, r string, f bool) bool {
	h.calls <- incoming{id, n, l, r, f}
	return h.accept
}

type testLogger struct {
	mu       sync.Mutex
	messages []string
}

func (l *testLogger) Log(id int64, m string) {
	l.mu.Lock()
	l.messages = append(l.messages, m)
	l.mu.Unlock()
}
func takeIncoming(t *testing.T, h *testHandler) incoming {
	t.Helper()
	select {
	case c := <-h.calls:
		return c
	case <-time.After(10 * time.Second):
		t.Fatal("no incoming handler callback")
		return incoming{}
	}
}
func TestIncomingHooksAndListenerOverrides(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	sid := handle(successful(t, r, "server.create", map[string]any{"region": relay.Map.Regions[1]}))
	h := &testHandler{calls: make(chan incoming, 8), accept: true}
	if e = r.SetHandler(sid, h); e != nil {
		t.Fatal(e)
	}
	log := &testLogger{}
	if e = r.SetLogger(sid, log); e != nil {
		t.Fatal(e)
	}
	successful(t, r, "server.start", map[string]any{"handle": sid})
	if e = r.SetHandler(sid, nil); e == nil {
		t.Fatal("late handler change accepted")
	}
	a := successful(t, r, "server.address", map[string]any{"handle": sid})
	cid := handle(successful(t, r, "client.create", map[string]any{"address": a["address"]}))
	successful(t, r, "client.ping", map[string]any{"handle": cid})
	for _, network := range []string{"tcp", "udp"} {
		remote := successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": network, "port": 8090})
		if network == "udp" {
			successful(t, r, "connection.write", map[string]any{"handle": handle(remote), "data": []byte("hello")})
		}
		got := takeIncoming(t, h)
		if got.network != network || got.forwarded {
			t.Fatalf("incoming %+v", got)
		}
		if network == "tcp" {
			successful(t, r, "connection.write", map[string]any{"handle": handle(remote), "data": []byte("hello")})
		}
		v := successful(t, r, "connection.read", map[string]any{"handle": got.handle, "count": 20})
		if v["data"] != base64.StdEncoding.EncodeToString([]byte("hello")) {
			t.Fatal("bad callback connection")
		}
	}
	for _, network := range []string{"tcp", "udp"} {
		remote := successful(t, r, "client.dialEndpoint", map[string]any{"handle": cid, "network": network, "address": "127.0.0.1:9876"})
		if network == "udp" {
			successful(t, r, "connection.write", map[string]any{"handle": handle(remote), "data": []byte("hello")})
		}
		got := takeIncoming(t, h)
		if !got.forwarded || got.network != network {
			t.Fatalf("forward hook %+v", got)
		}
	}
	makePair(t, r, sid, cid, "tcp")
	select {
	case got := <-h.calls:
		t.Fatalf("listener did not override hook: %+v", got)
	default:
	}
	log.mu.Lock()
	n := len(log.messages)
	log.mu.Unlock()
	if n == 0 {
		t.Fatal("no instance logs delivered")
	}
}
func TestVerboseFrozenAfterNetworkUse(t *testing.T) {
	if os.Getenv("TAILCAT_VERBOSE_TEST") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestVerboseFrozenAfterNetworkUse$")
		cmd.Env = append(os.Environ(), "TAILCAT_VERBOSE_TEST=1")
		out, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("verbose helper %v\n%s", e, out)
		}
		return
	}
	r := NewRuntime()
	defer r.Close()
	if e := r.ConfigureVerbose(true); e != nil {
		t.Fatal(e)
	}
	fixture(t)
	if e := r.ConfigureVerbose(false); e == nil {
		t.Fatal("verbose changed after network startup")
	}
}
func TestHandlerPreselectionRejectsBeforeAcceptance(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	sid := handle(successful(t, r, "server.create", map[string]any{"region": relay.Map.Regions[1]}))
	h := &testHandler{calls: make(chan incoming, 1), accept: false}
	if e = r.SetHandler(sid, h); e != nil {
		t.Fatal(e)
	}
	address := successful(t, r, "server.address", map[string]any{"handle": sid})
	cid := handle(successful(t, r, "client.create", map[string]any{"address": address["address"]}))
	successful(t, r, "client.ping", map[string]any{"handle": cid})
	a := invoke(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": 8090})
	if a.code == 0 {
		var c map[string]any
		json.Unmarshal([]byte(a.result), &c)
		deadline := time.Now().Add(200 * time.Millisecond).UnixNano()
		successful(t, r, "connection.deadline", map[string]any{"handle": handle(c), "readDeadline": deadline})
		a = invoke(t, r, "connection.read", map[string]any{"handle": handle(c), "count": 20})
		if a.code == 0 {
			t.Fatal("rejected TCP factory did not reset dial")
		}
	}
	select {
	case got := <-h.calls:
		t.Fatalf("rejected factory accepted connection %+v", got)
	default:
	}
}
