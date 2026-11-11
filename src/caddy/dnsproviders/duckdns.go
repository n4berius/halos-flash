// Package dnsproviders is halOS's own Caddy glue for DNS providers whose caddy-dns plugin carries
// no licence: it registers the MIT-licensed libdns provider as a Caddy module. Written for halOS
// from Caddy's module interfaces and the libdns providers' exported fields; MIT, like the rest of
// halOS (the repository's LICENSE).
package dnsproviders

import (
	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
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

// Provision fills in placeholders.
func (p *DuckDNS) Provision(caddy.Context) error {
	r := caddy.NewReplacer()
	p.Provider.APIToken = r.ReplaceAll(p.Provider.APIToken, "")
	p.Provider.OverrideDomain = r.ReplaceAll(p.Provider.OverrideDomain, "")
	p.Provider.Resolver = r.ReplaceAll(p.Provider.Resolver, "")
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

var (
	_ caddyfile.Unmarshaler = (*DuckDNS)(nil)
	_ caddy.Provisioner     = (*DuckDNS)(nil)
)
