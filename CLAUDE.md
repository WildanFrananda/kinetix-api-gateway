# CLAUDE.md — kinetix-api-gateway

The workspace `AGENTS.md` holds the stack and the verification commands; `README.md` holds the route table. This
file holds decisions that `config/gateway.pkl` states but cannot explain.

## One image, every environment: what the environment supplies

`bin/entrypoint.sh` renders `config/gateway.pkl` when the container starts. Lab and production run the same digest
and differ only in these values, all required unless marked:

| Variable | Pkl property | What it is |
| :--- | :--- | :--- |
| `KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64` | `identityJwtPublicKey` | identity's public key, base64 PEM |
| `KINETIX_JWT_ISSUER` | `jwtIssuer` | the one issuer the `jwt` plugin trusts |
| `KINETIX_GATEWAY_CORS_ORIGINS` | `corsOrigins` | must be set; empty leaves the `cors` plugin out |
| `KINETIX_GATEWAY_STAFF_RANGES` | `staffRanges` | comma-separated addresses or CIDRs the admin-only routes accept |
| `KINETIX_PUBLIC_API_HOST` | `publicApiHost` | the host this gateway serves (`host` or `host:port`), named by `security.txt` |
| `KINETIX_BACKOFFICE_HOST` | `backofficeHost` | the backoffice's host (`host`, or `host:port` in the lab), whose `/bff/` goes to the edge |
| `KINETIX_SELLER_HOST` | `sellerHost` | the seller web app's host, the same way |
| `KINETIX_STORAGE_HOST` (optional) | `storageHost` | the object store's host; empty renders no storage route |

There is no default staff range anywhere: the entrypoint refuses to start without one, `pkl eval` fails without
the property, and the Dockerfile's build step and CI both assert that a render without it fails. The Pkl type
refuses an empty list, anything that does not look like an IPv4 or IPv6 address or CIDR, and every `/0`, so a
typo cannot open the gate to everyone; Kong's own schema refuses at start what the loose IPv6 pattern lets
through. The values live in `kinetix-infrastructure` (lab compose; production's
`deploy/prod/platform.env`, through `compose.prod.yaml`), not in this public repository.

The two browser-app hosts work the same way: no default, the entrypoint refuses to start without either, and
the build step and both CIs assert that a render without one fails. Pkl also refuses a `:443` suffix (the
browser's `Host` carries no port there, and the edge's origin would be wrong), and a backoffice, seller,
public API, storage or internal host name used twice: two of them on one name would let one host's routes
shadow the other's.

## Admin-only routes answer only the staff network

Hardening item 3, option (a), ruled 2026-10-22. Each admin-only path has a dedicated route carrying Kong's
`ip-restriction` plugin (`staffGate` in the Pkl) with `allow` = `KINETIX_GATEWAY_STAFF_RANGES`:

| Route | Paths | Service |
| :--- | :--- | :--- |
| `identity-staff-route` | `/api/v1/sellers/applications`, `/api/v1/couriers/applications`, `~/api/v1/sellers/[^/]+/(verify\|reject)`, `~/api/v1/couriers/[^/]+/approve` | `identity-service` (with `jwt`) |
| `catalog-categories-staff-route` | `/api/v1/categories` for `POST`, `PUT`, `PATCH`, `DELETE` | `catalog-categories` |
| `warehouse-bins-staff-route`, `-stock-receipts-`, `-stock-adjustments-` | `/api/v1/warehouse/{bins,stock_receipts,stock_adjustments}` | `warehouse-bins`, `warehouse-stock-receipts`, `warehouse-stock-adjustments` |
| `matching-drivers-staff-route`, `matching-backoffice-staff-route` | `/api/v1/matching/drivers`, `/api/v1/matching/backoffice` | `matching-drivers`, `matching-backoffice` (with `jwt`) |
| `order-staff-route` | `~/api/v1/orders/(?i)sagas`, `~/api/v1/orders/(?i)returns/needs-attention`, `~/api/v1/orders/(?i)returns/[^/]+/reject`, `~/api/v1/orders/[^/]+/(?i)complete` | `order-service` |

Each staff route keeps what the route it was split from had: the same upstream host and resulting path, the same
`strip_path`, the same route plugins (`jwt` on identity and matching), the per-route `rate-limiting` (and `cors` when
origins are configured) that every TLS route carries, and the global `correlation-id` and `prometheus` plugins. `PATCH` on categories is fenced although catalog serves none, so a
future one is admin-only from its first day. Mixed endpoints, which a user or an admin may call
(`GET /api/v1/users/{id}/profile`, `GET /api/v1/sellers/{id}/application`, `GET /api/v1/orders/{orderId}`,
pricing's creates), are not fenced: a network cannot tell the two callers apart. They rely on identity's attempt
limits and admin two-factor, and on the admin audit.

**Why each route wins.** Kong 3.9's `traditional_compatible` router ranks a route with `methods` above one
without, then a regex path above a prefix, then a longer prefix above a shorter one. Catalog's staff route
shares the public route's path and wins by its methods, so `GET` still goes to the public route. Identity's and
order's staff routes win by a longer prefix or a regex inside their own services. Warehouse's and matching's
public routes strip `/api/v1/warehouse` and `/api/v1/matching`, and Kong strips the whole matched prefix, so a
staff route there needs its own service whose URL ends in the fenced segment (`…:3000/api/v1/bins`): the
upstream path is then the one the public route produced. One difference remains: Kong's ATC router always uses
`path_handling` v0 (v1 is not available in it), which puts a slash before a suffix glued to the fenced segment,
so `/api/v1/warehouse/bins.json` reaches warehouse as `/api/v1/bins/.json` (404) rather than
`/api/v1/bins.json`. The gate is never weaker for it. These routes report under their own service names in
Prometheus.

**Spellings.** Kong normalises the path before matching and forwards the normalised path (merged `//`,
resolved `.` and `..`, decoded percent-encoded unreserved characters), so `/api/v1/warehouse//bins` and
`/api/v1/warehouse/%62ins` are fenced and reach warehouse as `/api/v1/bins`. Identity (Fastify), catalog
(Django), warehouse (Rails) and matching (Phoenix) route case-sensitively, so a prefix covers every spelling
they serve. Order runs ASP.NET Core, whose routing ignores case, so `/api/v1/orders/x/COMPLETE` completes an
order: order's staff paths are regexes with `(?i)` after `/api/v1/orders/`, the part `order-route` itself
matches case-sensitively. Regex paths are anchored at the start and open at the end, so a trailing slash or a
longer tail is fenced too.

**The answer.** A refused address gets Kong's `403` with `{"message":"This route is not available from your
network","request_id":"…"}`. The message is fixed because Kong's default names the caller's address. `jwt`
(priority 1450) runs before `ip-restriction` (990) and Kong OSS cannot reorder plugins, so on identity's and
matching's staff routes a request without a valid token gets `jwt`'s 401 first and one with a valid token gets
the 403. A CORS preflight is answered by `cors` (2000) before the gate; it carries no credentials and reveals
nothing. The refusal happens before `rate-limiting` (910), so refused requests are not counted.

**Adding an admin-only path** takes three changes: a path on a staff route here (methods only where the path
also serves public methods), a line in the admin table of `test/edge_probe/checks.sh`, and, in the lab, a line in
section 5 of `test/route_conformance.sh` if the route needs no token. The route goes inside `...api(...)` like
every other API route, which gives it its internal twin (below).

## How staff reach the admin-only routes

Over WireGuard, to the server's tunnel address, with the public host name, so that TLS verifies and the `Host`
header is the API's:

```sh
curl --resolve api.wildanfrananda.my.id:443:<the server's tunnel address> \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.wildanfrananda.my.id/api/v1/sellers/applications
```

A browser does the same with a hosts-file line mapping the API host to the tunnel address while the tunnel is
up. The tunnel addresses and the staff range are in `kinetix-infrastructure`.

Why Kong sees the tunnel address: the gateway's port is published by Docker, and a packet that arrives on the
WireGuard interface for that port is DNAT-ed to the container by Docker's iptables rule with its source address
kept (Docker masquerades only traffic leaving the containers' bridge). Kong has no `trusted_ips`, so
`$remote_addr`, which `ip-restriction` reads, is that TCP source: the staff peer's tunnel address. The same
request over the internet carries the client's public address and is refused.

**This is proved on Docker networks, not on the server.** `test/edge_probe.sh` proves Kong's behaviour with real
source addresses; the server's path (WireGuard → Docker DNAT → Kong) is the user's to prove after the release: an
admin call over the tunnel reaches its service, the same call over mobile data gets the 403, and the access log
shows the tunnel address for the first. Three things change the source address Kong sees: a connection from the
server to itself (Docker's userland proxy answers it from the bridge gateway, so it is refused), a Docker or
firewall change that masquerades inbound traffic, and a proxy in front of the API host (next section).

In the lab, a connection from the Mac to the published port reaches Kong from the gateway address of the
network the gateway container is on (measured 2026-10-23 on Docker Desktop: a curl to `127.0.0.1:<published
port>` was logged from `10.231.30.1`, the gateway of that container's network). The lab's range must hold that
address for the Mac to act as staff, which is stable only if the compose network's subnet is pinned; containers
on the network have their own addresses and stay outside it unless the range is the whole subnet.

## Behind a proxy (hardening item 5): the switch, not yet applied

Kong is the edge today and trusts no forwarded header. When the API host moves behind a proxy (Cloudflare, say),
apply all of this together with the DNS switch:

1. Gateway environment in `compose.prod.yaml`:
   `KONG_TRUSTED_IPS=<every range the proxy publishes, comma-separated>` (Cloudflare:
   `https://www.cloudflare.com/ips-v4` and `/ips-v6`), `KONG_REAL_IP_HEADER=CF-Connecting-IP` (one address,
   set by the proxy), and `KONG_REAL_IP_RECURSIVE=on` (needed only if the header is `X-Forwarded-For`, where it
   makes nginx take the right-most address that is not trusted). Never put the staff range, a private range or
   `0.0.0.0/0` in `trusted_ips`: any peer in it may name its own address.
2. What it does: nginx's realip module replaces `$remote_addr` with the header's address only when the TCP peer
   is in `trusted_ips`. `ip-restriction` and `rate-limiting` (`limit_by = "ip"` reads
   `kong.client.get_forwarded_ip()`, i.e. `$remote_addr`) then see the real client. Without it every client
   behind the proxy shares the proxy's few addresses: the per-address limits (100 a minute, 600 on Midtrans'
   route) become shared by everyone, and the staff gate sees only the proxy. Staff keep reaching the gate over
   WireGuard, which bypasses the proxy; through the proxy they are refused, as they should be.
3. What reaches the services: `X-Real-IP` is `$remote_addr` (the real client after realip);
   `X-Forwarded-For` is the incoming header plus Kong's TCP peer (`$realip_remote_addr`, the proxy). identity's
   `trustProxy` (`src/infrastructure/http/gateway_hop.ts`) trusts only the gateway hop and takes the last
   `X-Forwarded-For` entry, which would then be the proxy: identity's per-address throttles would key on the
   proxy. identity must change in the same release (read `X-Real-IP` from the gateway hop, or trust the proxy's
   ranges at the next hop), and so must any other service that keys on the client address.
4. The origin accepts only the proxy on 443. Docker-published ports bypass ufw, so the filter goes in the
   `DOCKER-USER` chain (or the provider's firewall): on the public interface, `RETURN` for each proxy range with
   `-m conntrack --ctorigdstport 443`, then `DROP` for the rest of `--ctorigdstport 443`. WireGuard's interface
   stays open, or staff lose the gate.
5. Prove it: two clients behind the proxy have separate rate-limit budgets; a direct connection to the origin's
   public address is refused; the staff gate answers over WireGuard and refuses through the proxy; identity
   throttles per client.

## The browser apps' hosts: `/bff/` to the edge, nothing else (X14)

`EDGE-SERVICE.md` §10 in `kinetix-infrastructure` is the design. On `KINETIX_BACKOFFICE_HOST` and
`KINETIX_SELLER_HOST`, `edge-backoffice-route` and `edge-seller-route` send `/bff/` and everything under it to
`http://kinetix-edge-service:8080`, path and `Host` unchanged (`strip_path = false`, `preserve_host = true`:
the edge picks the app by host). Both carry the per-address rate limit; the backoffice one also carries the
staff gate, the same plugin and 403 body as the admin-only routes. Neither carries `jwt` (the edge holds the
session and sends identity's token on) or `cors` (the app and the edge share an origin).

- **`/bff/`, not `/bff`.** Kong's prefixes are string prefixes, so `/bff` would also send `/bffx` to the edge.
  Every path §10 lists is under `/bff/`; `/bff` itself answers 404.
- **Kong gets the host without its port.** The variables keep `host:port` in the lab because the edge builds
  the app's origin from them, but a route host with a port matches only that port. Without it the routes
  match the name whatever port the `Host` header names, so `backoffice.localhost:9999` cannot reach an API
  route either.
- **Everything else on those hosts is the app or a 404, never the API.** The API routes name no host, so without
  more they answer on any host, and an API answer under the app's origin is content on the origin that holds the
  session cookie. `backoffice-app-route` (since 2026-10-27, infra `docs/BACKOFFICE.md` BO-D3) takes `/` on the
  backoffice host and sends it to `http://kinetix-backoffice:8080`, the backoffice's static app, behind the staff
  gate and its own per-address limit (Kong keys the counter by route, so assets never spend `/bff/`'s budget);
  path unchanged, `Host` not kept. `seller-unrouted-route` takes `/` on the seller host and answers
  `404 {"message":"Not found"}` with `request-termination` until the seller web exists. Until the backoffice
  container runs, the staff network gets Kong's `503` for a name that does not resolve there. Both win because Kong 3.9's priority puts the
  number of matching fields first and then a plain (non-wildcard) host: host + path beats every host-less
  route, which has at most two fields (methods + path), and the `/bff/` route beats its catch-all by the
  longer prefix. A host-less route with three fields (methods, headers and path) would outrank the
  catch-all; the probe's table of paths on those hosts would show it. Neither catch-all carries methods, on
  purpose: a method it did not list would fall through to the API routes. The app answers a method it does not
  serve itself. Kong does not lowercase the
  `Host` header before routing, so `BACKOFFICE.…` matches neither route and reaches the API like any other
  host; browsers always send the lowercase name, so no page can be served that way.

**`rate-limiting` and `cors` are route plugins now, not global.** Kong OSS cannot exclude a route from a
global plugin (a route's own copy with `enabled = false` is skipped, and the global one runs), and the twins
must carry no rate limit while `/bff/` must carry no CORS. `onPublicListener` adds both to every TLS route
(no `cors` on the four browser-app routes, and no second limit where a route has its own, as Midtrans' does).
A cost: Kong's limit counter is keyed by the plugin's route, so the per-address budget of 100 a minute is now
per route, where the global plugin shared one budget across the API. Only `correlation-id` and `prometheus`
remain global.

## The internal listener and the twins

The edge calls the API through the gateway (§10, "The gateway's internal listener"), at
`http://kinetix-api-gateway:8000`. `KONG_PROXY_LISTEN` is `0.0.0.0:8443 ssl, 0.0.0.0:8000`: 8000 is plaintext
and must never be published. The `kong` base image already declares `EXPOSE 8000` (with 8001, 8443 and 8444),
which a Dockerfile cannot undo, so `docker run -P` would publish it: publish ports explicitly, as infra's compose
does (8443 only). Every API route is written once, inside `...api(...)`, and Pkl renders it twice:
the route the TLS listener serves (`protocols = ["https"]`, with its staff gate, rate limit and `cors`), and
its twin `<name>-internal` (same paths, methods, service, `strip_path` and `jwt`; no `ip-restriction`, no
`rate-limiting`, no `cors`). `/health`, `security.txt`, the courier socket, storage and the browser-app routes
have no twin (`publicOnly`, `browserApp`); the merchant socket has one (below).

**Why `protocols` alone would not do.** Kong 3.9 does not match on `protocols` for HTTP routes: the
`traditional_compatible` router never puts `net.protocol` in a route's expression, and after matching it
answers 426 only when an https-only route was matched over plaintext. A twin with `protocols = ["http"]`
and the original's paths would therefore tie with the original on the TLS listener, and whichever Kong
ordered first would win, for staff routes as well (measured 2026-10-23 with the probe: rendered that way, an
outside address reached `POST /api/v1/warehouse/bins` over TLS, and most twins never served the plaintext
listener). So each twin also names `hosts = ["kinetix-api-gateway"]`,
which raises it above its original (one more matching field) only when the request names that host, and
starts with `pre-function` code that answers `421 {"message":"Misdirected Request"}` unless the request
arrived in plaintext on port 8000 (`kong.request.get_scheme()` and `get_port()` read the connection, not a
header). A TLS request that names `kinetix-api-gateway` matches the twin and is refused before `jwt`; one
that does not matches the TLS route. A plaintext request that does not name the host matches only TLS
routes and gets Kong's 426. The `Host` header alone cannot bind a twin to the listener: Kong takes the port
for `host:port` matching from the `Host` header when it has one.

What the edge must do: call `http://kinetix-api-gateway:8000/api/...` with that `Host` (the default for that
URL; a `Host` copied from the browser matches no twin and gets 426).

**Why the twins carry no staff gate and no rate limit.** Their TCP peer is always the edge. The gate would
see the edge's address, never the staff member's, so it would refuse every admin from the backoffice (or
admit everyone, if the edge's network were in the range). The per-address limit would put every web user in
one budget. The browser's own address is checked where the browser enters: the staff gate and the rate
limit on `/bff/`. The services' own role checks still apply to every call.

**What someone on the network could do, and what not.** The listener is reachable only from containers on
the `kinetix` network. A container there could call an admin-only path through a twin from an address
outside the staff range, and without a rate limit, but it still needs a token identity issued (`jwt` on the
twin where the route has it, and each service's role check): with a stolen admin token it acts as that
admin. Paths without `jwt` at the gateway (catalog, warehouse, order, pricing, review, Midtrans, the merchant
socket) are as open to it as they are on the TLS listener, minus the per-address limit. From outside the network the listener is
unreachable, and a TLS request naming `kinetix-api-gateway` gets the 421. The guard passes only plaintext that
arrived on port 8000, so publishing 8000 is the one change that would put the twins on the internet.

**What the upstream sees.** Kong trusts no forwarded header, so the edge's `X-Forwarded-For` arrives intact
with the edge's address appended (`<browser>, <edge>`), `X-Real-IP` is the edge, `X-Forwarded-Host` is
`kinetix-api-gateway` and `X-Forwarded-Port` is 8000. `X-Forwarded-Proto` is `https`: the guard sets it,
because Kong would report its own plaintext hop and matching's production endpoint (`force_ssl` with
`rewrite_on: [:x_forwarded_proto]`) would redirect every call; every request the edge makes started as a
browser's TLS request to `/bff/`. A service that keys on the last `X-Forwarded-For` entry (identity's
`trustProxy`) sees the edge, which is why the edge calls identity directly for sign-in. `X-Request-Id` from
the edge is kept (`correlation-id` only fills a missing one).

**The merchant socket's twin (2026-10-27).** The edge proxies the seller web's WebSocket (X21) to
`/ws/v1/matching/merchant` and `/ws/v1/matching/merchant/websocket` on this listener, so
`matching-merchant-socket-route` is written inside `...api(...)` and gets `matching-merchant-socket-route-internal`:
the same two paths, `strip_path` and service, no `jwt` (matching checks the token and the seller role), the
guard first, no gate, limit or `cors`. Kong OSS passes an upgrade through any `http` or `https` route, so the
twin needs nothing the API twins lack; the probe shows `Upgrade`, the query and `X-Forwarded-Proto: https`
reaching the upstream. The courier socket keeps no twin: couriers use the app, which dials the TLS listener.
The public socket routes are unchanged.

**90-second timeouts on two services (2026-10-27).** The edge holds the seller web's merchant socket with 90 s
idle timeouts, and Kong's default `read_timeout` and `write_timeout` (60 s) would close an idle socket first.
`edge-service` (the `/bff/` routes on both app hosts) and `matching-merchant-socket` (the public route and its
twin) set both to 90000 ms (`idleSocketTimeout`); `connect_timeout` and every other service keep Kong's
defaults, and the invariants refuse any other value. A slow `/bff/` call or a silent merchant socket therefore
waits up to 90 s for Kong's 504 or close, on the public merchant socket too.

## `/health` and `/.well-known/security.txt`

`/health` answers `{"status":"ok"}` and nothing else (hardening item 6: it named the engine). Both routes are
`request-termination` on `health-service`, whose URL is never contacted; CI's "no upstream outside the network"
check exempts that one URL.

`security.txt` (RFC 9116) is `text/plain; charset=utf-8`, five lines and a trailing newline. Its values mirror
`kinetix-docs/src/site/security_contact.ts` (report URL, `Expires`, languages, policy path) and `Canonical` is
`https://<KINETIX_PUBLIC_API_HOST>/.well-known/security.txt`. `Expires` is 2027-10-21T00:00:00.000Z: renew it
here and in `security_contact.ts` together, at least 30 days before (by 2027-09-21).

## The Phoenix client appends `/websocket`

phoenix.js connects `new Socket("/ws/v1/matching/driver")` to `/ws/v1/matching/driver/websocket`. Each socket
route therefore takes both its bare path (the installed courier app) and `<path>/websocket`, and both reach
matching's `/driver/websocket` or `/merchant/websocket`, the only two socket paths matching serves; the longer
path is stripped whole, so nothing is appended. The query (`vsn`, `token`) passes through. Long polling is not
routed. The merchant socket's internal twin takes the same two paths.

## Kong reads a token from `Authorization` only (2026-10-27)

Kong's `jwt` plugin looks for a token in the query (`uri_param_names`, default `["jwt"]`), in cookies
(`cookie_names`, default none) and in headers (`header_names`, default `authorization`). With the default,
`…?jwt=<token>` passed Kong, and a token in a URL lands in logs, history and `Referer`. `jwtPlugin` sets both
lists to `[]` (an empty set is valid in Kong 3.9.4's `kong/plugins/jwt/schema.lua`), so every `jwt` route and
its twin read only `Authorization: Bearer …`. A token anywhere else is a missing token: Kong's `401
{"message":"Unauthorized"}` with a bare `WWW-Authenticate: Bearer`, before the request leaves the gateway. The
sockets carry no `jwt` plugin (matching reads its own `?token=`), so this does not touch them.

## Gates

- CI `config-valid` (GitHub and GitLab, paired): Pkl renders with and without origins and storage, refuses a
  contradiction, refuses a render without a staff range or with an everyone range, puts the gate on ten routes (the nine above and the backoffice app),
  `/health` and `security.txt` as above; refuses a render without either browser-app host, with `:443`, or with
  a host name used twice; `test/config_invariants.jq` over a JSON render (only `correlation-id` and `prometheus`
  global; every `jwt` plugin with empty `uri_param_names` and `cookie_names`; every TLS route https-only with
  a rate limit; every twin plaintext-only on the internal host with the guard first and no gate, limit or
  `cors`; the twins exactly the API routes and the merchant socket, each with its original's paths, methods,
  strip, service and `jwt`; the four browser-app routes as above; `read_timeout` and `write_timeout` 90000 on
  the edge's and the merchant socket's services only, with no `connect_timeout` anywhere); `deck file
  validate`; no upstream outside the network.
- CI `build-image` (GitHub): the image builds (its build step asserts the same render rules), then
  `test/edge_probe.sh <image>` runs the image against an echo upstream (the same image, `request-termination`
  with `echo`) on two Docker networks, one inside the staff range and one outside: every admin-only path reaches
  its upstream from inside and gets the 403 from outside (forged `X-Forwarded-For` and `X-Real-IP` included),
  every public path reaches the same upstream path from both, and `/health`, `security.txt`, the socket paths and a
  CORS preflight answer as above. It also runs the browser-app hosts (`/bff/` reaches the edge's port with
  `Host` kept, the limit and no CORS; the backoffice's refuses an outside address; twenty-odd other paths answer
  404 on the seller host and reach `kinetix-backoffice:8080` on the backoffice host, or its 403 from outside), TLS requests naming the internal host (421), and, from a third network outside the staff range, the
  plaintext listener: every API path through its twin, every `jwt` twin 401 without a token, the excluded
  routes 426, `X-Forwarded-For` intact, a burst of 120 unlimited. On every `jwt` route and twin, a valid token
  only in `?jwt=` or in a `jwt` cookie gets the 401 for a missing token. The merchant socket's twin passes an
  upgrade with its query and `X-Forwarded-Proto: https`; the same path answers 421 over TLS naming the internal
  host and 426 in plaintext naming any other, and the courier socket 426 in plaintext. Kong's own metrics then
  show that no twin served a TLS request and that every twin served a plaintext one. GitLab's image job comes from
  `kinetix-infrastructure`'s template and does not run the probe.
- The lab: `test/route_conformance.sh` against the running compose lab; section 5 checks that every admin-only
  route gives the same answer to the calling address and that no public route is gated. Run it from an address in
  the lab's range and from one outside it. Section 7 also upgrades both sockets in plaintext (the merchant one
  reaches matching, the courier one gets 426); section 8 checks that a token in the query or a cookie is not
  read.
