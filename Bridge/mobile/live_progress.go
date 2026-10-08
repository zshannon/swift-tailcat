package mobile

import (
	"encoding/json"
	upstreamperf "github.com/zshannon/swift-tailcat/bridge/internal/upstreamperf"
)

// Progress receives live official perf Progress JSON on a Go goroutine.
type Progress interface{ Update(result string) }

// SetProgress installs a callback before Begin. Nil disables live reports.
func (o *Operation) SetProgress(progress Progress) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.begun {
		return invalid("progress callback must be installed before Begin")
	}
	o.progress = progress
	return nil
}
func (o *Operation) emitProgress(p upstreamperf.Progress) {
	b, e := json.Marshal(p)
	if e != nil {
		return
	}
	o.mu.Lock()
	sink := o.progress
	o.mu.Unlock()
	if sink != nil {
		defer func() { recover() }()
		sink.Update(string(b))
	}
}
