package mobile

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"golang.org/x/crypto/ssh"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// ownedSSHPeer uses a pinned ephemeral host key and only a native loopback
// socket. It can withhold precise protocol replies without a shared service.
func ownedSSHPeer(t *testing.T, serve func(ssh.NewChannel)) (*Runtime, int64) {
	t.Helper()
	_, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	signer, e := ssh.NewSignerFromKey(key)
	if e != nil {
		t.Fatal(e)
	}
	ln, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	r := NewRuntime()
	t.Cleanup(func() { r.Close() })
	var mu sync.Mutex
	var peer net.Conn
	t.Cleanup(func() {
		ln.Close()
		mu.Lock()
		if peer != nil {
			peer.Close()
		}
		mu.Unlock()
	})
	go func() {
		c, e := ln.Accept()
		if e != nil {
			return
		}
		mu.Lock()
		peer = c
		mu.Unlock()
		config := &ssh.ServerConfig{NoClientAuth: true}
		config.AddHostKey(signer)
		server, channels, requests, e := ssh.NewServerConn(c, config)
		if e != nil {
			c.Close()
			return
		}
		defer server.Close()
		go ssh.DiscardRequests(requests)
		for channel := range channels {
			go serve(channel)
		}
	}()
	c, e := net.Dial("tcp", ln.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	conn, channels, requests, e := ssh.NewClientConn(c, ln.Addr().String(), &ssh.ClientConfig{User: "owned", HostKeyCallback: ssh.FixedHostKey(signer.PublicKey())})
	if e != nil {
		c.Close()
		t.Fatal(e)
	}
	client := ssh.NewClient(conn, channels, requests)
	id, e := r.NewOperation().add(&sshResource{client: client}, 0, client.Close)
	if e != nil {
		t.Fatal(e)
	}
	return r, id
}

func waitBlocked(t *testing.T, blocked <-chan string) string {
	t.Helper()
	select {
	case stage := <-blocked:
		return stage
	case <-time.After(2 * time.Second):
		t.Fatal("owned peer did not reach blocked request")
		return ""
	}
}
func awaitPromptly(t *testing.T, cb callback) answer {
	t.Helper()
	select {
	case a := <-cb:
		return a
	case <-time.After(time.Second):
		t.Fatal("operation did not finish after cancellation/close")
		return answer{}
	}
}

func TestSSHCreationCancellationAtChannelAndPTYRequests(t *testing.T) {
	for _, mode := range []string{"run-channel", "session-channel", "session-pty"} {
		t.Run(mode, func(t *testing.T) {
			blocked := make(chan string, 1)
			r, id := ownedSSHPeer(t, func(ch ssh.NewChannel) {
				if mode != "session-pty" {
					blocked <- "channel"
					return
				}
				c, requests, e := ch.Accept()
				if e != nil {
					return
				}
				defer c.Close()
				for request := range requests {
					if request.Type == "pty-req" {
						blocked <- "pty"
						continue
					}
					request.Reply(false, nil)
				}
			})
			method := "ssh.session"
			q := map[string]any{"handle": id}
			if mode == "run-channel" {
				method = "ssh.run"
				q["command"] = "owned"
			}
			if mode == "session-pty" {
				q["pty"] = map[string]any{"term": "xterm", "width": 80, "height": 24}
			}
			op, cb := begin(r, method, q)
			waitBlocked(t, blocked)
			op.Cancel()
			if a := awaitPromptly(t, cb); a.code != 2 {
				t.Fatalf("cancel %d %s", a.code, a.message)
			}
		})
	}
}

func sftpPacket(c io.ReadWriter, payload []byte) error {
	header := binary.BigEndian.AppendUint32(nil, uint32(len(payload)))
	if _, e := c.Write(append(header, payload...)); e != nil {
		return e
	}
	return nil
}
func sftpString(v string) []byte {
	return append(binary.BigEndian.AppendUint32(nil, uint32(len(v))), []byte(v)...)
}
func stalledSFTP(t *testing.T, blocked chan<- string) (*Runtime, int64, int64, int64) {
	r, sshID := ownedSSHPeer(t, func(ch ssh.NewChannel) {
		c, requests, e := ch.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		request, ok := <-requests
		if !ok {
			return
		}
		if request.Type != "subsystem" {
			request.Reply(false, nil)
			return
		}
		request.Reply(true, nil)
		go ssh.DiscardRequests(requests)
		for {
			header := make([]byte, 4)
			if _, e := io.ReadFull(c, header); e != nil {
				return
			}
			n := binary.BigEndian.Uint32(header)
			if n == 0 || n > 1024*1024 {
				return
			}
			packet := make([]byte, n)
			if _, e := io.ReadFull(c, packet); e != nil {
				return
			}
			if packet[0] == 1 {
				sftpPacket(c, []byte{2, 0, 0, 0, 3})
				continue
			}
			if len(packet) < 5 {
				return
			}
			switch packet[0] {
			case 3: // FXP_OPEN, return one stable handle.
				reply := append([]byte{102}, packet[1:5]...)
				sftpPacket(c, append(reply, sftpString("owned")...))
			case 5:
				blocked <- "read"
			case 6:
				blocked <- "write"
			case 8:
				blocked <- "stat"
			case 4:
				blocked <- "close"
			}
		}
	})
	sftpID := handle(successful(t, r, "sftp.connect", map[string]any{"handle": sshID}))
	fileID := handle(successful(t, r, "sftp.open", map[string]any{"handle": sftpID, "path": "owned", "write": true, "create": true}))
	return r, sshID, sftpID, fileID
}

func TestSFTPStalledFileOperationsCancelAndClose(t *testing.T) {
	for _, method := range []string{"read", "write", "stat"} {
		for _, mode := range []string{"cancel", "file", "parent", "runtime"} {
			t.Run(method+"/"+mode, func(t *testing.T) {
				blocked := make(chan string, 8)
				r, _, parent, file := stalledSFTP(t, blocked)
				op, cb := begin(r, "sftp.file."+method, map[string]any{"handle": file, "offset": 0, "count": 10, "data": []byte("owned")})
				waitBlocked(t, blocked)
				var closeResult callback
				switch mode {
				case "cancel":
					op.Cancel()
				case "file":
					_, closeResult = begin(r, "resource.close", map[string]any{"handle": file})
				case "parent":
					_, closeResult = begin(r, "resource.close", map[string]any{"handle": parent})
				case "runtime":
					closeResult = make(callback, 1)
					go func() { e := r.Close(); code, message := errorCode(e); closeResult.Complete("", code, message) }()
				}
				if a := awaitPromptly(t, cb); a.code != 2 {
					t.Fatalf("stalled file operation %d %s", a.code, a.message)
				}
				if closeResult != nil {
					if a := awaitPromptly(t, closeResult); a.code != 0 {
						t.Fatalf("close %d %s", a.code, a.message)
					}
				}
			})
		}
	}
}

func TestSFTPIdleCloseCancellationInterruptsAndJoins(t *testing.T) {
	blocked := make(chan string, 8)
	r, _, _, file := stalledSFTP(t, blocked)
	op, cb := begin(r, "resource.close", map[string]any{"handle": file})
	if stage := waitBlocked(t, blocked); stage != "close" {
		t.Fatalf("stage %s", stage)
	}
	op.Cancel()
	if a := awaitPromptly(t, cb); a.code != 0 {
		t.Fatalf("interrupted close did not report successful cleanup: %d %s", a.code, a.message)
	}
}

func TestSFTPAlreadyClosingFileInterruptedByParentAndRuntime(t *testing.T) {
	for _, mode := range []string{"parent", "runtime"} {
		t.Run(mode, func(t *testing.T) {
			blocked := make(chan string, 8)
			r, _, parent, file := stalledSFTP(t, blocked)
			_, fileClose := begin(r, "resource.close", map[string]any{"handle": file})
			if stage := waitBlocked(t, blocked); stage != "close" {
				t.Fatalf("stage %s", stage)
			}
			var parentClose callback
			if mode == "parent" {
				_, parentClose = begin(r, "resource.close", map[string]any{"handle": parent})
			} else {
				parentClose = make(callback, 1)
				go func() { e := r.Close(); code, message := errorCode(e); parentClose.Complete("", code, message) }()
			}
			if a := awaitPromptly(t, parentClose); a.code != 0 {
				t.Fatalf("parent close %d %s", a.code, a.message)
			}
			if a := awaitPromptly(t, fileClose); a.code != 0 && a.code != 2 {
				t.Fatalf("file close %d %s", a.code, a.message)
			}
		})
	}
}

func TestSSHConcurrentWaitInterruptedByCancellationAndRuntime(t *testing.T) {
	for _, mode := range []string{"cancel", "runtime"} {
		t.Run(mode, func(t *testing.T) {
			blocked := make(chan string, 1)
			r, id := ownedSSHPeer(t, func(ch ssh.NewChannel) {
				c, requests, e := ch.Accept()
				if e != nil {
					return
				}
				defer c.Close()
				for request := range requests {
					request.Reply(request.Type == "exec", nil)
					if request.Type == "exec" {
						blocked <- "exec"
					}
				}
			})
			session := handle(successful(t, r, "ssh.session", map[string]any{"handle": id}))
			successful(t, r, "ssh.session.start", map[string]any{"handle": session, "command": "owned"})
			waitBlocked(t, blocked)
			op, first := begin(r, "ssh.session.wait", map[string]any{"handle": session})
			_, second := begin(r, "ssh.session.wait", map[string]any{"handle": session})
			// Cancel an admitted wait, rather than cancelling before Begin has
			// reached the session (which intentionally has no transport effects).
			time.Sleep(20 * time.Millisecond)
			if mode == "cancel" {
				op.Cancel()
			} else {
				closed := make(chan error, 1)
				go func() { closed <- r.Close() }()
				select {
				case e := <-closed:
					if e != nil {
						t.Fatal(e)
					}
				case <-time.After(time.Second):
					t.Fatal("runtime close stalled")
				}
			}
			for _, cb := range []callback{first, second} {
				if a := awaitPromptly(t, cb); a.code != 2 && a.code != 3 {
					t.Fatalf("interrupted wait %d %s", a.code, a.message)
				}
			}
		})
	}
}

func TestSSHSessionWaitIsReusableAndConcurrent(t *testing.T) {
	release := make(chan struct{})
	r, id := ownedSSHPeer(t, func(ch ssh.NewChannel) {
		c, requests, e := ch.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		for request := range requests {
			if request.Type == "exec" {
				request.Reply(true, nil)
				<-release
				c.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
				return
			}
			request.Reply(false, nil)
		}
	})
	session := handle(successful(t, r, "ssh.session", map[string]any{"handle": id}))
	successful(t, r, "ssh.session.start", map[string]any{"handle": session, "command": "owned"})
	_, first := begin(r, "ssh.session.wait", map[string]any{"handle": session})
	_, second := begin(r, "ssh.session.wait", map[string]any{"handle": session})
	close(release)
	for _, cb := range []callback{first, second} {
		if a := awaitPromptly(t, cb); a.code != 0 {
			t.Fatalf("wait %d %s", a.code, a.message)
		}
	}
	_, third := begin(r, "ssh.session.wait", map[string]any{"handle": session})
	if a := awaitPromptly(t, third); a.code != 0 {
		t.Fatalf("repeat wait %d %s", a.code, a.message)
	}
}
