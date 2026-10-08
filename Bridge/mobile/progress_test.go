package mobile

import (
	"encoding/json"
	upstreamperf "github.com/zshannon/swift-tailcat/bridge/internal/upstreamperf"
	"sync"
	"testing"
	"time"
)

func TestProgressBoundedOrderedAndFrozen(t *testing.T) {
	p := &progressBuffer{}
	for i := 0; i < 1031; i++ {
		p.add(upstreamperf.Progress{Elapsed: time.Duration(i)})
	}
	v, dropped := p.finish()
	if len(v) != 1024 || dropped != 7 {
		t.Fatalf("progress len=%d dropped=%d", len(v), dropped)
	}
	if v[0].Elapsed != 7 || v[1023].Elapsed != 1030 {
		t.Fatal("progress not ordered")
	}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 1000; n++ {
				p.add(upstreamperf.Progress{Elapsed: -1})
			}
		}()
	}
	wg.Wait()
	v2, d2 := p.finish()
	if len(v2) != len(v) || d2 != dropped || v[0].Elapsed != 7 {
		t.Fatal("late callbacks changed frozen snapshot")
	}
}

type liveObserver struct {
	updates chan string
	mu      sync.Mutex
	count   int
}

func (p *liveObserver) Update(result string) {
	p.mu.Lock()
	p.count++
	p.mu.Unlock()
	select {
	case p.updates <- result:
	default:
	}
}
func TestLivePerfProgressBeforeCompletionAndCancellation(t *testing.T) {
	r, sid, cid := fixture(t)
	successful(t, r, "server.service", map[string]any{"handle": sid, "port": 5201, "kind": "perf"})
	for _, cancelled := range []bool{false, true} {
		p := &liveObserver{updates: make(chan string, 16)}
		op := r.NewOperation()
		if e := op.SetProgress(p); e != nil {
			t.Fatal(e)
		}
		cb := make(callback, 1)
		duration := 300 * time.Millisecond
		if cancelled {
			duration = 3 * time.Second
		}
		q := map[string]any{"handle": cid, "allowSharedRelay": true, "params": map[string]any{"proto": "tcp", "dir": "up", "duration": int64(duration), "interval": int64(100 * time.Millisecond), "streams": 1, "length": 512, "bitrate": 1000000}}
		input, _ := json.Marshal(q)
		op.Begin("perf.run", string(input), cb)
		select {
		case snapshot := <-p.updates:
			var v map[string]any
			if e := json.Unmarshal([]byte(snapshot), &v); e != nil || v["Elapsed"] == nil {
				t.Fatalf("invalid progress %s", snapshot)
			}
		case result := <-cb:
			t.Fatalf("completion arrived before live progress: %d %s", result.code, result.message)
		case <-time.After(10 * time.Second):
			t.Fatal("no live progress")
		}
		if e := op.SetProgress(nil); e == nil {
			t.Fatal("changed progress callback after Begin")
		}
		if cancelled {
			op.Cancel()
		}
		result := await(t, cb)
		expected := 0
		if cancelled {
			expected = 2
		}
		if result.code != expected {
			t.Fatalf("perf completion %d %s", result.code, result.message)
		}
		op.mu.Lock()
		held := op.progress != nil
		op.mu.Unlock()
		if held {
			t.Fatal("operation retains progress callback after completion")
		}
		p.mu.Lock()
		count := p.count
		p.mu.Unlock()
		time.Sleep(150 * time.Millisecond)
		p.mu.Lock()
		after := p.count
		p.mu.Unlock()
		if after != count {
			t.Fatal("progress callback arrived after completion")
		}
	}
}
