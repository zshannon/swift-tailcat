package mobile

import (
	"context"
	"encoding/base64"
	"encoding/json"
	relayfixture "github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"net"
	"os"
	"strconv"
	"tailscale.com/envknob"
	"tailscale.com/net/netcheck"
	"tailscale.com/syncs"
	"tailscale.com/tailcfg"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	envknob.Setenv("IN_TS_TEST", "true")
	netcheck.HookStartCaptivePortalDetection.SetForTest(func(ctx context.Context, c *netcheck.Client, dm *tailcfg.DERPMap, preferred tailcfg.DERPRegionID, set func(bool)) (<-chan struct{}, func()) {
		return syncs.ClosedChan(), func() {}
	})
	os.Exit(m.Run())
}
func handle(v map[string]any) int64 { return int64(v["handle"].(float64)) }
func begin(r *Runtime, m string, q any) (*Operation, callback) {
	b, _ := json.Marshal(q)
	cb := make(callback, 1)
	o := r.NewOperation()
	o.Begin(m, string(b), cb)
	return o, cb
}
func await(t *testing.T, cb callback) answer {
	t.Helper()
	select {
	case a := <-cb:
		return a
	case <-time.After(20 * time.Second):
		t.Fatal("operation timed out")
		return answer{}
	}
}
func fixture(t *testing.T) (*Runtime, int64, int64) {
	t.Helper()
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(relay.Close)
	dm := relay.Map
	r := NewRuntime()
	t.Cleanup(func() { r.Close() })
	s := successful(t, r, "server.create", map[string]any{"region": dm.Regions[1]})
	sid := handle(s)
	successful(t, r, "server.start", map[string]any{"handle": sid})
	a := successful(t, r, "server.address", map[string]any{"handle": sid})
	c := successful(t, r, "client.create", map[string]any{"address": a["address"]})
	cid := handle(c)
	successful(t, r, "client.ping", map[string]any{"handle": cid})
	return r, sid, cid
}
func makePair(t *testing.T, r *Runtime, sid, cid int64, network string) (int64, int64, int64) {
	t.Helper()
	ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": network, "address": ":0"})
	lid := handle(ln)
	_, port, e := net.SplitHostPort(ln["address"].(string))
	if e != nil {
		t.Fatal(e)
	}
	p, _ := strconv.Atoi(port)
	_, cb := begin(r, "listener.accept", map[string]any{"handle": lid})
	remote := successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": network, "port": p})
	rid := handle(remote)
	if network == "udp" {
		successful(t, r, "connection.write", map[string]any{"handle": rid, "data": []byte("open")})
	}
	a := await(t, cb)
	if a.code != 0 {
		t.Fatalf("accept %d %s", a.code, a.message)
	}
	var local map[string]any
	json.Unmarshal([]byte(a.result), &local)
	return lid, handle(local), rid
}
func TestEncryptedTCPHalfCloseAndParentClose(t *testing.T) {
	r, sid, cid := fixture(t)
	lid, local, remote := makePair(t, r, sid, cid, "tcp")
	successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("request")})
	successful(t, r, "connection.closeWrite", map[string]any{"handle": remote})
	v := successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100})
	if v["data"] != base64.StdEncoding.EncodeToString([]byte("request")) {
		t.Fatalf("payload %v", v)
	}
	v = successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100})
	if v["eof"] != true {
		t.Fatal("no EOF after half close")
	}
	successful(t, r, "connection.write", map[string]any{"handle": local, "data": []byte("reply")})
	v = successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
	if v["data"] != base64.StdEncoding.EncodeToString([]byte("reply")) {
		t.Fatal("return path after half close failed")
	}
	successful(t, r, "resource.close", map[string]any{"handle": lid})
	successful(t, r, "connection.address", map[string]any{"handle": local})
	successful(t, r, "connection.write", map[string]any{"handle": local, "data": []byte("after-listener-close")})
	v = successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
	if v["data"] != base64.StdEncoding.EncodeToString([]byte("after-listener-close")) {
		t.Fatal("listener close killed accepted stream")
	}
	successful(t, r, "resource.close", map[string]any{"handle": sid})
	if a := invoke(t, r, "connection.address", map[string]any{"handle": local}); a.code != 3 {
		t.Fatalf("accepted connection survives server close: %d", a.code)
	}
}
func TestEncryptedUDPPreservesDatagrams(t *testing.T) {
	r, sid, cid := fixture(t)
	_, local, remote := makePair(t, r, sid, cid, "udp")
	successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100})
	for _, data := range [][]byte{[]byte("one"), []byte("second")} {
		successful(t, r, "connection.write", map[string]any{"handle": remote, "data": data})
		v := successful(t, r, "connection.readPacket", map[string]any{"handle": local, "count": 100})
		if v["data"] != base64.StdEncoding.EncodeToString(data) {
			t.Fatalf("datagram %v", v)
		}
		successful(t, r, "connection.writePacket", map[string]any{"handle": local, "data": data, "address": v["address"]})
		got := successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
		if got["data"] != base64.StdEncoding.EncodeToString(data) {
			t.Fatal("reply mismatch")
		}
	}
}
func TestCancelledReadAllowsNextRead(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	a, b := net.Pipe()
	defer b.Close()
	o := r.NewOperation()
	v, e := o.connection(a, 0)
	if e != nil {
		t.Fatal(e)
	}
	id := v.(map[string]any)["handle"].(int64)
	op, cb := begin(r, "connection.read", map[string]any{"handle": id, "count": 20})
	time.Sleep(20 * time.Millisecond)
	op.Cancel()
	if result := await(t, cb); result.code != 2 {
		t.Fatalf("cancel code %d", result.code)
	}
	go b.Write([]byte("next"))
	v2 := successful(t, r, "connection.read", map[string]any{"handle": id, "count": 20})
	if v2["data"] != base64.StdEncoding.EncodeToString([]byte("next")) {
		t.Fatal("bad next read")
	}
}
func TestCancelledAcceptClosesListener(t *testing.T) {
	r, sid, _ := fixture(t)
	ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": "tcp", "address": ":0"})
	lid := handle(ln)
	op, cb := begin(r, "listener.accept", map[string]any{"handle": lid})
	time.Sleep(20 * time.Millisecond)
	op.Cancel()
	if a := await(t, cb); a.code != 2 {
		t.Fatalf("cancel got %d", a.code)
	}
	if a := invoke(t, r, "listener.accept", map[string]any{"handle": lid}); a.code != 3 {
		t.Fatalf("listener survives cancellation: %d", a.code)
	}
}
func TestAdmissionNilAndEmptyDistinct(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	k := successful(t, r, "identity.generate", map[string]any{})
	pub := k["Public"].(map[string]any)["ServerPublic"].(string)
	open := successful(t, r, "server.create", map[string]any{})
	deny := successful(t, r, "server.create", map[string]any{"allowedClients": []string{}})
	a := successful(t, r, "server.contains", map[string]any{"handle": handle(open), "key": pub})
	if a["allowed"] != true {
		t.Fatal("nil admission should allow all")
	}
	a = successful(t, r, "server.contains", map[string]any{"handle": handle(deny), "key": pub})
	if a["allowed"] != false {
		t.Fatal("empty admission should deny all")
	}
}
func TestInvalidPortsAndEmptyExec(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	s := handle(successful(t, r, "server.create", map[string]any{}))
	for _, q := range []map[string]any{{"handle": s, "port": -1, "kind": "exec", "exec": []string{"/bin/cat"}}, {"handle": s, "port": 22, "kind": "exec", "exec": []string{}}} {
		a := invoke(t, r, "server.service", q)
		if a.code != 1 {
			t.Fatalf("invalid service code %d %s", a.code, a.message)
		}
	}
}
func TestDisconnectDoesNotChangeOpenAdmission(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	sid := handle(successful(t, r, "server.create", map[string]any{}))
	id := successful(t, r, "identity.generate", map[string]any{})
	key := id["Public"].(map[string]any)["ServerPublic"]
	successful(t, r, "server.disconnect", map[string]any{"handle": sid, "key": key})
	v := successful(t, r, "server.contains", map[string]any{"handle": sid, "key": key})
	if v["allowed"] != true {
		t.Fatal("disconnect changed nil admission policy")
	}
}
