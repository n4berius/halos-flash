// Package dnsproviders is halOS's own Caddy glue for DNS providers whose caddy-dns plugin carries
// no licence: it registers the MIT-licensed libdns provider as a Caddy module. Written for halOS
// from Caddy's module interfaces and the libdns providers' exported fields; MIT, like the rest of
// halOS (the repository's LICENSE).
package dnsproviders

import (
	"context"
	"fmt"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/libdns/libdns"
	"github.com/libdns/duckdns"
)

// DuckDNS is the dns.providers.duckdns module.
//
//	dns duckdns <api_token>
//	dns duckdns {
//		api_token <token>
//		override_domain <domain>
//		resolver <host:port>
//	}
//
// Values may use placeholders, such as {file./run/credentials/halos-proxy.service/dns-token}.
type DuckDNS struct{ *duckdns.Provider }

func init() { caddy.RegisterModule(DuckDNS{}) }

// CaddyModule returns the module's information.
func (DuckDNS) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "dns.providers.duckdns",
		New: func() caddy.Module { return &DuckDNS{new(duckdns.Provider)} },
	}
}

// Provision fills in placeholders, then checks the values they gave.
func (p *DuckDNS) Provision(caddy.Context) error {
	r := caddy.NewReplacer()
	p.Provider.APIToken = r.ReplaceAll(p.Provider.APIToken, "")
	p.Provider.OverrideDomain = r.ReplaceAll(p.Provider.OverrideDomain, "")
	p.Provider.Resolver = r.ReplaceAll(p.Provider.Resolver, "")
	// The parse-time check saw only the placeholder; this one sees what the file held.
	if p.Provider.APIToken == "" {
		return fmt.Errorf("duckdns: the api_token is empty (its file missing or empty?)")
	}
	return nil
}

// UnmarshalCaddyfile reads the Caddyfile form above.
func (p *DuckDNS) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	d.Next() // the provider's name
	if d.NextArg() {
		p.Provider.APIToken = d.Val()
	}
	if d.NextArg() {
		return d.ArgErr()
	}
	for d.NextBlock(0) {
		var dst *string
		switch d.Val() {
		case "api_token":
			dst = &p.Provider.APIToken
		case "override_domain":
			dst = &p.Provider.OverrideDomain
		case "resolver":
			dst = &p.Provider.Resolver
		default:
			return d.Errf("unknown duckdns setting %q", d.Val())
		}
		if *dst != "" {
			return d.Errf("%s set twice", d.Val())
		}
		if !d.NextArg() {
			return d.ArgErr()
		}
		*dst = d.Val()
		if d.NextArg() {
			return d.ArgErr()
		}
	}
	if p.Provider.APIToken == "" {
		return d.Err("duckdns needs an api_token")
	}
	return nil
}

// The record methods pass the provider's own, with its credentials removed from any error text.

// GetRecords lists the zone's records.
func (p *DuckDNS) GetRecords(ctx context.Context, zone string) ([]libdns.Record, error) {
	r, err := p.Provider.GetRecords(ctx, zone)
	return r, redact(err, p.Provider.APIToken)
}

// AppendRecords adds records to the zone.
func (p *DuckDNS) AppendRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	r, err := p.Provider.AppendRecords(ctx, zone, recs)
	return r, redact(err, p.Provider.APIToken)
}

// SetRecords sets records in the zone.
func (p *DuckDNS) SetRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	r, err := p.Provider.SetRecords(ctx, zone, recs)
	return r, redact(err, p.Provider.APIToken)
}

// DeleteRecords removes records from the zone.
func (p *DuckDNS) DeleteRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	r, err := p.Provider.DeleteRecords(ctx, zone, recs)
	return r, redact(err, p.Provider.APIToken)
}

var (
	_ caddyfile.Unmarshaler = (*DuckDNS)(nil)
	_ caddy.Provisioner     = (*DuckDNS)(nil)
	_ libdns.RecordGetter   = (*DuckDNS)(nil)
	_ libdns.RecordAppender = (*DuckDNS)(nil)
	_ libdns.RecordSetter   = (*DuckDNS)(nil)
	_ libdns.RecordDeleter  = (*DuckDNS)(nil)
)
