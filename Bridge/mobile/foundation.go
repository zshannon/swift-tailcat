package mobile

import (
	"encoding/json"
	"github.com/tailscale/tailcat"
)

// ConfigureVerbose configures the existing process-wide, frozen-on-use setting.
func ConfigureVerbose(verbose bool) error {
	verbosity.Lock()
	defer verbosity.Unlock()
	if verbosity.frozen {
		return invalid("process verbosity is frozen after first network use")
	}
	tailcat.Verbose = verbose
	return nil
}

// GenerateIdentity generates an identity without allocating a runtime or engine.
func GenerateIdentity() (string, error) {
	value, err := json.Marshal(tailcat.NewPrivateKey())
	return string(value), err
}

// GeneratePresharedKey generates a key without allocating a runtime or engine.
func GeneratePresharedKey() (string, error) {
	key := tailcat.NewPresharedKey()
	data, _ := key.MarshalBinary()
	text, _ := key.MarshalText()
	value, err := json.Marshal(map[string]any{"data": data, "isZero": key.IsZero(), "key": string(text)})
	return string(value), err
}

// AbortResource interrupts a subtree without joining operations or callbacks.
// Swift closes/joins the matching handles after this synchronous interruption.
func (r *Runtime) AbortResource(handle int64) {
	r.mu.Lock()
	selected := map[int64]bool{handle: true}
	for changed := true; changed; {
		changed = false
		for id, entry := range r.resources {
			if selected[entry.parent] && !selected[id] {
				selected[id] = true
				changed = true
			}
		}
		for id, closing := range r.closing {
			if selected[closing.entry.parent] && !selected[id] {
				selected[id] = true
				changed = true
			}
		}
	}
	var entries []any
	for id := range selected {
		if entry := r.resources[id]; entry != nil {
			entries = append(entries, entry.value)
		}
		if closing := r.closing[id]; closing != nil {
			entries = append(entries, closing.entry.value)
		}
	}
	var operations []*Operation
	for operation := range r.operations {
		for _, reference := range operation.references {
			if selected[reference] {
				operations = append(operations, operation)
				break
			}
		}
	}
	r.mu.Unlock()
	for _, operation := range operations {
		operation.Cancel()
	}
	for _, entry := range entries {
		interruptTransport(entry)
	}
}
