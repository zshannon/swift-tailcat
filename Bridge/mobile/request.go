package mobile

import (
	"encoding/json"
	"github.com/tailscale/tailcat"
	upstreamperf "github.com/zshannon/swift-tailcat/bridge/internal/upstreamperf"
	"tailscale.com/tailcfg"
	"time"
)

type portRange struct {
	First int `json:"first"`
	Last  int `json:"last"`
}
type request struct {
	Write               bool                 `json:"write"`
	Environment         map[string]string    `json:"environment"`
	Resolver            string               `json:"resolver"`
	Name                string               `json:"name"`
	Handle              int64                `json:"handle"`
	Other               int64                `json:"other"`
	Cache               int64                `json:"cache"`
	Address             string               `json:"address"`
	Local               string               `json:"local"`
	Remote              string               `json:"remote"`
	Network             string               `json:"network"`
	Port                int                  `json:"port"`
	Count               int                  `json:"count"`
	Data                []byte               `json:"data"`
	Key                 string               `json:"key"`
	DiscoKey            string               `json:"discoKey"`
	PrivateKey          string               `json:"privateKey"`
	PresharedKey        string               `json:"presharedKey"`
	Info                tailcat.ConnInfo     `json:"info"`
	Identity            json.RawMessage      `json:"identity"`
	Region              *tailcfg.DERPRegion  `json:"region"`
	RegionID            tailcfg.DERPRegionID `json:"regionID"`
	Map                 *tailcfg.DERPMap     `json:"map"`
	DERPMapURL          string               `json:"derpMapURL"`
	ForServer           bool                 `json:"forServer"`
	DisablePresharedKey bool                 `json:"disablePresharedKey"`
	AllowedClients      *[]string            `json:"allowedClients"`
	AllowedProxies      *[]string            `json:"allowedProxies"`
	ServedTCPPorts      *[]portRange         `json:"servedTCPPorts"`
	ServedUDPPorts      *[]portRange         `json:"servedUDPPorts"`
	UDPIdleTimeout      time.Duration        `json:"udpIdleTimeout"`
	ExitNode            bool                 `json:"exitNode"`
	LocalPortHost       string               `json:"localPortHost"`
	URL                 string               `json:"url"`
	Etag                string               `json:"etag"`
	StoredAt            *int64               `json:"storedAt"`
	ReadDeadline        *int64               `json:"readDeadline"`
	WriteDeadline       *int64               `json:"writeDeadline"`
	Packet              bool                 `json:"packet"`
	Bind                string               `json:"bind"`
	Kind                string               `json:"kind"`
	Exec                []string             `json:"exec"`
	SSH                 *tailcat.SSHOptions  `json:"ssh"`
	Keys                []string             `json:"keys"`
	MaxStreams          int                  `json:"maxStreams"`
	MaxDuration         time.Duration        `json:"maxDuration"`
	Params              upstreamperf.Params  `json:"params"`
	AllowSharedRelay    bool                 `json:"allowSharedRelay"`
	RequireDirect       bool                 `json:"requireDirect"`
	User                string               `json:"user"`
	PrivateKeys         []string             `json:"privateKeys"`
	HostKey             string               `json:"hostKey"`
	Command             string               `json:"command"`
	Input               []byte               `json:"input"`
	PTY                 *ptyOptions          `json:"pty"`
	Width               int                  `json:"width"`
	Height              int                  `json:"height"`
	Path                string               `json:"path"`
	Destination         string               `json:"destination"`
	Offset              int64                `json:"offset"`
	Create              bool                 `json:"create"`
	Truncate            bool                 `json:"truncate"`
	Mode                uint32               `json:"mode"`
	AccessTime          int64                `json:"accessTime"`
	ModifyTime          int64                `json:"modifyTime"`
}
type ptyOptions struct {
	Term   string `json:"term"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}
