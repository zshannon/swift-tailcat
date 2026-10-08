//go:build darwin && !ios

package mobile

import (
	"context"
	"github.com/creack/pty"
	gliderssh "github.com/tailscale/gliderssh"
	"github.com/tailscale/tailcat"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

func runSSHProcess(ctx context.Context, s *tailcat.Server, session gliderssh.Session, forced []string) error {
	argv := forced
	if len(argv) == 0 {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/sh"
		}
		if session.RawCommand() == "" {
			argv = []string{shell, "-l"}
		} else {
			argv = []string{shell, "-c", session.RawCommand()}
		}
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	configureProcess(cmd)
	cmd.Env = append(os.Environ(), s.PeerEnv(session.LocalAddr(), session.RemoteAddr())...)
	for _, env := range session.Environ() {
		name, _, ok := strings.Cut(env, "=")
		if ok && (name == "TERM" || name == "COLORTERM" || name == "LANG" || strings.HasPrefix(name, "LC_")) {
			cmd.Env = append(cmd.Env, env)
		}
	}
	if len(forced) > 0 && session.RawCommand() != "" {
		cmd.Env = append(cmd.Env, "SSH_ORIGINAL_COMMAND="+session.RawCommand())
	}
	if len(forced) == 0 {
		cmd.Dir, _ = os.UserHomeDir()
	}
	request, windows, isPTY := session.Pty()
	if isPTY {
		if managed, ok := session.Context().Value(managedWindowsKey{}).(*managedWindows); ok {
			request.Window, windows = managed.snapshot()
		}
		session.DisablePTYEmulation()
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true}
		cmd.Env = append(cmd.Env, "TERM="+request.Term)
		terminal, e := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(request.Window.Height), Cols: uint16(request.Window.Width)})
		if e != nil {
			return e
		}
		defer terminal.Close()
		resizeDone := make(chan struct{})
		resizeExited := make(chan struct{})
		defer func() { close(resizeDone); <-resizeExited }()
		go func() {
			defer close(resizeExited)
			for {
				select {
				case w, ok := <-windows:
					if !ok {
						return
					}
					pty.Setsize(terminal, &pty.Winsize{Rows: uint16(w.Height), Cols: uint16(w.Width)})
				case <-resizeDone:
					return
				}
			}
		}()
		go io.Copy(terminal, session)
		io.Copy(session, terminal)
		return cmd.Wait()
	}
	input, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	stdout, e := cmd.StdoutPipe()
	if e != nil {
		input.Close()
		return e
	}
	stderr, e := cmd.StderrPipe()
	if e != nil {
		input.Close()
		stdout.Close()
		return e
	}
	if e = cmd.Start(); e != nil {
		input.Close()
		stdout.Close()
		stderr.Close()
		return e
	}
	go func() { io.Copy(input, session); input.Close() }()
	done := make(chan struct{})
	go func() { io.Copy(session.Stderr(), stderr); close(done) }()
	io.Copy(session, stdout)
	<-done
	return cmd.Wait()
}
