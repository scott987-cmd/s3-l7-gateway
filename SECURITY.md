# Security

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/scott987-cmd/s3-l7-gateway/security/advisories/new) rather than a public issue. Include the affected component, the configuration that triggers it, and the impact you observed.

## What this gateway is for

The asset being protected is threefold: the private object data, the **real upstream AK/SK**, and the access boundary between callers. The design assumption is that callers sit outside the trust boundary and must never hold the real credentials.

| Trust zone | Holds | May do |
|---|---|---|
| Caller | Virtual AK/SK, gateway endpoint, region | Produce standard S3 SigV4 requests. Cannot obtain real credentials or bypass the gateway. |
| Edge (WAF/LB) | Public certificate, origin config, source policy | Terminate TLS, run L7 protections, re-originate over HTTPS. **Must not rewrite already-signed HTTP semantics.** |
| Gateway runtime | Virtual key store, real credentials in memory, audit log | Verify virtual signatures, attribute the caller, strip the old signature and re-sign with real credentials. |
| Object storage | Private buckets and objects | Accept only requests signed with real upstream credentials that satisfy the bucket policy. |

What crosses a trust boundary is a **signature proof, never a key**. Both the virtual SK and the real SK are used only for local HMAC computation inside their own zone; neither travels on the wire.

## Defence in depth

No single check carries the design. If one layer is misconfigured, the next still constrains the blast radius.

| Layer | Implementation | Risk addressed |
|---|---|---|
| Internet edge | WAF/LB, IP allowlists, global rate limiting, bot and scanner protection | DDoS, scanning, brute force, hostile sources |
| Transport | TLS 1.2/1.3, ECDHE suites, session tickets off, HTTPS origin recommended | Eavesdropping, MITM, downgrade, weak ciphers |
| Ingress narrowing | `GW_SERVER_NAMES` Host allowlist; unknown Host closes the connection; `/healthz` source allowlist | Host confusion, bare-IP access, wildcard scanning |
| Request authentication | Virtual SigV4 with region/service, clock window, SignedHeaders, mandatory Host, constant-time HMAC | Forged credentials, tampering with signed fields, cross-region reuse, timing side channels |
| Replay protection | Per-process one-shot signature cache on write methods by default | Repeated writes, overwrites, deletes |
| Credential isolation | Callers hold virtual keys only; real credentials come from `creds` (static / IMDS / STS) | Broad real-credential leakage, fleet-wide rotation |
| Outbound sanitisation | Client `Authorization`, security token, date, payload hash and checksum/trailer headers stripped before re-signing | Virtual signature contaminating upstream, token smuggling, header confusion |
| Least-privilege runtime | All services read-only rootfs, `cap_drop: ALL`, `no-new-privileges`; nginx non-root | In-container persistence, privilege escalation |
| Internal isolation | `authd`, `creds`, `sigv4-proxy` map no host port; only nginx is exposed | Bypassing the entry point to reach verification or credential services |
| Audit | Structured logs attributed by virtual access key; full query string not recorded | Non-attributable access, leaking signed parameters |
| Resource protection | `SIGV4_PROXY_MEM_LIMIT` (4 GiB default), nginx body and connection limits, restart policy | Large-object OOM, connection exhaustion |

## Credential leak is a bounded event

A leaked **virtual** key is contained by four things at once: it is one key among many, it only works through the gateway, the real credentials behind it are least-privilege, and it is scoped to one bucket host. Containment does **not** require rotating every caller, and never requires handing real credentials to an application.

```bash
LINES=500 ./scripts/ops.sh audit                       # 1. attribute the leaked virtual AK
./scripts/keyctl.sh disable AKxxxxx --reload           # 2. seconds-level disable, others unaffected
                                                       # 3. confirm old credential now returns 403
./scripts/keyctl.sh add --owner team-a --reload        # 4. re-issue for that application
./scripts/ops.sh bundle                                # 5. capture a 0600, non-interpolated evidence bundle
```

A leaked **real** upstream credential is a different class of event and is exactly what this design exists to prevent: real credentials never leave the gateway runtime, are never sent to clients, and never appear in WAF or audit logs.

## Residual risks

Stated plainly, because each one bounds what you can promise.

**Headers are verified, the body is not re-hashed.** `authd` checks the payload hash the signature declares but does not read the whole body; the outbound leg uses `UNSIGNED-PAYLOAD` to stay streaming. This is safe only if client→WAF and WAF→gateway are both HTTPS and the WAF does not modify the body. Do not deploy with a plaintext hop.

**Replay cache is per-process.** A single instance rejects a repeated write signature inside the time window; instances do not share that state. Strict global once-only semantics need a shared cache or sticky load balancing.

**A leaked virtual key has a window.** Until it is disabled, the holder can act through the gateway within the real credential's permissions. Shorten the window with one key per application, expiry dates, audit alerting and seconds-level `disable`; bound the damage with least-privilege real credentials.

**`static` mode keeps real AK/SK on the gateway host.** The file is `0600` and the credentials only enter the `creds` runtime, but where the platform supports it, prefer IMDS or STS temporary credentials.

**Large objects at high concurrency can OOM the proxy.** Measured: 256 MiB at concurrency 16 triggered `sigv4-proxy` OOM on a 2 vCPU / 7.4 GiB host. The memory limit bounds the blast radius; it does not remove the characteristic. Load-test at your own object sizes.

**Presigned URLs are not supported.** Standard header-based SigV4 only. Do not put query-only authentication in a customer commitment.

## Security acceptance checklist

- [ ] Wrong virtual AK/SK, expired keys and tampered signatures all return 403 with no upstream status
- [ ] The same write signature replayed inside the window is rejected
- [ ] Unknown Host closes the connection; public sources cannot reach `/healthz`
- [ ] WAF reaches the gateway over HTTPS and preserves Host, path, query, SignedHeaders and body semantics
- [ ] Real upstream credentials carry only the minimum permissions on the target bucket
- [ ] `authd`, `creds` and `sigv4-proxy` expose no host ports; containers stay read-only and least-privilege
- [ ] Audit logs attribute by virtual AK and record neither full query, SK nor security token
- [ ] Key disable and hot reload have been rehearsed; the old credential returns 403 immediately
- [ ] Large-object and production concurrency load tests are done, with alerting on OOM, 502 and container restarts

## Secret hygiene in this repository

- `.env` and `auth/keys.json` are gitignored; only `.env.example` and an empty key placeholder are tracked.
- `scripts/package.sh` excludes `.env`, real key material, certificates, logs and Git metadata from delivery archives.
- CI scans the tree for key-shaped strings and private keys on every push and pull request.
- No credential, certificate, private key, real IP address or internal hostname is committed here.
