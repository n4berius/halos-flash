package dnsproviders

import (
	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
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

// Provision fills in placeholders.
func (p *Namecheap) Provision(caddy.Context) error {
	r := caddy.NewReplacer()
	p.Provider.APIKey = r.ReplaceAll(p.Provider.APIKey, "")
	p.Provider.User = r.ReplaceAll(p.Provider.User, "")
	p.Provider.ClientIP = r.ReplaceAll(p.Provider.ClientIP, "")
	p.Provider.APIEndpoint = r.ReplaceAll(p.Provider.APIEndpoint, "")
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

var (
	_ caddyfile.Unmarshaler = (*Namecheap)(nil)
	_ caddy.Provisioner     = (*Namecheap)(nil)
)
