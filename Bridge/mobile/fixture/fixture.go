// Package fixture supplies an owned loopback DERP and STUN relay for integration
// tests. It is deliberately separate from the gomobile product package.
package fixture

import (
	"context"
	"net"
	"net/http/httptest"
	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stunserver"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

type Fixture struct {
	Map    *tailcfg.DERPMap
	http   *httptest.Server
	derp   *derpserver.Server
	cancel context.CancelFunc
}

func Start() (*Fixture, error) {
	ctx, cancel := context.WithCancel(context.Background())
	stun := stunserver.New(ctx)
	if e := stun.Listen("127.0.0.1:0"); e != nil {
		cancel()
		return nil, e
	}
	go stun.Serve()
	d := derpserver.New(key.NewNode(), logger.Discard)
	ln, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		cancel()
		d.Close()
		return nil, e
	}
	srv := httptest.NewUnstartedServer(derpserver.Handler(d))
	srv.Listener.Close()
	srv.Listener = ln
	srv.StartTLS()
	region := &tailcfg.DERPRegion{RegionID: 1, RegionCode: "owned-loopback", Nodes: []*tailcfg.DERPNode{{Name: "owned-loopback", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none", DERPPort: ln.Addr().(*net.TCPAddr).Port, STUNPort: stun.LocalAddr().(*net.UDPAddr).Port, InsecureForTests: true, STUNTestIP: "127.0.0.1"}}}
	return &Fixture{Map: &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{1: region}}, http: srv, derp: d, cancel: cancel}, nil
}
func (f *Fixture) Close() {
	f.cancel()
	f.http.CloseClientConnections()
	f.derp.Close()
	f.http.Close()
}
