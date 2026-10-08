//go:build !darwin || ios

package mobile

import "os/exec"

func configureProcess(cmd *exec.Cmd) {}
