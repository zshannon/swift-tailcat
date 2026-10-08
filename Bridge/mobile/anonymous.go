package mobile

import (
	"context"
	"github.com/tailscale/tailcat"
	"golang.org/x/crypto/ssh"
	"net"
	"net/netip"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func (o *Operation) probeAnonymous(q *request) (any, error) {
	base, e := getAs[*clientResource](o.runtime, q.Handle)
	if e != nil {
		return nil, e
	}
	if q.Port == 0 {
		q.Port = 22
	}
	if e = validPort(q.Port, false); e != nil {
		return nil, e
	}
	expected, _, _, _, e := ssh.ParseAuthorizedKey([]byte(q.HostKey))
	if e != nil {
		return nil, invalid("valid hostKey is required for anonymous probe")
	}
	stranger := &tailcat.Client{Server: base.c.Server, Key: key.NewNode(), DERPMapURL: base.c.DERPMapURL, DERPMapCache: base.c.DERPMapCache, Logf: logger.Discard}
	h, e := o.add(&clientResource{c: stranger}, q.Handle, stranger.Close)
	if e != nil {
		return nil, e
	}
	defer o.runtime.closeHandleInternal(h)
	var conn net.Conn
	if q.Address != "" {
		ap, err := netip.ParseAddrPort(q.Address)
		if err != nil {
			return nil, invalid("invalid SSH endpoint")
		}
		conn, e = stranger.DialTCP(o.ctx, ap)
	} else {
		conn, e = stranger.DialTCPPort(o.ctx, uint16(q.Port))
	}
	if e != nil {
		return nil, e
	}
	defer conn.Close()
	stop := context.AfterFunc(o.ctx, func() { conn.Close() })
	defer stop()
	hostMismatch := false
	cc, chans, requests, e := ssh.NewClientConn(conn, string(stranger.Server), &ssh.ClientConfig{User: q.User, HostKeyCallback: func(_ string, _ net.Addr, p ssh.PublicKey) error {
		if string(expected.Marshal()) != string(p.Marshal()) {
			hostMismatch = true
			return invalid("SSH host key mismatch")
		}
		return nil
	}})
	if o.ctx.Err() != nil {
		return nil, o.ctx.Err()
	}
	if e != nil {
		if hostMismatch {
			return nil, e
		}
		return map[string]any{"accessible": false}, nil
	}
	client := ssh.NewClient(cc, chans, requests)
	client.Close()
	return map[string]any{"accessible": true}, nil
}
