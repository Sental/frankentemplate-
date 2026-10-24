# {{GENERATED_HEADER}}
#
# Varnish VCL for Magento. Based on Magento's varnish7.vcl; Mage-OS 3.6 ships no
# Varnish 8 template, so `varnishd -C` on Varnish 8 is the compatibility check.
#
# Rendered values:
#   backend host   the active app: {{PROJECT}}-app in dev, {{PROJECT}}-app-<colour> on
#                  a server. Varnish resolves it once, when this VCL loads, and refuses
#                  to load if it doesn't resolve. That's why this names only the active
#                  colour, and why a release reloads this VCL after switching.
#   admin path     ADMIN_FRONT_NAME from .env, in both places it's needed.
#
# The purge ACL trusts the private address ranges, not hostnames or one subnet:
#   - Hostnames would be frozen when the VCL loads. A recreated app, cron or consumers
#     container gets a new IP, and its purges would get a 405.
#   - The backend subnet is Docker's choice and can change whenever the network is
#     recreated. Trusting the private ranges keeps the ACL constant.
# That's safe only because nothing outside the stack can reach Varnish directly. Its
# port is never published, and Caddy, the one path in from outside, refuses PURGE and
# BAN on every site. Keep both true. If your Docker daemon allocates networks outside
# RFC 1918, add that range here.
vcl 4.0;

import std;

backend default {
    .host = "{{VARNISH_BACKEND}}";
    .port = "80";
    .first_byte_timeout = 600s;
    .probe = {
        .url = "/health_check.php";
        .timeout = 2s;
        .interval = 5s;
        .window = 10;
        .threshold = 5;
    }
}

# Who may PURGE: Varnish itself, and the stack's containers on Docker's private
# networks. The app, cron and consumers all send purges. See the header for why these
# ranges are safe.
acl purge {
    "localhost";
    "127.0.0.1";
    "10.0.0.0"/8;
    "172.16.0.0"/12;
    "192.168.0.0"/16;
}

sub vcl_recv {
    # Answered here, without the backend, so the edge's health check measures Varnish
    # alone: the edge keeps routing here while the app is down, so grace can serve
    # cached pages. The container health check uses it too.
    if (req.url == "/.varnish-health") {
        return (synth(200, "OK"));
    }

    if (req.restarts > 0) {
        set req.hash_always_miss = true;
    }

    # The SSL indicator: Magento builds https:// URLs and secure cookies from it.
    if (req.http.X-Forwarded-Proto == "https") {
        set req.http.X-Forwarded-Port = "443";
    }

    # Sort query parameters, so the same page under a different parameter order
    # shares one cache object.
    if (req.url ~ "\?.+&.+") {
        set req.url = std.querysort(req.url);
    }

    if (req.method == "PURGE") {
        if (client.ip !~ purge) {
            return (synth(405, "Method not allowed"));
        }
        # No tag header: fall back to a plain URL purge.
        if (!req.http.X-Magento-Tags-Pattern && !req.http.X-Pool) {
            return (purge);
        }
        if (req.http.X-Magento-Tags-Pattern) {
          ban("obj.http.X-Magento-Tags ~ " + req.http.X-Magento-Tags-Pattern);
        }
        if (req.http.X-Pool) {
          ban("obj.http.X-Pool ~ " + req.http.X-Pool);
        }
        return (synth(200, "Purged"));
    }

    if (req.method != "GET" &&
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "DELETE") {
          # Non-RFC2616 methods, or CONNECT.
          return (pipe);
    }

    # Only GET and HEAD are cacheable.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Never cache the admin.
    if (req.url ~ "/({{ADMIN_FRONT_NAME}})(/|$|\?)") {
        return (pass);
    }

    # Never cache customer, cart or checkout pages.
    if (req.url ~ "/customer" || req.url ~ "/checkout") {
        return (pass);
    }

    # Never cache the app's health check.
    if (req.url ~ "^/(pub/)?(health_check.php)$") {
        return (pass);
    }

    set req.http.grace = "none";

    # Normalise URLs that arrive with a scheme and host.
    set req.url = regsub(req.url, "^http[s]?://", "");

    std.collect(req.http.Cookie);

    # Strip marketing parameters, so they don't multiply cache objects.
    if (req.url ~ "(\?|&)(gad_source|gbraid|wbraid|_gl|dclid|gclsrc|srsltid|msclkid|gclid|cx|_kx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+)=") {
        set req.url = regsuball(req.url, "(gad_source|gbraid|wbraid|_gl|dclid|gclsrc|srsltid|msclkid|gclid|cx|_kx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+)=[-_A-z0-9+()%.]+&?", "");
        set req.url = regsub(req.url, "[?|&]+$", "");
    }

    # Static and media files are the same for everyone: drop the SSL indicator and
    # cookies before hashing.
    if (req.url ~ "^/(pub/)?(media|static)/") {
        unset req.http.Https;
        unset req.http.X-Forwarded-Proto;
        unset req.http.Cookie;
    }

    # Authenticated GraphQL without a cache id is per user: don't cache it.
    if (req.url ~ "/graphql" && !req.http.X-Magento-Cache-Id && req.http.Authorization ~ "^Bearer") {
        return (pass);
    }

    return (hash);
}

sub vcl_hash {
    if ((req.url !~ "/graphql" || !req.http.X-Magento-Cache-Id) && req.http.cookie ~ "X-Magento-Vary=") {
        hash_data(regsub(req.http.cookie, "^.*?X-Magento-Vary=([^;]+);*.*$", "\1"));
    }

    # Separate http and https objects, so http visitors never get https URLs or the reverse.
    if (req.http.X-Forwarded-Proto) {
        hash_data(req.http.X-Forwarded-Proto);
    }

    if (req.url ~ "/graphql") {
        call process_graphql_headers;
    }
}

sub process_graphql_headers {
    if (req.http.X-Magento-Cache-Id) {
        hash_data(req.http.X-Magento-Cache-Id);

        # Once the client stops sending its token, stop serving what was cached for
        # the logged-in customer.
        if (req.http.Authorization ~ "^Bearer") {
            hash_data("Authorized");
        }
    }

    if (req.http.Store) {
        hash_data(req.http.Store);
    }

    if (req.http.Content-Currency) {
        hash_data(req.http.Content-Currency);
    }
}

sub vcl_backend_response {
    # Keep the URL on the object, for URL-pattern bans.
    set beresp.http.x-url = bereq.url;

    set beresp.grace = 3d;

    if (beresp.http.content-type ~ "text") {
        set beresp.do_esi = true;
    }

    if (bereq.url ~ "\.js$" || beresp.http.content-type ~ "text") {
        set beresp.do_gzip = true;
    }

    if (beresp.http.X-Magento-Debug) {
        set beresp.http.X-Magento-Cache-Control = beresp.http.Cache-Control;
    }

    # Never cache the admin. A second guard, in case vcl_recv's check is bypassed.
    if (bereq.url ~ "/({{ADMIN_FRONT_NAME}})(/|$|\?)") {
        set beresp.uncacheable = true;
        set beresp.ttl = 86400s;
        return (deliver);
    }

    # Cache only 200s and 404s, and nothing marked private.
    if ((beresp.status != 200 && beresp.status != 404) || beresp.http.Cache-Control ~ "private") {
        set beresp.uncacheable = true;
        set beresp.ttl = 86400s;
        return (deliver);
    }

    # A cacheable response must not set cookies.
    if (beresp.ttl > 0s && (bereq.method == "GET" || bereq.method == "HEAD")) {
        # Merge multiple Set-Cookie headers.
        std.collect(beresp.http.set-cookie);
        # The response varies (X-Magento-Vary) but the request didn't say how: don't
        # cache it under this request's hash.
        if ((bereq.url !~ "/graphql" || !bereq.http.X-Magento-Cache-Id)
         && bereq.http.cookie !~ "X-Magento-Vary="
         && beresp.http.set-cookie ~ "X-Magento-Vary=") {
           set beresp.ttl = 0s;
           set beresp.uncacheable = true;
        }
        unset beresp.http.set-cookie;
    }

    # Uncacheable pages go straight to the backend for 2 minutes (hit-for-pass).
    if (beresp.ttl <= 0s ||
        beresp.http.Surrogate-control ~ "no-store" ||
        (!beresp.http.Surrogate-Control &&
        beresp.http.Cache-Control ~ "no-cache|no-store") ||
        beresp.http.Vary == "*") {
        set beresp.ttl = 120s;
        set beresp.uncacheable = true;
    }

    # GraphQL: if Magento's cache id differs from the request's, don't cache under
    # the request's key.
    if (bereq.url ~ "/graphql" && bereq.http.X-Magento-Cache-Id && bereq.http.X-Magento-Cache-Id != beresp.http.X-Magento-Cache-Id) {
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
    }

    return (deliver);
}

sub vcl_deliver {
    if (obj.uncacheable) {
        set resp.http.X-Magento-Cache-Debug = "UNCACHEABLE";
    } else if (obj.hits) {
        set resp.http.X-Magento-Cache-Debug = "HIT";
        set resp.http.Grace = req.http.grace;
    } else {
        set resp.http.X-Magento-Cache-Debug = "MISS";
    }

    # Browsers may cache static and media files, but not pages.
    if (resp.http.Cache-Control !~ "private" && req.url !~ "^/(pub/)?(media|static)/") {
        set resp.http.Pragma = "no-cache";
        set resp.http.Expires = "-1";
        set resp.http.Cache-Control = "no-store, no-cache, must-revalidate, max-age=0";
    }

    # Easier to read in browser devtools than X-Magento-Cache-Debug.
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }

    # Marks responses served stale while the object revalidates in the background.
    if (obj.ttl < 0s && obj.ttl + obj.grace > 0s) {
        set resp.http.X-Varnish-Grace = "STALE";
    }

    if (!resp.http.X-Magento-Debug) {
        unset resp.http.Age;
    }
    unset resp.http.X-Magento-Debug;
    unset resp.http.X-Magento-Tags;
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;
    unset resp.http.x-url;
}

sub vcl_hit {
    if (obj.ttl >= 0s) {
        # Within its TTL.
        return (deliver);
    }
    if (std.healthy(req.backend_hint)) {
        if (obj.ttl + 300s > 0s) {
            # Past its TTL but within grace: serve it while it refreshes.
            set req.http.grace = "normal (healthy server)";
            return (deliver);
        } else {
            # Past grace too: fetch a fresh copy.
            return (restart);
        }
    } else {
        # The backend is sick: keep serving what's cached.
        set req.http.grace = "unlimited (unhealthy server)";
        return (deliver);
    }
}
