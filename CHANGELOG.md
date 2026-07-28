# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `scripts/public_functional_test.sh`: serial, non-performance coverage through an explicitly supplied public endpoint, including zero-byte objects, encoded keys, metadata, Range GET, CopyObject, multipart transfer, listing, and residue cleanup.

- `scripts/verify_security.sh`: repeatable post-deployment security verification for signature rejection, upstream isolation, bucket routing, write replay protection, virtual-key revocation and recovery, credential leakage, audit attribution, and runtime container hardening.

- `docs/aliyun-oss.zh-CN.md`: a verified Alibaba Cloud OSS deployment guide, recording that OSS accepts AWS SigV4, that it does not validate the region string but does require service `s3`, the internal-versus-public endpoint distinction, and the full measured result of a from-zero deployment.

- Public repository scaffolding: Chinese-default README with an English version, `DISCLAIMER.md`, `SECURITY.md`, `CONTRIBUTING.md`, this changelog, and a published documentation site under `docs/`.
- Continuous integration: `gofmt`, `go vet` and `go test` for both Go services, shell parsing and ShellCheck, a Docker Compose config validation, and a credential scan over the whole tree.
- Documentation site including an L4-versus-L7 comparison backed by the measured small-object numbers, so the trade-off can be read rather than argued.

### Fixed

- **`verify_security.sh` depended on curl's version-specific `--aws-sigv4` canonical request behavior.** The curl 7.76.1 shipped by the verified CentOS Stream 9 host produced signatures that the gateway correctly rejected, while AWS CLI traffic and the script's own manual replay signer passed. Ordinary positive, negative, revocation, leakage, and cleanup probes now use one Python-standard-library SigV4 implementation; the real TOS security run passes `23/0/0` without changing gateway authentication behavior.

- **A repeat deployment could recreate backend containers while leaving Nginx running with stale resolved container IPs.** `deploy.sh` now force-recreates the full Compose group after builds, ensuring Nginx resolves the current authd and proxy addresses.

- **The upstream signing proxy omitted `Content-Length: 0` for empty PUT requests and signed before copying `x-amz-*` business headers.** Aliyun OSS consequently rejected zero-byte objects with `MissingContentLength` and metadata writes with `SignatureDoesNotMatch`. The delivery now loads an audited Linux/amd64 compatibility image based on upstream commit `9e83e1b5d2372d5ced60a85b912906e3a34502a2`; patch provenance and binary/archive hashes are recorded in `patches/aws-sigv4-proxy-s3-compat.patch`.

- **Delivery archives built on macOS emitted `LIBARCHIVE.xattr.com.apple.provenance` warnings when extracted on Linux.** The packager now suppresses macOS extended attributes and Apple metadata while creating the tarball.

- **Fresh deployments could produce a Compose ownership warning for the pre-seeded Nginx log volume.** `deploy.sh` intentionally creates the volume before Compose so UID 101 can own the audit log, but it did not attach Compose's project and volume labels. Newly seeded volumes now carry those labels and are recognized by current Compose versions.

- **`verify_security.sh` could warn that audit attribution was missing even when matching records existed.** With `pipefail` enabled, `grep -q` closed the `docker compose exec` pipeline as soon as it found a match; the producer then received SIGPIPE and made the whole condition false. Log and header checks now match captured input directly, avoiding false negatives on larger audit logs.

- **Object keys containing spaces reached `sigv4-proxy` with an invalid request target.** The path-style bucket stripping map used Nginx `$uri`, which decodes `%20` into a literal space before proxying; authentication succeeded but the re-signing proxy returned 400. Routing now derives the upstream path from the raw `$request_uri` while keeping the query separate, and the smoke test includes a space-containing object key regression.

- **`stress_test.sh` could report a successful process exit despite failed operations.** Per-step failures were written to the TSV but never affected the final exit status, the Docker stats filter still matched the old `s3gw-deploy` project name rather than current `s3gw-*` containers, and a large error report could exit early with SIGPIPE before the summary. It now exits non-zero when any worker fails, safely truncates error output, and includes the active gateway containers in resource snapshots.

- **`init_host.sh` wrote a fixed list of registry mirrors, two of which were unreachable.** Mirror reachability varies by network; Docker tries them in order and stalls on each dead one, which shows up as `docker pull` hanging with no output. Measured on the test ECS: `docker.mirrors.ustc.edu.cn` and `mirror.ccs.tencentyun.com` both timed out while only `docker.m.daocloud.io` answered. The installer now probes each candidate and writes only the ones that respond — and writes nothing at all when none do, which is the right outcome outside China.

- **Bucket-level operations were routed to the upstream as an object.** The path-style→virtual-hosted map in `nginx/s3gw.conf.template` only matched a bucket segment followed by `/`, so a request without a trailing slash — `GET /bucket?list-type=2`, `HEAD /bucket` — fell through to the default and reached the upstream as a GetObject for a key named after the bucket. Verified against Alibaba Cloud OSS: the upstream answered `NoSuchKey` with `<Key>commvalult</Key>`, `aws s3api head-bucket` returned 404 and `aws s3 ls s3://bucket` failed. Since clients are required to use path-style, a single-segment path is unambiguously a bucket; the map now rewrites it to `/`. Object paths are unchanged and the full smoke test still passes.
- **`configure.sh` could derive a bucket host that can never work.** When `S3_BUCKET_HOST` is omitted it derives `<TEST_BUCKET>.<S3_ENDPOINT_HOST>`. Operators are commonly handed the already bucket-qualified endpoint (`bucket.oss-cn-beijing-internal.aliyuncs.com`), and pasting that as `S3_ENDPOINT_HOST` produced `bucket.bucket.oss-...`, which no single-label wildcard certificate covers — every upstream request would fail TLS verification. It now detects the bucket prefix and splits the two hosts apart instead.


- `init_host.sh` could not install Docker on Alibaba Cloud Linux 4 / Anolis, and by extension on any RHEL-family distribution whose `$releasever` is not one docker-ce publishes for. docker-ce ships only `centos/{7,8,9,10}`; Alinux 4 expands `$releasever` to `4`, so every mirror returned 404, and `rpm -E %{rhel}` returns the literal `%{rhel}` there so nothing could be derived from it either. The installer now probes `repodata/repomd.xml` across mirrors and candidate release versions and writes an explicit `baseurl`, bypassing `$releasever` entirely. Debian/Ubuntu support was added on the same probe-first principle, and aws-cli now falls back package manager → official v2 installer → pip3.
- `speed_test.sh` treated any output from `delete-object` as failure instead of checking the exit code, so a successful cleanup was reported as `[WARN] cleanup failed` whenever aws-cli wrote anything to stderr — which aws-cli v1 does on every `--no-verify-ssl` call. It now branches on the exit code, matching `smoke_test.sh`.

- `stress_test.sh`: `key` was assigned in the same `local` statement as `c` and `idx`, so those expanded before the assignments took effect and every worker in a concurrency batch wrote to the *same* object key instead of distinct ones. Concurrency levels and object sizes in past runs were still real, and the `sigv4-proxy` OOM boundary still holds, but throughput figures from before this fix should be re-measured.
- `smoke_test.sh`: an unguarded `cd` could continue in the wrong directory if it failed.

### Changed

- Third-party provenance is stated up front: this is an independent project, not an official or endorsed offering of any vendor. The `LICENSE` copyright holder is filled in.
- Delivery-package section now points at `scripts/package.sh` and repository releases rather than an external download.
- Example bucket names and key owners in `.env.example`, `auth/authd_test.go` and the reference document are generic placeholders.

### Notes

The clean Alibaba Cloud Linux 4 acceptance run completed with preflight `21/0/0`, smoke `7/0/0`, and security verification `23/0/0`. With 64 MiB objects and a 4 GiB proxy limit, concurrency 1–16 passed; concurrency 32 produced 31/32 successful PUTs and two memcg OOM restarts, establishing the current single-instance failure boundary.

The clean Volcengine CentOS Stream 9 + TOS run completed on 2026-07-29 using the `cn-beijing` private S3 endpoint: acceptance smoke `7/0/0`, public-IP serial functional coverage `10/10`, security verification `23/0/0`, repeat-deployment smoke `7/0/0`, zero container restarts/OOMs/log errors, and zero test-object residue. No performance test was run in this validation.

Prebuilt Linux amd64 runtime binaries are deliberately **not** tracked in git — they are build artifacts, already listed in `.gitignore`. `deploy.sh` builds them with Go when they are missing, and `scripts/package.sh` produces delivery archives that include them for hosts without Go.

## [1.0.0]

Initial public release of the S3 SigV4 gateway.

### Added

- Four-service composition: `nginx` (TLS, Host allowlist, health checks, rate limiting, audit, path-style routing), `authd` (virtual SigV4 verification, write replay protection), `creds` (static / IMDS / STS real-credential sidecar), `sigv4-proxy` (strip old signature, re-sign with real credentials).
- Virtual AK/SK issued per application, with owner, note and expiry; `keyctl.sh` for add, list, disable, enable and hot reload without restarting the gateway.
- One-command `acceptance.sh` chaining configure, preflight, deploy, health and smoke test.
- Operations tooling: health, status, logs, audit, reload, doctor and support bundle.
- Testing tooling: smoke test, quick throughput test and staged concurrency stress test.
- Runtime hardening: read-only root filesystems, `cap_drop: ALL`, `no-new-privileges`, non-root nginx, no host ports on internal services, digest-pinned images.

### Verified

From-zero delivery on a freshly reinstalled CentOS Stream 9 ECS with no Docker, Compose or aws-cli present: preflight `PASS=21 WARN=0 FAIL=0`, smoke `PASS=5 WARN=1 FAIL=0` (the warning is the real credential lacking `DeleteObject`), 8 MiB PUT/GET with MD5 match, signed PUT/GET through a public load balancer, `/healthz` returning 403 to public sources after hardening, and unknown Host closing the connection.

Capacity on 2 vCPU / 7.4 GiB: 64 MiB at concurrency 32 succeeded; 256 MiB at concurrency 4 and 8 succeeded; 256 MiB at concurrency 16 triggered a `sigv4-proxy` OOM. These are controlled-test references, not a production SLA.
