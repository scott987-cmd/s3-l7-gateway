# 对接阿里云 OSS

本文记录一次**真实环境实测**的完整过程与结论：Alibaba Cloud Linux 4 (Anolis) ECS + 阿里云 OSS（cn-beijing）。
所有数字与行为均为实测所得，不是推导。

> 本项目与阿里云无隶属或背书关系。这里出现的产品名称仅用于说明配置格式。

## 一、先回答最关键的问题：OSS 接受 AWS SigV4 吗？

**接受。** 这是整个方案能否落在 OSS 上的前提，实测确认：

```bash
curl --aws-sigv4 "aws:amz:cn-beijing:s3" --user "<AK>:<SK>" \
  "https://<bucket>.oss-cn-beijing.aliyuncs.com/?list-type=2&max-keys=3"
# → 返回标准 S3 <ListBucketResult>
```

PUT / GET / HEAD / DELETE 全部以标准 SigV4 通过（200 / 200 / 200 / 204）。

### 两个反直觉的实测结论

| 项 | 实测结果 | 对配置的影响 |
|---|---|---|
| **region 字符串** | `cn-beijing`、`oss-cn-beijing`、甚至 `us-east-1` 都返回 **200**；只有空值返回 400 | OSS **不校验** credential scope 里的 region。但 `authd` 会校验客户端 region 与 `S3_REGION` 是否一致，所以两端仍必须约定同一个值 |
| **service 名** | `s3` → 200；`oss` → **400** | `S3_SERVICE` 必须是 `s3`，不能写 `oss` |

## 二、内网端点 vs 公网端点

| 端点 | 形态 | 何时可用 |
|---|---|---|
| 内网 | `<bucket>.oss-cn-beijing-internal.aliyuncs.com` | **仅同区域 VPC 内**。实测在 cn-beijing ECS 上解析到 `100.118.58.x`，连接 3.4 ms |
| 公网 | `<bucket>.oss-cn-beijing.aliyuncs.com` | 任意位置 |

生产用内网端点：不走公网、时延更低、无公网流量费。
**从本机（VPC 外）验证时必须改用公网端点**，否则 preflight 会在 DNS/TCP 检查处失败——那是环境限制，不是配置错误。

## 三、实测通过的配置

```bash
export S3_ACCESS_KEY=<真实AK>     # 走环境变量，不进 shell history、不写入仓库
export S3_SECRET_KEY=<真实SK>

./scripts/acceptance.sh \
  S3_REGION=cn-beijing \
  S3_ENDPOINT_HOST=oss-cn-beijing-internal.aliyuncs.com \
  S3_BUCKET_HOST=<bucket>.oss-cn-beijing-internal.aliyuncs.com \
  S3_CREDS_SOURCE=static \
  TEST_BUCKET=<bucket> \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=8443 \
  GW_SERVER_NAMES="s3gw.example.com <ECS公网IP> localhost" \
  HEALTH_ALLOW_DIRECTIVES="allow 127.0.0.1; allow 172.16.0.0/12; deny all;" \
  SIGV4_PROXY_MEM_LIMIT=2g \
  TEST_REQUIRE_DELETE=1
```

要点：

- `S3_ENDPOINT_HOST` 是 **region 级**端点（不带 bucket），`S3_BUCKET_HOST` 是 **bucket 级**虚拟主机名（带 bucket）。OSS 用 virtual-hosted 风格，两者形态不同，不要填反。
- `S3_CREDS_SOURCE=static`。`imds` / `sts` 是 Volcengine 专用实现，在阿里云 ECS 上不适用。
- 客户端对**网关**仍用 path-style（`https://gateway/<bucket>/<key>`）；网关回源时自动转成 OSS 的 virtual-hosted 形式。
- `TEST_REQUIRE_DELETE=1` 仅当你的 OSS 凭证确实有 `DeleteObject` 权限时才设。

## 四、Alibaba Cloud Linux / Anolis 上安装 Docker

`init_host.sh` 已处理，但值得知道原因：**docker-ce 只发布到 `centos/{7,8,9,10}`**，而 Alibaba Cloud Linux 4 的 `$releasever` 展开成 `4`，官方 repo 文件会拼出 `.../centos/4/x86_64/stable/`，必然 404。这台机器上 `rpm -E %{rhel}` 还会返回字面量 `%{rhel}`，任何基于它的推导也会失败。

脚本的做法是**先探测再落盘**：对每个镜像站按候选 releasever 依次 HEAD `repodata/repomd.xml`，命中哪个就把该 URL 写成显式 `baseurl`，完全绕开 `$releasever`。实测在本机选中 `mirrors.aliyun.com` + `centos/9`，装上 docker-ce 29.6.2 / compose v5.3.1。

## 五、实测结果

环境：Alibaba Cloud Linux 4.0.4 (Anolis)，4 vCPU / 7 GiB，裸机（无 docker / jq / aws-cli / go）。

| 阶段 | 结果 |
|---|---|
| `init_host.sh` | 从零装齐 docker-ce 29.6.2 + compose v5.3.1 + aws-cli |
| `preflight.sh` | `PASS=21 WARN=0 FAIL=0`，并正确识别内网私有 IP |
| `deploy.sh` | 四容器全部 healthy，仅 nginx 映射宿主 8443 |
| `smoke_test.sh` | `PASS=6 WARN=0 FAIL=0`（含 DELETE） |
| `speed_test.sh` | 64 MiB：PUT 32 MB/s、GET 64 MB/s、MD5 一致 |

安全行为逐项验证：

| 验证项 | 结果 |
|---|---|
| 未知 Host | 连接被关闭 |
| 错误虚拟 SK / 未知虚拟 AK / 无签名 | 全部 403，且审计中 `upstream_time` 为空——未验签请求不触达 OSS |
| **写请求重放**（手工构造、连发三次完全相同的 Authorization） | 第 1 次 200，第 2、3 次 **403 forbidden** |
| **密钥吊销** | `keyctl disable --reload` 后同一凭证立即 403；`enable` 后恢复 200 |
| 审计归因 | 按虚拟 AK 记录 method / uri / status / 耗时；`has_query` 只记是否存在 |
| 真实凭证泄露 | 审计日志、容器日志、响应头中均**未出现**真实 AK/SK |
| 公网访问 `/healthz` | 403（来源白名单生效） |
| 容器加固 | 四容器均 `ReadonlyRootfs=true` `CapDrop=[ALL]` `no-new-privileges:true` |
| 宿主端口暴露面 | 仅 8443（除 SSH 外） |

> 这些数字来自一次特定环境的实测，用于证明链路与机制真实可用，**不构成生产 SLA**。你的对象大小、并发和实例规格不同，必须自行压测。

## 六、踩过的坑

**从 VPC 外验证会误报。** 在 macOS 上跑 `preflight.sh` 会出现 2 个 FAIL——原因是 macOS 没有 `getent` 和 `timeout`（GNU coreutils），不是配置问题。同一份配置在 Linux ECS 上是 `FAIL=0`。要在本机验证，请改用公网端点，并把 preflight 的网络两项结果当作不适用。

**aws-cli v1 的 stderr 噪音。** v1 在 `--no-verify-ssl` 下每次调用都会往 stderr 打 `InsecureRequestWarning`。`speed_test.sh` 曾按"输出非空"判定失败，于是把成功的清理报成 `[WARN] cleanup failed`。现已改为按退出码判定，`init_host.sh` 也调整为优先安装 aws-cli v2。
