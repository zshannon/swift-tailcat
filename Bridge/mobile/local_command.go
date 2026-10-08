package mobile

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

type proxyServiceResource struct{ listener net.Listener }

func (o *Operation) socksCommand(q *request) (any, error) {
	if runtime.GOOS != "darwin" {
		return nil, unsupported("proxy command execution is supported only on macOS")
	}
	if len(q.Exec) == 0 || strings.TrimSpace(q.Exec[0]) == "" {
		return nil, invalid("exec must contain a nonempty program")
	}
	service, e := getAs[*proxyServiceResource](o.runtime, q.Handle)
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithCancel(o.ctx)
	done := make(chan struct{})
	h, e := o.add(cancel, q.Handle, func() error { cancel(); return nil })
	if e != nil {
		cancel()
		close(done)
		return nil, e
	}
	defer o.runtime.closeHandleInternal(h)
	cmd := exec.CommandContext(ctx, q.Exec[0], q.Exec[1:]...)
	configureProcess(cmd)
	cmd.WaitDelay = 2 * time.Second
	cmd.Env = os.Environ()
	for name, value := range q.Environment {
		if name == "" || strings.ContainsAny(name, "=\x00") || strings.ContainsRune(value, '\x00') {
			close(done)
			return nil, invalid("invalid environment entry")
		}
		cmd.Env = append(cmd.Env, name+"="+value)
	}
	url := "socks5h://" + service.listener.Addr().String()
	for _, name := range []string{"ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"} {
		cmd.Env = append(cmd.Env, name+"="+url)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	e = cmd.Run()
	close(done)
	exit := 0
	if e != nil {
		var ee *exec.ExitError
		if errors.As(e, &ee) {
			exit = ee.ExitCode()
		} else {
			return nil, e
		}
	}
	return map[string]any{"stdout": stdout.Bytes(), "stderr": stderr.Bytes(), "exitCode": exit}, nil
}
