# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Public repository scaffolding: Chinese-default README with an English version, `DISCLAIMER.md`, `SECURITY.md`, `CONTRIBUTING.md`, this changelog, and a published documentation site under `docs/`.
- Continuous integration: `gofmt`, `go vet` and `go test` for both Go services, shell parsing and ShellCheck, a Docker Compose config validation, and a credential scan over the whole tree.
- Documentation site including an L4-versus-L7 comparison backed by the measured small-object numbers, so the trade-off can be read rather than argued.

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
