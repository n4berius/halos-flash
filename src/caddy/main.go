// halOS's Caddy (halos-proxy.service): the standard modules plus the DNS providers halOS offers
// for Let's Encrypt's DNS-01 challenge. Fedora's own caddy package has no DNS providers, and Caddy
// links its plugins at build time, so halOS builds it here. go.mod and go.sum pin every module by
// version and hash; the Containerfile's caddy stage builds it with Fedora's Go.
package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddy-dns/cloudflare"
	_ "github.com/caddy-dns/porkbun"
	_ "github.com/caddyserver/caddy/v2/modules/standard"

	// DuckDNS and Namecheap: halOS's own modules on the MIT libdns providers, since their
	// caddy-dns plugins carry no licence.
	_ "github.com/n4berius/halos-flash/caddy/dnsproviders"
)

func main() {
	caddycmd.Main()
}
