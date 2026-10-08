package mobile

import (
	"context"
	"github.com/tailscale/tailcat"
	"net"
	"strings"
	"time"
)

func (o *Operation) lookup(q *request) (any, error) {
	name := strings.TrimSpace(q.Name)
	if _, e := tailcat.ParseAddr(tailcat.Addr(name)); e == nil {
		return map[string]any{"address": name, "dnsName": ""}, nil
	}
	if !strings.Contains(name, ".") {
		return nil, invalid("name is neither a Tailcat address nor a DNS name")
	}
	for _, label := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if _, e := tailcat.ParseAddr(tailcat.Addr(label)); e == nil {
			return nil, invalid("refusing DNS lookup containing a secret Tailcat address label")
		}
	}
	resolver := net.DefaultResolver
	if q.Resolver != "" {
		if _, _, e := net.SplitHostPort(q.Resolver); e != nil {
			return nil, invalid("resolver must be host:port")
		}
		resolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, q.Resolver)
		}}
	}
	ctx, cancel := context.WithTimeout(o.ctx, 5*time.Second)
	defer cancel()
	records, e := resolver.LookupTXT(ctx, name)
	if e != nil {
		return nil, e
	}
	for _, record := range records {
		if value, ok := strings.CutPrefix(record, "tailcat="); ok {
			address := strings.TrimSpace(value)
			if _, e := tailcat.ParseAddr(tailcat.Addr(address)); e != nil {
				return nil, invalid("invalid Tailcat address in TXT record")
			}
			return map[string]any{"address": address, "dnsName": name}, nil
		}
	}
	return nil, invalid("no tailcat= TXT record for DNS name")
}
