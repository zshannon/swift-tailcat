package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"
)

// CacheStorage synchronously stores JSON entries. Get returns an empty string
// for a miss; Put returns an empty string on success or an error message.
// Callbacks run without bridge locks. They must return promptly and must not
// synchronously close their own cache/runtime, whose close joins callbacks.
type CacheStorage interface {
	Get(url string) string
	Put(url, entry string) string
}

type cacheEntry struct {
	Data     []byte `json:"data"`
	Etag     string `json:"etag"`
	StoredAt int64  `json:"storedAt"`
	OK       bool   `json:"ok"`
}

type cacheResource struct {
	mu           sync.Mutex
	entries      map[string]cacheEntry
	storage      CacheStorage
	used, closed bool
	wg           sync.WaitGroup
}

// SetCacheStorage installs storage before any direct use or attachment. Nil
// preserves the default memory storage. Registration never invokes user code.
func (r *Runtime) SetCacheStorage(handle int64, storage CacheStorage) error {
	c, err := getAs[*cacheResource](r, handle)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return errClosed
	}
	if c.used {
		return invalid("cache storage must be installed before use")
	}
	c.storage = storage
	return nil
}

func getCache(r *Runtime, handle int64) (*cacheResource, error) {
	c, err := getAs[*cacheResource](r, handle)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil, errClosed
	}
	c.used = true
	return c, nil
}

func (c *cacheResource) Get(url string) (data []byte, etag string, stored time.Time, ok bool) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.used = true
	sink := c.storage
	if sink == nil {
		v, found := c.entries[url]
		c.mu.Unlock()
		return append([]byte(nil), v.Data...), v.Etag, time.Unix(0, v.StoredAt), found
	}
	c.wg.Add(1)
	c.mu.Unlock()
	defer c.wg.Done()
	defer func() {
		if recover() != nil {
			data, etag, stored, ok = nil, "", time.Time{}, false
		}
	}()
	var wire struct {
		Data     json.RawMessage `json:"data"`
		Etag     *string         `json:"etag"`
		StoredAt *int64          `json:"storedAt"`
		OK       *bool           `json:"ok"`
	}
	if json.Unmarshal([]byte(sink.Get(url)), &wire) != nil || wire.Data == nil || wire.Etag == nil || wire.StoredAt == nil || wire.OK == nil || !*wire.OK {
		return
	}
	if json.Unmarshal(wire.Data, &data) != nil {
		return nil, "", time.Time{}, false
	}
	return data, *wire.Etag, time.Unix(0, *wire.StoredAt), true
}

func (c *cacheResource) Put(url string, data []byte, etag string) error {
	return c.putAt(url, data, etag, time.Now())
}

func (c *cacheResource) putAt(url string, data []byte, etag string, stored time.Time) (err error) {
	v := cacheEntry{append([]byte(nil), data...), etag, stored.UnixNano(), true}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errClosed
	}
	c.used = true
	sink := c.storage
	if sink == nil {
		c.entries[url] = v
		c.mu.Unlock()
		return nil
	}
	c.wg.Add(1)
	c.mu.Unlock()
	defer c.wg.Done()
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("cache storage panic contained: %v", p)
		}
	}()
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if message := sink.Put(url, string(b)); message != "" {
		return errors.New(message)
	}
	return nil
}

func (c *cacheResource) close() error {
	c.mu.Lock()
	c.closed = true
	c.storage = nil
	c.entries = nil
	c.mu.Unlock()
	c.wg.Wait()
	return nil
}
