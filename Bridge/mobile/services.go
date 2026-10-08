package mobile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/pkg/sftp"
	"github.com/tailscale/tailcat"
	upstreamperf "github.com/zshannon/swift-tailcat/bridge/internal/upstreamperf"
	"golang.org/x/crypto/ssh"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

type sshResource struct {
	client  *ssh.Client
	hostKey string
}
type sftpResource struct {
	client    *sftp.Client
	ssh       *sshResource
	sshHandle int64
}
type sessionResource struct {
	ssh       *sshResource
	sshHandle int64
	session   *ssh.Session
	stdin     io.WriteCloser
	stdout    io.Reader
	stderr    bytes.Buffer
	mu        sync.Mutex
	started   bool
	readBusy  bool
	writeBusy bool
	waitOnce  sync.Once
	waitDone  chan struct{}
	waitErr   error
}

func (o *Operation) service(method string, q *request) (any, error) {
	if method == "perf.run" || method == "ssh.connect" || method == "ssh.probeAnonymous" {
		freezeVerbose()
	}
	r := o.runtime
	ctx := o.ctx
	switch method {
	case "server.service":
		s, e := getAs[*serverResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if e = validPort(q.Port, false); e != nil {
			return nil, e
		}
		var handler func(net.Conn)
		var hostSigner ssh.Signer
		switch q.Kind {
		case "exec":
			if len(q.Exec) == 0 || strings.TrimSpace(q.Exec[0]) == "" {
				return nil, invalid("exec must contain a nonempty program")
			}
			if runtime.GOOS != "darwin" {
				return nil, unsupported("local process execution is supported only on macOS")
			}
		case "ssh":
			if q.SSH == nil {
				return nil, invalid("SSH options required")
			}
			if (q.SSH.Shell || len(q.SSH.Exec) > 0) && runtime.GOOS != "darwin" {
				return nil, unsupported("SSH process execution is supported only on macOS")
			}
			if len(q.SSH.Exec) > 0 && strings.TrimSpace(q.SSH.Exec[0]) == "" {
				return nil, invalid("empty SSH forced command")
			}
			if q.SSH.AuthorizedKeys != nil {
				if e = tailcat.ValidateSSHAuthorizedKeys(q.SSH.AuthorizedKeys); e != nil {
					return nil, invalid("invalid authorized keys: %v", e)
				}
			}
			if q.SSH.Files != nil {
				if q.SSH.Files.Mode > tailcat.FileServeWOPlus || q.SSH.Files.Dir == "" {
					return nil, invalid("invalid rooted file service")
				}
				root, e := os.OpenRoot(q.SSH.Files.Dir)
				if e != nil {
					return nil, e
				}
				root.Close()
			}
			if !tailcat.SupportsSSHServer() {
				return nil, unsupported("SSH server is unavailable")
			}
			hostSigner, e = ensureSSHHostKey()
			if e != nil {
				return nil, e
			}
		case "perf":
			if q.MaxStreams < 0 || q.MaxDuration < 0 {
				return nil, invalid("negative performance limit")
			}
		default:
			return nil, invalid("unknown service kind")
		}
		if e = s.start(ctx); e != nil {
			return nil, e
		}
		ln, e := s.s.Listen(ctx, "tcp", net.JoinHostPort("", strconv.Itoa(q.Port)))
		if e != nil {
			return nil, e
		}
		serviceCtx, cancel := context.WithCancel(context.Background())
		h, e := o.add(ln, q.Handle, func() error { cancel(); return ln.Close() })
		if e != nil {
			return nil, e
		}
		owned := &ownedListener{ln, r, h}
		if q.Kind == "ssh" {
			handler = managedSSHHandler(serviceCtx, s.s, *q.SSH, hostSigner)
		}
		if q.Kind == "exec" {
			handler = func(c net.Conn) { defer c.Close(); runProcess(serviceCtx, s.s, c, q.Exec) }
		}
		if q.Kind == "perf" {
			ps := &upstreamperf.Server{MaxStreams: q.MaxStreams, MaxDuration: q.MaxDuration}
			handler = ps.HandleTCP
			udp, e := s.s.Listen(ctx, "udp", net.JoinHostPort("", strconv.Itoa(q.Port)))
			if e != nil {
				r.closeHandleInternal(h)
				return nil, e
			}
			uh, e := o.add(udp, h, udp.Close)
			if e != nil {
				r.closeHandleInternal(h)
				return nil, e
			}
			go acceptService(&ownedListener{udp, r, uh}, ps.HandleUDP)
		}
		go acceptService(owned, handler)
		out := map[string]any{"handle": h, "address": ln.Addr().String()}
		if hostSigner != nil {
			out["hostKey"] = string(ssh.MarshalAuthorizedKey(hostSigner.PublicKey()))
		}
		return out, nil
	case "perf.run":
		c, e := getAs[*clientResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if _, e = c.c.Ping(ctx); e != nil {
			return nil, e
		}
		path, e := c.c.DiscoPing(ctx)
		if e != nil {
			return nil, e
		}
		if path.Endpoint == "" {
			reg := c.c.DERPRegion()
			if reg != nil {
				for _, n := range reg.Nodes {
					host := strings.ToLower(strings.TrimSuffix(n.HostName, "."))
					if host == "ipn.dev" || host == "tailscale.com" || strings.HasSuffix(host, ".ipn.dev") || strings.HasSuffix(host, ".tailscale.com") {
						return nil, unsupported("throughput over shared Tailscale DERP is prohibited")
					}
				}
			}
			if q.RequireDirect || !q.AllowSharedRelay {
				return nil, unsupported("direct path required; opt in to owned custom relay testing")
			}
		}
		progress := &progressBuffer{notify: o.emitProgress}
		defer progress.finish()
		pc := &upstreamperf.Client{DialTCP: func(ctx context.Context) (net.Conn, error) { return c.c.DialTCPPort(ctx, upstreamperf.Port) }, DialUDP: func(ctx context.Context) (net.Conn, error) { return c.c.DialUDPPort(ctx, upstreamperf.Port) }, OnProgress: func(p upstreamperf.Progress) { progress.add(p) }}
		res, e := pc.Run(ctx, q.Params)
		if e != nil {
			return nil, e
		}
		b, e := json.Marshal(res)
		if e != nil {
			return nil, e
		}
		var object map[string]any
		json.Unmarshal(b, &object)
		snapshots, dropped := progress.finish()
		object["progress"] = snapshots
		object["progressDropped"] = dropped
		return object, nil
	case "ssh.probeAnonymous":
		return o.probeAnonymous(q)
	case "ssh.connect":
		c, e := getAs[*clientResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		if q.Port == 0 {
			q.Port = 22
		}
		if e = validPort(q.Port, false); e != nil {
			return nil, e
		}
		if q.HostKey == "" {
			return nil, invalid("hostKey is required (OpenSSH authorized key text)")
		}
		expected, _, _, _, e := ssh.ParseAuthorizedKey([]byte(q.HostKey))
		if e != nil {
			return nil, invalid("invalid SSH host key")
		}
		var auth []ssh.AuthMethod
		for _, text := range q.PrivateKeys {
			signer, e := ssh.ParsePrivateKey([]byte(text))
			if e != nil {
				return nil, invalid("invalid SSH private key: %v", e)
			}
			auth = append(auth, ssh.PublicKeys(signer))
		}
		config := &ssh.ClientConfig{User: q.User, Auth: auth, HostKeyCallback: func(host string, addr net.Addr, p ssh.PublicKey) error {
			if !bytes.Equal(expected.Marshal(), p.Marshal()) {
				return errors.New("SSH host key mismatch")
			}
			return nil
		}, Timeout: 15 * time.Second}
		var conn net.Conn
		if q.Address != "" {
			ap, err := netip.ParseAddrPort(q.Address)
			if err != nil {
				return nil, invalid("invalid SSH endpoint")
			}
			conn, e = c.c.DialTCP(ctx, ap)
		} else {
			conn, e = c.c.DialTCPPort(ctx, uint16(q.Port))
		}
		if e != nil {
			return nil, e
		}
		stop := context.AfterFunc(ctx, func() { conn.Close() })
		defer stop()
		cc, chans, reqs, e := ssh.NewClientConn(conn, string(c.c.Server), config)
		if e != nil {
			conn.Close()
			return nil, e
		}
		client := ssh.NewClient(cc, chans, reqs)
		h, e := o.add(&sshResource{client, q.HostKey}, q.Handle, client.Close)
		return map[string]any{"handle": h, "hostKey": q.HostKey}, e
	case "ssh.run":
		s, e := getAs[*sshResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		stop := context.AfterFunc(ctx, func() { s.client.Close(); r.closeHandleInternal(q.Handle) })
		defer stop()
		session, e := s.client.NewSession()
		if e != nil {
			return nil, e
		}
		defer session.Close()
		session.Stdin = bytes.NewReader(q.Input)
		var stdout, stderr bytes.Buffer
		session.Stdout = &stdout
		session.Stderr = &stderr
		e = session.Run(q.Command)
		exit := 0
		if e != nil {
			var ee *ssh.ExitError
			if errors.As(e, &ee) {
				exit = ee.ExitStatus()
			} else {
				return nil, e
			}
		}
		return map[string]any{"stdout": stdout.Bytes(), "stderr": stderr.Bytes(), "exitCode": exit}, nil
	case "ssh.session":
		s, e := getAs[*sshResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		stop := context.AfterFunc(ctx, func() { s.client.Close(); r.closeHandleInternal(q.Handle) })
		defer stop()
		session, e := s.client.NewSession()
		if e != nil {
			return nil, e
		}
		v := &sessionResource{session: session, ssh: s, sshHandle: q.Handle, waitDone: make(chan struct{})}
		if q.PTY != nil {
			if q.PTY.Width <= 0 || q.PTY.Height <= 0 {
				session.Close()
				return nil, invalid("positive PTY dimensions required")
			}
			if e = session.RequestPty(q.PTY.Term, q.PTY.Height, q.PTY.Width, ssh.TerminalModes{}); e != nil {
				session.Close()
				return nil, e
			}
		}
		v.stdin, e = session.StdinPipe()
		if e != nil {
			session.Close()
			return nil, e
		}
		v.stdout, e = session.StdoutPipe()
		if e != nil {
			session.Close()
			return nil, e
		}
		session.Stderr = &v.stderr
		h, e := o.add(v, q.Handle, session.Close)
		return map[string]any{"handle": h}, e
	case "ssh.session.start", "ssh.session.read", "ssh.session.write", "ssh.session.closeInput", "ssh.session.wait", "ssh.session.resize":
		s, e := getAs[*sessionResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		stop := context.AfterFunc(ctx, func() { s.ssh.client.Close(); r.closeHandleInternal(s.sshHandle) })
		defer stop()
		switch method {
		case "ssh.session.start":
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.started {
				return nil, invalid("session already started")
			}
			if q.Command == "" {
				e = s.session.Shell()
			} else {
				e = s.session.Start(q.Command)
			}
			if e == nil {
				s.started = true
			}
			return nil, e
		case "ssh.session.read":
			s.mu.Lock()
			if s.readBusy {
				s.mu.Unlock()
				return nil, invalid("session read already in progress")
			}
			s.readBusy = true
			s.mu.Unlock()
			defer func() { s.mu.Lock(); s.readBusy = false; s.mu.Unlock() }()
			if q.Count <= 0 || q.Count > 16*1024*1024 {
				return nil, invalid("invalid read count")
			}
			buf := make([]byte, q.Count)
			n, e := s.stdout.Read(buf)
			if n > 0 || errors.Is(e, io.EOF) {
				return map[string]any{"data": buf[:n], "eof": errors.Is(e, io.EOF)}, nil
			}
			return nil, e
		case "ssh.session.write", "ssh.session.closeInput":
			s.mu.Lock()
			if s.writeBusy {
				s.mu.Unlock()
				return nil, invalid("session write already in progress")
			}
			s.writeBusy = true
			s.mu.Unlock()
			defer func() { s.mu.Lock(); s.writeBusy = false; s.mu.Unlock() }()
			if method == "ssh.session.closeInput" {
				return nil, s.stdin.Close()
			}
			n, e := s.stdin.Write(q.Data)
			return map[string]any{"count": n}, e
		case "ssh.session.wait":
			s.mu.Lock()
			started := s.started
			s.mu.Unlock()
			if !started {
				return nil, invalid("session has not started")
			}
			s.waitOnce.Do(func() {
				go func() { s.waitErr = s.session.Wait(); close(s.waitDone) }()
			})
			<-s.waitDone
			e = s.waitErr
			exit := 0
			if e != nil {
				var ee *ssh.ExitError
				if errors.As(e, &ee) {
					exit = ee.ExitStatus()
				} else {
					return nil, e
				}
			}
			return map[string]any{"exitCode": exit, "stderr": s.stderr.Bytes()}, nil
		default:
			if q.Width <= 0 || q.Height <= 0 {
				return nil, invalid("positive PTY dimensions required")
			}
			return nil, s.session.WindowChange(q.Height, q.Width)
		}
	case "sftp.connect":
		s, e := getAs[*sshResource](r, q.Handle)
		if e != nil {
			return nil, e
		}
		stop := context.AfterFunc(ctx, func() { s.client.Close(); r.closeHandleInternal(q.Handle) })
		defer stop()
		client, e := sftp.NewClient(s.client)
		if e != nil {
			return nil, e
		}
		h, e := o.add(&sftpResource{client: client, ssh: s, sshHandle: q.Handle}, q.Handle, client.Close)
		return map[string]any{"handle": h}, e
	default:
		return o.sftpMethod(method, q)
	}
}
func acceptService(ln net.Listener, handler func(net.Conn)) {
	for {
		c, e := ln.Accept()
		if e != nil {
			return
		}
		go func() { defer c.Close(); handler(c) }()
	}
}
func runProcess(ctx context.Context, s *tailcat.Server, c net.Conn, argv []string) error {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	configureProcess(cmd)
	cmd.Env = append(os.Environ(), s.PeerEnv(c.LocalAddr(), c.RemoteAddr())...)
	stdin, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	cmd.Stdout = c
	cmd.Stderr = c
	if e = cmd.Start(); e != nil {
		stdin.Close()
		return e
	}
	go func() { io.Copy(stdin, c); stdin.Close() }()
	e = cmd.Wait()
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
	return e
}
func (o *Operation) sftpMethod(method string, q *request) (any, error) {
	if strings.HasPrefix(method, "sftp.file.") {
		return o.fileMethod(method, q)
	}
	resource, e := getAs[*sftpResource](o.runtime, q.Handle)
	if e != nil {
		return nil, e
	}
	if q.Path == "" {
		return nil, invalid("path is required")
	}
	c := resource.client
	stop := context.AfterFunc(o.ctx, func() { resource.ssh.client.Close(); o.runtime.closeHandleInternal(resource.sshHandle) })
	defer stop()
	switch method {
	case "sftp.open":
		flags := os.O_RDONLY
		if q.Write {
			flags = os.O_WRONLY
		}
		if q.Create {
			flags |= os.O_CREATE
		}
		if q.Truncate {
			flags |= os.O_TRUNC
		}
		file, e := c.OpenFile(q.Path, flags)
		if e != nil {
			return nil, e
		}
		h, e := o.add(&fileResource{file: file, ssh: resource.ssh, sshHandle: resource.sshHandle}, q.Handle, file.Close)
		return map[string]any{"handle": h}, e
	case "sftp.list":
		entries, e := c.ReadDir(q.Path)
		if e != nil {
			return nil, e
		}
		out := make([]any, 0, len(entries))
		for _, f := range entries {
			out = append(out, fileInfo(f))
		}
		return map[string]any{"files": out}, nil
	case "sftp.stat", "sftp.lstat":
		var f os.FileInfo
		if method == "sftp.lstat" {
			f, e = c.Lstat(q.Path)
		} else {
			f, e = c.Stat(q.Path)
		}
		if e != nil {
			return nil, e
		}
		return fileInfo(f), nil
	case "sftp.read":
		if q.Offset < 0 || q.Count <= 0 || q.Count > 16*1024*1024 {
			return nil, invalid("invalid file read offset/count")
		}
		f, e := c.Open(q.Path)
		if e != nil {
			return nil, e
		}
		defer f.Close()
		buf := make([]byte, q.Count)
		n, e := f.ReadAt(buf, q.Offset)
		if errors.Is(e, io.EOF) {
			e = nil
		}
		return map[string]any{"data": buf[:n]}, e
	case "sftp.write":
		if q.Offset < 0 {
			return nil, invalid("negative file offset")
		}
		flags := os.O_WRONLY
		if q.Create {
			flags |= os.O_CREATE
		}
		if q.Truncate {
			flags |= os.O_TRUNC
		}
		f, e := c.OpenFile(q.Path, flags)
		if e != nil {
			return nil, e
		}
		defer f.Close()
		n, e := f.WriteAt(q.Data, q.Offset)
		return map[string]any{"count": n}, e
	case "sftp.mkdir":
		return nil, c.Mkdir(q.Path)
	case "sftp.remove":
		return nil, c.Remove(q.Path)
	case "sftp.rename":
		return nil, c.Rename(q.Path, q.Destination)
	case "sftp.chmod":
		return nil, c.Chmod(q.Path, os.FileMode(q.Mode))
	case "sftp.times":
		return nil, c.Chtimes(q.Path, time.Unix(0, q.AccessTime), time.Unix(0, q.ModifyTime))
	}
	return nil, unsupported("unknown SFTP method")
}
func fileInfo(f os.FileInfo) map[string]any {
	return map[string]any{"name": f.Name(), "size": f.Size(), "mode": uint32(f.Mode()), "modifiedAt": f.ModTime().UnixNano(), "isDirectory": f.IsDir()}
}
