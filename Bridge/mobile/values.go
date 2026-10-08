package mobile

import (
	"encoding/json"
	"github.com/tailscale/tailcat"
	"runtime"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"time"
)

func (o *Operation) options(q *request) ([]any, error) {
	var opts []any
	if q.DERPMapURL != "" {
		opts = append(opts, tailcat.DERPMapURL(q.DERPMapURL))
	}
	if q.ForServer {
		opts = append(opts, tailcat.ExpandForServer)
	}
	if q.Cache != 0 {
		c, e := getCache(o.runtime, q.Cache)
		if e != nil {
			return nil, e
		}
		opts = append(opts, c)
	}
	return opts, nil
}
func parsePrivate(s string) (key.NodePrivate, error) {
	var k key.NodePrivate
	if s != "" {
		if e := k.UnmarshalText([]byte(s)); e != nil {
			return k, invalid("invalid private key: %v", e)
		}
	}
	return k, nil
}
func parseNode(s string) (key.NodePublic, error) {
	var k key.NodePublic
	if e := k.UnmarshalText([]byte(s)); e != nil {
		return k, invalid("invalid public key: %v", e)
	}
	return k, nil
}
func parsePSK(s string) (tailcat.PresharedKey, error) {
	var k tailcat.PresharedKey
	if s != "" {
		if e := k.UnmarshalText([]byte(s)); e != nil {
			return k, invalid("invalid preshared key: %v", e)
		}
	}
	return k, nil
}
func (o *Operation) values(method string, q *request) (any, bool, error) {
	ctx := o.ctx
	switch method {
	case "capabilities":
		return map[string]any{"processExecution": runtime.GOOS == "darwin", "sshServer": tailcat.SupportsSSHServer(), "maxUDPPayload": tailcat.MaxUDPPayload, "defaultUDPIdleTimeout": int64(tailcat.DefaultUDPIdleTimeout), "upstreamRevision": "b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f"}, true, nil
	case "documentation.readme":
		return tailcat.README, true, nil
	case "identity.generate":
		return tailcat.NewPrivateKey(), true, nil
	case "identity.import":
		var k tailcat.PrivateKey
		if len(q.Identity) == 0 {
			return nil, true, invalid("identity is required")
		}
		if e := json.Unmarshal(q.Identity, &k); e != nil {
			return nil, true, invalid("invalid identity: %v", e)
		}
		if k.Private.IsZero() || k.Private.Public() != k.Public.ServerPublic.NodePublic {
			return nil, true, invalid("identity public/private key mismatch")
		}
		return &k, true, nil
	case "key.public", "key.disco":
		k, e := parsePrivate(q.PrivateKey)
		if e != nil {
			return nil, true, e
		}
		if k.IsZero() {
			return nil, true, invalid("privateKey is required")
		}
		if method == "key.public" {
			p := tailcat.NodePublic{NodePublic: k.Public()}
			b, _ := p.MarshalBinary()
			return map[string]any{"key": p.String(), "data": b}, true, nil
		}
		p := tailcat.DiscoPublicForNode(k)
		b, _ := p.MarshalBinary()
		return map[string]any{"key": p.String(), "data": b}, true, nil
	case "key.preshared":
		p := tailcat.NewPresharedKey()
		var e error
		if q.Data != nil {
			e = p.UnmarshalBinary(q.Data)
		} else if q.Key != "" {
			e = p.UnmarshalText([]byte(q.Key))
		}
		if e != nil {
			return nil, true, invalid("invalid PSK: %v", e)
		}
		b, _ := p.MarshalBinary()
		text, _ := p.MarshalText()
		return map[string]any{"key": string(text), "data": b, "isZero": p.IsZero()}, true, nil
	case "address.parse", "address.raw", "address.resolve":
		if method == "address.resolve" {
			freezeVerbose()
		}
		if q.Address == "" {
			return nil, true, invalid("address is required")
		}
		if method == "address.raw" {
			v, e := tailcat.ParseAddrRaw(tailcat.Addr(q.Address))
			if e != nil {
				e = invalid("invalid address: %v", e)
			}
			return v, true, e
		}
		ci, e := tailcat.ParseAddr(tailcat.Addr(q.Address))
		if e != nil {
			return nil, true, invalid("invalid address: %v", e)
		}
		if method == "address.parse" {
			return ci, true, nil
		}
		opts, e := o.options(q)
		if e != nil {
			return nil, true, e
		}
		if q.Map != nil {
			for _, region := range q.Map.Regions {
				if e := validateRegions([]*tailcfg.DERPRegion{region}); e != nil {
					return nil, true, e
				}
			}
			opts = append(opts, q.Map)
		}
		a, e := tailcat.Addr(q.Address).Resolve(ctx, opts...)
		return map[string]any{"address": string(a)}, true, e
	case "disco.encodePing":
		k, e := parseNode(q.Key)
		if e != nil {
			return nil, true, e
		}
		var d key.DiscoPublic
		if e = d.UnmarshalText([]byte(q.DiscoKey)); e != nil {
			return nil, true, invalid("invalid discovery key")
		}
		return map[string]any{"data": tailcat.EncodeMeowPing(k, d)}, true, nil
	case "disco.parsePing":
		k, d, ok := tailcat.ParseMeowPing(q.Data)
		return map[string]any{"key": k.String(), "discoKey": d.String(), "ok": ok}, true, nil
	case "disco.encodePong":
		return map[string]any{"data": tailcat.EncodeMeowed()}, true, nil
	case "disco.inspect":
		return map[string]any{"isMeow": tailcat.IsMeowPacket(q.Data), "isMeowed": tailcat.IsMeowedPacket(q.Data)}, true, nil
	case "address.expand":
		freezeVerbose()
		if e := validateRegions(q.Info.Region); e != nil {
			return nil, true, e
		}
		opts, e := o.options(q)
		if e != nil {
			return nil, true, e
		}
		if q.Map != nil {
			opts = append(opts, q.Map)
		}
		e = q.Info.Expand(ctx, opts...)
		return q.Info, true, e
	case "key.node", "key.discovery":
		if method == "key.node" {
			var p tailcat.NodePublic
			var e error
			if q.Data != nil {
				e = p.UnmarshalBinary(q.Data)
			} else {
				e = p.UnmarshalText([]byte(q.Key))
			}
			if e != nil {
				return nil, true, invalid("invalid node key")
			}
			b, _ := p.MarshalBinary()
			return map[string]any{"key": p.String(), "data": b}, true, nil
		}
		var p tailcat.DiscoPublic
		var e error
		if q.Data != nil {
			e = p.UnmarshalBinary(q.Data)
		} else {
			e = p.UnmarshalText([]byte(q.Key))
		}
		if e != nil {
			return nil, true, invalid("invalid discovery key")
		}
		b, _ := p.MarshalBinary()
		return map[string]any{"key": p.String(), "data": b}, true, nil
	case "address.encode":
		if q.Info.ServerPublic.IsZero() || q.Info.ServerDiscoPublic.IsZero() {
			return nil, true, invalid("public and discovery keys are required")
		}
		if e := validateRegions(q.Info.Region); e != nil {
			return nil, true, e
		}
		return map[string]any{"address": string(q.Info.Addr())}, true, nil
	case "derp.fetch":
		freezeVerbose()
		opts, e := o.options(q)
		if e != nil {
			return nil, true, e
		}
		dm, e := tailcat.FetchDERPMap(ctx, opts...)
		return dm, true, e
	case "derp.pick":
		freezeVerbose()
		if q.Map == nil {
			return nil, true, invalid("map is required")
		}
		for _, r := range q.Map.Regions {
			if e := validateRegions([]*tailcfg.DERPRegion{r}); e != nil {
				return nil, true, e
			}
		}
		id, e := tailcat.PickBestRegion(ctx, q.Map)
		return map[string]any{"region": id}, true, e
	case "cache.create":
		c := &cacheResource{entries: map[string]cacheEntry{}}
		h, e := o.add(c, 0, c.close)
		return map[string]any{"handle": h}, true, e
	case "cache.get", "cache.put":
		c, e := getCache(o.runtime, q.Handle)
		if e != nil {
			return nil, true, e
		}
		if q.URL == "" {
			return nil, true, invalid("url is required")
		}
		if method == "cache.get" {
			b, etag, stored, ok := c.Get(q.URL)
			return map[string]any{"data": b, "etag": etag, "storedAt": stored.UnixNano(), "ok": ok}, true, nil
		}
		stored := time.Now()
		if q.StoredAt != nil {
			stored = time.Unix(0, *q.StoredAt)
		}
		e = c.putAt(q.URL, q.Data, q.Etag, stored)
		return nil, true, e
	case "ssh.validateKeys":
		return nil, true, tailcat.ValidateSSHAuthorizedKeys(q.Keys)
	}
	return nil, false, nil
}
func validateRegions(regions []*tailcfg.DERPRegion) error {
	for _, r := range regions {
		if r == nil {
			return invalid("null region")
		}
		for _, n := range r.Nodes {
			if n == nil {
				return invalid("null relay node")
			}
		}
	}
	return nil
}
