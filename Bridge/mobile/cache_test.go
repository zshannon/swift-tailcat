package mobile

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestDERPCacheFreshRevalidationStaleAndCancellation(t *testing.T) {
	var calls atomic.Int64
	var mode atomic.Int64
	body := []byte(`{"Regions":{"1":{"RegionID":1,"RegionCode":"local","Nodes":[{"Name":"local","RegionID":1,"HostName":"127.0.0.1"}]}}}`)
	requested := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		switch mode.Load() {
		case 1:
			if r.Header.Get("If-None-Match") != "etag" {
				t.Error("missing revalidation ETag")
			}
			if r.Header.Get("Tailcat-Mode") != "server" {
				t.Error("missing server map hint")
			}
			w.WriteHeader(304)
		case 2:
			w.WriteHeader(503)
		case 3:
			requested <- struct{}{}
			<-r.Context().Done()
		default:
			w.Header().Set("ETag", "etag")
			w.Write(body)
		}
	}))
	defer server.Close()
	r := NewRuntime()
	defer r.Close()
	cache := handle(successful(t, r, "cache.create", map[string]any{}))
	fetch := map[string]any{"derpMapURL": server.URL, "cache": cache}
	for i := 0; i < 2; i++ {
		got := successful(t, r, "derp.fetch", fetch)
		if got["Regions"].(map[string]any)["1"] == nil {
			t.Fatal("missing cached region")
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("fresh cache made %d requests", calls.Load())
	}
	stale := func() {
		successful(t, r, "cache.put", map[string]any{"handle": cache, "url": server.URL, "data": body, "etag": "etag", "storedAt": time.Now().Add(-2 * time.Hour).UnixNano()})
	}
	stale()
	mode.Store(1)
	fetch["forServer"] = true
	successful(t, r, "derp.fetch", fetch)
	entry := successful(t, r, "cache.get", map[string]any{"handle": cache, "url": server.URL})
	if int64(entry["storedAt"].(float64)) < time.Now().Add(-time.Minute).UnixNano() {
		t.Fatal("304 failed to renew freshness")
	}
	stale()
	mode.Store(2)
	successful(t, r, "derp.fetch", fetch)
	stale()
	mode.Store(3)
	op, cb := begin(r, "derp.fetch", fetch)
	select {
	case <-requested:
	case <-time.After(5 * time.Second):
		t.Fatal("no pending fetch")
	}
	op.Cancel()
	if a := await(t, cb); a.code != 2 {
		t.Fatalf("cancelled cached fetch %d %s", a.code, a.message)
	}
	var dm map[string]any
	if e := json.Unmarshal(body, &dm); e != nil {
		t.Fatal(e)
	}
}
