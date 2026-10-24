# shellcheck shell=bash
# =============================================================================
# OpenSearch certificates and users, generated per install by deploy/setup.
#
#   .stack/opensearch/certs/   root-ca.pem, node.pem (names <project>-opensearch and
#                              opensearch), node-key.pem, admin.pem, admin-key.pem
#                              (mounted into OpenSearch; root-ca.pem also into the app
#                              containers and Dashboards)
#   .stack/opensearch/ca/      root-ca-key.pem: the CA's private key, never mounted
#                              anywhere. Only needed to issue new certificates.
#   .stack/opensearch/hashes.env   bcrypt hashes of the three OpenSearch passwords in
#                              .env, which bin/render puts into internal_users.yml
#
# Nothing here ever goes into a repository (FINDINGS F-19). Subjects and names match
# deploy/config/opensearch/opensearch.yml: admin_dn CN=admin,OU=stack,O=stack and
# nodes_dn CN=node,OU=stack,O=stack.
# =============================================================================

readonly OPENSEARCH_UID=1000

# os_certs_ensure OWNER: issues whatever is missing or no longer fits. With no CA, that's
# all three certificates. With a CA, it's the node certificate, when it's missing or
# doesn't name <project>-opensearch: a project renamed since, or a certificate from
# before the hyphen naming. Clients verify that name, so a stale certificate would
# fail every connection. OWNER (uid:gid) owns the files afterwards: the dev user in
# dev, OpenSearch's uid on a server.
os_certs_ensure() {
    local owner=$1 stack_dir="$STACK_ROOT/.stack/opensearch"
    mkdir -p "$stack_dir/certs" "$stack_dir/ca"
    # openssl runs in a throwaway Alpine container, so the host needs no openssl
    # version of its own. genpkey writes PKCS#8 keys, which OpenSearch requires.
    docker run --rm -i \
        -e PROJECT="$(project)" -e OWNER="$owner" \
        -v "$stack_dir/certs:/certs" -v "$stack_dir/ca:/ca" \
        alpine:3 sh -eu <<'SH'
apk add --no-cache -q openssl >/dev/null
cd /certs
key() { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1" 2>/dev/null; }

sign() {  # sign NAME SUBJECT EXTFILE
    openssl req -new -key "$1-key.pem" -subj "$2" -out "$1.csr"
    openssl x509 -req -sha256 -days 3650 -in "$1.csr" -CA root-ca.pem -CAkey /ca/root-ca-key.pem \
        -CAcreateserial -CAserial /ca/root-ca.srl -extfile "$3" -out "$1.pem"
    rm -f "$1.csr"
}

if [ ! -f root-ca.pem ]; then
    echo "setup: generating the OpenSearch CA and admin certificate" >&2
    key /ca/root-ca-key.pem
    openssl req -new -x509 -sha256 -days 3650 -key /ca/root-ca-key.pem \
        -subj "/O=stack/OU=stack/CN=${PROJECT} stack root CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out root-ca.pem

    # The admin: a client certificate for securityadmin.sh.
    key admin-key.pem
    cat > /tmp/admin.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EXT
    sign admin "/O=stack/OU=stack/CN=admin" /tmp/admin.ext

    # A new CA can't vouch for a node certificate the old one signed.
    rm -f node.pem node-key.pem
fi

# The node: TLS on both the transport and HTTP layers. Clients connect as
# <project>-opensearch; `opensearch` is the network alias the installer looks for.
host="${PROJECT}-opensearch"
if [ -f node.pem ] && openssl x509 -in node.pem -noout -ext subjectAltName 2>/dev/null | grep -Eq "DNS:${host}(,|\$)"; then
    echo "setup: OpenSearch certificates already exist and name ${host}; keeping them" >&2
else
    if [ -f node.pem ]; then
        echo "setup: warning: the OpenSearch node certificate doesn't name ${host}: issuing a new one from the same CA. A running OpenSearch uses it once its container restarts." >&2
    else
        echo "setup: issuing the OpenSearch node certificate for ${host}" >&2
    fi
    if [ ! -f /ca/root-ca-key.pem ]; then
        echo "setup: the CA's private key (.stack/opensearch/ca/root-ca-key.pem) is missing, so no node certificate can be issued. Delete .stack/opensearch/certs to start a new CA, then re-run setup." >&2
        exit 1
    fi
    key node-key.pem
    cat > /tmp/node.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${host},DNS:opensearch,DNS:localhost,IP:127.0.0.1
EXT
    sign node "/O=stack/OU=stack/CN=node" /tmp/node.ext
fi

chown -R "$OWNER" /certs /ca
chmod 0644 /certs/*.pem
chmod 0600 /certs/*-key.pem /ca/*
SH
    # OpenSearch runs as uid 1000 and must read node-key.pem. If the owner is another
    # uid (a dev user who isn't 1000), the key has to be world-readable instead.
    if [ "${owner%%:*}" != "$OPENSEARCH_UID" ]; then
        chmod 0644 "$stack_dir/certs/node-key.pem" "$stack_dir/certs/admin-key.pem"
        warn "your uid isn't $OPENSEARCH_UID, so OpenSearch's keys are world-readable (0644) for it to read them"
    fi
}

# os_hash IMAGE PASSWORD: a bcrypt hash from OpenSearch's own tool, in the image the
# stack runs, so the format always matches what OpenSearch expects.
os_hash() {
    local image=$1 password=$2 hash
    # shellcheck disable=SC2016 # the regex matches a literal "$2y$" hash prefix
    hash=$(docker run --rm --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh \
        "$image" -p "$password" 2>/dev/null | grep -E '^\$2[aby]\$' | tail -n1 || true)
    [ -n "$hash" ] || die "OpenSearch's hash.sh returned no hash (image $image). Run it by hand to see why:
    docker run --rm --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh $image -p test"
    printf '%s' "$hash"
}

# os_hashes_ensure IMAGE: writes hashes.env if it's missing; an existing one is kept even
# when .env's passwords change. To change an OpenSearch password, set it in .env, delete
# hashes.env, then re-run setup: it rehashes, renders internal_users.yml, and
# bin/opensearch-security applies it to the running cluster.
os_hashes_ensure() {
    local image=$1 file="$STACK_ROOT/.stack/opensearch/hashes.env" tmp
    if [ -f "$file" ]; then
        info "OpenSearch password hashes already exist; keeping them"
        return 0
    fi
    info "hashing the OpenSearch passwords with OpenSearch's hash.sh (each run starts a JVM: a few seconds)"
    # Plain assignments, so a failed hash stops setup here. The same call inside
    # printf's arguments would quietly write an empty hash.
    local admin dashboards magento
    admin=$(os_hash "$image" "$(env_get OPENSEARCH_ADMIN_PASSWORD)")
    dashboards=$(os_hash "$image" "$(env_get OPENSEARCH_DASHBOARDS_PASSWORD)")
    magento=$(os_hash "$image" "$(env_get OPENSEARCH_MAGENTO_PASSWORD)")
    tmp="$file.tmp.$$"
    (
        umask 077
        {
            printf '# Generated by deploy/setup from the passwords in .env. Single-quoted: bcrypt hashes contain $.\n'
            printf "OPENSEARCH_ADMIN_HASH='%s'\n" "$admin"
            printf "OPENSEARCH_DASHBOARDS_HASH='%s'\n" "$dashboards"
            printf "OPENSEARCH_MAGENTO_HASH='%s'\n" "$magento"
        } > "$tmp"
    )
    mv "$tmp" "$file"
}
