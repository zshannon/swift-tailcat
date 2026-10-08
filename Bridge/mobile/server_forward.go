package mobile

import (
	"context"
	"github.com/tailscale/tailcat"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

// localFlowOwner admits workers until close, then cancels pending native dials
// and waits for the workers. Their sockets are separately registered resources.
type localFlowOwner struct {
	mu     sync.Mutex
	ctx    context.Context
	cancel context.CancelFunc
	closed bool
	wg     sync.WaitGroup
}

func newLocalFlowOwner() *localFlowOwner {
	ctx, cancel := context.WithCancel(context.Background())
	return &localFlowOwner{ctx: ctx, cancel: cancel}
}
func (f *localFlowOwner) start(run func(context.Context)) bool {
	f.mu.Lock()
	if f.closed {
		f.mu.Unlock()
		return false
	}
	f.wg.Add(1)
	f.mu.Unlock()
	go func() { defer f.wg.Done(); run(f.ctx) }()
	return true
}
func (f *localFlowOwner) close() {
	f.mu.Lock()
	f.closed = true
	f.cancel()
	f.mu.Unlock()
	f.wg.Wait()
}

func localForwardHost(host string) (string, error) {
	if host == "" {
		return "", nil
	}
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	}
	if ip, e := netip.ParseAddr(host); e == nil {
		return ip.String(), nil
	}
	if strings.ContainsAny(host, ":/[]@ \t\r\n") || host == "" {
		return "", invalid("local forwarding host must be a hostname or IP without a port")
	}
	return host, nil
}

func localForwardEndpoint(address string) (string, error) {
	host, port, e := net.SplitHostPort(address)
	if e != nil || host == "" {
		return "", invalid("forwarding address must contain a host and port")
	}
	host, e = localForwardHost(host)
	if e != nil {
		return "", e
	}
	p, e := strconv.Atoi(port)
	if e != nil || validPort(p, false) != nil {
		return "", invalid("invalid forwarding destination port")
	}
	return net.JoinHostPort(host, strconv.Itoa(p)), nil
}

func installLocalPorts(s *serverResource) {
	s.s.OnTCP = nil
	s.s.OnUDP = nil
	if s.localPortHost == "" {
		return
	}
	s.s.OnTCP = func(port uint16) func(net.Conn) {
		address := net.JoinHostPort(s.localPortHost, strconv.Itoa(int(port)))
		return func(c net.Conn) { <-s.forwardLocal(c, "tcp", address, s.handle, s.flows) }
	}
	s.s.OnUDP = func(port uint16) func(tailcat.ConnPacketConn) {
		address := net.JoinHostPort(s.localPortHost, strconv.Itoa(int(port)))
		return func(c tailcat.ConnPacketConn) { <-s.forwardLocal(c, "udp", address, s.handle, s.flows) }
	}
}

func (s *serverResource) forwardLocal(c net.Conn, network, address string, parent int64, owner *localFlowOwner) <-chan struct{} {
	done := make(chan struct{})
	source, e := s.runtime.ownConnection(c, parent)
	if e != nil {
		close(done)
		return done
	}
	if !owner.start(func(ctx context.Context) {
		defer close(done)
		defer source.Close()
		dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		target, e := (&net.Dialer{}).DialContext(dialCtx, network, address)
		if e != nil {
			return
		}
		native, e := s.runtime.ownRawConnection(target, parent)
		if e != nil {
			return
		}
		defer native.Close()
		if network == "udp" {
			a, ok := source.Conn.(tailcat.ConnPacketConn)
			b, ok2 := native.Conn.(tailcat.ConnPacketConn)
			if ok && ok2 {
				tailcat.ProxyPacketConns(a, b)
			}
		} else {
			tailcat.ProxyConns(source, native)
		}
	}) {
		source.Close()
		close(done)
	}
	return done
}

func (o *Operation) serverForward(q *request) (any, error) {
	s, e := getAs[*serverResource](o.runtime, q.Handle)
	if e != nil {
		return nil, e
	}
	if q.Network != "tcp" && q.Network != "udp" {
		return nil, invalid("forwarding network must be tcp or udp")
	}
	if e = validPort(q.Port, true); e != nil {
		return nil, e
	}
	target, e := localForwardEndpoint(q.Address)
	if e != nil {
		return nil, e
	}
	if e = s.start(o.ctx); e != nil {
		return nil, e
	}
	ln, e := s.s.Listen(o.ctx, q.Network, net.JoinHostPort("", strconv.Itoa(q.Port)))
	if e != nil {
		return nil, e
	}
	owner := newLocalFlowOwner()
	h, e := o.add(ln, q.Handle, func() error {
		e := ln.Close()
		owner.close()
		return e
	})
	if e != nil {
		return nil, e
	}
	owner.start(func(context.Context) {
		for {
			c, e := ln.Accept()
			if e != nil {
				return
			}
			s.forwardLocal(c, q.Network, target, h, owner)
		}
	})
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	p, _ := strconv.Atoi(port)
	return map[string]any{"handle": h, "address": ln.Addr().String(), "port": p}, nil
}
