package mobile

import (
	"encoding/json"
	relayfixture "github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type testCacheStorage struct {
	get func(string) string
	put func(string, string) string
}

func (s *testCacheStorage) Get(url string) string        { return s.get(url) }
func (s *testCacheStorage) Put(url, entry string) string { return s.put(url, entry) }

func TestInjectedCachePreservesEntryAndExplicitStoreTimestamp(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	var saved string
	storage := &testCacheStorage{get: func(url string) string {
		if url != "https://owned.invalid/map" {
			t.Error(url)
		}
		return saved
	}, put: func(url, entry string) string { saved = entry; return "" }}
	if e := r.SetCacheStorage(h, storage); e != nil {
		t.Fatal(e)
	}
	stamp := time.Unix(123, 456).UnixNano()
	successful(t, r, "cache.put", map[string]any{"handle": h, "url": "https://owned.invalid/map", "data": []byte("owned"), "etag": "opaque", "storedAt": stamp})
	var wire struct {
		Data     []byte
		Etag     string
		StoredAt int64
		OK       bool
	}
	if err := json.Unmarshal([]byte(saved), &wire); err != nil {
		t.Fatal(err)
	}
	if string(wire.Data) != "owned" || wire.Etag != "opaque" || wire.StoredAt != stamp || !wire.OK {
		t.Fatalf("wrong stored entry: %+v", wire)
	}
	got := successful(t, r, "cache.get", map[string]any{"handle": h, "url": "https://owned.invalid/map"})
	if got["data"] != "b3duZWQ=" || got["etag"] != "opaque" || got["ok"] != true {
		t.Fatalf("injected entry lost: %v", got)
	}
}

func TestInjectedCacheMalformedPanicAndWriteErrors(t *testing.T) {
	for _, bad := range []string{"not JSON", `{"data":"bad-base64","etag":"","storedAt":1,"ok":true}`, `{"data":"b2s=","etag":"","storedAt":1}`} {
		r := NewRuntime()
		h := handle(successful(t, r, "cache.create", map[string]any{}))
		s := &testCacheStorage{get: func(string) string { return bad }, put: func(string, string) string { return "disk is full" }}
		if e := r.SetCacheStorage(h, s); e != nil {
			t.Fatal(e)
		}
		got := successful(t, r, "cache.get", map[string]any{"handle": h, "url": "owned"})
		if got["ok"] != false {
			t.Fatal("malformed entry was accepted", got)
		}
		a := invoke(t, r, "cache.put", map[string]any{"handle": h, "url": "owned", "data": []byte("data")})
		if a.code != 5 || a.message != "disk is full" {
			t.Fatalf("write error lost: %+v", a)
		}
		r.Close()
	}
}

func TestInjectedCachePanicsAreContained(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	s := &testCacheStorage{get: func(string) string { panic("get exploded") }, put: func(string, string) string { panic("put exploded") }}
	if e := r.SetCacheStorage(h, s); e != nil {
		t.Fatal(e)
	}
	if got := successful(t, r, "cache.get", map[string]any{"handle": h, "url": "owned"}); got["ok"] != false {
		t.Fatal(got)
	}
	if a := invoke(t, r, "cache.put", map[string]any{"handle": h, "url": "owned"}); a.code != 5 || !strings.Contains(a.message, "put exploded") {
		t.Fatal(a)
	}
}

func TestInjectedCacheRegistrationFreezesOnUseAndAttachment(t *testing.T) {
	for _, attachment := range []bool{false, true} {
		r := NewRuntime()
		h := handle(successful(t, r, "cache.create", map[string]any{}))
		if attachment {
			if _, e := getCache(r, h); e != nil {
				t.Fatal(e)
			}
		} else {
			successful(t, r, "cache.get", map[string]any{"handle": h, "url": "owned"})
		}
		if r.SetCacheStorage(h, nil) == nil {
			t.Fatal("storage replaced after use")
		}
		successful(t, r, "resource.close", map[string]any{"handle": h})
		if a := invoke(t, r, "cache.get", map[string]any{"handle": h, "url": "owned"}); a.code != 3 {
			t.Fatal(a)
		}
		if r.SetCacheStorage(h, nil) == nil {
			t.Fatal("storage installed after close")
		}
		r.Close()
	}
}

func TestInjectedCacheCloseJoinsCallbacksWithoutBridgeLocks(t *testing.T) {
	for _, runtimeClose := range []bool{false, true} {
		r := NewRuntime()
		h := handle(successful(t, r, "cache.create", map[string]any{}))
		entered, release := make(chan struct{}), make(chan struct{})
		s := &testCacheStorage{get: func(string) string {
			if _, e := r.get(h); e != nil {
				t.Error(e)
			} // Reentry proves no runtime mutex across callback.
			close(entered)
			<-release
			return `{"data":"b2s=","etag":"e","storedAt":1,"ok":true}`
		}, put: func(string, string) string { return "" }}
		if e := r.SetCacheStorage(h, s); e != nil {
			t.Fatal(e)
		}
		c, e := getCache(r, h)
		if e != nil {
			t.Fatal(e)
		}
		_, cb := begin(r, "cache.get", map[string]any{"handle": h, "url": "owned"})
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			t.Fatal("no callback")
		}
		done := make(chan error, 1)
		go func() {
			if runtimeClose {
				done <- r.Close()
			} else {
				done <- r.closeHandle(h)
			}
		}()
		select {
		case <-done:
			t.Fatal("close returned before callback")
		case <-time.After(50 * time.Millisecond):
		}
		close(release)
		select {
		case e := <-done:
			if e != nil {
				t.Fatal(e)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("close did not join callback")
		}
		await(t, cb)
		if _, _, _, ok := c.Get("owned"); ok {
			t.Fatal("closed retained cache returned an entry")
		}
		if c.Put("owned", nil, "") == nil {
			t.Fatal("closed retained cache accepted a write")
		}
		r.Close()
	}
}

func TestInjectedFetchFresh304StaleAndIgnoredWriteFailure(t *testing.T) {
	var mu sync.Mutex
	saved := ""
	var mode, calls atomic.Int64
	body := []byte(`{"Regions":{"1":{"RegionID":1,"RegionCode":"owned","Nodes":[]}}}`)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		calls.Add(1)
		switch mode.Load() {
		case 1:
			if q.Header.Get("If-None-Match") != "opaque" {
				t.Error("lost etag")
			}
			w.WriteHeader(304)
		case 2:
			w.WriteHeader(503)
		default:
			w.Header().Set("Etag", "opaque")
			w.Write(body)
		}
	}))
	defer server.Close()
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	s := &testCacheStorage{get: func(url string) string {
		if url != server.URL {
			t.Error(url)
		}
		mu.Lock()
		defer mu.Unlock()
		return saved
	}, put: func(url, entry string) string {
		mu.Lock()
		defer mu.Unlock()
		if mode.Load() == 3 {
			return "unwritable"
		}
		saved = entry
		return ""
	}}
	if e := r.SetCacheStorage(h, s); e != nil {
		t.Fatal(e)
	}
	fetch := map[string]any{"cache": h, "derpMapURL": server.URL}
	successful(t, r, "derp.fetch", fetch)
	successful(t, r, "derp.fetch", fetch)
	if calls.Load() != 1 {
		t.Fatal("fresh injected cache fetched again")
	}
	stale := func() {
		successful(t, r, "cache.put", map[string]any{"handle": h, "url": server.URL, "data": body, "etag": "opaque", "storedAt": time.Now().Add(-2 * time.Hour).UnixNano()})
	}
	stale()
	mode.Store(1)
	successful(t, r, "derp.fetch", fetch)
	entry := successful(t, r, "cache.get", map[string]any{"handle": h, "url": server.URL})
	if int64(entry["storedAt"].(float64)) < time.Now().Add(-time.Minute).UnixNano() {
		t.Fatal("304 did not refresh injected cache")
	}
	stale()
	mode.Store(2)
	successful(t, r, "derp.fetch", fetch)
	mu.Lock()
	saved = ""
	mu.Unlock()
	mode.Store(3)
	successful(t, r, "derp.fetch", fetch)
	if a := invoke(t, r, "cache.put", map[string]any{"handle": h, "url": server.URL, "data": body}); a.code != 5 {
		t.Fatal("explicit store lost error", a)
	}
}

func TestCacheExplicitEpochIsNotReplacedByNow(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	successful(t, r, "cache.put", map[string]any{"handle": h, "url": "owned", "data": []byte("epoch"), "storedAt": int64(0)})
	got := successful(t, r, "cache.get", map[string]any{"handle": h, "url": "owned"})
	if got["storedAt"] != float64(0) {
		t.Fatal("explicit epoch replaced by current time", got)
	}
}

func TestInjectedCacheMissingWireFieldsAreMisses(t *testing.T) {
	for _, bad := range []string{`{"data":"b2s=","ok":true}`, `{"data":"b2s=","etag":"e","ok":true}`, `{"etag":"e","storedAt":1,"ok":true}`} {
		r := NewRuntime()
		h := handle(successful(t, r, "cache.create", map[string]any{}))
		s := &testCacheStorage{get: func(string) string { return bad }, put: func(string, string) string { return "" }}
		if e := r.SetCacheStorage(h, s); e != nil {
			t.Fatal(e)
		}
		if got := successful(t, r, "cache.get", map[string]any{"handle": h, "url": "owned"}); got["ok"] != false {
			t.Error("incomplete wire entry accepted", got)
		}
		r.Close()
	}
}

func TestServerStartCacheCallbackCanReenterPolicyRegistration(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	body, e := json.Marshal(relay.Map)
	if e != nil {
		t.Fatal(e)
	}
	wire, e := json.Marshal(cacheEntry{Data: body, Etag: "owned", StoredAt: time.Now().UnixNano(), OK: true})
	if e != nil {
		t.Fatal(e)
	}
	var sid int64
	reentered := make(chan error, 1)
	s := &testCacheStorage{get: func(string) string {
		// The bounded watchdog permits cleanup on RED while proving the supported
		// synchronous setter is blocked specifically during cache callback dispatch.
		go func() { reentered <- r.SetPolicy(sid, nil) }()
		select {
		case e := <-reentered:
			if e != nil {
				t.Error(e)
			}
		case <-time.After(250 * time.Millisecond):
			t.Error("cache callback reentry blocked by server mutex")
		}
		return string(wire)
	}, put: func(string, string) string { return "" }}
	if e := r.SetCacheStorage(h, s); e != nil {
		t.Fatal(e)
	}
	sid = handle(successful(t, r, "server.create", map[string]any{"cache": h, "regionID": 1, "derpMapURL": "http://127.0.0.1:1/unused"}))
	successful(t, r, "server.start", map[string]any{"handle": sid})
}

func TestServerCloseDuringCachePrefetchPreventsStartup(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	body, e := json.Marshal(relay.Map)
	if e != nil {
		t.Fatal(e)
	}
	wire, e := json.Marshal(cacheEntry{Data: body, StoredAt: time.Now().UnixNano(), OK: true})
	if e != nil {
		t.Fatal(e)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	s := &testCacheStorage{get: func(string) string { close(entered); <-release; return string(wire) }, put: func(string, string) string { return "" }}
	if e := r.SetCacheStorage(h, s); e != nil {
		t.Fatal(e)
	}
	sid := handle(successful(t, r, "server.create", map[string]any{"cache": h, "regionID": 1}))
	server, e := getAs[*serverResource](r, sid)
	if e != nil {
		t.Fatal(e)
	}
	_, starting := begin(r, "server.start", map[string]any{"handle": sid})
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("no prefetch callback")
	}
	_, closing := begin(r, "resource.close", map[string]any{"handle": sid})
	observed := make(chan bool, 1)
	go func() {
		deadline := time.Now().Add(500 * time.Millisecond)
		for time.Now().Before(deadline) {
			server.mu.Lock()
			closed := server.closed
			server.mu.Unlock()
			if closed {
				observed <- true
				return
			}
			time.Sleep(time.Millisecond)
		}
		observed <- false
	}()
	select {
	case closed := <-observed:
		if !closed {
			t.Error("server was not invalidated during prefetch")
		}
	case <-time.After(time.Second):
		t.Error("close state blocked behind cache callback")
	}
	close(release)
	if a := await(t, starting); a.code != 2 && a.code != 3 {
		t.Fatal("startup survived close", a)
	}
	if a := await(t, closing); a.code != 0 {
		t.Fatal(a)
	}
	server.mu.Lock()
	started := server.started
	server.mu.Unlock()
	if started {
		t.Fatal("closed prefetch started native server")
	}
}

func TestConcurrentServerStartsSerializeAfterCachePrefetch(t *testing.T) {
	relay, e := relayfixture.Start()
	if e != nil {
		t.Fatal(e)
	}
	defer relay.Close()
	r := NewRuntime()
	defer r.Close()
	h := handle(successful(t, r, "cache.create", map[string]any{}))
	body, e := json.Marshal(relay.Map)
	if e != nil {
		t.Fatal(e)
	}
	wire, e := json.Marshal(cacheEntry{Data: body, StoredAt: time.Now().UnixNano(), OK: true})
	if e != nil {
		t.Fatal(e)
	}
	arrived, release := make(chan struct{}, 2), make(chan struct{})
	s := &testCacheStorage{get: func(string) string { arrived <- struct{}{}; <-release; return string(wire) }, put: func(string, string) string { return "" }}
	if e := r.SetCacheStorage(h, s); e != nil {
		t.Fatal(e)
	}
	sid := handle(successful(t, r, "server.create", map[string]any{"cache": h, "regionID": 1}))
	_, first := begin(r, "server.start", map[string]any{"handle": sid})
	_, second := begin(r, "server.start", map[string]any{"handle": sid})
	for i := 0; i < 2; i++ {
		select {
		case <-arrived:
		case <-time.After(time.Second):
			close(release)
			t.Fatal("prefetch serialized under server state lock")
		}
	}
	close(release)
	for _, cb := range []callback{first, second} {
		if a := await(t, cb); a.code != 0 {
			t.Fatal("duplicate actual startup", a)
		}
	}
}
