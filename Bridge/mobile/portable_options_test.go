package mobile

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"tailscale.com/tailcfg"
	"testing"
	"time"
)

// This catches dropping the explicit map option and making an unwanted fetch.
func TestAddressResolveUsesExplicitMapWithoutHTTP(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	identity := successful(t, r, "identity.generate", map[string]any{})
	info := identity["Public"].(map[string]any)
	info["RegionID"] = 1
	address := successful(t, r, "address.encode", map[string]any{"info": info})["address"]
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		t.Error("explicit map made HTTP request")
		w.WriteHeader(503)
	}))
	defer server.Close()
	dm := &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{1: {RegionID: 1, RegionCode: "owned", Nodes: []*tailcfg.DERPNode{}}}}
	got := successful(t, r, "address.resolve", map[string]any{"address": address, "map": dm, "derpMapURL": server.URL})
	parsed := successful(t, r, "address.parse", map[string]any{"address": got["address"]})
	if len(parsed["Region"].([]any)) != 1 {
		t.Fatal("explicit region lost", parsed)
	}
	dm.Regions[1].Nodes = []*tailcfg.DERPNode{nil}
	if a := invoke(t, r, "address.resolve", map[string]any{"address": address, "map": dm, "derpMapURL": server.URL}); a.code != 1 {
		t.Fatal("null map node was not rejected", a)
	}
}

func TestGenericDialSupportsUDP6AndGenericUDP(t *testing.T) {
	r, sid, cid := fixture(t)
	server := successful(t, r, "server.address", map[string]any{"handle": sid})
	for _, network := range []string{"udp6", "udp"} {
		ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": "udp6", "address": ":0"})
		_, port, e := net.SplitHostPort(ln["address"].(string))
		if e != nil {
			t.Fatal(e)
		}
		destination := net.JoinHostPort(server["ip"].(string), port)
		_, cb := begin(r, "listener.accept", map[string]any{"handle": handle(ln)})
		remote := handle(successful(t, r, "client.dial", map[string]any{"handle": cid, "network": network, "address": destination}))
		successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("owned")})
		a := await(t, cb)
		if a.code != 0 {
			t.Fatal(a)
		}
		var local map[string]any
		json.Unmarshal([]byte(a.result), &local)
		successful(t, r, "connection.deadline", map[string]any{"handle": handle(local), "readDeadline": time.Now().Add(3 * time.Second).UnixNano()})
		got := successful(t, r, "connection.read", map[string]any{"handle": handle(local), "count": 100})
		if got["data"] != base64.StdEncoding.EncodeToString([]byte("owned")) {
			t.Fatal(got)
		}
	}
	if a := invoke(t, r, "client.dial", map[string]any{"handle": cid, "network": "unix", "address": "server.tailcat:8090"}); a.code != 1 {
		t.Fatal("invalid network reached upstream", a)
	}
	// tcp4 and udp4 must reach upstream rather than adapter validation even when
	// this synthetic server only advertises its IPv6 node address.
	for _, network := range []string{"tcp4", "udp4"} {
		a := invoke(t, r, "client.dial", map[string]any{"handle": cid, "network": network, "address": net.JoinHostPort(server["ip"].(string), strconv.Itoa(8090))})
		if a.code == 1 {
			t.Fatal("valid generic network rejected", a)
		}
	}
}

func TestServerListenResolvesOwnedServicePort(t *testing.T) {
	r, sid, cid := fixture(t)
	ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": "tcp", "address": ":http"})
	if _, port, e := net.SplitHostPort(ln["address"].(string)); e != nil || port != "80" {
		t.Fatal("http service did not resolve to 80", ln, e)
	}
	_, cb := begin(r, "listener.accept", map[string]any{"handle": handle(ln)})
	remote := handle(successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": 80}))
	a := await(t, cb)
	if a.code != 0 {
		t.Fatal(a)
	}
	var local map[string]any
	json.Unmarshal([]byte(a.result), &local)
	successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("owned-service")})
	got := successful(t, r, "connection.read", map[string]any{"handle": handle(local), "count": 100})
	if got["data"] != "b3duZWQtc2VydmljZQ==" {
		t.Fatal(got)
	}
	if a := invoke(t, r, "server.listen", map[string]any{"handle": sid, "network": "tcp", "address": ":unknown-owned-service"}); a.code != 1 {
		t.Fatal("unknown service not rejected", a)
	}
}
