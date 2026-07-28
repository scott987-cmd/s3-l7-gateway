# aws-sigv4-proxy compatibility build

The bundled `s3gw-sigv4-proxy:s3-compat-v2` Linux/amd64 image is based on
[`awslabs/aws-sigv4-proxy`](https://github.com/awslabs/aws-sigv4-proxy) commit
`9e83e1b5d2372d5ced60a85b912906e3a34502a2`.

The patch makes two narrowly scoped S3 compatibility corrections:

1. Copy permitted business headers before signing, so headers such as
   `x-amz-meta-*` are included in the new upstream SigV4 signature.
2. Normalize a zero-length non-chunked request to `http.NoBody`, causing Go's
   HTTP transport to emit the `Content-Length: 0` required by Aliyun OSS.

Reproduction:

```bash
git clone https://github.com/awslabs/aws-sigv4-proxy.git
cd aws-sigv4-proxy
git checkout 9e83e1b5d2372d5ced60a85b912906e3a34502a2
git apply /path/to/aws-sigv4-proxy-s3-compat.patch
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o aws-sigv4-proxy ./cmd/aws-sigv4-proxy
```

Integrity:

| Artifact | SHA-256 |
|---|---|
| Patched Linux/amd64 binary | `e59ffd6a91a7cff9e63b962da090326d8cb6972ebb283ef490dd4008f2e7c56f` |
| Bundled image archive | `7f423bc44a286c1dec4117d129e57ef06d972983106054b730a170d1b4dd9a07` |

The upstream Apache-2.0 `LICENSE` and `NOTICE` are retained under
`third_party/aws-sigv4-proxy/`.
