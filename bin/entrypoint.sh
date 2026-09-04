#!/usr/bin/env sh
# Places the TLS material Kong needs, then hands over to the image's own entrypoint.
#
# The certificate and key arrive as base64 environment variables rather than as build arguments,
# because a build argument is recorded in the image and `docker history` prints it — the private
# key of the platform's only public surface must not be baked into a distributable layer. Every
# other secret on this platform reaches its container the same way.
set -eu

TLS_DIR="${KONG_TLS_DIR:-/tmp/kong-tls}"

if [ -z "${KINETIX_GATEWAY_TLS_CERT_B64:-}" ] || [ -z "${KINETIX_GATEWAY_TLS_KEY_B64:-}" ]; then
  echo "KINETIX_GATEWAY_TLS_CERT_B64 and KINETIX_GATEWAY_TLS_KEY_B64 are required." >&2
  echo "The gateway serves TLS only; there is no plaintext listener to fall back to." >&2
  exit 1
fi

mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR"

umask 077
printf '%s' "$KINETIX_GATEWAY_TLS_CERT_B64" | base64 -d > "$TLS_DIR/server.pem"
printf '%s' "$KINETIX_GATEWAY_TLS_KEY_B64"  | base64 -d > "$TLS_DIR/server.key"

# Assert the decoded material, not the exit status of base64. A truncated variable decodes
# without complaint and Kong then fails to start with an error about the file, not the value.
grep -q "BEGIN CERTIFICATE" "$TLS_DIR/server.pem" || {
  echo "KINETIX_GATEWAY_TLS_CERT_B64 did not decode to a PEM certificate" >&2
  exit 1
}
grep -q "PRIVATE KEY" "$TLS_DIR/server.key" || {
  echo "KINETIX_GATEWAY_TLS_KEY_B64 did not decode to a PEM private key" >&2
  exit 1
}

export KONG_SSL_CERT="$TLS_DIR/server.pem"
export KONG_SSL_CERT_KEY="$TLS_DIR/server.key"

exec /docker-entrypoint.sh "$@"
