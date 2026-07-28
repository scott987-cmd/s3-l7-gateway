# Deployment Guide

This gateway is for S3-compatible object storage. The default customer path uses static upstream S3 credentials and does not require Volcengine/TOS-specific features.

## One-command acceptance

Use environment variables for sensitive values to avoid putting real credentials in shell history:

```bash
export S3_ACCESS_KEY=<real-upstream-ak>
export S3_SECRET_KEY=<real-upstream-sk>

./scripts/acceptance.sh \
  S3_REGION=<region> \
  S3_ENDPOINT_HOST=<s3-endpoint-host> \
  S3_BUCKET_HOST=<bucket>.<s3-endpoint-host> \
  TEST_BUCKET=<bucket> \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=443 \
  GW_SERVER_NAMES="s3gw.example.com" \
  HEALTH_ALLOW_DIRECTIVES="allow <waf-cidr>; allow <clb-health-cidr>; allow 127.0.0.1; deny all;"
```

`acceptance.sh` runs:

1. `configure.sh`: writes `.env` and creates a virtual client AK/SK when needed.
2. `preflight.sh`: checks config, dependencies, port use, upstream DNS, upstream TCP 443, and compose syntax.
3. `deploy.sh`: builds Go components and starts compose services.
4. `ops.sh health`: checks gateway, `authd`, and `creds`.
5. `smoke_test.sh`: verifies wrong virtual credentials are rejected, then PUT/GET/HEAD through the gateway.

## Required parameters

| Parameter | Description |
|---|---|
| `S3_REGION` | SigV4 region expected by the upstream object storage. |
| `S3_ENDPOINT_HOST` | Upstream S3 endpoint host without scheme. Prefer private/VPC endpoint when available. |
| `S3_BUCKET_HOST` | Upstream virtual-hosted bucket host, usually `<bucket>.<s3-endpoint-host>`. |
| `S3_CREDS_SOURCE` | `static` by default. Use `imds`/`sts` only for supported provider-specific flows. |
| `S3_ACCESS_KEY` | Real upstream S3 access key. |
| `S3_SECRET_KEY` | Real upstream S3 secret key. |
| `S3_SESSION_TOKEN` | Optional upstream session token. |
| `TEST_BUCKET` | Bucket used by smoke and capacity tests. |
| `GW_BIND_ADDR` | `127.0.0.1` for local tests; `0.0.0.0` behind CLB/LB. |
| `GW_LISTEN_PORT` | Host listen port, commonly `443` behind CLB/LB. |
| `GW_SERVER_NAMES` | Space-separated HTTP Host values accepted by Nginx. Include the client-facing S3 gateway domain forwarded by WAF/CLB. |
| `HEALTH_ALLOW_DIRECTIVES` | Nginx `allow`/`deny` directives for `/healthz`. Use WAF/CLB health-source CIDRs; do not use `allow all`. |
| `SIGV4_PROXY_MEM_LIMIT` | Container memory limit for `sigv4-proxy`; default `4g`. Size it with the tested object-size/concurrency boundary. |

## WAF and HTTPS origin

For production internet exposure, use:

```text
S3 client -> HTTPS -> WAF -> HTTPS -> CLB/LB -> HTTPS :443 -> gateway
```

WAF TLS termination does not by itself break SigV4. The WAF and load balancer must preserve the client-signed HTTP `Host`, method, path, query, `Authorization`, `x-amz-*` signing headers, other `SignedHeaders`, and request body semantics.

The public client domain and private origin address may differ. If the WAF supports independent origin address, TLS SNI, and HTTP Host settings:

```text
origin address: origin-s3gw.example.internal
origin SNI: origin-s3gw.example.internal
HTTP Host: s3gw.example.com
```

The origin certificate must cover the origin SNI, while `GW_SERVER_NAMES` must contain the HTTP Host signed by the client. If the WAF cannot configure SNI and Host independently, use a gateway certificate that covers the actual WAF origin hostname.

Keep WAF-to-gateway HTTPS enabled and configure backend certificate verification. HTTP origin is not provided by the default gateway configuration.

Before customer handoff, follow the full configuration and validation checklist in [`security-waf.md`](security-waf.md).

## Host initialization

On a new CentOS/RHEL compatible host:

```bash
sudo bash scripts/init_host.sh
```

This installs Docker Engine, the Compose plugin, and `aws-cli` if missing. It is idempotent and can be rerun.

The customer package includes prebuilt Linux amd64 runtime binaries:

- `auth/authd-linux-amd64`
- `creds/creds-linux-amd64`
- `creds/ca-certificates.crt`

Therefore the customer host does not need Go and does not need to pull a Go builder image during deployment. `deploy.sh` only builds small runtime images from the packaged binaries.

## Preflight only

Run this before deployment when validating a customer machine:

```bash
./scripts/preflight.sh
```

If checking an already deployed node where the gateway port is occupied by this same project:

```bash
ALLOW_PORT_IN_USE=1 ./scripts/preflight.sh
```

## Packaging

Generate a clean customer package:

```bash
./scripts/package.sh
```

The package excludes `.git`, `.env`, real credentials, virtual keys, generated certs, logs, support bundles, and backup files.

## Verified clean-host flow

The following flow was verified on a reinstalled Alibaba Cloud Linux 4 ECS that initially had no Docker, no Compose, and no aws-cli:

```bash
sudo bash scripts/init_host.sh

export S3_ACCESS_KEY=<real-ak>
export S3_SECRET_KEY=<real-sk>

./scripts/acceptance.sh \
  S3_REGION=cn-beijing \
  S3_ENDPOINT_HOST=tos-s3-cn-beijing.ivolces.com \
  S3_BUCKET_HOST=private-proxy.tos-s3-cn-beijing.ivolces.com \
  TEST_BUCKET=private-proxy \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=443 \
  TEST_KEY=s3gw-clean-acceptance.txt \
  TEST_REQUIRE_DELETE=0
```

Result:

```text
configure passed
preflight PASS=21 WARN=0 FAIL=0
deploy passed
health passed
smoke PASS=7 WARN=0 FAIL=0
acceptance passed
```
