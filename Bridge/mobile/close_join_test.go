package mobile

import (
	"fmt"
	"testing"
	"time"
)

func TestConcurrentCloseJoinsParentTriggeredCleanup(t *testing.T) {
	r := NewRuntime()
	defer r.Close()
	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	parent, e := r.NewOperation().add(struct{}{}, 0, func() error { return nil })
	if e != nil {
		t.Fatal(e)
	}
	child, e := r.NewOperation().add(struct{}{}, parent, func() error { close(entered); <-release; return nil })
	if e != nil {
		t.Fatal(e)
	}
	_, first := begin(r, "resource.close", map[string]any{"handle": parent})
	<-entered
	_, second := begin(r, "resource.close", map[string]any{"handle": child})
	_, third := begin(r, "resource.close", map[string]any{"handle": parent})
	for _, cb := range []callback{first, second, third} {
		select {
		case a := <-cb:
			t.Fatalf("close returned before cleanup barrier: %d", a.code)
		case <-time.After(20 * time.Millisecond):
		}
	}
	close(release)
	for _, cb := range []callback{first, second, third} {
		if a := awaitPromptly(t, cb); a.code != 0 {
			t.Fatalf("joined close %d %s", a.code, a.message)
		}
	}
}

func TestParentAndRuntimeJoinAlreadyClosingChild(t *testing.T) {
	for _, mode := range []string{"parent", "runtime"} {
		t.Run(mode, func(t *testing.T) {
			r := NewRuntime()
			defer r.Close()
			entered, release := make(chan struct{}), make(chan struct{})
			defer func() {
				select {
				case <-release:
				default:
					close(release)
				}
			}()
			parent, _ := r.NewOperation().add(struct{}{}, 0, func() error { return nil })
			child, _ := r.NewOperation().add(struct{}{}, parent, func() error { close(entered); <-release; return nil })
			firstOperation, first := begin(r, "resource.close", map[string]any{"handle": child})
			<-entered
			var second callback
			if mode == "parent" {
				_, second = begin(r, "resource.close", map[string]any{"handle": parent})
			} else {
				second = make(callback, 1)
				go func() { e := r.Close(); code, message := errorCode(e); second.Complete("", code, message) }()
				// Start the next close after runtime shutdown interrupts admitted
				// operations. Both close operations must still join actual cleanup.
				select {
				case <-firstOperation.ctx.Done():
				case <-time.After(2 * time.Second):
					t.Fatal("runtime did not begin cancelling admitted operations")
				}
			}
			third := make(callback, 1)
			thirdOperation := r.NewOperation()
			if mode == "runtime" {
				// Swift permits a cleanup operation to be created after shutdown;
				// cancellation before Begin must not skip joining that cleanup.
				thirdOperation.Cancel()
			}
			thirdOperation.Begin("resource.close", fmt.Sprintf(`{"handle":%d}`, child), third)
			for _, cb := range []callback{first, second, third} {
				select {
				case a := <-cb:
					t.Fatalf("close returned before cleanup: %d", a.code)
				case <-time.After(20 * time.Millisecond):
				}
			}
			close(release)
			for _, cb := range []callback{first, second, third} {
				if a := awaitPromptly(t, cb); a.code != 0 {
					t.Fatalf("joined close %d %s", a.code, a.message)
				}
			}
		})
	}
}
