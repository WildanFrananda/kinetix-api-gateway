#!/bin/sh
set -eu

cd /work

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt-private.pem 2>/dev/null
openssl pkey -in jwt-private.pem -pubout -out jwt-public.pem
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=$API_HOST" \
  -addext "subjectAltName=DNS:$API_HOST,DNS:$BACKOFFICE_NAME,DNS:$SELLER_NAME,DNS:$STORAGE_HOST" \
  -keyout tls.key \
  -out tls.pem 2>/dev/null

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iss":"%s","sub":"probe","exp":%s}' "$ISSUER" "$(($(date +%s) + 3600))" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign jwt-private.pem -binary | b64url)"
printf '%s.%s.%s' "$header" "$payload" "$signature" > token

chmod 0644 jwt-public.pem tls.pem tls.key token
rm -f jwt-private.pem
