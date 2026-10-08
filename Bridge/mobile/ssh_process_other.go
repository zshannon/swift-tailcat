//go:build !darwin || ios

package mobile

import (
	"context"
	gliderssh "github.com/tailscale/gliderssh"
	"github.com/tailscale/tailcat"
)

func runSSHProcess(context.Context, *tailcat.Server, gliderssh.Session, []string) error {
	return unsupported("local process execution is supported only on macOS")
}
