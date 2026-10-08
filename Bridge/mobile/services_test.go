package mobile

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"github.com/tailscale/tailcat"
	"golang.org/x/crypto/ssh"
	"golang.org/x/net/proxy"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestSSHAndRootedFilesIsolatedHome(t *testing.T) {
	if os.Getenv("TAILCAT_ISOLATED_TEST") != "1" {
		home := t.TempDir()
		cmd := exec.Command(os.Args[0], "-test.run=^TestSSHAndRootedFilesIsolatedHome$", "-test.v")
		cmd.Env = append(os.Environ(), "TAILCAT_ISOLATED_TEST=1", "HOME="+home, "XDG_CONFIG_HOME="+filepath.Join(home, "config"))
		output, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("isolated test: %v\n%s", e, output)
		}
		return
	}
	r, sid, cid := fixture(t)
	dir := t.TempDir()
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "secret"), []byte("outside"), 0600)
	os.Symlink(outside, filepath.Join(dir, "escape"))
	service := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2222, "kind": "ssh", "ssh": map[string]any{"Files": map[string]any{"Dir": dir, "Mode": 1}}})
	host, ok := service["hostKey"].(string)
	if !ok || host == "" {
		t.Fatal("SSH service must return public host key")
	}
	ssh := successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2222, "user": "test", "hostKey": host})
	file := successful(t, r, "sftp.connect", map[string]any{"handle": handle(ssh)})
	fid := handle(file)
	successful(t, r, "sftp.write", map[string]any{"handle": fid, "path": "hello", "data": []byte("file body"), "create": true, "truncate": true})
	got := successful(t, r, "sftp.read", map[string]any{"handle": fid, "path": "hello", "count": 100})
	if got["data"] != base64.StdEncoding.EncodeToString([]byte("file body")) {
		t.Fatal("file roundtrip failed")
	}
	if e := os.Mkdir(filepath.Join(dir, "nested"), 0700); e != nil {
		t.Fatal(e)
	}
	for name, target := range map[string]string{"file-link": "hello", "directory-link": "nested", "self-link": "."} {
		if e := os.Symlink(target, filepath.Join(dir, name)); e != nil {
			t.Fatal(e)
		}
		meta := successful(t, r, "sftp.lstat", map[string]any{"handle": fid, "path": name})
		if os.FileMode(uint32(meta["mode"].(float64)))&os.ModeSymlink == 0 || meta["isDirectory"] != false {
			t.Fatalf("Lstat followed %s: %v", name, meta)
		}
	}
	for _, path := range []string{"../secret", "escape/secret"} {
		a := invoke(t, r, "sftp.read", map[string]any{"handle": fid, "path": path, "count": 100})
		if a.code == 0 {
			t.Fatalf("escaped file root using %s", path)
		}
	}
	for _, mode := range []int{0, 2, 3} {
		t.Run(fmt.Sprintf("file-mode-%d", mode), func(t *testing.T) {
			root := t.TempDir()
			path := "upload"
			if mode == 3 {
				os.Mkdir(filepath.Join(root, "nested"), 0700)
				path = "nested/upload"
			}
			os.WriteFile(filepath.Join(root, path), []byte("original"), 0600)
			service := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2223 + mode, "kind": "ssh", "ssh": map[string]any{"Files": map[string]any{"Dir": root, "Mode": mode}}})
			client := successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2223 + mode, "user": "test", "hostKey": service["hostKey"]})
			files := successful(t, r, "sftp.connect", map[string]any{"handle": handle(client)})
			id := handle(files)
			if mode == 0 {
				successful(t, r, "sftp.read", map[string]any{"handle": id, "path": path, "count": 20})
				if a := invoke(t, r, "sftp.open", map[string]any{"handle": id, "path": path, "write": true, "create": true}); a.code == 0 {
					t.Fatal("read-only service allowed upload")
				}
				return
			}
			opened := successful(t, r, "sftp.open", map[string]any{"handle": id, "path": path, "write": true, "create": true, "truncate": true})
			file := handle(opened)
			data := bytes.Repeat([]byte("chunked-payload"), 16384)
			for offset := 0; offset < len(data); offset += 65536 {
				end := offset + 65536
				if end > len(data) {
					end = len(data)
				}
				written := successful(t, r, "sftp.file.write", map[string]any{"handle": file, "offset": offset, "data": data[offset:end]})
				if int(written["count"].(float64)) != end-offset {
					t.Fatal("short upload")
				}
			}
			successful(t, r, "resource.close", map[string]any{"handle": file})
			// A normal file close must leave its SFTP/SSH parent usable for
			// subsequent files; only cancellation requires transport shutdown.
			next := successful(t, r, "sftp.open", map[string]any{"handle": id, "path": "next-upload", "write": true, "create": true})
			successful(t, r, "resource.close", map[string]any{"handle": handle(next)})
			base := root
			if mode == 3 {
				base = filepath.Join(root, "nested")
			}
			entries, e := os.ReadDir(base)
			if e != nil {
				t.Fatal(e)
			}
			matches := 0
			for _, entry := range entries {
				body, e := os.ReadFile(filepath.Join(base, entry.Name()))
				if e == nil && bytes.Equal(body, data) {
					matches++
				}
			}
			if matches != 1 {
				t.Fatalf("multi-chunk write-only upload split/lost: %d complete files", matches)
			}
			original, e := os.ReadFile(filepath.Join(root, path))
			if e != nil || string(original) != "original" {
				t.Fatal("collision overwrote existing file")
			}
			if a := invoke(t, r, "sftp.list", map[string]any{"handle": id, "path": "."}); a.code == 0 {
				t.Fatal("write-only service allowed listing")
			}
		})
	}
	if runtime.GOOS == "darwin" {
		successful(t, r, "resource.close", map[string]any{"handle": handle(service)})
		shellService := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2222, "kind": "ssh", "ssh": map[string]any{"Exec": []string{"/bin/cat"}}})
		shell := successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2222, "user": "test", "hostKey": shellService["hostKey"]})
		result := successful(t, r, "ssh.run", map[string]any{"handle": handle(shell), "command": "ignored", "input": []byte("forced")})
		if result["stdout"] != base64.StdEncoding.EncodeToString([]byte("forced")) || result["exitCode"] != float64(0) {
			t.Fatalf("forced command result %v", result)
		}
	}
}
func TestForwardAndSOCKSEncryptedTCP(t *testing.T) {
	r, sid, cid := fixture(t)
	ln := successful(t, r, "server.listen", map[string]any{"handle": sid, "network": "tcp", "address": ":8080"})
	lid := handle(ln)
	echo := func() {
		_, cb := begin(r, "listener.accept", map[string]any{"handle": lid})
		a := await(t, cb)
		if a.code != 0 {
			t.Errorf("accept: %s", a.message)
			return
		}
		var v map[string]any
		json.Unmarshal([]byte(a.result), &v)
		h := handle(v)
		got := successful(t, r, "connection.read", map[string]any{"handle": h, "count": 20})
		successful(t, r, "connection.write", map[string]any{"handle": h, "data": got["data"]})
		successful(t, r, "resource.close", map[string]any{"handle": h})
	}
	forward := successful(t, r, "forward.start", map[string]any{"handle": cid, "bind": "127.0.0.1:0", "port": 8080})
	go echo()
	c, e := net.Dial("tcp", forward["address"].(string))
	if e != nil {
		t.Fatal(e)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	c.Write([]byte("forward"))
	buf := make([]byte, 20)
	n, e := c.Read(buf)
	c.Close()
	if e != nil || !bytes.Equal(buf[:n], []byte("forward")) {
		t.Fatalf("forward reply %q %v", buf[:n], e)
	}
	socks := successful(t, r, "socks.start", map[string]any{"handle": cid, "bind": "127.0.0.1:0"})
	dial, e := proxy.SOCKS5("tcp", socks["address"].(string), nil, proxy.Direct)
	if e != nil {
		t.Fatal(e)
	}
	go echo()
	c, e = dial.Dial("tcp", "server.tailcat:8080")
	if e != nil {
		t.Fatal(e)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	c.Write([]byte("socks"))
	n, e = c.Read(buf)
	c.Close()
	if e != nil || string(buf[:n]) != "socks" {
		t.Fatalf("socks reply %q %v", buf[:n], e)
	}
}
func TestPerfOwnedRelay(t *testing.T) {
	r, sid, cid := fixture(t)
	successful(t, r, "server.service", map[string]any{"handle": sid, "port": 5201, "kind": "perf", "maxStreams": 2, "maxDuration": int64(3 * time.Second)})
	for _, proto := range []string{"tcp", "udp"} {
		for _, direction := range []string{"up", "down", "both"} {
			t.Run(proto+"/"+direction, func(t *testing.T) {
				result := successful(t, r, "perf.run", map[string]any{"handle": cid, "allowSharedRelay": true, "params": map[string]any{"proto": proto, "dir": direction, "duration": int64(250 * time.Millisecond), "interval": int64(100 * time.Millisecond), "streams": 1, "length": 512, "bitrate": 1000000}})
				p := result["params"].(map[string]any)
				if p["dir"] != direction || p["proto"] != proto {
					t.Fatalf("params %v", p)
				}
				progress := result["progress"].([]any)
				if len(progress) == 0 || len(progress) > 1024 {
					t.Fatalf("progress count %d", len(progress))
				}
				if direction != "down" {
					if result["clientSent"].(map[string]any)["bytes"].(float64) <= 0 || result["serverReceived"].(map[string]any)["bytes"].(float64) <= 0 {
						t.Fatal("no upload traffic")
					}
				}
				if direction != "up" {
					if result["serverSent"].(map[string]any)["bytes"].(float64) <= 0 || result["clientReceived"].(map[string]any)["bytes"].(float64) <= 0 {
						t.Fatal("no download traffic")
					}
				}
			})
		}
	}
}
func TestAnonymousSSHProbeAndEndpointRoutingIsolatedHome(t *testing.T) {
	if os.Getenv("TAILCAT_PROBE_TEST") != "1" {
		home := t.TempDir()
		cmd := exec.Command(os.Args[0], "-test.run=^TestAnonymousSSHProbeAndEndpointRoutingIsolatedHome$", "-test.v")
		cmd.Env = append(os.Environ(), "TAILCAT_PROBE_TEST=1", "HOME="+home, "XDG_CONFIG_HOME="+filepath.Join(home, "config"))
		out, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("probe helper %v\n%s", e, out)
		}
		return
	}
	r, sid, cid := fixture(t)
	root := t.TempDir()
	service := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2401, "kind": "ssh", "ssh": map[string]any{"Files": map[string]any{"Dir": root, "Mode": 0}}})
	probe := successful(t, r, "ssh.probeAnonymous", map[string]any{"handle": cid, "port": 2401, "user": "stranger", "hostKey": service["hostKey"]})
	if probe["accessible"] != true {
		t.Fatal("anonymous SSH probe missed open service")
	}
	public, private, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	key, e := ssh.NewPublicKey(public)
	if e != nil {
		t.Fatal(e)
	}
	authorized := string(ssh.MarshalAuthorizedKey(key))
	protected := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2402, "kind": "ssh", "ssh": map[string]any{"AuthorizedKeys": []string{authorized}, "Files": map[string]any{"Dir": root, "Mode": 0}}})
	probe = successful(t, r, "ssh.probeAnonymous", map[string]any{"handle": cid, "port": 2402, "user": "stranger", "hostKey": protected["hostKey"]})
	if probe["accessible"] != false {
		t.Fatal("anonymous SSH probe accepted protected service")
	}
	der, e := x509.MarshalPKCS8PrivateKey(private)
	if e != nil {
		t.Fatal(e)
	}
	signer := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	authenticated := successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2402, "user": "test", "hostKey": protected["hostKey"], "privateKeys": []string{signer}})
	successful(t, r, "sftp.connect", map[string]any{"handle": handle(authenticated)})
	if a := invoke(t, r, "ssh.validateKeys", map[string]any{"keys": []string{"command=\"restricted\" " + authorized}}); a.code == 0 {
		t.Fatal("authorized-key options accepted")
	}
	server, e := getAs[*serverResource](r, sid)
	if e != nil {
		t.Fatal(e)
	}
	relay := handle(successful(t, r, "server.create", map[string]any{"region": server.s.Region, "exitNode": true}))
	address := successful(t, r, "server.address", map[string]any{"handle": relay})
	relayClient := handle(successful(t, r, "client.create", map[string]any{"address": address["address"]}))
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	host, e := ensureSSHHostKey()
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go acceptService(listener, managedSSHHandler(ctx, server.s, tailcat.SSHOptions{Files: &tailcat.FileService{Dir: root, Mode: tailcat.FileServeRO}}, host))
	endpoint := successful(t, r, "ssh.connect", map[string]any{"handle": relayClient, "address": listener.Addr().String(), "user": "test", "hostKey": service["hostKey"]})
	files := successful(t, r, "sftp.connect", map[string]any{"handle": handle(endpoint)})
	successful(t, r, "sftp.list", map[string]any{"handle": handle(files), "path": "."})
}
