# ---- runtime stage: scratch，只放二进制 + CA 根证书(STS/HTTPS 需要) ----
FROM scratch
# STS/HTTPS 需要根证书；package.sh 会写入 ca-certificates.crt。
COPY ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY creds-linux-amd64 /creds
# 以非 root 运行(数字 UID，scratch 无 /etc/passwd)
USER 65534:65534
ENTRYPOINT ["/creds"]
