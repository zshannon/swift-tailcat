// Command fixture starts a temporary owned relay and prints one DERPMap JSON line.
package main

import (
	"encoding/json"
	"fmt"
	"github.com/zshannon/swift-tailcat/bridge/mobile/fixture"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	f, e := fixture.Start()
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	defer f.Close()
	json.NewEncoder(os.Stdout).Encode(f.Map)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	<-signals
}
