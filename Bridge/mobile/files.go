package mobile

import (
	"context"
	"errors"
	"github.com/pkg/sftp"
	"io"
	"sync/atomic"
)

type fileResource struct {
	ssh       *sshResource
	sshHandle int64
	file      *sftp.File
	readBusy  atomic.Bool
	writeBusy atomic.Bool
}

func (o *Operation) fileMethod(method string, q *request) (any, error) {
	v, e := getAs[*fileResource](o.runtime, q.Handle)
	if e != nil {
		return nil, e
	}
	stop := context.AfterFunc(o.ctx, func() { v.ssh.client.Close(); o.runtime.closeHandleInternal(v.sshHandle) })
	defer stop()
	switch method {
	case "sftp.file.stat":
		f, e := v.file.Stat()
		if e != nil {
			return nil, e
		}
		return fileInfo(f), nil
	case "sftp.file.read":
		if q.Offset < 0 || q.Count <= 0 || q.Count > 16*1024*1024 {
			return nil, invalid("invalid file read offset/count")
		}
		if !v.readBusy.CompareAndSwap(false, true) {
			return nil, invalid("file read already in progress")
		}
		defer v.readBusy.Store(false)
		buf := make([]byte, q.Count)
		n, e := v.file.ReadAt(buf, q.Offset)
		eof := errors.Is(e, io.EOF)
		if eof {
			e = nil
		}
		return map[string]any{"data": buf[:n], "eof": eof}, e
	case "sftp.file.write":
		if q.Offset < 0 {
			return nil, invalid("negative file offset")
		}
		if !v.writeBusy.CompareAndSwap(false, true) {
			return nil, invalid("file write already in progress")
		}
		defer v.writeBusy.Store(false)
		n, e := v.file.WriteAt(q.Data, q.Offset)
		return map[string]any{"count": n}, e
	}
	return nil, unsupported("unknown persistent file method")
}
