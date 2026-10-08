package mobile

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func processScript(t *testing.T) ([]string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pids")
	return []string{"/bin/sh", "-c", fmt.Sprintf("echo $$ > %q; sleep 30 & echo $! >> %q; wait", path, path)}, path
}
func processIDs(t *testing.T, path string) []int {
	t.Helper()
	until := time.Now().Add(5 * time.Second)
	for time.Now().Before(until) {
		b, _ := os.ReadFile(path)
		parts := strings.Fields(string(b))
		if len(parts) == 2 {
			ids := []int{}
			for _, p := range parts {
				pid, e := strconv.Atoi(p)
				if e != nil {
					t.Fatal(e)
				}
				ids = append(ids, pid)
			}
			return ids
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("owned child did not start")
	return nil
}
func stoppedProcesses(t *testing.T, ids []int) {
	t.Helper()
	until := time.Now().Add(5 * time.Second)
	for time.Now().Before(until) {
		alive := false
		for _, pid := range ids {
			if e := syscall.Kill(pid, 0); e == syscall.ESRCH {
				continue
			}
			out, e := exec.Command("/bin/ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
			if e != nil || strings.HasPrefix(strings.TrimSpace(string(out)), "Z") {
				continue
			}
			alive = true
		}
		if !alive {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("owned process group remains live: %v", ids)
}
func TestMacOSManagedProcessesPTYAndProxyCommand(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("process execution is macOS only")
	}
	if os.Getenv("TAILCAT_PROCESS_TEST") != "1" {
		home := t.TempDir()
		cmd := exec.Command(os.Args[0], "-test.run=^TestMacOSManagedProcessesPTYAndProxyCommand$", "-test.v")
		cmd.Env = append(os.Environ(), "TAILCAT_PROCESS_TEST=1", "HOME="+home, "XDG_CONFIG_HOME="+filepath.Join(home, "config"))
		out, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("process helper %v\n%s", e, out)
		}
		return
	}
	r, sid, cid := fixture(t)
	argv, path := processScript(t)
	service := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2301, "kind": "exec", "exec": argv})
	successful(t, r, "client.dialPort", map[string]any{"handle": cid, "network": "tcp", "port": 2301})
	pids := processIDs(t, path)
	successful(t, r, "resource.close", map[string]any{"handle": handle(service)})
	stoppedProcesses(t, pids)
	argv, path = processScript(t)
	service = successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2302, "kind": "ssh", "ssh": map[string]any{"Exec": argv}})
	client := successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2302, "user": "test", "hostKey": service["hostKey"]})
	session := successful(t, r, "ssh.session", map[string]any{"handle": handle(client)})
	sessionID := handle(session)
	successful(t, r, "ssh.session.start", map[string]any{"handle": sessionID, "command": "ignored"})
	pids = processIDs(t, path)
	successful(t, r, "resource.close", map[string]any{"handle": sessionID})
	stoppedProcesses(t, pids)
	service = successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2303, "kind": "ssh", "ssh": map[string]any{"Shell": true}})
	client = successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2303, "user": "test", "hostKey": service["hostKey"]})
	session = successful(t, r, "ssh.session", map[string]any{"handle": handle(client), "pty": map[string]any{"term": "xterm", "width": 80, "height": 24}})
	sessionID = handle(session)
	successful(t, r, "ssh.session.start", map[string]any{"handle": sessionID, "command": "stty size; read token; stty size; printf 'received:%s' \"$token\""})
	first := successful(t, r, "ssh.session.read", map[string]any{"handle": sessionID, "count": 200})
	data, _ := base64.StdEncoding.DecodeString(first["data"].(string))
	if !bytes.Contains(data, []byte("24 80")) {
		t.Fatalf("initial PTY size %q", data)
	}
	successful(t, r, "ssh.session.resize", map[string]any{"handle": sessionID, "width": 100, "height": 30})
	successful(t, r, "ssh.session.write", map[string]any{"handle": sessionID, "data": []byte("token\n")})
	var output []byte
	for {
		v := successful(t, r, "ssh.session.read", map[string]any{"handle": sessionID, "count": 200})
		chunk, _ := base64.StdEncoding.DecodeString(v["data"].(string))
		output = append(output, chunk...)
		if v["eof"] == true {
			break
		}
	}
	result := successful(t, r, "ssh.session.wait", map[string]any{"handle": sessionID})
	if result["exitCode"] != float64(0) || !bytes.Contains(output, []byte("30 100")) || !bytes.Contains(output, []byte("received:token")) {
		t.Fatalf("PTY output %q result %v", output, result)
	}
	service = successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2304, "kind": "ssh", "ssh": map[string]any{"Exec": []string{"/bin/cat"}}})
	client = successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2304, "user": "test", "hostKey": service["hostKey"]})
	session = successful(t, r, "ssh.session", map[string]any{"handle": handle(client)})
	sessionID = handle(session)
	successful(t, r, "ssh.session.start", map[string]any{"handle": sessionID, "command": "ignored"})
	successful(t, r, "ssh.session.write", map[string]any{"handle": sessionID, "data": []byte("stdin-EOF")})
	successful(t, r, "ssh.session.closeInput", map[string]any{"handle": sessionID})
	v := successful(t, r, "ssh.session.read", map[string]any{"handle": sessionID, "count": 100})
	if v["data"] != base64.StdEncoding.EncodeToString([]byte("stdin-EOF")) {
		t.Fatal("session stdin EOF lost output")
	}
	successful(t, r, "ssh.session.wait", map[string]any{"handle": sessionID})
	socks := successful(t, r, "socks.start", map[string]any{"handle": cid, "bind": "127.0.0.1:0"})
	proxyID := handle(socks)
	result = successful(t, r, "socks.command", map[string]any{"handle": proxyID, "exec": []string{"/bin/sh", "-c", "printf '%s|%s|%s' \"$ALL_PROXY\" \"$https_proxy\" \"$CUSTOM\""}, "environment": map[string]any{"CUSTOM": "owned"}})
	decoded, _ := base64.StdEncoding.DecodeString(result["stdout"].(string))
	url := "socks5h://" + socks["address"].(string)
	if string(decoded) != url+"|"+url+"|owned" {
		t.Fatalf("proxy environment %q", decoded)
	}
	argv, path = processScript(t)
	_, done := begin(r, "socks.command", map[string]any{"handle": proxyID, "exec": argv})
	pids = processIDs(t, path)
	successful(t, r, "resource.close", map[string]any{"handle": proxyID})
	if a := await(t, done); a.code != 2 {
		t.Fatalf("proxy command parent cancellation %d %s", a.code, a.message)
	}
	stoppedProcesses(t, pids)
	socks = successful(t, r, "socks.start", map[string]any{"handle": cid, "bind": "127.0.0.1:0"})
	argv, path = processScript(t)
	_, done = begin(r, "socks.command", map[string]any{"handle": handle(socks), "exec": argv})
	pids = processIDs(t, path)
	r.Close()
	if a := await(t, done); a.code != 2 {
		t.Fatal("runtime close did not cancel proxy command")
	}
	stoppedProcesses(t, pids)
}
