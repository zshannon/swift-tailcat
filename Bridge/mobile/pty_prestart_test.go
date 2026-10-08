package mobile

import (
	"bytes"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestPTYResizeBeforeStartIsolatedHome(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("process execution is macOS only")
	}
	if os.Getenv("TAILCAT_PTY_PRESTART") != "1" {
		home := t.TempDir()
		cmd := exec.Command(os.Args[0], "-test.run=^TestPTYResizeBeforeStartIsolatedHome$", "-test.v")
		cmd.Env = append(os.Environ(), "TAILCAT_PTY_PRESTART=1", "HOME="+home, "XDG_CONFIG_HOME="+filepath.Join(home, "config"))
		if out, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("PTY prestart helper %v\n%s", e, out)
		}
		return
	}
	r, sid, cid := fixture(t)
	service := successful(t, r, "server.service", map[string]any{"handle": sid, "port": 2510, "kind": "ssh", "ssh": map[string]any{"Shell": true}})
	client := handle(successful(t, r, "ssh.connect", map[string]any{"handle": cid, "port": 2510, "user": "owned", "hostKey": service["hostKey"]}))
	session := handle(successful(t, r, "ssh.session", map[string]any{"handle": client, "pty": map[string]any{"term": "xterm", "width": 80, "height": 24}}))
	for _, size := range [][2]int{{90, 25}, {100, 30}} {
		successful(t, r, "ssh.session.resize", map[string]any{"handle": session, "width": size[0], "height": size[1]})
	}
	_, cb := begin(r, "ssh.session.start", map[string]any{"handle": session, "command": "stty size"})
	if a := awaitPromptly(t, cb); a.code != 0 {
		t.Fatalf("start after cold resize %d %s", a.code, a.message)
	}
	var output []byte
	for {
		v := successful(t, r, "ssh.session.read", map[string]any{"handle": session, "count": 100})
		data, _ := base64.StdEncoding.DecodeString(v["data"].(string))
		output = append(output, data...)
		if v["eof"] == true {
			break
		}
	}
	result := successful(t, r, "ssh.session.wait", map[string]any{"handle": session})
	if result["exitCode"] != float64(0) || !bytes.Contains(output, []byte("30 100")) {
		t.Fatalf("cold resized PTY %q %v", output, result)
	}
}
