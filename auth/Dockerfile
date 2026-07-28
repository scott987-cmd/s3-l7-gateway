# ---- runtime stage: scratch，只放二进制，无 shell / 无包管理器 / 无解释器 ----
FROM scratch
COPY authd-linux-amd64 /authd
# 以非 root 运行（数字 UID，scratch 无 /etc/passwd）
USER 65534:65534
EXPOSE 8081
ENTRYPOINT ["/authd"]
