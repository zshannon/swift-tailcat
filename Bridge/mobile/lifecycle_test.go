package mobile

import (
	"encoding/json"
	"net"
	"strconv"
	"testing"
	"time"
)

type gatedAcceptListener struct {
	net.Listener
	accepted chan struct{}
	resume   chan struct{}
}

func (l *gatedAcceptListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e == nil {
		close(l.accepted)
		<-l.resume
	}
	return c, e
}

func TestQueuedConnectionAcceptedAfterRevocation(t *testing.T) {
	for _, network := range []string{"tcp", "udp"} {
		t.Run(network, func(t *testing.T) {
			r, sid, cid := fixture(t)
			ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": network, "address": ":0"})
			resource, e := getAs[*listenerResource](r, handle(ln))
			if e != nil {
				t.Fatal(e)
			}
			// Deterministically stop between the engine accepting the flow and
			// the adapter registering it, the same boundary that can race revoke.
			gate := &gatedAcceptListener{Listener: resource.ln, accepted: make(chan struct{}), resume: make(chan struct{})}
			resource.ln = gate
			defer func() {
				select {
				case <-gate.resume:
				default:
					close(gate.resume)
				}
			}()
			_, cb := begin(r, "listener.accept", map[string]any{"handle": handle(ln)})
			_, port, e := net.SplitHostPort(ln["address"].(string))
			if e != nil {
				t.Fatal(e)
			}
			p, _ := strconv.Atoi(port)
			remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": network, "port": p}))
			successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("queued")})
			select {
			case <-gate.accepted:
			case <-time.After(2 * time.Second):
				t.Fatal("engine did not accept owned flow")
			}
			key := successful(t, r, "client.key", map[string]any{"handle": cid})["key"]
			successful(t, r, "server.revoke", map[string]any{"handle": sid, "key": key})
			close(gate.resume)
			a := await(t, cb)
			if a.code != 0 {
				t.Fatalf("accept: %d %s", a.code, a.message)
			}
			var accepted map[string]any
			if e := json.Unmarshal([]byte(a.result), &accepted); e != nil {
				t.Fatal(e)
			}
			local := handle(accepted)
			successful(t, r, "connection.deadline", map[string]any{"handle": local, "readDeadline": time.Now().Add(100 * time.Millisecond).UnixNano()})
			if a := invoke(t, r, "connection.read", map[string]any{"handle": local, "count": 100}); a.code != 5 {
				t.Fatalf("late accept bypassed revocation: %d %s %s", a.code, a.result, a.message)
			}
		})
	}
}

func TestUnusedClientDrain(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	identity := successful(t, r, "identity.generate", map[string]any{})
	info := identity["Public"].(map[string]any)
	info["RegionID"] = 1
	address := successful(t, r, "address.encode", map[string]any{"info": info})["address"]
	cid := handle(successful(t, r, "client.create", map[string]any{"address": address}))
	if a := invoke(t, r, "client.drain", map[string]any{"handle": cid}); a.code != 0 {
		t.Fatalf("unused client has no TCP endpoints to drain: %d %s", a.code, a.message)
	}
}

func TestCancelledDrainPreservesActiveConnection(t *testing.T) {
	r, sid, cid := fixture(t)
	_, local, remote := makePair(t, r, sid, cid, "tcp")
	for _, request := range []struct {
		method string
		id     int64
	}{{"client.drain", cid}, {"server.drain", sid}} {
		op, cb := begin(r, request.method, map[string]any{"handle": request.id})
		time.AfterFunc(20*time.Millisecond, op.Cancel)
		if a := await(t, cb); a.code != 2 {
			t.Fatalf("%s cancellation: %d %s", request.method, a.code, a.message)
		}
		successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("still-open")})
		successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100})
	}
}
