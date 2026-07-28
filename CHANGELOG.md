# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `docs/aliyun-oss.zh-CN.md`: a verified Alibaba Cloud OSS deployment guide, recording that OSS accepts AWS SigV4, that it does not validate the region string but does require service `s3`, the internal-versus-public endpoint distinction, and the full measured result of a from-zero deployment.

- Public repository scaffolding: Chinese-default README with an English version, `DISCLAIMER.md`, `SECURITY.md`, `CONTRIBUTING.md`, this changelog, and a published documentation site under `docs/`.
- Continuous integration: `gofmt`, `go vet` and `go test` for both Go services, shell parsing and ShellCheck, a Docker Compose config validation, and a credential scan over the whole tree.
- Documentation site including an L4-versus-L7 comparison backed by the measured small-object numbers, so the trade-off can be read rather than argued.

### Fixed

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
