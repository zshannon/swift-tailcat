package mobile

import (
	"fmt"
	"github.com/tailscale/tailcat"
	"net"
	"net/netip"
	"strconv"
	"sync"
)

// Handler receives a runtime-owned incoming connection. Return true to retain it
// for asynchronous work; return false to reject and close it.
type Handler interface {
	Select(network, destination string, forwarded bool) bool
	Connection(handle int64, network, local, remote string, forwarded bool) bool
}

// Logger receives an instance's formatted Go logs. It must return promptly.
type Logger interface {
	Log(handle int64, message string)
}
type logState struct {
	mu     sync.Mutex
	logger Logger
	handle int64
	closed bool
	wg     sync.WaitGroup
}

func (l *logState) logf(format string, args ...any) {
	l.mu.Lock()
	sink, h := l.logger, l.handle
	if sink != nil && !l.closed {
		l.wg.Add(1)
	} else {
		sink = nil
	}
	l.mu.Unlock()
	if sink != nil {
		defer l.wg.Done()
		defer func() { recover() }()
		sink.Log(h, fmt.Sprintf(format, args...))
	}
}
func (l *logState) close() { l.mu.Lock(); l.closed = true; l.logger = nil; l.mu.Unlock(); l.wg.Wait() }
func (r *Runtime) SetLogger(handle int64, sink Logger) error {
	v, e := r.get(handle)
	if e != nil {
		return e
	}
	var l *logState
	switch v := v.(type) {
	case *serverResource:
		l = v.logs
	case *clientResource:
		l = v.logs
	default:
		return invalid("logger requires a client or server")
	}
	if l == nil {
		return invalid("resource does not expose logging")
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return errClosed
	}
	l.logger = sink
	return nil
}
func (r *Runtime) SetHandler(handle int64, handler Handler) error {
	s, e := getAs[*serverResource](r, handle)
	if e != nil {
		return e
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.started {
		return invalid("handler must be installed before startup")
	}
	if s.closed {
		return errClosed
	}
	s.handler = handler
	if handler == nil {
		installLocalPorts(s)
		if s.exitNode {
			installExit(s)
		} else {
			s.s.OnTCPForward = nil
			s.s.OnUDPForward = nil
		}
		return nil
	}
	receive := func(c net.Conn, network string, forwarded bool) {
		s.mu.Lock()
		callback, closed := s.handler, s.closed
		s.mu.Unlock()
		if callback == nil || closed {
			c.Close()
			return
		}
		tracked, e := r.ownConnection(c, handle)
		if e != nil {
			return
		}
		r.mu.Lock()
		if r.closed {
			r.mu.Unlock()
			tracked.Close()
			return
		}
		r.wg.Add(1)
		r.mu.Unlock()
		defer r.wg.Done()
		retained := false
		defer func() {
			recover()
			if !retained {
				tracked.Close()
			}
		}()
		retained = callback.Connection(tracked.handle, network, c.LocalAddr().String(), c.RemoteAddr().String(), forwarded)
		if retained {
			// netstack retains forwarded destination routing for the duration
			// of its handler. Keep it until the asynchronous owner closes.
			<-tracked.done
		}
	}
	selectIncoming := func(network, destination string, forwarded bool) (selected bool) {
		defer func() { recover() }()
		s.mu.Lock()
		callback, closed := s.handler, s.closed
		s.mu.Unlock()
		if callback == nil || closed {
			return false
		}
		return callback.Select(network, destination, forwarded)
	}
	s.s.OnTCP = func(port uint16) func(net.Conn) {
		if !selectIncoming("tcp", ":"+strconv.Itoa(int(port)), false) {
			return nil
		}
		return func(c net.Conn) { receive(c, "tcp", false) }
	}
	s.s.OnUDP = func(port uint16) func(tailcat.ConnPacketConn) {
		if !selectIncoming("udp", ":"+strconv.Itoa(int(port)), false) {
			return nil
		}
		return func(c tailcat.ConnPacketConn) { receive(c, "udp", false) }
	}
	s.s.OnTCPForward = func(ap netip.AddrPort) func(net.Conn) {
		if !s.proxyAdmission(ap) {
			return nil
		}
		if !selectIncoming("tcp", ap.String(), true) {
			return nil
		}
		return func(c net.Conn) { receive(c, "tcp", true) }
	}
	s.s.OnUDPForward = func(ap netip.AddrPort) func(tailcat.ConnPacketConn) {
		if !s.proxyAdmission(ap) {
			return nil
		}
		if !selectIncoming("udp", ap.String(), true) {
			return nil
		}
		return func(c tailcat.ConnPacketConn) { receive(c, "udp", true) }
	}
	return nil
}

var verbosity struct {
	sync.Mutex
	frozen bool
}

// ConfigureVerbose sets the process-wide upstream knob before its first use.
func (r *Runtime) ConfigureVerbose(verbose bool) error {
	r.mu.Lock()
	closed := r.closed
	r.mu.Unlock()
	if closed {
		return errClosed
	}
	return ConfigureVerbose(verbose)
}
func freezeVerbose() { verbosity.Lock(); verbosity.frozen = true; verbosity.Unlock() }
