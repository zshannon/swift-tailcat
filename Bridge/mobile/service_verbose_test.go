package mobile

import (
	"crypto/ed25519"
	"crypto/rand"
	relayfixture "github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"golang.org/x/crypto/ssh"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestServiceFirstNetworkUseFreezesVerbose(t *testing.T) {
	method := os.Getenv("TAILCAT_VERBOSE_SERVICE")
	if method == "" {
		for _, method := range []string{"ssh.connect", "perf.run", "ssh.probeAnonymous"} {
			t.Run(method, func(t *testing.T) {
				cmd := exec.Command(os.Args[0], "-test.run=^TestServiceFirstNetworkUseFreezesVerbose$", "-test.v")
				cmd.Env = append(os.Environ(), "TAILCAT_VERBOSE_SERVICE="+method)
				if out, e := cmd.CombinedOutput(); e != nil {
					t.Fatalf("cold service helper %v\n%s", e, out)
				}
			})
		}
		return
	}
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	if e := r.ConfigureVerbose(false); e != nil {
		t.Fatal(e)
	}
	identity := successful(t, r, "identity.generate", map[string]any{})
	info := identity["Public"].(map[string]any)
	info["Region"] = []any{relay.Map.Regions[1]}
	address := successful(t, r, "address.encode", map[string]any{"info": info})["address"]
	id := handle(successful(t, r, "client.create", map[string]any{"address": address}))
	_, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	signer, e := ssh.NewSignerFromKey(key)
	if e != nil {
		t.Fatal(e)
	}
	q := map[string]any{"handle": id, "port": 22, "user": "owned", "hostKey": string(ssh.MarshalAuthorizedKey(signer.PublicKey()))}
	op, cb := begin(r, method, q)
	started := false
	until := time.Now().Add(3 * time.Second)
	for time.Now().Before(until) {
		r.mu.Lock()
		var clients []*clientResource
		for h, v := range r.resources {
			if c, ok := v.value.(*clientResource); ok && (method != "ssh.probeAnonymous" || h != id) {
				clients = append(clients, c)
			}
		}
		r.mu.Unlock()
		for _, c := range clients {
			if c.c.DERPRegion() != nil {
				started = true
			}
		}
		if started {
			break
		}
		time.Sleep(time.Millisecond)
	}
	op.Cancel()
	if a := awaitPromptly(t, cb); a.code != 2 {
		t.Fatalf("cancel startup %d %s", a.code, a.message)
	}
	if !started {
		t.Fatal("owned client never started its network stack")
	}
	if e := r.ConfigureVerbose(true); e == nil {
		t.Fatalf("%s left process verbosity mutable after first network use", method)
	}
}
