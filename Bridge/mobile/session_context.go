package mobile

import (
	"context"
	gliderssh "github.com/tailscale/gliderssh"
	"golang.org/x/crypto/ssh"
	"sync"
	"time"
)

// The upstream context is connection-scoped; this wrapper additionally observes
// closing one SSH session channel, so cancelling a session kills its process.
type channelContext struct {
	gliderssh.Context
	inner context.Context
}

func (c *channelContext) Deadline() (time.Time, bool) { return c.inner.Deadline() }
func (c *channelContext) Done() <-chan struct{}       { return c.inner.Done() }
func (c *channelContext) Err() error                  { return c.inner.Err() }
func (c *channelContext) Value(k any) any             { return c.inner.Value(k) }

type observedChannel struct {
	ssh.NewChannel
	ctx     context.Context
	cancel  context.CancelFunc
	windows *managedWindows
}

type managedWindowsKey struct{}
type managedWindows struct {
	mu      sync.Mutex
	hasPTY  bool
	current gliderssh.Window
	events  chan gliderssh.Window
}

func (w *managedWindows) initial(payload []byte) {
	var p struct {
		Term                                     string
		Width, Height, WidthPixels, HeightPixels uint32
		Modes                                    string
	}
	if ssh.Unmarshal(payload, &p) != nil {
		return
	}
	w.mu.Lock()
	w.hasPTY = true
	w.current = gliderssh.Window{Width: int(p.Width), Height: int(p.Height)}
	w.mu.Unlock()
}
func (w *managedWindows) resize(payload []byte) bool {
	var p struct{ Width, Height, WidthPixels, HeightPixels uint32 }
	if ssh.Unmarshal(payload, &p) != nil {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.hasPTY {
		return false
	}
	w.current = gliderssh.Window{Width: int(p.Width), Height: int(p.Height)}
	// Coalesce unconsumed dimensions. A terminal resize must never block the
	// request loop before an exec/shell handler has started reading windows.
	select {
	case <-w.events:
	default:
	}
	w.events <- w.current
	return true
}
func (w *managedWindows) snapshot() (gliderssh.Window, <-chan gliderssh.Window) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.current, w.events
}

func (c *observedChannel) Accept() (ssh.Channel, <-chan *ssh.Request, error) {
	channel, requests, e := c.NewChannel.Accept()
	if e != nil {
		return nil, nil, e
	}
	forwarded := make(chan *ssh.Request)
	go func() {
		defer close(forwarded)
		defer c.cancel()
		for {
			select {
			case <-c.ctx.Done():
				return
			case request, ok := <-requests:
				if !ok {
					return
				}
				if request.Type == "pty-req" {
					c.windows.initial(request.Payload)
				}
				if request.Type == "window-change" {
					request.Reply(c.windows.resize(request.Payload), nil)
					continue
				}
				select {
				case forwarded <- request:
				case <-c.ctx.Done():
					return
				}
			}
		}
	}()
	return channel, forwarded, nil
}
func managedSessionChannel(srv *gliderssh.Server, conn *ssh.ServerConn, ch ssh.NewChannel, outer gliderssh.Context) {
	windows := &managedWindows{events: make(chan gliderssh.Window, 1)}
	inner, cancel := context.WithCancel(context.WithValue(outer, managedWindowsKey{}, windows))
	defer cancel()
	gliderssh.DefaultSessionHandler(srv, conn, &observedChannel{NewChannel: ch, ctx: inner, cancel: cancel, windows: windows}, &channelContext{outer, inner})
}
