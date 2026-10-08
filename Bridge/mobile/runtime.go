// Package mobile is the gomobile-safe asynchronous Tailcat boundary.
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/pkg/sftp"
	"io"
	"net"
	"os"
	"sync"
)

// Completion receives exactly one JSON result on a Go goroutine.
type Completion interface {
	Complete(result string, code int, message string)
}

// Policy decides admission and proxy destinations synchronously. Callbacks must not
// wait on an actor that is awaiting a bridge operation.
type Policy interface {
	AllowClient(key string) bool
	AllowProxy(endpoint string) bool
}

type bridgeError struct {
	code    int
	message string
}

func (e *bridgeError) Error() string       { return e.message }
func invalid(f string, a ...any) error     { return &bridgeError{1, fmt.Sprintf(f, a...)} }
func unsupported(f string, a ...any) error { return &bridgeError{4, fmt.Sprintf(f, a...)} }

var errClosed = &bridgeError{3, "resource or runtime is closed"}

type resource struct {
	value  any
	parent int64
	close  func() error
}

type closeGroup struct {
	done chan struct{}
	err  error
}
type closingResource struct {
	entry *resource
	group *closeGroup
}

// Runtime owns all resource handles and in-flight operations.
type Runtime struct {
	mu         sync.Mutex
	resources  map[int64]*resource
	closing    map[int64]*closingResource
	operations map[*Operation]struct{}
	next       int64
	closed     bool
	wg         sync.WaitGroup
	closeDone  chan struct{}
	closeErr   error
}

// Operation is a one-shot cancellable asynchronous call.
type Operation struct {
	runtime         *Runtime
	mu              sync.Mutex
	ctx             context.Context
	cancel          context.CancelFunc
	begun, finished bool
	created         []int64
	references      []int64
	done            chan struct{}
	progress        Progress
}

func NewRuntime() *Runtime {
	return &Runtime{resources: map[int64]*resource{}, closing: map[int64]*closingResource{}, operations: map[*Operation]struct{}{}, closeDone: make(chan struct{})}
}
func (r *Runtime) NewOperation() *Operation {
	ctx, cancel := context.WithCancel(context.Background())
	return &Operation{runtime: r, ctx: ctx, cancel: cancel, done: make(chan struct{})}
}
func (o *Operation) Cancel() {
	o.mu.Lock()
	if !o.finished {
		o.cancel()
	}
	o.mu.Unlock()
}
func (o *Operation) Begin(method, input string, completion Completion) {
	o.mu.Lock()
	if o.begun {
		o.mu.Unlock()
		return
	}
	o.begun = true
	o.mu.Unlock()
	r := o.runtime
	r.mu.Lock()
	closed := r.closed
	if !closed {
		r.operations[o] = struct{}{}
		r.wg.Add(1)
	}
	r.mu.Unlock()
	go func() {
		defer close(o.done)
		if !closed {
			defer func() { r.mu.Lock(); delete(r.operations, o); r.mu.Unlock(); r.wg.Done() }()
		}
		var result any
		var err error
		func() {
			defer func() {
				if p := recover(); p != nil {
					err = fmt.Errorf("adapter panic contained: %v", p)
				}
			}()
			if closed && method != "resource.close" {
				err = errClosed
				return
			}
			// Cleanup must execute/join even when cancellation predates Begin.
			// Its cancellation callback still interrupts the owned transport.
			if method != "resource.close" {
				if err = o.ctx.Err(); err != nil {
					return
				}
			}
			var q request
			if err = decodeRequest(input, &q); err != nil {
				return
			}
			if method != "resource.close" {
				r.mu.Lock()
				o.references = []int64{q.Handle, q.Other, q.Cache}
				r.mu.Unlock()
			}
			result, err = o.execute(method, &q)
		}()
		o.mu.Lock()
		// A later zero-progress stream write can fail after earlier primitives
		// consumed bytes. Preserve that cause. Deadline interruption remains
		// cancellation, and resource-returning operations still dispose on cancel.
		var timeout net.Error
		writeFailed := method == "connection.write" && result != nil && err != nil && !(errors.As(err, &timeout) && timeout.Timeout())
		// A joined resource close reports its actual outcome, including genuine
		// cleanup failures, rather than the operation's interruption signal.
		if !closed && method != "resource.close" && o.ctx.Err() != nil && !consumedIO(method, result) && !writeFailed {
			err = o.ctx.Err()
		}
		o.finished = true
		o.progress = nil
		created := append([]int64(nil), o.created...)
		o.cancel()
		o.mu.Unlock()
		if err != nil {
			for _, h := range created {
				r.closeHandleInternal(h)
			}
		}
		code, message := errorCode(err)
		output := ""
		if err == nil {
			if result == nil {
				result = map[string]any{}
			}
			b, e := json.Marshal(result)
			if e != nil {
				code, message = errorCode(e)
				for _, h := range created {
					r.closeHandleInternal(h)
				}
			} else {
				output = string(b)
			}
		}
		if completion != nil {
			completion.Complete(output, code, message)
		}
	}()
}
func errorCode(err error) (int, string) {
	if err == nil {
		return 0, ""
	}
	var e *bridgeError
	if errors.As(err, &e) {
		return e.code, e.message
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return 2, err.Error()
	}
	return 5, err.Error()
}
func decodeRequest(input string, q *request) error {
	var object map[string]json.RawMessage
	if err := json.Unmarshal([]byte(input), &object); err != nil || object == nil {
		return invalid("input must be a JSON object")
	}
	if err := json.Unmarshal([]byte(input), q); err != nil {
		return invalid("invalid input: %v", err)
	}
	return nil
}
func (o *Operation) add(v any, parent int64, close func() error) (int64, error) {
	r := o.runtime
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		close()
		return 0, errClosed
	}
	if parent != 0 {
		if _, ok := r.resources[parent]; !ok {
			r.mu.Unlock()
			close()
			return 0, errClosed
		}
	}
	r.next++
	h := r.next
	r.resources[h] = &resource{v, parent, close}
	r.mu.Unlock()
	o.mu.Lock()
	o.created = append(o.created, h)
	o.mu.Unlock()
	return h, nil
}
func (r *Runtime) get(h int64) (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil, errClosed
	}
	v := r.resources[h]
	if v == nil {
		return nil, errClosed
	}
	return v.value, nil
}
func getAs[T any](r *Runtime, h int64) (T, error) {
	var zero T
	v, e := r.get(h)
	if e != nil {
		return zero, e
	}
	out, ok := v.(T)
	if !ok {
		return zero, invalid("handle has wrong resource type")
	}
	return out, nil
}
func (r *Runtime) closeHandle(h int64) error {
	return r.closeHandleMode(h, true)
}

// Cleanup reentry must not join its own enclosing close group. External callers
// always use closeHandle and join the shared completion, including parent closes.
func (r *Runtime) closeHandleInternal(h int64) error {
	return r.closeHandleMode(h, false)
}
func (r *Runtime) closeHandleMode(h int64, join bool) error {
	r.mu.Lock()
	if existing := r.closing[h]; existing != nil {
		r.mu.Unlock()
		if !join {
			return nil
		}
		<-existing.group.done
		return existing.group.err
	}
	// The upstream SFTP close sends stdin EOF and waits for a remote reply;
	// aborting it requires the SSH transport. Invalidate that entire owned
	// subtree so sibling handles cannot appear live after transport shutdown.
	if entry := r.resources[h]; entry != nil {
		if s, ok := entry.value.(*sftpResource); ok {
			h = s.sshHandle
		}
	}
	group := &closeGroup{done: make(chan struct{})}
	var selected []*resource
	selectedIDs := map[int64]bool{}
	dependencies := map[*closeGroup]bool{}
	var collect func(int64)
	collect = func(id int64) {
		if v := r.resources[id]; v != nil {
			delete(r.resources, id)
			selectedIDs[id] = true
			r.closing[id] = &closingResource{entry: v, group: group}
			for k, c := range r.resources {
				if c.parent == id {
					collect(k)
				}
			}
			for _, closing := range r.closing {
				if closing.entry.parent == id && closing.group != group {
					dependencies[closing.group] = true
				}
			}
			selected = append(selected, v)
		}
	}
	collect(h)
	var interrupted []*Operation
	for op := range r.operations {
		for _, ref := range op.references {
			if selectedIDs[ref] {
				interrupted = append(interrupted, op)
				break
			}
		}
	}
	r.mu.Unlock()
	if len(selected) == 0 {
		return nil
	}
	for _, op := range interrupted {
		op.Cancel()
	}
	// Abort SSH/SFTP transports before touching file locks or joining a file
	// close already waiting for its remote acknowledgement.
	for _, v := range selected {
		interruptTransport(v.value)
	}
	var first error
	for dependency := range dependencies {
		<-dependency.done
		if first == nil {
			first = dependency.err
		}
	}
	for _, v := range selected {
		if e := v.close(); e != nil && first == nil && !closedCleanupError(e) {
			first = e
		}
	}
	for _, op := range interrupted {
		<-op.done
	}
	r.mu.Lock()
	group.err = first
	close(group.done)
	for id := range selectedIDs {
		delete(r.closing, id)
	}
	r.mu.Unlock()
	return first
}

func closedCleanupError(e error) bool {
	return errors.Is(e, io.EOF) || errors.Is(e, net.ErrClosed) || errors.Is(e, os.ErrClosed) || errors.Is(e, sftp.ErrSSHFxConnectionLost) || errors.Is(e, sftp.ErrSSHFxNoConnection)
}

func interruptTransport(v any) {
	switch v := v.(type) {
	case *connectionResource:
		v.c.Close()
	case *listenerResource:
		v.ln.Close()
	case *sshResource:
		v.client.Close()
	case *sftpResource:
		v.ssh.client.Close()
	}
}
func (r *Runtime) interruptHandle(h int64) {
	r.mu.Lock()
	entry := r.resources[h]
	if entry == nil && r.closing[h] != nil {
		entry = r.closing[h].entry
	}
	r.mu.Unlock()
	if entry == nil {
		return
	}
	switch v := entry.value.(type) {
	case *fileResource:
		v.ssh.client.Close()
		r.closeHandleInternal(v.sshHandle)
	case *sessionResource:
		v.ssh.client.Close()
		r.closeHandleInternal(v.sshHandle)
	case *sftpResource:
		v.ssh.client.Close()
		r.closeHandleInternal(v.sshHandle)
	case *connectionResource:
		v.c.Close()
	default:
		interruptTransport(entry.value)
	}
}

// RequestShutdown rejects new work and interrupts transports synchronously.
// Joining callbacks and remote cleanup happens independently of the requester.
func (r *Runtime) RequestShutdown() {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	r.closed = true
	ops := make([]*Operation, 0, len(r.operations))
	for o := range r.operations {
		ops = append(ops, o)
	}
	handles := make([]int64, 0, len(r.resources))
	var transports []any
	for h := range r.resources {
		handles = append(handles, h)
		transports = append(transports, r.resources[h].value)
	}
	for h, closing := range r.closing {
		handles = append(handles, h)
		transports = append(transports, closing.entry.value)
	}
	r.mu.Unlock()
	for _, o := range ops {
		o.Cancel()
	}
	for _, v := range transports {
		interruptTransport(v)
	}
	go r.finishClose(handles)
}

func (r *Runtime) finishClose(handles []int64) {
	var first error
	for _, h := range handles {
		if e := r.closeHandle(h); e != nil && first == nil {
			first = e
		}
	}
	r.wg.Wait()
	r.mu.Lock()
	r.closeErr = first
	close(r.closeDone)
	r.mu.Unlock()
}

// Close joins the single shutdown outcome, including a previous request.
func (r *Runtime) Close() error {
	r.RequestShutdown()
	<-r.closeDone
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.closeErr
}

// SetPolicy installs callbacks before the server starts. Nil means allow all.
func (r *Runtime) SetPolicy(handle int64, policy Policy) error {
	s, e := getAs[*serverResource](r, handle)
	if e != nil {
		return e
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.started {
		return invalid("policy must be installed before startup")
	}
	s.policy = policy
	return nil
}

// Consumed stream bytes cannot be replayed after cancellation. Resource-returning
// operations still use cancellation disposal; only completed I/O wins this race.
func consumedIO(method string, result any) bool {
	fields, ok := result.(map[string]any)
	if !ok {
		return false
	}
	switch method {
	case "connection.read", "connection.readPacket":
		data, _ := fields["data"].([]byte)
		return len(data) > 0
	case "connection.write":
		count, _ := fields["count"].(int)
		return count > 0
	}
	return false
}
