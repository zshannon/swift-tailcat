package mobile

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	relayfixture "github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"io"
	"net"
	"testing"
	"time"
)

func socksAssociation(t *testing.T, address string) (net.Conn, *net.UDPConn) {
	t.Helper()
	control, e := net.Dial("tcp", address)
	if e != nil {
		t.Fatal(e)
	}
	control.SetDeadline(time.Now().Add(10 * time.Second))
	control.Write([]byte{5, 1, 0})
	greeting := make([]byte, 2)
	if _, e = io.ReadFull(control, greeting); e != nil || !bytes.Equal(greeting, []byte{5, 0}) {
		t.Fatalf("SOCKS greeting %v %v", greeting, e)
	}
	control.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0})
	reply := make([]byte, 10)
	if _, e = io.ReadFull(control, reply); e != nil || reply[1] != 0 || reply[3] != 1 {
		t.Fatalf("associate reply %v %v", reply, e)
	}
	endpoint := &net.UDPAddr{IP: net.IP(reply[4:8]), Port: int(binary.BigEndian.Uint16(reply[8:10]))}
	udp, e := net.DialUDP("udp", nil, endpoint)
	if e != nil {
		t.Fatal(e)
	}
	udp.SetDeadline(time.Now().Add(10 * time.Second))
	return control, udp
}
func TestSOCKSUDPAssociate(t *testing.T) {
	r, sid, cid := fixture(t)
	ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": "udp", "address": ":8091"})
	socks := successful(t, r, "socks.start", map[string]any{"handle": cid, "bind": "127.0.0.1:0"})
	control, udp := socksAssociation(t, socks["address"].(string))
	defer control.Close()
	defer udp.Close()
	_, accept := begin(r, "listener.accept", map[string]any{"handle": handle(ln)})
	host := "server.tailcat"
	packet := append([]byte{0, 0, 0, 3, byte(len(host))}, []byte(host)...)
	packet = binary.BigEndian.AppendUint16(packet, 8091)
	packet = append(packet, []byte("associate")...)
	udp.Write(packet)
	a := await(t, accept)
	if a.code != 0 {
		t.Fatal(a.message)
	}
	var incoming map[string]any
	json.Unmarshal([]byte(a.result), &incoming)
	got := successful(t, r, "connection.read", map[string]any{"handle": handle(incoming), "count": 100})
	successful(t, r, "connection.write", map[string]any{"handle": handle(incoming), "data": got["data"]})
	buf := make([]byte, 100)
	n, e := udp.Read(buf)
	if e != nil || !bytes.HasSuffix(buf[:n], []byte("associate")) {
		t.Fatalf("UDP SOCKS response %v %v", buf[:n], e)
	}
	successful(t, r, "resource.close", map[string]any{"handle": handle(socks)})
	if _, e = control.Read(buf); e == nil {
		t.Fatal("SOCKS control survives session close")
	}
}
func TestExitTCPUDPForwardingAndProxyPolicy(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	tcp, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer tcp.Close()
	go func() {
		for {
			c, e := tcp.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	udp, e := net.ListenPacket("udp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer udp.Close()
	go func() {
		buf := make([]byte, 100)
		for {
			n, a, e := udp.ReadFrom(buf)
			if e != nil {
				return
			}
			udp.WriteTo(buf[:n], a)
		}
	}()
	r := NewRuntime()
	defer r.Close()
	sid := handle(successful(t, r, "server.create", map[string]any{"region": relay.Map.Regions[1], "exitNode": true, "allowedProxies": []string{tcp.Addr().String(), udp.LocalAddr().String()}}))
	address := successful(t, r, "server.address", map[string]any{"handle": sid})
	cid := handle(successful(t, r, "client.create", map[string]any{"address": address["address"]}))
	successful(t, r, "client.ping", map[string]any{"handle": cid})
	for _, target := range []struct{ network, address string }{{"tcp", tcp.Addr().String()}, {"udp", udp.LocalAddr().String()}} {
		c := successful(t, r, "client.dialEndpoint", map[string]any{"handle": cid, "network": target.network, "address": target.address})
		id := handle(c)
		successful(t, r, "connection.write", map[string]any{"handle": id, "data": []byte(target.network)})
		got := successful(t, r, "connection.read", map[string]any{"handle": id, "count": 100})
		if got["data"] != base64.StdEncoding.EncodeToString([]byte(target.network)) {
			t.Fatalf("exit response %v", got)
		}
	}
	denied, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer denied.Close()
	denied.(*net.TCPListener).SetDeadline(time.Now().Add(250 * time.Millisecond))
	response := invoke(t, r, "client.dialEndpoint", map[string]any{"handle": cid, "network": "tcp", "address": denied.Addr().String()})
	if response.code == 0 {
		var c map[string]any
		json.Unmarshal([]byte(response.result), &c)
		id := handle(c)
		successful(t, r, "connection.deadline", map[string]any{"handle": id, "readDeadline": time.Now().Add(100 * time.Millisecond).UnixNano()})
		invoke(t, r, "connection.write", map[string]any{"handle": id, "data": []byte("denied")})
		if a := invoke(t, r, "connection.read", map[string]any{"handle": id, "count": 100}); a.code == 0 {
			var got map[string]any
			json.Unmarshal([]byte(a.result), &got)
			if got["data"] != "" {
				t.Fatal("proxy policy delivered rejected traffic")
			}
		}
	}
	if target, e := denied.Accept(); e == nil {
		target.Close()
		t.Fatal("proxy policy dialed rejected owned destination")
	}
}
func TestDynamicAdmissionAndRevocation(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	sid := handle(successful(t, r, "server.create", map[string]any{"region": relay.Map.Regions[1], "allowedClients": []string{}}))
	address := successful(t, r, "server.address", map[string]any{"handle": sid})
	cid := handle(successful(t, r, "client.create", map[string]any{"address": address["address"]}))
	key := successful(t, r, "client.key", map[string]any{"handle": cid})["key"]
	op, cb := begin(r, "client.ping", map[string]any{"handle": cid})
	time.AfterFunc(100*time.Millisecond, op.Cancel)
	if a := await(t, cb); a.code != 2 {
		t.Fatalf("denied ping %d %s", a.code, a.message)
	}
	successful(t, r, "server.admit", map[string]any{"handle": sid, "key": key})
	successful(t, r, "client.ping", map[string]any{"handle": cid})
	_, local, remote := makePair(t, r, sid, cid, "tcp")
	peer := successful(t, r, "connection.address", map[string]any{"handle": local})
	identity := successful(t, r, "server.peer", map[string]any{"handle": sid, "address": peer["remote"]})
	if identity["ok"] != true || identity["key"] != key {
		t.Fatalf("peer key %v", identity)
	}
	successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("before")})
	successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100})
	successful(t, r, "server.revoke", map[string]any{"handle": sid, "key": key})
	v := successful(t, r, "server.contains", map[string]any{"handle": sid, "key": key})
	if v["allowed"] != false {
		t.Fatal("revoked key still admitted")
	}
	successful(t, r, "connection.deadline", map[string]any{"handle": local, "readDeadline": time.Now().Add(100 * time.Millisecond).UnixNano()})
	successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("after")})
	if a := invoke(t, r, "connection.read", map[string]any{"handle": local, "count": 100}); a.code == 0 {
		var got map[string]any
		json.Unmarshal([]byte(a.result), &got)
		if got["data"] != "" {
			t.Fatalf("revoked connection delivered traffic: %v", got)
		}
	}
}
