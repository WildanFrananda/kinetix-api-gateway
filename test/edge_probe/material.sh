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

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj "/CN=Kinetix probe onion CA" \
  -addext "nameConstraints=critical,permitted;DNS:$ONION_NAME" \
  -keyout onion-ca.key \
  -out onion-ca.pem 2>/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=$ONION_NAME" \
  -keyout onion.key \
  -out onion.csr 2>/dev/null
printf '%s\n' \
  "subjectAltName=DNS:$ONION_NAME" \
  "extendedKeyUsage=serverAuth" \
  "keyUsage=critical,digitalSignature" \
  "basicConstraints=critical,CA:FALSE" > onion.ext
openssl x509 -req -days 1 \
  -in onion.csr \
  -CA onion-ca.pem \
  -CAkey onion-ca.key \
  -extfile onion.ext \
  -out onion.pem 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out onion-other.key 2>/dev/null

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iss":"%s","sub":"probe","exp":%s}' "$ISSUER" "$(($(date +%s) + 3600))" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign jwt-private.pem -binary | b64url)"
printf '%s.%s.%s' "$header" "$payload" "$signature" > token

chmod 0644 jwt-public.pem tls.pem tls.key token onion-ca.pem onion.pem onion.key onion-other.key
rm -f jwt-private.pem onion-ca.key onion.csr onion.ext
