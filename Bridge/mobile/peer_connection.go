package mobile

import (
	"github.com/tailscale/tailcat"
	"net"
	"tailscale.com/types/key"
)

// The pinned engine removes peer metadata on disconnect but can retain an
// established WireGuard flow. Suppress data until that authenticated peer is
// present again, preserving blackhole/deadline behavior without resetting it.
type peerConn struct {
	net.Conn
	server *serverResource
	peer   key.NodePublic
}

func (s *serverResource) guard(c net.Conn) net.Conn {
	// Metadata may already be removed when an accepted flow reaches the
	// adapter. A missing identity must fail closed, never bypass the guard.
	k, _ := s.s.PeerKey(c.RemoteAddr())
	p := &peerConn{Conn: c, server: s, peer: k}
	if pc, ok := c.(tailcat.ConnPacketConn); ok {
		return &peerPacketConn{peerConn: p, packet: pc}
	}
	return p
}
func (c *peerConn) active() bool {
	c.server.mu.Lock()
	closed := c.server.closed
	c.server.mu.Unlock()
	if closed {
		return false
	}
	k, ok := c.server.s.PeerKey(c.RemoteAddr())
	return ok && k == c.peer
}
func (c *peerConn) Read(p []byte) (int, error) {
	for {
		n, e := c.Conn.Read(p)
		if c.active() || (n == 0 && e != nil) {
			return n, e
		}
		if e != nil {
			return 0, e
		}
	}
}
func (c *peerConn) Write(p []byte) (int, error) {
	if !c.active() {
		return len(p), nil
	}
	return c.Conn.Write(p)
}
func (c *peerConn) CloseWrite() error {
	if v, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return v.CloseWrite()
	}
	return unsupported("connection does not support half close")
}

type peerPacketConn struct {
	*peerConn
	packet tailcat.ConnPacketConn
}

func (c *peerPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, a, e := c.packet.ReadFrom(p)
		if c.active() || (n == 0 && e != nil) {
			return n, a, e
		}
		if e != nil {
			return 0, a, e
		}
	}
}
func (c *peerPacketConn) WriteTo(p []byte, a net.Addr) (int, error) {
	if !c.active() {
		return len(p), nil
	}
	return c.packet.WriteTo(p, a)
}
func (r *Runtime) guardIncoming(c net.Conn, parent int64) net.Conn {
	r.mu.Lock()
	var s *serverResource
	for parent != 0 {
		entry := r.resources[parent]
		if entry == nil {
			break
		}
		if v, ok := entry.value.(*serverResource); ok {
			s = v
			break
		}
		parent = entry.parent
	}
	r.mu.Unlock()
	if s != nil {
		return s.guard(c)
	}
	return c
}
