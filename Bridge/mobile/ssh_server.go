package mobile

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	gliderssh "github.com/tailscale/gliderssh"
	"github.com/tailscale/tailcat"
	"golang.org/x/crypto/ssh"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var hostKeyMu sync.Mutex

// ensureSSHHostKey interoperates with the pinned upstream's documented persistent
// host-key file. The host app's container determines os.UserConfigDir.
func ensureSSHHostKey() (ssh.Signer, error) {
	hostKeyMu.Lock()
	defer hostKeyMu.Unlock()
	dir, e := os.UserConfigDir()
	if e != nil {
		return nil, e
	}
	dir = filepath.Join(dir, "tailcat", "ssh")
	if e = os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	path := filepath.Join(dir, "ssh_host_ed25519_key")
	b, e := os.ReadFile(path)
	if errors.Is(e, os.ErrNotExist) {
		_, private, e2 := ed25519.GenerateKey(rand.Reader)
		if e2 != nil {
			return nil, e2
		}
		der, e2 := x509.MarshalPKCS8PrivateKey(private)
		if e2 != nil {
			return nil, e2
		}
		b = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
		f, e2 := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if errors.Is(e2, os.ErrExist) {
			b, e = os.ReadFile(path)
		} else if e2 != nil {
			return nil, e2
		} else {
			_, e = f.Write(b)
			closeErr := f.Close()
			if e == nil {
				e = closeErr
			}
		}
	}
	if e != nil {
		return nil, e
	}
	return ssh.ParsePrivateKey(b)
}
func managedSSHHandler(serviceCtx context.Context, s *tailcat.Server, opts tailcat.SSHOptions, signer ssh.Signer) func(net.Conn) {
	allowed := map[string]bool{}
	for _, text := range opts.AuthorizedKeys {
		for _, line := range strings.Split(text, "\n") {
			if p, _, _, _, e := ssh.ParseAuthorizedKey([]byte(line)); e == nil {
				allowed[string(p.Marshal())] = true
			}
		}
	}
	return func(c net.Conn) {
		srv := &gliderssh.Server{HostSigners: []gliderssh.Signer{signer}, ChannelHandlers: map[string]gliderssh.ChannelHandler{"session": managedSessionChannel}, RequestHandlers: map[string]gliderssh.RequestHandler{}, SubsystemHandlers: map[string]gliderssh.SubsystemHandler{}}
		if opts.AuthorizedKeys == nil {
			srv.NoClientAuthHandler = func(gliderssh.Context) error { return nil }
		} else {
			srv.PublicKeyHandler = func(_ gliderssh.Context, p gliderssh.PublicKey) error {
				if allowed[string(p.Marshal())] {
					return nil
				}
				return errors.New("SSH public key is not authorized")
			}
		}
		srv.Handler = func(session gliderssh.Session) {
			ctx, cancel := context.WithCancel(serviceCtx)
			defer cancel()
			stop := context.AfterFunc(session.Context(), cancel)
			defer stop()
			if !opts.Shell && len(opts.Exec) == 0 {
				fmt.Fprintln(session.Stderr(), "shell and exec sessions are disabled")
				session.Exit(1)
				return
			}
			e := runSSHProcess(ctx, s, session, opts.Exec)
			exit := 0
			if e != nil {
				var ee interface{ ExitCode() int }
				if errors.As(e, &ee) {
					exit = ee.ExitCode()
					if exit < 0 {
						exit = 255
					}
				} else {
					fmt.Fprintln(session.Stderr(), e)
					exit = 1
				}
			}
			session.Exit(exit)
		}
		if len(opts.Exec) == 0 && (opts.Files != nil || opts.Shell) {
			srv.SubsystemHandlers["sftp"] = func(session gliderssh.Session) { // Keep official rooted os.Root confinement and all four file modes.
				ctx, cancel := context.WithCancel(serviceCtx)
				defer cancel()
				stop := context.AfterFunc(session.Context(), cancel)
				defer stop()
				a, rawB := net.Pipe()
				b := newBufferedConn(rawB)
				defer a.Close()
				go s.SSHConnHandler(tailcat.SSHOptions{Shell: opts.Shell, Files: opts.Files})(b)
				interrupt := context.AfterFunc(ctx, func() { a.Close(); b.Close() })
				defer interrupt()
				cc, chans, reqs, e := ssh.NewClientConn(a, "inner-tailcat-sftp", &ssh.ClientConfig{User: session.User(), HostKeyCallback: ssh.FixedHostKey(signer.PublicKey())})
				if e != nil {
					session.Exit(1)
					return
				}
				client := ssh.NewClient(cc, chans, reqs)
				defer client.Close()
				inner, e := client.NewSession()
				if e != nil {
					session.Exit(1)
					return
				}
				defer inner.Close()
				input, e := inner.StdinPipe()
				if e != nil {
					session.Exit(1)
					return
				}
				output, e := inner.StdoutPipe()
				if e != nil {
					session.Exit(1)
					return
				}
				var stderr bytes.Buffer
				inner.Stderr = &stderr
				if e = inner.RequestSubsystem("sftp"); e != nil {
					session.Exit(1)
					return
				}
				go func() { io.Copy(input, session); input.Close() }()
				io.Copy(session, output)
				e = inner.Wait()
				if e != nil {
					session.Exit(1)
				} else {
					session.Exit(0)
				}
			}
		}
		srv.HandleConn(c)
	}
}

// SSH peers write handshake packets before reading. A bounded writer queue
// gives the in-memory link ordinary socket buffering without opening LAN ports.
type bufferedConn struct {
	net.Conn
	queue chan []byte
	done  chan struct{}
	once  sync.Once
}

func newBufferedConn(c net.Conn) *bufferedConn {
	v := &bufferedConn{Conn: c, queue: make(chan []byte, 16), done: make(chan struct{})}
	go func() {
		defer v.Close()
		for {
			select {
			case <-v.done:
				return
			case data := <-v.queue:
				if _, e := v.Conn.Write(data); e != nil {
					return
				}
			}
		}
	}()
	return v
}
func (c *bufferedConn) Write(p []byte) (int, error) {
	data := append([]byte(nil), p...)
	select {
	case <-c.done:
		return 0, net.ErrClosed
	case c.queue <- data:
		return len(p), nil
	}
}
func (c *bufferedConn) Close() error {
	var e error
	c.once.Do(func() { close(c.done); e = c.Conn.Close() })
	return e
}
