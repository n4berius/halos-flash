package dnsproviders

import (
	"context"
	"fmt"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/libdns/libdns"
	"github.com/libdns/namecheap"
)

// Namecheap is the dns.providers.namecheap module. Namecheap's API answers only addresses the
// account has allowed in its settings; without client_ip the library looks up this machine's
// public address itself.
//
//	dns namecheap {
//		api_key <key>
//		user <api user>
//		client_ip <this machine's public IPv4>
//		api_endpoint <url>
//	}
type Namecheap struct{ *namecheap.Provider }

func init() { caddy.RegisterModule(Namecheap{}) }

// CaddyModule returns the module's information.
func (Namecheap) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "dns.providers.namecheap",
		New: func() caddy.Module { return &Namecheap{new(namecheap.Provider)} },
	}
}

// Provision fills in placeholders, then checks the values they gave.
func (p *Namecheap) Provision(caddy.Context) error {
	r := caddy.NewReplacer()
	p.Provider.APIKey = r.ReplaceAll(p.Provider.APIKey, "")
	p.Provider.User = r.ReplaceAll(p.Provider.User, "")
	p.Provider.ClientIP = r.ReplaceAll(p.Provider.ClientIP, "")
	p.Provider.APIEndpoint = r.ReplaceAll(p.Provider.APIEndpoint, "")
	// The parse-time check saw only the placeholder; this one sees what the file held.
	if p.Provider.APIKey == "" || p.Provider.User == "" {
		return fmt.Errorf("namecheap: the api_key or user is empty (its file missing or empty?)")
	}
	return nil
}

// UnmarshalCaddyfile reads the Caddyfile form above.
func (p *Namecheap) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	d.Next() // the provider's name
	if d.NextArg() {
		return d.ArgErr()
	}
	for d.NextBlock(0) {
		var dst *string
		switch d.Val() {
		case "api_key":
			dst = &p.Provider.APIKey
		case "user":
			dst = &p.Provider.User
		case "client_ip":
			dst = &p.Provider.ClientIP
		case "api_endpoint":
			dst = &p.Provider.APIEndpoint
		default:
			return d.Errf("unknown namecheap setting %q", d.Val())
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
	if p.Provider.APIKey == "" || p.Provider.User == "" {
		return d.Err("namecheap needs an api_key and a user")
	}
	return nil
}

// The record methods pass the provider's own, with its credentials removed from any error text.

// GetRecords lists the zone's records.
func (p *Namecheap) GetRecords(ctx context.Context, zone string) ([]libdns.Record, error) {
	r, err := p.Provider.GetRecords(ctx, zone)
	return r, redact(err, p.Provider.APIKey)
}

// AppendRecords adds records to the zone.
func (p *Namecheap) AppendRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	r, err := p.Provider.AppendRecords(ctx, zone, recs)
	return r, redact(err, p.Provider.APIKey)
}

// SetRecords sets records in the zone.
func (p *Namecheap) SetRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	r, err := p.Provider.SetRecords(ctx, zone, recs)
	return r, redact(err, p.Provider.APIKey)
}

// DeleteRecords removes records from the zone.
func (p *Namecheap) DeleteRecords(ctx context.Context, zone string, recs []libdns.Record) ([]libdns.Record, error) {
	r, err := p.Provider.DeleteRecords(ctx, zone, recs)
	return r, redact(err, p.Provider.APIKey)
}

var (
	_ caddyfile.Unmarshaler = (*Namecheap)(nil)
	_ caddy.Provisioner     = (*Namecheap)(nil)
	_ libdns.RecordGetter   = (*Namecheap)(nil)
	_ libdns.RecordAppender = (*Namecheap)(nil)
	_ libdns.RecordSetter   = (*Namecheap)(nil)
	_ libdns.RecordDeleter  = (*Namecheap)(nil)
)
