# {{GENERATED_HEADER}}
#
# Server edge: TLS from Let's Encrypt, then everything to Varnish. The site sits
# behind Cloudflare in Full (strict) mode.
{
	email {$ACME_EMAIL}
	# Listens inside the container only (never published), so `caddy reload` can
	# apply a new Caddyfile without dropping connections.
	admin localhost:2019
	servers {
		# Only Cloudflare may tell us who the visitor is. Without this, Magento sees
		# Cloudflare's edge address as every customer's IP. The ranges come from
		# deploy/config/caddy/cloudflare-ips.txt.
		trusted_proxies static {{CLOUDFLARE_TRUSTED_PROXIES}}
		client_ip_headers CF-Connecting-IP
	}
}

# PURGE and BAN never pass the edge, on any site. Varnish's purge ACL trusts the private
# address ranges, which is safe only because Caddy, the one way in from outside, refuses
# these methods. Import this in every site block, including new ones.
(refuse_cache_methods) {
	@cacheMethods method PURGE BAN
	respond @cacheMethods "Method not allowed" 405
}

{$STORE_DOMAIN} {
	import refuse_cache_methods

	reverse_proxy {{PROJECT}}-varnish:80 {
		# Exactly one address, the visitor's, which Magento reads from X-Forwarded-For.
		header_up X-Forwarded-For {client_ip}

		# Varnish answers this itself, without asking the app. Caddy then keeps routing
		# to Varnish while the app is down, so Varnish can serve cached pages from grace.
		# A check that went through to the app would take Varnish out of rotation with it.
		health_uri /.varnish-health
		health_interval 10s
		health_timeout 3s
	}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	# To stdout, so it's in `bin/log caddy`, within Docker's log limits.
	log {
		output stdout
		format json
	}
}

# Each name in STORE_ALIASES (e.g. www.) redirects to STORE_DOMAIN. Empty when there
# are none.
{{STORE_ALIASES_SITE}}
