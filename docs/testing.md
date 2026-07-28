# Testing and Capacity Guide

## Smoke test

```bash
./scripts/smoke_test.sh
```

Expected result:

```text
PASS healthz=200
PASS bogus creds rejected
PASS put-object
PASS get-object + content match
PASS head-object
WARN delete-object skipped: real S3 credentials do not allow DeleteObject
PASS=5 WARN=1 FAIL=0
```

`DeleteObject` is optional because many customer credentials are read/write-only and do not include delete permission. Set `TEST_REQUIRE_DELETE=1` if delete permission must be part of acceptance.

## Quick throughput test

```bash
SIZE_MB=64 ./scripts/speed_test.sh
```

This performs one PUT and one GET through the gateway and compares MD5.

On the clean ECS validation run, an 8 MiB quick test passed:

```text
PASS put-object
PASS get-object
PASS md5 match
WARN cleanup skipped: real S3 credentials do not allow DeleteObject
```

## Stair-step stress test

Local gateway endpoint:

```bash
SIZE_MB=64 CONCURRENCY_LIST="1 2 4 8 16 32" ./scripts/stress_test.sh
```

CLB or external load balancer endpoint:

```bash
MODE=clb CLB_IP=<public-or-private-lb-ip> SIZE_MB=32 CONCURRENCY_LIST="1 2 4 8 16 32" ./scripts/stress_test.sh
```

`MODE=clb` signs requests for the IP endpoint. It validates the CLB/IP data path and capacity, but it does not prove that a WAF preserves the final customer domain in HTTP Host/SigV4.

For final WAF acceptance, configure real or temporary controlled DNS for the customer gateway domain and run standard S3 PUT/GET/HEAD and multipart operations through that domain. Using only `curl --resolve` is useful for TLS/Host probing, but the current stress script does not inject a custom DNS resolution into `aws-cli`.

Useful variables:

| Variable | Default | Description |
|---|---:|---|
| `SIZE_MB` | `64` | Object size per operation. |
| `CONCURRENCY_LIST` | `1 2 4 8 16` | Concurrency steps. |
| `ROUNDS` | `1` | Repeated rounds per step. |
| `DIRECTION` | `both` | `put`, `get`, or `both`. |
| `MODE` | `local` | `local` uses `127.0.0.1:<GW_LISTEN_PORT>`, `clb` uses `CLB_IP:443`. |
| `WORKDIR` | `/tmp/s3gw-stress` | Payload, downloads, errors, result TSV. |

The result TSV records success, fail, elapsed seconds, and MiB/s for each step.

## WAF acceptance

After WAF onboarding, verify:

1. Invalid virtual credentials return 403.
2. PUT, GET, and HEAD succeed through the final customer domain.
3. Multipart upload succeeds.
4. Object keys containing spaces, percent encoding, non-ASCII characters, and deep paths succeed.
5. The WAF does not rewrite the signed Host, path, query, or signing headers.
6. Large uploads are not rejected by body-inspection limits or buffered until timeout.
7. WAF/CLB logs redact credentials and signing material.
8. Public `/healthz` is blocked while the CLB health source receives 200.

The complete WAF/TLS checklist is in [`security-waf.md`](security-waf.md).

## Interpreting failures

- `403` at the gateway with empty `access_key`: virtual credential rejected by `authd`.
- `403` with populated `access_key` and upstream status: upstream object storage denied the real credential or policy.
- `502` from Nginx with `upstream prematurely closed`: usually `sigv4-proxy` crash/reset or upstream reset.
- OOM in `dmesg`: reduce large-object concurrency or scale out.

## Security noise during public exposure

When the ECS 443 port was exposed publicly, audit logs immediately showed internet scanners probing common PHP, PHPUnit, ThinkPHP, and Docker API paths. These requests had empty `access_key`, returned 403 at the gateway, and did not reach upstream object storage.

This confirms `authd` blocks unauthenticated requests, but production exposure should still use CLB/WAF/security-group allowlists rather than long-term bare ECS exposure.
