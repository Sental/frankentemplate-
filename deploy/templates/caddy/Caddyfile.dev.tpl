# {{GENERATED_HEADER}}
#
# Dev edge. Every name below gets a certificate from Caddy's own local CA;
# `bin/trust` makes Windows trust that CA and adds the names to the hosts file.
{
	local_certs
	# Listens inside the container only (it's never published), so that
	# `caddy reload` works for bin/varnish.
	admin localhost:2019
}

# PURGE and BAN never pass the edge, on any site. Varnish's purge ACL trusts the private
# address ranges, which is safe only because Caddy, the one way in from outside, refuses
# these methods. Import this in every site block, including new ones.
(refuse_cache_methods) {
	@cacheMethods method PURGE BAN
	respond @cacheMethods "Method not allowed" 405
}

# The store. {{STORE_UPSTREAM}} is Varnish, or the app directly after `bin/varnish off`.
{$STORE_DOMAIN} {
	import refuse_cache_methods
	reverse_proxy {{STORE_UPSTREAM}}
}

logs.{$STORE_DOMAIN} {
	import refuse_cache_methods
	reverse_proxy {{PROJECT}}-dozzle:8080
}

mail.{$STORE_DOMAIN} {
	import refuse_cache_methods
	reverse_proxy {{PROJECT}}-mailpit:8025
}

pma.{$STORE_DOMAIN} {
	import refuse_cache_methods
	reverse_proxy {{PROJECT}}-phpmyadmin:80
}

mq.{$STORE_DOMAIN} {
	import refuse_cache_methods
	reverse_proxy {{PROJECT}}-rabbitmq:15672
}

# OpenSearch Dashboards, when DEV_PROFILES includes search-ui. When it doesn't, bin/render
# puts a 503 page here saying it's off and how to turn it on.
search.{$STORE_DOMAIN} {
	import refuse_cache_methods
	{{SEARCH_UI_HANDLER}}
}
