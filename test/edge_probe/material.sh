#!/bin/sh
set -eu

cd /work

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt-private.pem 2>/dev/null
openssl pkey -in jwt-private.pem -pubout -out jwt-public.pem
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=$API_HOST" \
  -addext "subjectAltName=DNS:$API_HOST,DNS:$SELLER_NAME,DNS:$STORAGE_HOST" \
  -keyout tls.key \
  -out tls.pem 2>/dev/null

constrained_leaf() {
  name="$1"
  host="$2"

  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=Kinetix probe $name CA" \
    -addext "nameConstraints=critical,permitted;DNS:$host" \
    -keyout "$name-ca.key" \
    -out "$name-ca.pem" 2>/dev/null
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=$host" \
    -keyout "$name.key" \
    -out "$name.csr" 2>/dev/null
  printf '%s\n' \
    "subjectAltName=DNS:$host" \
    "extendedKeyUsage=serverAuth" \
    "keyUsage=critical,digitalSignature" \
    "basicConstraints=critical,CA:FALSE" > "$name.ext"
  openssl x509 -req -days 1 \
    -in "$name.csr" \
    -CA "$name-ca.pem" \
    -CAkey "$name-ca.key" \
    -extfile "$name.ext" \
    -out "$name.pem" 2>/dev/null
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$name-other.key" 2>/dev/null
  rm -f "$name-ca.key" "$name.csr" "$name.ext"
}

constrained_leaf onion "$ONION_NAME"
constrained_leaf backoffice "$BACKOFFICE_NAME"

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iss":"%s","sub":"probe","exp":%s}' "$ISSUER" "$(($(date +%s) + 3600))" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign jwt-private.pem -binary | b64url)"
printf '%s.%s.%s' "$header" "$payload" "$signature" > token

mkdir -p app/tiles
{
  printf 'PMTiles\003'
  openssl rand 98296
} > app/tiles/basemap.pmtiles
printf '{"build":"probe","bytes":98304,"maxzoom":15}\n' > app/tiles/basemap.json
chmod 0755 app app/tiles
chmod 0644 app/tiles/basemap.pmtiles app/tiles/basemap.json

chmod 0644 \
  jwt-public.pem \
  tls.pem \
  tls.key \
  token \
  onion-ca.pem \
  onion.pem \
  onion.key \
  onion-other.key \
  backoffice-ca.pem \
  backoffice.pem \
  backoffice.key \
  backoffice-other.key
rm -f jwt-private.pem
