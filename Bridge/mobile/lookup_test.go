package mobile

import (
	"golang.org/x/net/dns/dnsmessage"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestOwnedDNSTXTLookupAndSecretLabelRejection(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	id := successful(t, r, "identity.generate", map[string]any{})
	info := id["Public"].(map[string]any)
	info["RegionID"] = 1
	encoded := successful(t, r, "address.encode", map[string]any{"info": info})["address"].(string)
	dns, e := net.ListenPacket("udp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer dns.Close()
	var record atomic.Value
	record.Store("tailcat= " + encoded + " ")
	var calls atomic.Int64
	var ignore atomic.Bool
	requested := make(chan struct{}, 8)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, addr, e := dns.ReadFrom(buf)
			if e != nil {
				return
			}
			var m dnsmessage.Message
			if e = m.Unpack(buf[:n]); e != nil {
				continue
			}
			calls.Add(1)
			select {
			case requested <- struct{}{}:
			default:
			}
			if ignore.Load() {
				continue
			}
			m.Header.Response = true
			m.Header.Authoritative = true
			m.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: m.Questions[0].Name, Type: dnsmessage.TypeTXT, Class: dnsmessage.ClassINET, TTL: 1}, Body: &dnsmessage.TXTResource{TXT: []string{record.Load().(string)}}}}
			out, e := m.Pack()
			if e == nil {
				dns.WriteTo(out, addr)
			}
		}
	}()
	q := map[string]any{"name": "owned.example.test", "resolver": dns.LocalAddr().String()}
	got := successful(t, r, "address.lookup", q)
	if got["address"] != encoded {
		t.Fatal("TXT address changed")
	}
	before := calls.Load()
	a := invoke(t, r, "address.lookup", map[string]any{"name": encoded + ".example.test", "resolver": dns.LocalAddr().String()})
	if a.code != 1 || calls.Load() != before {
		t.Fatal("secret Tailcat label was queried over DNS")
	}
	record.Store("tailcat=malformed")
	if a = invoke(t, r, "address.lookup", q); a.code != 1 {
		t.Fatal("malformed TXT address accepted")
	}
	for len(requested) > 0 {
		<-requested
	}
	ignore.Store(true)
	op, cb := begin(r, "address.lookup", q)
	select {
	case <-requested:
	case <-time.After(5 * time.Second):
		t.Fatal("no pending DNS query")
	}
	op.Cancel()
	if a = await(t, cb); a.code != 2 {
		t.Fatalf("DNS cancellation %d %s", a.code, a.message)
	}
}
