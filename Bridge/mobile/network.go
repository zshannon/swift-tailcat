package mobile

import (
	"context"
	"errors"
	"github.com/tailscale/tailcat"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/wgengine/filter"
	"time"
)

type serverResource struct {
	mu            sync.Mutex
	s             *tailcat.Server
	started       bool
	closed        bool
	policy        Policy
	allow         *tailcat.KeySet
	proxy         map[string]bool
	denied        map[key.NodePublic]bool
	handler       Handler
	logs          *logState
	exitNode      bool
	localPortHost string
	runtime       *Runtime
	handle        int64
	flows         *localFlowOwner
}
type clientResource struct {
	c    *tailcat.Client
	logs *logState
}
type connectionResource struct {
	c             net.Conn
	readBusy      atomic.Bool
	writeBusy     atomic.Bool
	deadlineMu    sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time
}
type listenerResource struct {
	ln         net.Listener
	acceptBusy atomic.Bool
	parent     int64
}

func validPort(port int, allowZero bool) error {
	min := 1
	if allowZero {
		min = 0
	}
	if port < min || port > 65535 {
		return invalid("port must be in %d...65535", min)
	}
	return nil
}
func ranges(in *[]portRange) ([]filter.PortRange, error) {
	if in == nil {
		return nil, nil
	}
	out := make([]filter.PortRange, 0, len(*in))
	for _, p := range *in {
		if e := validPort(p.First, true); e != nil {
			return nil, e
		}
		if e := validPort(p.Last, true); e != nil {
			return nil, e
		}
		if p.Last < p.First {
			return nil, invalid("port range last precedes first")
		}
		out = append(out, filter.PortRange{First: uint16(p.First), Last: uint16(p.Last)})
	}
	return out, nil
}
func (s *serverResource) admission(k key.NodePublic) bool {
	s.mu.Lock()
	p, a, blocked, closed := s.policy, s.allow, s.denied[k], s.closed
	s.mu.Unlock()
	if blocked || closed {
		return false
	}
	if p != nil {
		return p.AllowClient(k.String())
	}
	return a == nil || a.Contains(k)
}
func (s *serverResource) proxyAdmission(ap netip.AddrPort) bool {
	s.mu.Lock()
	p, m := s.policy, s.proxy
	s.mu.Unlock()
	if p != nil {
		return p.AllowProxy(ap.String())
	}
	return m == nil || m[ap.String()]
}
func (o *Operation) connection(c net.Conn, parent int64) (any, error) {
	c = o.runtime.guardIncoming(c, parent)
	h, e := o.add(&connectionResource{c: c}, parent, c.Close)
	if e != nil {
		return nil, e
	}
	return map[string]any{"handle": h, "local": c.LocalAddr().String(), "remote": c.RemoteAddr().String()}, nil
}
func (o *Operation) execute(method string, q *request) (any, error) {
	if v, ok, e := o.values(method, q); ok {
		return v, e
	}
	r := o.runtime
	ctx := o.ctx
	switch method {
	case "resource.close":
		stop := context.AfterFunc(ctx, func() { r.interruptHandle(q.Handle) })
		defer stop()
		return nil, r.closeHandle(q.Handle)
	case "server.create":
		host, e := localForwardHost(q.LocalPortHost)
		if e != nil {
			return nil, e
		}
		if q.UDPIdleTimeout < 0 {
			return nil, invalid("negative UDP idle timeout")
		}
		k, e := parsePrivate(q.PrivateKey)
		if e != nil {
			return nil, e
		}
		psk, e := parsePSK(q.PresharedKey)
		if e != nil {
			return nil, e
		}
		if e = validateRegions([]*tailcfg.DERPRegion{}); e != nil {
			return nil, e
		}
		if q.Region != nil {
			if e = validateRegions([]*tailcfg.DERPRegion{q.Region}); e != nil {
				return nil, e
			}
		}
		tcp, e := ranges(q.ServedTCPPorts)
		if e != nil {
			return nil, e
		}
		udp, e := ranges(q.ServedUDPPorts)
		if e != nil {
			return nil, e
		}
		s := &serverResource{s: &tailcat.Server{Key: k, PresharedKey: psk, DisablePresharedKey: q.DisablePresharedKey, Region: q.Region, RegionID: q.RegionID, DERPMapURL: q.DERPMapURL, ServedTCPPorts: tcp, ServedUDPPorts: udp, UDPIdleTimeout: q.UDPIdleTimeout, Logf: logger.Discard}}
		if q.Cache != 0 {
			c, e := getCache(r, q.Cache)
			if e != nil {
				return nil, e
			}
			s.s.DERPMapCache = c
		}
		if q.AllowedClients != nil {
			s.allow = &tailcat.KeySet{}
			for _, text := range *q.AllowedClients {
				k, e := parseNode(text)
				if e != nil {
					return nil, e
				}
				s.allow.Add(k)
			}
		}
		if q.AllowedProxies != nil {
			s.proxy = map[string]bool{}
			for _, text := range *q.AllowedProxies {
				ap, e := netip.ParseAddrPort(text)
				if e != nil {
					return nil, invalid("invalid proxy endpoint")
				}
				s.proxy[ap.String()] = true
			}
		}
		s.logs = &logState{}
		s.exitNode = q.ExitNode
		s.localPortHost = host
		s.runtime = r
		s.flows = newLocalFlowOwner()
		s.s.Logf = s.logs.logf
		s.s.AllowClient = s.admission
		s.s.AllowProxy = s.proxyAdmission
		h, e := o.add(s, 0, func() error {
			s.mu.Lock()
			s.closed = true
			started := s.started
			s.policy = nil
			s.handler = nil
			s.mu.Unlock()
			s.flows.close()
			s.logs.close()
			if !started {
				return nil
			}
			return s.s.Close()
		})
		if e != nil {
			return nil, e
		}
		s.handle = h
		installLocalPorts(s)
		s.logs.mu.Lock()
		s.logs.handle = h
		s.logs.mu.Unlock()
		if q.ExitNode {
			installExit(s)
		}
		return map[string]any{"handle": h}, nil
	case "server.start":
		s, e := getAs[*serverResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		return nil, s.start(ctx)
	case "server.forward":
		return o.serverForward(q)
	case "server.address", "server.status", "server.drain":
		s, e := getAs[*serverResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if e = s.start(ctx); e != nil {
			return nil, e
		}
		switch method {
		case "server.address":
			return map[string]any{"address": string(s.s.TailcatAddr()), "ip": s.s.Addr().String()}, nil
		case "server.status":
			return s.s.Status(), nil
		default:
			return nil, s.s.DrainTCP(ctx)
		}
	case "server.listen":
		s, e := getAs[*serverResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if q.Network != "tcp" && q.Network != "tcp6" && q.Network != "udp" && q.Network != "udp6" {
			return nil, invalid("unsupported listener network")
		}
		_, port, e := net.SplitHostPort(q.Address)
		if e != nil {
			return nil, invalid("invalid listen address: %v", e)
		}
		if _, e = net.LookupPort(q.Network, port); e != nil {
			return nil, invalid("invalid listen port")
		}
		if e = s.start(ctx); e != nil {
			return nil, e
		}
		ln, e := s.s.Listen(ctx, q.Network, q.Address)
		if e != nil {
			return nil, e
		}
		h, e := o.add(&listenerResource{ln: ln, parent: q.Handle}, q.Handle, ln.Close)
		return map[string]any{"handle": h, "address": ln.Addr().String()}, e
	case "listener.accept":
		ln, e := getAs[*listenerResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if !ln.acceptBusy.CompareAndSwap(false, true) {
			return nil, invalid("accept already in progress")
		}
		defer ln.acceptBusy.Store(false)
		stop := context.AfterFunc(ctx, func() { r.closeHandle(q.Handle) })
		defer stop()
		c, e := ln.ln.Accept()
		if e != nil {
			return nil, e
		}
		return o.connection(c, ln.parent)
	case "server.admit", "server.revoke", "server.contains", "server.disconnect":
		s, e := getAs[*serverResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		k, e := parseNode(q.Key)
		if e != nil {
			return nil, e
		}
		s.mu.Lock()
		a, started := s.allow, s.started
		switch method {
		case "server.admit":
			delete(s.denied, k)
			if a != nil {
				a.Add(k)
			}
		case "server.revoke":
			if a != nil {
				a.Remove(k)
			}
			if s.denied == nil {
				s.denied = map[key.NodePublic]bool{}
			}
			s.denied[k] = true
		}
		s.mu.Unlock()
		switch method {
		case "server.admit":
			return map[string]any{"allowed": true}, nil
		case "server.contains":
			return map[string]any{"allowed": s.admission(k)}, nil
		case "server.revoke":
			if started {
				s.s.DisconnectClient(k)
			}
			return map[string]any{"allowed": false}, nil
		default:
			if !started {
				return map[string]any{"disconnected": false}, nil
			}
			return map[string]any{"disconnected": s.s.DisconnectClient(k)}, nil
		}

	case "server.peer", "server.peerEnvironment":
		s, e := getAs[*serverResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if e = s.start(ctx); e != nil {
			return nil, e
		}
		if method == "server.peer" {
			ap, e := netip.ParseAddrPort(q.Address)
			if e != nil {
				return nil, invalid("invalid peer address")
			}
			k, ok := s.s.PeerKey(net.TCPAddrFromAddrPort(ap))
			return map[string]any{"key": k.String(), "ok": ok}, nil
		}
		local, e := netip.ParseAddrPort(q.Local)
		if e != nil {
			return nil, invalid("invalid local address")
		}
		remote, e := netip.ParseAddrPort(q.Remote)
		if e != nil {
			return nil, invalid("invalid remote address")
		}
		return map[string]any{"environment": s.s.PeerEnv(net.TCPAddrFromAddrPort(local), net.TCPAddrFromAddrPort(remote))}, nil
	case "client.create":
		if _, e := tailcat.ParseAddr(tailcat.Addr(q.Address)); e != nil {
			return nil, invalid("invalid server address: %v", e)
		}
		k, e := parsePrivate(q.PrivateKey)
		if e != nil {
			return nil, e
		}
		c := tailcat.NewClient(tailcat.Addr(q.Address))
		c.Key = k
		c.DERPMapURL = q.DERPMapURL
		c.Logf = logger.Discard
		if q.Cache != 0 {
			cache, e := getCache(r, q.Cache)
			if e != nil {
				return nil, e
			}
			c.DERPMapCache = cache
		}
		logs := &logState{}
		c.Logf = logs.logf
		h, e := o.add(&clientResource{c: c, logs: logs}, 0, func() error { logs.close(); return c.Close() })
		logs.mu.Lock()
		logs.handle = h
		logs.mu.Unlock()
		return map[string]any{"handle": h}, e
	case "client.key", "client.region", "client.ping", "client.discoPing", "client.drain":
		if method != "client.key" {
			freezeVerbose()
		}
		c, e := getAs[*clientResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		switch method {
		case "client.key":
			return map[string]any{"key": c.c.PublicKey().String()}, nil
		case "client.region":
			return c.c.DERPRegion(), nil
		case "client.ping":
			return c.c.Ping(ctx)
		case "client.discoPing":
			return c.c.DiscoPing(ctx)
		default:
			// The pinned engine dereferences its lazy stack in DrainTCP. Before
			// successful startup there cannot be any TCP connections to drain.
			if c.c.DERPRegion() == nil {
				return nil, ctx.Err()
			}
			return nil, c.c.DrainTCP(ctx)
		}
	case "client.dial", "client.dialPort", "client.dialEndpoint":
		freezeVerbose()
		c, e := getAs[*clientResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		var conn net.Conn
		switch method {
		case "client.dial":
			switch q.Network {
			case "tcp", "tcp4", "tcp6", "udp", "udp4", "udp6":
			default:
				return nil, invalid("Dial accepts tcp, tcp4, tcp6, udp, udp4 or udp6")
			}
			if _, _, e = net.SplitHostPort(q.Address); e != nil {
				return nil, invalid("invalid dial address")
			}
			conn, e = c.c.Dial(ctx, q.Network, q.Address)
		case "client.dialPort":
			if e = validPort(q.Port, false); e != nil {
				return nil, e
			}
			if q.Network == "udp" {
				conn, e = c.c.DialUDPPort(ctx, uint16(q.Port))
			} else if q.Network == "tcp" {
				conn, e = c.c.DialTCPPort(ctx, uint16(q.Port))
			} else {
				return nil, invalid("network must be tcp or udp")
			}
		case "client.dialEndpoint":
			ap, err := netip.ParseAddrPort(q.Address)
			if err != nil {
				return nil, invalid("invalid endpoint: %v", err)
			}
			if q.Network == "udp" {
				conn, e = c.c.DialUDP(ctx, ap)
			} else if q.Network == "tcp" {
				conn, e = c.c.DialTCP(ctx, ap)
			} else {
				return nil, invalid("network must be tcp or udp")
			}
		}
		if e != nil {
			return nil, e
		}
		return o.connection(conn, q.Handle)
	case "connection.address", "connection.read", "connection.write", "connection.readPacket", "connection.writePacket", "connection.deadline", "connection.closeWrite", "connection.proxy":
		return o.connectionMethod(method, q)
	case "socks.command":
		return o.socksCommand(q)
	case "address.lookup":
		return o.lookup(q)
	case "forward.start", "socks.start":
		return o.forward(method, q)
	case "server.service", "perf.run", "ssh.connect", "ssh.probeAnonymous", "ssh.run", "ssh.session", "ssh.session.start", "ssh.session.read", "ssh.session.write", "ssh.session.wait", "ssh.session.resize", "ssh.session.closeInput", "sftp.connect", "sftp.list", "sftp.stat", "sftp.lstat", "sftp.read", "sftp.write", "sftp.mkdir", "sftp.remove", "sftp.rename", "sftp.chmod", "sftp.times", "sftp.open", "sftp.file.stat", "sftp.file.read", "sftp.file.write":
		return o.service(method, q)
	}
	return nil, unsupported("unknown method %q", method)
}
func (s *serverResource) start(ctx context.Context) error {
	freezeVerbose()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errClosed
	}
	if s.started {
		s.mu.Unlock()
		return nil
	}
	// Resolution may invoke host cache code. Snapshot immutable inputs and
	// release bridge state locks before entering that callback boundary.
	region, rid := s.s.Region, s.s.RegionID
	mapURL, cache := s.s.DERPMapURL, s.s.DERPMapCache
	s.mu.Unlock()
	if region == nil {
		if rid == 0 {
			rid = -1
		}
		ci := tailcat.ConnInfo{RegionID: rid}
		opts := []any{tailcat.ExpandForServer}
		if mapURL != "" {
			opts = append(opts, tailcat.DERPMapURL(mapURL))
		}
		if cache != nil {
			opts = append(opts, cache)
		}
		if e := ci.Expand(ctx, opts...); e != nil {
			return e
		}
		if len(ci.Region) == 0 {
			return invalid("no relay region selected")
		}
		region = ci.Region[0]
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errClosed
	}
	if s.started {
		return nil
	}
	if e := ctx.Err(); e != nil {
		return e
	}
	// Only actual startup is serialized. Providing the resolved region prevents
	// upstream Start from fetching through the host cache while this lock is held.
	if s.s.Region == nil {
		s.s.Region = region
	}
	if e := s.s.Start(); e != nil {
		return e
	}
	s.started = true
	if e := ctx.Err(); e != nil {
		s.closed = true
		s.s.Close()
		return e
	}
	return nil
}
func (o *Operation) connectionMethod(method string, q *request) (any, error) {
	v, e := getAs[*connectionResource](o.runtime, q.Handle)
	if e != nil {
		return nil, e
	}
	c := v.c
	ctx := o.ctx
	switch method {
	case "connection.address":
		return map[string]any{"local": c.LocalAddr().String(), "remote": c.RemoteAddr().String()}, nil
	case "connection.deadline":
		v.deadlineMu.Lock()
		defer v.deadlineMu.Unlock()
		if q.ReadDeadline != nil {
			v.readDeadline = deadline(*q.ReadDeadline)
			if e = c.SetReadDeadline(v.readDeadline); e != nil {
				return nil, e
			}
		}
		if q.WriteDeadline != nil {
			v.writeDeadline = deadline(*q.WriteDeadline)
			e = c.SetWriteDeadline(v.writeDeadline)
		}
		return nil, e
	case "connection.closeWrite":
		cw, ok := c.(interface{ CloseWrite() error })
		if !ok {
			return nil, unsupported("connection does not support half close")
		}
		return nil, cw.CloseWrite()
	case "connection.proxy":
		other, e := getAs[*connectionResource](o.runtime, q.Other)
		if e != nil {
			return nil, e
		}
		stop := context.AfterFunc(ctx, func() { c.Close(); other.c.Close() })
		defer stop()
		if q.Packet {
			a, ok := c.(tailcat.ConnPacketConn)
			b, ok2 := other.c.(tailcat.ConnPacketConn)
			if !ok || !ok2 {
				return nil, invalid("packet proxy requires packet connections")
			}
			tailcat.ProxyPacketConns(a, b)
		} else {
			tailcat.ProxyConns(c, other.c)
		}
		return nil, nil
	case "connection.read", "connection.readPacket":
		if q.Count <= 0 || q.Count > 16*1024*1024 {
			return nil, invalid("count must be in 1...16777216")
		}
		if !v.readBusy.CompareAndSwap(false, true) {
			return nil, invalid("read already in progress")
		}
		defer v.readBusy.Store(false)
		cleanup := interruptIO(ctx, v, true)
		defer cleanup()
		buf := make([]byte, q.Count)
		var n int
		var addr net.Addr
		if method == "connection.readPacket" {
			pc, ok := c.(net.PacketConn)
			if !ok {
				return nil, invalid("not a packet connection")
			}
			n, addr, e = pc.ReadFrom(buf)
		} else {
			n, e = c.Read(buf)
		}
		if ctx.Err() != nil && n == 0 {
			return nil, ctx.Err()
		}
		out := map[string]any{"data": buf[:n], "eof": errors.Is(e, io.EOF)}
		if addr != nil {
			out["address"] = addr.String()
		}
		// A successful empty UDP read is a datagram, not an absent result or
		// EOF. Preserve its fields (and packet source) just like any other read.
		if e == nil || n > 0 || errors.Is(e, io.EOF) {
			return out, nil
		}
		return nil, e
	case "connection.write", "connection.writePacket":
		if !v.writeBusy.CompareAndSwap(false, true) {
			return nil, invalid("write already in progress")
		}
		defer v.writeBusy.Store(false)
		cleanup := interruptIO(ctx, v, false)
		defer cleanup()
		var n int
		if method == "connection.writePacket" {
			pc, ok := c.(net.PacketConn)
			if !ok {
				return nil, invalid("not a packet connection")
			}
			ap, err := netip.ParseAddrPort(q.Address)
			if err != nil {
				return nil, invalid("invalid packet destination")
			}
			n, e = pc.WriteTo(q.Data, net.UDPAddrFromAddrPort(ap))
		} else {
			n, e = c.Write(q.Data)
		}
		// A write can consume bytes and also fail. Return both facts, preserving
		// the genuine I/O error even if task cancellation races completion.
		if e == nil && n == 0 && ctx.Err() != nil {
			e = ctx.Err()
		}
		if e != nil && n > 0 && method == "connection.write" {
			code, message := errorCode(e)
			return map[string]any{"count": n, "writeErrorCode": code, "writeErrorMessage": message}, nil
		}
		return map[string]any{"count": n}, e
	}
	return nil, unsupported("connection operation")
}
func deadline(ns int64) time.Time {
	if ns == 0 {
		return time.Time{}
	}
	return time.Unix(0, ns)
}
func installExit(s *serverResource) {
	s.s.OnTCPForward = func(ap netip.AddrPort) func(net.Conn) {
		if !s.proxyAdmission(ap) {
			return nil
		}
		return func(c net.Conn) {
			<-s.forwardLocal(c, "tcp", ap.String(), s.handle, s.flows)
		}
	}
	s.s.OnUDPForward = func(ap netip.AddrPort) func(tailcat.ConnPacketConn) {
		if !s.proxyAdmission(ap) {
			return nil
		}
		return func(c tailcat.ConnPacketConn) {
			<-s.forwardLocal(c, "udp", ap.String(), s.handle, s.flows)
		}
	}
}

func interruptIO(ctx context.Context, v *connectionResource, read bool) func() {
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		v.deadlineMu.Lock()
		if read {
			v.c.SetReadDeadline(time.Now())
		} else {
			v.c.SetWriteDeadline(time.Now())
		}
		v.deadlineMu.Unlock()
		close(done)
	})
	return func() {
		if !stop() {
			<-done
			v.deadlineMu.Lock()
			if read {
				v.c.SetReadDeadline(v.readDeadline)
			} else {
				v.c.SetWriteDeadline(v.writeDeadline)
			}
			v.deadlineMu.Unlock()
		}
	}
}
