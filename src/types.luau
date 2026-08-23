--!strict
-- Kinetix API Gateway Type Definitions (Luau Strict Type System & Lute Engine)

export type Request = {
    path: string,
    query: { [string]: string }?,
    url: string?,
    method: string,
    headers: { [string]: string },
    body: string?
}

export type Response = {
    status: number?,
    headers: { [string]: string }?,
    body: string?
}

export type GatewayConfig = {
    port: number,
    identity_service_url: string,
    catalog_service_url: string,
    warehouse_service_url: string,
    matching_service_url: string
}

return {}
