# Operations Guide

## Daily commands

```bash
./scripts/ops.sh health
./scripts/ops.sh status
./scripts/ops.sh audit
./scripts/ops.sh logs
```

## Support bundle

When escalation is needed:

```bash
./scripts/ops.sh bundle
```

The bundle includes compose config, service status, service logs, Nginx audit tail, listener state, socket summary, memory, disk, and host metadata. It does not include `.env`.

On the clean ECS validation run:

```text
support bundle: support/s3gw-support-20260727-174511.tgz
```

## Virtual client key lifecycle

Create one virtual AK/SK per client or tenant:

```bash
./scripts/keyctl.sh add --owner team-a --note "client-a" --expires 2026-12-31T23:59:59Z --reload
```

Disable a leaked key:

```bash
./scripts/keyctl.sh disable AKxxxxx --note "leaked" --reload
```

List key status:

```bash
./scripts/keyctl.sh list
```

`--reload` sends `SIGHUP` to the compose service `authd`, so it works even when the project is deployed under different directory names and container names.

## Important metrics

Watch:

- `nginx` `status`, `request_time`, `upstream_status`, `upstream_time`
- `authd` 403 rate for malformed signatures or unknown virtual keys
- `sigv4-proxy` 502/connection reset/OOM
- container memory, especially `sigv4-proxy` during large PUT concurrency
- host `dmesg` for OOM kills

## Public exposure signals

If the gateway is reachable from the internet, expect unsolicited scans. In validation, scanners requested paths such as:

- `/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php`
- `/index.php?...think...`
- `/containers/json`

Expected safe behavior:

- `access_key` is empty.
- status is 403.
- `upstream_status` is empty.

If unauthenticated scan traffic ever has a non-empty `upstream_status`, review `auth_request` and location matching immediately.

## Nginx exposure hardening

The gateway includes several hardening defaults:

- Unknown `Host` values are handled by a default TLS server and closed with status 444.
- The real gateway server only accepts `127.0.0.1`, `localhost`, and names configured by `GW_SERVER_NAMES`.
- `/healthz` is controlled by `HEALTH_ALLOW_DIRECTIVES`; by default it allows loopback and common private ranges only.
- Audit logs no longer record full query strings; they record only whether a query exists.
- `sigv4-proxy` has a default memory limit via `SIGV4_PROXY_MEM_LIMIT=4g`.
- Nginx uses a higher `nofile` ulimit and `worker_rlimit_nofile`.

When testing through a CLB IP directly, include that IP in `GW_SERVER_NAMES`. In production, prefer the customer gateway domain name and put the ECS behind CLB/WAF or security-group allowlists.

## WAF and TLS operations

The production default is WAF TLS termination followed by HTTPS origin to the gateway. TLS termination does not invalidate SigV4 as long as the WAF preserves the signed HTTP Host, path, query, headers, and body semantics.

Operational checks:

- Confirm the WAF origin protocol remains HTTPS and backend certificate verification is enabled.
- Confirm the origin HTTP Host is the client-facing gateway domain, even when the origin address or SNI uses an internal hostname.
- Confirm the gateway certificate covers the WAF origin SNI.
- Confirm WAF/CLB source CIDRs are the only network sources allowed to reach ECS 443.
- Confirm WAF blocks public `/healthz`, or restricts it to approved monitoring sources.
- Confirm WAF and CLB logs redact `Authorization`, `x-amz-security-token`, and credential-bearing query data.
- Re-run PUT/GET/HEAD and multipart tests after any WAF managed-rule, certificate, domain, origin, or normalization change.

See [`security-waf.md`](security-waf.md) for the full security baseline and failure matrix.

## Known capacity behavior

In the tested 2 vCPU / 7.4 GiB ECS:

- On the latest 4 vCPU / 7.3 GiB run, 64 MiB objects succeeded through concurrency 16; concurrency 32 exceeded the 4 GiB proxy limit.
- 256 MiB objects succeeded at concurrency 4 and 8.
- 256 MiB x concurrency 16 triggered `aws-sigv4-proxy` OOM.

For production, apply instance-level concurrency limits for large PUT workloads or scale horizontally behind CLB/LB.
