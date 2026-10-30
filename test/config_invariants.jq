def plugin_names: [.plugins[]?.name];
def has_plugin($name): plugin_names | any(.[]; . == $name);
def twin: .name | endswith("-internal");
def onion: .name | endswith("-onion-route");
def guard: [.plugins[]? | select(.name == "pre-function") | .config.access[0]][0] // "";
def guard_port: guard | capture("get_port\\(\\) ~= (?<port>[0-9]+) ").port // null;
def redirect: guard
  | capture("get_scheme\\(\\) == \"http\" and kong\\.request\\.get_port\\(\\) == (?<port>[0-9]+) then return kong\\.response\\.exit\\((?<status>[0-9]+), nil, \\{ Location = \"(?<location>[^\"]*)\" \\.\\. kong\\.request\\.get_path_with_query\\(\\) \\}\\) end ")
  // null;
def shape: {paths, methods, strip_path, service_url, jwt: has_plugin("jwt")};
def without_twin: [
  "health-route",
  "security-txt-route",
  "matching-driver-socket-route",
  "storage-route",
  "edge-backoffice-route",
  "edge-seller-route",
  "backoffice-app-route",
  "seller-unrouted-route"
];
def browser_app: .name as $name | ["edge-backoffice-route", "edge-seller-route", "backoffice-app-route", "seller-unrouted-route"] | any(.[]; . == $name);
def route($name): first(.[] | select(.name == $name)) // {};
def long_lived: .name as $name | ["edge-service", "matching-merchant-socket"] | any(.[]; . == $name);
def timeouts: {connect_timeout, read_timeout, write_timeout};

[.services[] as $service | $service.routes[] | . + {service_url: $service.url}] as $routes
| [
    (.plugins[]? | . + {owner: "the global plugins"}),
    (.services[] | .name as $owner | .plugins[]? | . + {owner: $owner}),
    ($routes[] | .name as $owner | .plugins[]? | . + {owner: $owner})
  ] as $all_plugins
| ($all_plugins | map(select(.name == "jwt"))) as $jwt_plugins
| ($routes | map(select(twin))) as $twins
| ($routes | map(select(onion))) as $onions
| ($routes | map(select((twin | not) and (onion | not)))) as $tls
| ($tls | map(select(.name as $name | without_twin | any(.[]; . == $name) | not))) as $api
| [
    (if [.plugins[].name] != ["correlation-id", "prometheus"]
      then "the global plugins are \([.plugins[].name]): rate-limiting and cors would reach the twins and /bff/"
      else empty end),
    (if ($twins | length) == 0 then "no internal twin was rendered" else empty end),
    (if ($jwt_plugins | length) == 0 then "no jwt plugin was rendered" else empty end),
    (if ([.services[] | select(long_lived)] | length) != 2
      then "the edge's and the merchant socket's services are not both rendered: \([.services[].name])"
      else empty end),
    (.services[] | select(long_lived)
      | select(timeouts != {connect_timeout: null, read_timeout: 90000, write_timeout: 90000})
      | "\(.name) does not hold an idle socket for 90 s on Kong's connect default: \(timeouts)"),
    (.services[] | select(long_lived | not)
      | select(timeouts != {connect_timeout: null, read_timeout: null, write_timeout: null})
      | "\(.name) changes Kong's default timeouts: \(timeouts)"),
    ($jwt_plugins[] | select(.config.uri_param_names != [] or .config.cookie_names != [])
      | "\(.owner)'s jwt reads a token from the query or a cookie: \(.config | {uri_param_names, cookie_names})"),
    ($twins[] | select(.protocols != ["http"] or .hosts != ["kinetix-api-gateway"])
      | "\(.name) is not bound to the internal host over plaintext: \(.protocols) \(.hosts)"),
    ($twins[] | select(plugin_names[0] != "pre-function")
      | "\(.name) does not refuse TLS first: \(plugin_names)"),
    ($twins[] | select(guard_port != "8000") | "\(.name)'s guard does not pin the internal port 8000: \(guard_port)"),
    ($twins[] | select(has_plugin("ip-restriction") or has_plugin("rate-limiting") or has_plugin("cors"))
      | "\(.name) carries a public-listener plugin: \(plugin_names)"),
    ($tls[] | select(.protocols != ["https"]) | "\(.name) answers plaintext: \(.protocols)"),
    ($tls[] | select(has_plugin("rate-limiting") | not) | "\(.name) has no per-address rate limit"),
    ($tls[] | select(browser_app | not) | select(has_plugin("cors") | not) | "\(.name) lost the cors plugin"),
    ($tls[] | select(browser_app) | select(has_plugin("cors") or has_plugin("jwt"))
      | "\(.name) is a browser-app route with cors or jwt: \(plugin_names)"),
    (if ($api | map(.name + "-internal") | sort) != ($twins | map(.name) | sort)
      then "the twins \($twins | map(.name) | sort) are not exactly the API routes \($api | map(.name) | sort)"
      else empty end),
    ($api[] | (.name + "-internal") as $twin_name | shape as $wanted
      | ($twins | route($twin_name) | shape) as $got
      | select($got != $wanted) | "\($twin_name) differs from \(.name): \($got) != \($wanted)"),
    ($routes | route("edge-backoffice-route")
      | select(.hosts != [$backoffice] or .paths != ["/bff/"] or .strip_path != false or .preserve_host != true
          or .service_url != "http://kinetix-edge-service:8080" or (plugin_names | sort) != ["ip-restriction", "rate-limiting"])
      | "edge-backoffice-route is not the gated /bff/ route of \($backoffice): \(.)"),
    ($routes | route("edge-seller-route")
      | select(.hosts != [$seller] or .paths != ["/bff/"] or .strip_path != false or .preserve_host != true
          or .service_url != "http://kinetix-edge-service:8080" or plugin_names != ["rate-limiting"])
      | "edge-seller-route is not the /bff/ route of \($seller): \(.)"),
    ($routes | route("backoffice-app-route")
      | select(.hosts != [$backoffice] or .paths != ["/"] or .methods != null or .strip_path != false
          or .preserve_host == true or .service_url != "http://kinetix-backoffice:8080"
          or (plugin_names | sort) != ["ip-restriction", "rate-limiting"])
      | "backoffice-app-route is not the gated app route of \($backoffice) outside /bff/: \(.)"),
    ($routes | route("seller-unrouted-route")
      | select(.hosts != [$seller] or .paths != ["/"] or (plugin_names | sort) != ["rate-limiting", "request-termination"])
      | "seller-unrouted-route does not close \($seller) outside /bff/: \(.)"),
    (if ($onions | map(.name) | sort) != ["backoffice-app-onion-route", "edge-backoffice-onion-route"]
      then "the onion routes are \($onions | map(.name) | sort), not the backoffice's two"
      else empty end),
    ($onions[] | select(.protocols != ["http", "https"] or .hosts != [$onion] or plugin_names != ["pre-function", "rate-limiting"])
      | "\(.name) is not the guarded route of the onion host, over http and https, with only its limit: \(.)"),
    ($onions[] | select(guard_port != "8444") | "\(.name)'s guard does not serve the onion's TLS port 8444 alone: \(guard_port)"),
    ($onions[] | select(redirect != {port: "8081", status: "308", location: "https://\($onion)"})
      | "\(.name)'s guard does not redirect plaintext on 8081 to https://<the onion address> with 308: \(redirect)"),
    (if [.certificates[]?] | length != 1 then "\([.certificates[]?] | length) certificates, not the onion's one" else empty end),
    (.certificates[]? | select(.snis != [{name: $onion}]) | "a certificate is not for the onion host alone: \(.snis)"),
    (.certificates[]? | select((.cert | contains("-----BEGIN CERTIFICATE-----") | not) or (.key | contains("PRIVATE KEY-----") | not))
      | "the onion's certificate entity does not carry a PEM certificate and private key"),
    ($routes[] | select(onion | not) | select((.hosts // []) | any(.[]; . == $onion))
      | "\(.name) names the onion host, which only the onion routes may"),
    ($routes | route("edge-backoffice-onion-route")
      | select(.paths != ["/bff/"] or .methods != null or .strip_path != false or .preserve_host != true
          or .service_url != "http://kinetix-edge-service:8080")
      | "edge-backoffice-onion-route is not the onion's /bff/ route to the edge: \(.)"),
    ($routes | route("backoffice-app-onion-route")
      | select(.paths != ["/"] or .methods != null or .strip_path != false or .preserve_host == true
          or .service_url != "http://kinetix-backoffice:8080")
      | "backoffice-app-onion-route is not the onion's app route outside /bff/: \(.)")
  ]
| .[]
