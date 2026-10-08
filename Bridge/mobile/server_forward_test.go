package mobile

import (
	"encoding/base64"
	relayfixture "github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"io"
	"net"
	"strconv"
	"testing"
	"time"
)

func echoUDP(t *testing.T, address string) net.PacketConn {
	t.Helper()
	c, e := net.ListenPacket("udp", address)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { c.Close() })
	go func() {
		buf := make([]byte, 65535)
		for {
			n, a, e := c.ReadFrom(buf)
			if e != nil {
				return
			}
			c.WriteTo(buf[:n], a)
		}
	}()
	return c
}

func TestServerForwardTCPHalfCloseAndServiceClose(t *testing.T) {
	r, sid, cid := fixture(t)
	target, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer target.Close()
	accepted := make(chan net.Conn, 2)
	go func() {
		for {
			c, e := target.Accept()
			if e != nil {
				return
			}
			accepted <- c
		}
	}()
	service := successful(t, r, "server.forward", map[string]any{"handle": sid, "port": 0, "network": "tcp", "address": target.Addr().String()})
	port := int(service["port"].(float64))
	remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": port}))
	native := <-accepted
	defer native.Close()
	native.SetDeadline(time.Now().Add(2 * time.Second))
	reply := make(chan error, 1)
	go func() {
		data, e := io.ReadAll(native)
		if e == nil && string(data) != "request" {
			t.Errorf("native forwarded payload: %q", data)
		}
		if e == nil {
			_, e = native.Write([]byte("reply"))
		}
		if e == nil {
			e = native.(*net.TCPConn).CloseWrite()
		}
		reply <- e
	}()
	successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("request")})
	successful(t, r, "connection.closeWrite", map[string]any{"handle": remote})
	got := successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
	if got["data"] != base64.StdEncoding.EncodeToString([]byte("reply")) {
		t.Fatalf("forwarded half-close return path: %v", got)
	}
	if e := <-reply; e != nil {
		t.Fatal(e)
	}
	remote = handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": port}))
	native = <-accepted
	defer native.Close()
	native.SetReadDeadline(time.Now().Add(time.Second))
	successful(t, r, "resource.close", map[string]any{"handle": handle(service)})
	if n, e := native.Read(make([]byte, 1)); n != 0 || e != io.EOF {
		t.Fatalf("native target survives forwarding service close: %d %v", n, e)
	}
	successful(t, r, "connection.deadline", map[string]any{"handle": remote, "readDeadline": time.Now().Add(time.Second).UnixNano()})
	got = successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
	if got["eof"] != true {
		t.Fatalf("client survives forwarding service close: %v", got)
	}
}

func TestServerForwardUDPEmptyAndNonemptyDatagrams(t *testing.T) {
	r, sid, cid := fixture(t)
	target := echoUDP(t, "127.0.0.1:0")
	service := successful(t, r, "server.forward", map[string]any{"handle": sid, "port": 0, "network": "udp", "address": target.LocalAddr().String()})
	remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "udp", "port": service["port"]}))
	successful(t, r, "connection.deadline", map[string]any{"handle": remote, "readDeadline": time.Now().Add(2 * time.Second).UnixNano()})
	for _, data := range [][]byte{{}, []byte("one"), []byte("second")} {
		successful(t, r, "connection.write", map[string]any{"handle": remote, "data": data})
		got := successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
		if got["data"] != base64.StdEncoding.EncodeToString(data) || got["eof"] != false {
			t.Fatalf("forwarded datagram: %v", got)
		}
	}
	successful(t, r, "resource.close", map[string]any{"handle": handle(service)})
}

func TestServerForwardUDPRevocationAndParentClose(t *testing.T) {
	r, sid, cid := fixture(t)
	target, e := net.ListenPacket("udp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer target.Close()
	service := successful(t, r, "server.forward", map[string]any{"handle": sid, "port": 0, "network": "udp", "address": target.LocalAddr().String()})
	remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "udp", "port": service["port"]}))
	successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("before")})
	target.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 100)
	if n, _, e := target.ReadFrom(buf); e != nil || string(buf[:n]) != "before" {
		t.Fatalf("native UDP before revoke: %q %v", buf[:n], e)
	}
	key := successful(t, r, "client.key", map[string]any{"handle": cid})["key"]
	successful(t, r, "server.revoke", map[string]any{"handle": sid, "key": key})
	for _, data := range [][]byte{{}, []byte("after")} {
		successful(t, r, "connection.write", map[string]any{"handle": remote, "data": data})
	}
	target.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	if n, _, e := target.ReadFrom(buf); e == nil {
		t.Fatalf("native target received revoked UDP datagram %q", buf[:n])
	} else if timeout, ok := e.(net.Error); !ok || !timeout.Timeout() {
		t.Fatal(e)
	}
	started := time.Now()
	successful(t, r, "resource.close", map[string]any{"handle": sid})
	if time.Since(started) > time.Second {
		t.Fatal("server close did not release blocked UDP proxy pumps promptly")
	}
	if a := invoke(t, r, "resource.close", map[string]any{"handle": handle(service)}); a.code != 0 {
		t.Fatalf("closed forwarding child is not idempotent: %d", a.code)
	}
}

func TestServerLocalPortHostAndListenerOverride(t *testing.T) {
	for _, host := range []string{"127.0.0.1", "::1"} {
		t.Run(host, func(t *testing.T) {
			relay, e := relayfixture.Start()
			if e != nil {
				t.Fatal(e)
			}
			defer relay.Close()
			tcp, e := net.Listen("tcp", net.JoinHostPort(host, "0"))
			if e != nil {
				t.Fatal(e)
			}
			defer tcp.Close()
			_, portText, _ := net.SplitHostPort(tcp.Addr().String())
			port, _ := strconv.Atoi(portText)
			echoUDP(t, net.JoinHostPort(host, portText))
			r := NewRuntime()
			defer r.Close()
			sid := handle(successful(t, r, "server.create", map[string]any{"region": relay.Map.Regions[1], "localPortHost": host, "servedTCPPorts": []map[string]int{{"first": port, "last": port}}, "servedUDPPorts": []map[string]int{{"first": port, "last": port}}}))
			address := successful(t, r, "server.address", map[string]any{"handle": sid})["address"]
			cid := handle(successful(t, r, "client.create", map[string]any{"address": address}))
			ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": "tcp", "address": ":" + portText})
			_, cb := begin(r, "listener.accept", map[string]any{"handle": handle(ln)})
			remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": port}))
			a := await(t, cb)
			if a.code != 0 {
				t.Fatal(a.message)
			}
			successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("override")})
			tcp.(*net.TCPListener).SetDeadline(time.Now().Add(50 * time.Millisecond))
			if c, e := tcp.Accept(); e == nil {
				c.Close()
				t.Fatal("direct mapping overrode an active listener")
			}
			tcp.(*net.TCPListener).SetDeadline(time.Time{})
			successful(t, r, "resource.close", map[string]any{"handle": handle(ln)})
			go func() {
				c, e := tcp.Accept()
				if e == nil {
					defer c.Close()
					io.Copy(c, c)
				}
			}()
			for _, network := range []string{"tcp", "udp"} {
				remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": network, "port": port}))
				successful(t, r, "connection.deadline", map[string]any{"handle": remote, "readDeadline": time.Now().Add(2 * time.Second).UnixNano()})
				successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte(network)})
				got := successful(t, r, "connection.read", map[string]any{"handle": remote, "count": 100})
				if got["data"] != base64.StdEncoding.EncodeToString([]byte(network)) {
					t.Fatalf("same-port %s mapping: %v", network, got)
				}
			}
			// Same-port defaults must still honor the explicit served-port
			// filter, rather than reach an unrelated owned native endpoint.
			denied, e := net.Listen("tcp", net.JoinHostPort(host, "0"))
			if e != nil {
				t.Fatal(e)
			}
			defer denied.Close()
			_, deniedText, _ := net.SplitHostPort(denied.Addr().String())
			deniedPort, _ := strconv.Atoi(deniedText)
			op, result := begin(r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": deniedPort})
			time.AfterFunc(100*time.Millisecond, op.Cancel)
			if a := await(t, result); a.code == 0 {
				t.Fatalf("served-port filter accepted unrelated port: %s", a.result)
			}
			denied.(*net.TCPListener).SetDeadline(time.Now().Add(50 * time.Millisecond))
			if c, e := denied.Accept(); e == nil {
				c.Close()
				t.Fatal("served-port filter dialed unrelated native target")
			}
		})
	}
}
