package mobile

import (
	"context"
	"github.com/tailscale/tailcat"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"tailscale.com/net/socks5"
	"tailscale.com/types/logger"
	"time"
)

type ownedConn struct {
	net.Conn
	r      *Runtime
	handle int64
	once   sync.Once
	done   <-chan struct{}
}

func (c *ownedConn) Close() error {
	var e error
	c.once.Do(func() { e = c.r.closeHandleInternal(c.handle) })
	return e
}
func (c *ownedConn) CloseWrite() error {
	if v, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return v.CloseWrite()
	}
	return unsupported("half close unavailable")
}
func (r *Runtime) ownConnection(c net.Conn, parent int64) (*ownedConn, error) {
	c = r.guardIncoming(c, parent)
	return r.ownRawConnection(c, parent)
}

// Native targets have no Tailcat peer identity; track their lifetime without
// applying the authenticated incoming-flow guard.
func (r *Runtime) ownRawConnection(c net.Conn, parent int64) (*ownedConn, error) {
	r.mu.Lock()
	if r.closed || r.resources[parent] == nil {
		r.mu.Unlock()
		c.Close()
		return nil, errClosed
	}
	r.next++
	h := r.next
	done := make(chan struct{})
	var completed sync.Once
	r.resources[h] = &resource{value: &connectionResource{c: c}, parent: parent, close: func() error {
		e := c.Close()
		completed.Do(func() { close(done) })
		return e
	}}
	r.mu.Unlock()
	return &ownedConn{Conn: c, r: r, handle: h, done: done}, nil
}

type ownedListener struct {
	net.Listener
	r      *Runtime
	parent int64
}

func (l *ownedListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e != nil {
		return nil, e
	}
	return l.r.ownConnection(c, l.parent)
}
func (o *Operation) forward(method string, q *request) (any, error) {
	r := o.runtime
	freezeVerbose()
	var base *tailcat.Client
	if q.Handle != 0 {
		c, e := getAs[*clientResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		base = c.c
	}
	if method == "forward.start" && base == nil {
		return nil, invalid("client handle required")
	}
	if q.Bind == "" {
		q.Bind = "127.0.0.1:0"
	}
	ln, e := net.Listen("tcp", q.Bind)
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithCancel(context.Background())
	var value any = ln
	if method == "socks.start" {
		value = &proxyServiceResource{listener: ln}
	}
	h, e := o.add(value, q.Handle, func() error { cancel(); return ln.Close() })
	if e != nil {
		return nil, e
	}
	owned := &ownedListener{ln, r, h}
	if method == "forward.start" {
		if q.Network != "" && q.Network != "tcp" {
			r.closeHandleInternal(h)
			return nil, invalid("forward network must be tcp")
		}
		if q.Address == "" {
			if e = validPort(q.Port, false); e != nil {
				r.closeHandleInternal(h)
				return nil, e
			}
		} else if _, e = netip.ParseAddrPort(q.Address); e != nil {
			r.closeHandleInternal(h)
			return nil, invalid("invalid forward endpoint")
		}
		go func() {
			for {
				local, e := owned.Accept()
				if e != nil {
					return
				}
				go func() {
					defer local.Close()
					dialCtx, stop := context.WithTimeout(ctx, 15*time.Second)
					defer stop()
					var remote net.Conn
					var e error
					if q.Address != "" {
						remote, e = base.DialTCP(dialCtx, netip.MustParseAddrPort(q.Address))
					} else {
						remote, e = base.DialTCPPort(dialCtx, uint16(q.Port))
					}
					if e != nil {
						return
					}
					tracked, e := r.ownConnection(remote, h)
					if e != nil {
						return
					}
					defer tracked.Close()
					tailcat.ProxyConns(local, tracked)
				}()
			}
		}()
		out := map[string]any{"handle": h, "address": ln.Addr().String()}
		if q.Port == 80 {
			out["url"] = "http://" + ln.Addr().String() + "/"
		}
		return out, nil
	}
	var clientsMu sync.Mutex
	clients := map[string]*tailcat.Client{}
	dial := func(callCtx context.Context, network, address string) (net.Conn, error) {
		linked, stop := context.WithTimeout(ctx, 15*time.Second)
		defer stop()
		end := context.AfterFunc(callCtx, stop)
		defer end()
		host, portText, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		p, e := strconv.Atoi(portText)
		if e != nil || validPort(p, false) != nil {
			return nil, invalid("invalid SOCKS port")
		}
		selected := base
		toServer := host == "" || host == "server.tailcat"
		if strings.HasPrefix(host, "tc") && !strings.Contains(host, ".") {
			if _, e := tailcat.ParseAddr(tailcat.Addr(host)); e == nil {
				toServer = true
				clientsMu.Lock()
				selected = clients[host]
				if selected == nil {
					selected = tailcat.NewClient(tailcat.Addr(host))
					selected.Logf = logger.Discard
					clients[host] = selected
					r.mu.Lock()
					if !r.closed && r.resources[h] != nil {
						r.next++
						r.resources[r.next] = &resource{value: &clientResource{c: selected}, parent: h, close: selected.Close}
					} else {
						selected.Close()
					}
					r.mu.Unlock()
				}
				clientsMu.Unlock()
			}
		}
		if selected == nil {
			return nil, invalid("SOCKS destination requires a default client or Tailcat hostname")
		}
		var conn net.Conn
		if toServer {
			if network == "udp" {
				conn, e = selected.DialUDPPort(linked, uint16(p))
			} else {
				conn, e = selected.DialTCPPort(linked, uint16(p))
			}
		} else {
			ip, e2 := netip.ParseAddr(host)
			if e2 != nil {
				ips, err := net.DefaultResolver.LookupNetIP(linked, "ip", host)
				if err != nil {
					return nil, err
				}
				if len(ips) == 0 {
					return nil, invalid("host has no addresses")
				}
				ip = ips[0]
				for _, a := range ips {
					if a.Unmap().Is4() {
						ip = a.Unmap()
						break
					}
				}
			}
			ap := netip.AddrPortFrom(ip.Unmap(), uint16(p))
			if network == "udp" {
				conn, e = selected.DialUDP(linked, ap)
			} else {
				conn, e = selected.DialTCP(linked, ap)
			}
		}
		if e != nil {
			return nil, e
		}
		return r.ownConnection(conn, h)
	}
	ss := &socks5.Server{Logf: logger.Discard, Dialer: dial}
	go ss.Serve(owned)
	return map[string]any{"handle": h, "address": ln.Addr().String()}, nil
}
