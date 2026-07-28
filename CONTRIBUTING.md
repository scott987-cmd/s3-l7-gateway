# Contributing

## Ground rules

Three properties define this gateway. A change that breaks any of them is out of scope here.

1. **Real upstream credentials never leave the gateway runtime.** They are never sent to a client, never logged, never placed in a response header.
2. **Every request is verified before it reaches the upstream.** No path may skip `authd` verification and reach `sigv4-proxy`.
3. **The old client signature is stripped before re-signing.** `Authorization`, security token, date, payload hash and checksum/trailer headers must not survive to the upstream request.

CI enforces what it can; reviewers enforce the rest.

## Before opening a pull request

```bash
(cd auth   && gofmt -l . && go vet ./... && go test ./...)
(cd creds  && gofmt -l . && go vet ./... && go test ./...)
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck --severity=warning scripts/*.sh
```

`gofmt -l .` must print nothing.

## Testing a real change

Static checks cannot prove a signature path works. If you touch `authd`, `creds`, `sigv4-proxy` wiring or the nginx template, run the real thing against a real S3-compatible endpoint on a disposable host:

```bash
export S3_ACCESS_KEY=... S3_SECRET_KEY=...
./scripts/acceptance.sh S3_REGION=... S3_ENDPOINT_HOST=... S3_BUCKET_HOST=... TEST_BUCKET=...
SIZE_MB=64 ./scripts/speed_test.sh
```

Say in the pull request which upstream, object sizes and concurrency you tested. "Builds fine" is not a test result.

Signature changes deserve a test in `auth/authd_test.go`. The existing tests compute signatures at runtime rather than asserting frozen digests, so add cases in that style.

## Style

- Go: standard `gofmt`, no new third-party dependencies without a reason in the pull request.
- Shell: `set -euo pipefail`, and every new setting is an environment variable with a default, documented in `.env.example` and the user guide.
- Anything that writes to the host must be idempotent and safe to re-run.
- Help text must match behaviour. A help string that overstates what a command does is a bug.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
