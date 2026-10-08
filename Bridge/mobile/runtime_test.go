package mobile

import (
	"encoding/json"
	"net"
	"testing"
	"time"
)

type answer struct {
	result  string
	code    int
	message string
}
type callback chan answer

func (c callback) Complete(result string, code int, message string) {
	c <- answer{result, code, message}
}
func invoke(t *testing.T, r *Runtime, method string, input any) answer {
	t.Helper()
	b, e := json.Marshal(input)
	if e != nil {
		t.Fatal(e)
	}
	cb := make(callback, 1)
	r.NewOperation().Begin(method, string(b), cb)
	select {
	case a := <-cb:
		return a
	case <-time.After(15 * time.Second):
		t.Fatalf("%s timeout", method)
		return answer{}
	}
}
func successful(t *testing.T, r *Runtime, method string, input any) map[string]any {
	t.Helper()
	a := invoke(t, r, method, input)
	if a.code != 0 {
		t.Fatalf("%s: %d %s", method, a.code, a.message)
	}
	var v map[string]any
	if e := json.Unmarshal([]byte(a.result), &v); e != nil {
		t.Fatal(e)
	}
	return v
}
func TestIdentityAddressRoundTrip(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	id := successful(t, r, "identity.generate", map[string]any{})
	info := id["Public"].(map[string]any)
	info["RegionID"] = 1
	encoded := successful(t, r, "address.encode", map[string]any{"info": info})
	parsed := successful(t, r, "address.parse", map[string]any{"address": encoded["address"]})
	if parsed["ServerPublic"] != info["ServerPublic"] {
		t.Fatal("public key changed")
	}
	if parsed["PresharedKey"] != info["PresharedKey"] {
		t.Fatal("PSK changed")
	}
}
func TestMalformedInputReturnsInvalid(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	for _, m := range []string{"server.create", "address.parse", "connection.read"} {
		cb := make(callback, 1)
		r.NewOperation().Begin(m, "null", cb)
		if a := <-cb; a.code != 1 {
			t.Fatalf("%s: got code %d, want invalid", m, a.code)
		}
	}
}
func TestCancelledBeforeBegin(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	o := r.NewOperation()
	o.Cancel()
	cb := make(callback, 1)
	o.Begin("identity.generate", "{}", cb)
	if a := <-cb; a.code != 2 {
		t.Fatalf("got %d, want cancellation", a.code)
	}
}
func TestClosedRuntime(t *testing.T) {
	r := NewRuntime()
	r.Close()
	a := invoke(t, r, "identity.generate", map[string]any{})
	if a.code != 3 {
		t.Fatalf("got %d, want closed", a.code)
	}
}
func TestDiscoWireRoundTrip(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	id := successful(t, r, "identity.generate", map[string]any{})
	pub := id["Public"].(map[string]any)
	wire := successful(t, r, "disco.encodePing", map[string]any{"key": pub["ServerPublic"], "discoKey": pub["ServerDiscoPublic"]})
	parsed := successful(t, r, "disco.parsePing", map[string]any{"data": wire["data"]})
	if parsed["ok"] != true || parsed["key"] != pub["ServerPublic"] || parsed["discoKey"] != pub["ServerDiscoPublic"] {
		t.Fatalf("wire decode %v", parsed)
	}
}
func TestResourceCloseCancelsOutstandingRead(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	a, b := net.Pipe()
	defer b.Close()
	value, e := r.NewOperation().connection(a, 0)
	if e != nil {
		t.Fatal(e)
	}
	id := value.(map[string]any)["handle"].(int64)
	_, cb := begin(r, "connection.read", map[string]any{"handle": id, "count": 20})
	resource, e := getAs[*connectionResource](r, id)
	if e != nil {
		t.Fatal(e)
	}
	deadline := time.Now().Add(time.Second)
	for !resource.readBusy.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	successful(t, r, "resource.close", map[string]any{"handle": id})
	if a := await(t, cb); a.code != 2 {
		t.Fatalf("read on closed parent result %d %s", a.code, a.message)
	}
}
