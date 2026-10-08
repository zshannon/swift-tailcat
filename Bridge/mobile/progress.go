package mobile

import (
	upstreamperf "github.com/zshannon/swift-tailcat/bridge/internal/upstreamperf"
	"sync"
)

const maxProgressSnapshots = 1024

// progressBuffer freezes a bounded, ordered snapshot before Run returns to JSON
// encoding. Late official progress callbacks are harmless and retain no resources.
type progressBuffer struct {
	mu       sync.Mutex
	items    []upstreamperf.Progress
	next     int
	dropped  int64
	finished bool
	notify   func(upstreamperf.Progress)
	wg       sync.WaitGroup
	frozen   []upstreamperf.Progress
}

func (p *progressBuffer) add(v upstreamperf.Progress) {
	p.mu.Lock()
	if p.finished {
		p.mu.Unlock()
		return
	}
	if len(p.items) < maxProgressSnapshots {
		p.items = append(p.items, v)
	} else {
		p.items[p.next] = v
		p.next = (p.next + 1) % maxProgressSnapshots
		p.dropped++
	}
	notify := p.notify
	if notify != nil {
		p.wg.Add(1)
	}
	p.mu.Unlock()
	if notify != nil {
		defer p.wg.Done()
		notify(v)
	}
}
func (p *progressBuffer) finish() ([]upstreamperf.Progress, int64) {
	p.mu.Lock()
	if !p.finished {
		p.finished = true
		p.frozen = make([]upstreamperf.Progress, 0, len(p.items))
		p.frozen = append(p.frozen, p.items[p.next:]...)
		p.frozen = append(p.frozen, p.items[:p.next]...)
		p.items = nil
		p.notify = nil
	}
	frozen, dropped := append([]upstreamperf.Progress(nil), p.frozen...), p.dropped
	p.mu.Unlock()
	p.wg.Wait()
	return frozen, dropped
}
