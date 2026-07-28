# WAF 与 TLS 安全接入指南

本文面向客户网络、安全、云平台和交付团队，描述 S3 兼容对象存储网关前置 WAF/CLB 时的推荐架构、配置边界和验收方法。

## 结论

生产推荐链路：

```text
标准 S3 客户端
  -> HTTPS
WAF（终止客户端 TLS、执行 L7 防护）
  -> HTTPS
CLB/LB
  -> HTTPS :443
S3 网关 nginx（验证虚拟 SigV4）
  -> HTTPS
私网/VPC S3 endpoint（使用真实凭证重新签名）
```

WAF 做 TLS 卸载没有问题。SigV4 不签 URL scheme，也不要求一条 TLS 会话贯穿客户端和网关。WAF 解密后重新建立到后端的 HTTPS 连接，不会天然破坏签名。

真正的约束是：WAF/CLB 不得改变客户端签名覆盖的 HTTP 语义，尤其是 `Host`、method、path、query、`Authorization`、`x-amz-date`、`x-amz-content-sha256`、`x-amz-security-token` 和其他出现在 `SignedHeaders` 中的头。

## 域名、Host、SNI 与证书

外网域名和内网回源域名不要求一致，但需要区分四个概念：

| 项目 | 示例 | 要求 |
|---|---|---|
| 客户端访问域名 | `s3gw.example.com` | 客户端 endpoint；其 HTTP `Host` 参与 SigV4 签名。 |
| WAF 回源地址 | `origin-s3gw.example.internal` 或私网 IP | 只用于 WAF 找到后端，可以与客户端域名不同。 |
| WAF 回源 HTTP Host | `s3gw.example.com` | 必须保留客户端签名时的 Host，不能改成后端 IP 或内部域名。 |
| WAF 回源 TLS SNI | `origin-s3gw.example.internal` 或 `s3gw.example.com` | 用于验证网关证书；必须在网关证书 SAN 中。 |

最简单的配置是客户端域名、回源 Host、回源 SNI 和网关证书 SAN 都使用同一个业务域名。

如果 WAF 支持独立配置回源地址、HTTP Host 和 TLS SNI，也可以使用不同的内外网域名：

```text
回源地址: origin-s3gw.example.internal
回源 SNI: origin-s3gw.example.internal
HTTP Host: s3gw.example.com
```

此时网关证书覆盖 `origin-s3gw.example.internal`，`GW_SERVER_NAMES` 包含客户端签名使用的 `s3gw.example.com`。如果 WAF 不能分别设置 SNI 和 Host，则网关证书需要覆盖 WAF 实际发送的域名。

证书分为两套：

- WAF 公网证书：覆盖客户端访问域名，由客户端校验。
- 网关回源证书：覆盖 WAF 回源 SNI，由 WAF 校验。

生产必须启用 WAF 对后端证书的校验。自签证书和 `--no-verify-ssl` 只用于部署前测试。安全要求更高时，可以在 WAF 到网关之间启用 mTLS。

## TLS 模式选择

| 模式 | 结论 | 说明 |
|---|---|---|
| WAF 终止 TLS，回源 HTTPS | 推荐 | WAF 可做 L7 检测，后端链路继续加密；当前网关默认支持。 |
| TCP/TLS 透传 | 可选 | 不改 HTTP 报文，但 WAF 无法做完整 L7 检测。 |
| WAF 终止 TLS，回源 HTTP | 不推荐且当前默认不支持 | 理论上 scheme 不参与 SigV4，但后端链路明文；需要额外新增 HTTP listener 并重新完成安全评审和验收。 |

如果客户要求“WAF 返回后端仍然使用 HTTPS”，该要求与本方案推荐模式一致，不需要修改网关代码。

## SigV4 保真要求

WAF/CLB 必须满足：

1. 保留原始 HTTP method。
2. HTTP `Host` 保持为客户端签名时的网关域名。
3. 不规范化、解码后重编码或合并对象 key 路径。
4. 不删除 query 参数，不修改参数名、值、重复参数或编码语义。
5. 不删除或改写 `Authorization` 和 `x-amz-*` 签名相关头。
6. 不修改任何列入 `SignedHeaders` 的头值。
7. 不解压、重压缩、转码或改写请求体和响应体。

WAF 添加未参与签名的代理头通常不会影响验签，但不能覆盖已签头。对象 key 可能合法包含空格、百分号、非 ASCII 字符和看起来像攻击路径的片段，WAF 规则需要通过真实对象 key 用例验证，不能仅按普通 Web URL 规则直接阻断。

当前 `authd` 只支持 `Authorization` 请求头形式的 SigV4，不支持仅通过 `X-Amz-*` query 参数传递认证信息的预签名 URL。WAF 规则和客户接入说明不应把预签名 URL 列为已支持能力。

`authd` 验证客户端声明的 `x-amz-content-sha256` 是否参与签名，但不会读取并重新计算整个请求体；网关到对象存储的重签链路使用 `UNSIGNED-PAYLOAD` 保持流式传输。因此 WAF 属于受信边界，必须禁用请求体转换，并用 HTTPS 回源防止 WAF 与网关之间的第三方篡改。

## WAF 配置基线

### 协议与方法

允许标准 S3 操作所需的方法：

- `GET`
- `HEAD`
- `PUT`
- `POST`
- `DELETE`
- 浏览器跨域场景按需允许 `OPTIONS`

Multipart Upload 会使用带 query 的 `POST`、`PUT` 和 `DELETE`。不能只允许简单 GET/PUT。

### 请求大小与超时

- WAF 最大请求体必须覆盖客户单次对象或分片大小。
- 对超过 WAF 检查上限的大对象配置流式转发或受控的 body inspection bypass。
- 禁止因为“未检查完整 body”直接拒绝合法大对象。
- WAF、CLB idle timeout 和上传超时应不小于网关的 300 秒超时，或按客户最大对象和最低带宽重新计算。
- 禁止 WAF 缓冲全部大对象后再回源，否则会放大内存、临时磁盘和延迟风险。

### 规则与限流

- 阻断明显非 S3 探测，例如 PHP、ThinkPHP、Docker API 和管理后台路径。
- 对 S3 数据路径设置规则排除，避免对象 key 触发 SQL 注入、路径穿越或脚本特征误报。
- 以 WAF 做全局限流、IP 黑白名单、IP 信誉、Bot 和 DDoS 防护。
- 网关 nginx 的 `limit_req`/`limit_conn` 只作为单实例兜底。

网关未配置可信代理 IP 解析时，nginx 看到的来源地址是 WAF/CLB，而不是最终客户端；此时所有客户端可能共享同一个 nginx 限流桶。不要直接信任任意 `X-Forwarded-For`。如需在网关恢复真实客户端 IP，必须只信任明确的 WAF/CLB 出口 CIDR，并单独评审 `real_ip` 配置。

### 缓存与内容处理

- 禁止 WAF/CDN 缓存 S3 写请求和私有对象响应。
- 禁止自动压缩、解压、图片处理、内容替换和字符集转换。
- 禁止自动追加、删除或重写签名相关 header/query。
- 如启用恶意文件检测，必须保证检测过程只读且不改变上传内容。

### 日志脱敏

WAF、CLB 和日志平台不得记录以下值的明文：

- `Authorization`
- `x-amz-security-token`
- 真实或虚拟 AK/SK
- 完整认证 query

网关审计日志默认不记录完整 query，只记录 `has_query`。排障时也不要临时打开包含签名中间量或完整请求头的日志。

## CLB、网络与健康检查

- ECS 安全组入站 443 只允许 WAF/CLB 出口 CIDR 和必要的运维网段。
- 禁止后端 ECS 443 长期直接暴露公网。
- CLB 到网关使用 HTTPS 443，并校验网关证书。
- CLB 健康检查请求的 Host 必须命中 `GW_SERVER_NAMES`。
- CLB 健康检查来源 CIDR 必须加入 `HEALTH_ALLOW_DIRECTIVES`。

`/healthz` 默认只允许本机和常见内网网段。公网直接访问返回 403 是安全预期，不代表网关故障。

如果公网请求先经过 WAF，后端看到的来源可能全部是 WAF 出口 IP。此时仅靠网关的来源白名单无法阻止公网用户经 WAF 访问 `/healthz`，WAF 必须额外阻断公共 `/healthz`，或者只允许明确的监控来源。

## 网关参数模板

```bash
export S3_ACCESS_KEY=<real-upstream-ak>
export S3_SECRET_KEY=<real-upstream-sk>

./scripts/acceptance.sh \
  S3_REGION=<region> \
  S3_ENDPOINT_HOST=<private-s3-endpoint-host> \
  S3_BUCKET_HOST=<bucket>.<private-s3-endpoint-host> \
  TEST_BUCKET=<bucket> \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=443 \
  GW_SERVER_NAMES="s3gw.example.com health.s3gw.example.internal" \
  HEALTH_ALLOW_DIRECTIVES="allow <waf-cidr>; allow <clb-health-cidr>; allow 127.0.0.1; deny all;" \
  SIGV4_PROXY_MEM_LIMIT=4g \
  TEST_REQUIRE_DELETE=0
```

说明：

- `S3_ENDPOINT_HOST` 优先使用对象存储的 VPC/内网 endpoint。
- `S3_BUCKET_HOST` 是上游对象存储的 virtual-hosted bucket host，与客户访问网关的域名无关。
- `GW_SERVER_NAMES` 填 WAF/CLB 实际转发到 nginx 的 HTTP Host。
- 不要把原始 ECS 公网 IP 永久加入 `GW_SERVER_NAMES`；IP 直连只用于临时诊断。
- `HEALTH_ALLOW_DIRECTIVES` 使用 WAF/CLB 的真实出口 CIDR，不要用 `allow all`。

## 上线验收

上线不能只验证 `/healthz`，必须从客户最终域名完成标准 S3 业务操作。

### 1. 网关本机验收

```bash
./scripts/preflight.sh
./scripts/acceptance.sh
SIZE_MB=64 ./scripts/speed_test.sh
```

### 2. 域名和证书

在 DNS 未正式生效时，可以用 `curl --resolve` 验证 TLS、SNI 和 Host 路由：

```bash
curl -v \
  --resolve s3gw.example.com:443:<waf-ip> \
  https://s3gw.example.com/healthz
```

如果 WAF 阻断公共健康检查，403 是预期。证书必须覆盖 `s3gw.example.com`，不能依赖 `-k` 通过。

完整 SigV4 业务验证需要让标准 S3 客户端实际解析最终域名。测试阶段可以临时配置受控 DNS 或 `/etc/hosts`，不要用 CLB IP 替代域名签名。

### 3. S3 业务验证

使用虚拟 AK/SK 经 WAF 执行：

1. 错误虚拟凭证返回 403。
2. PUT、GET、HEAD 成功，下载内容与上传内容一致。
3. Multipart Upload 成功。
4. 包含空格、百分号、非 ASCII 字符和较深目录的对象 key 成功。
5. 未授权 bucket/path 不会误转发。
6. WAF 日志已脱敏，网关审计能看到虚拟 access key 和上游状态。

### 4. 容量验证

`stress_test.sh MODE=clb` 使用 IP 作为 endpoint，适合验证 CLB/IP 链路容量，但不能证明最终业务域名的 Host/SigV4 保真。

WAF 最终验收应使用真实域名解析后再进行阶梯压测，至少覆盖：

```text
32 MiB: concurrency 1/2/4/8/16/32
64 MiB: concurrency 1/2/4/8/16
客户最大分片: 按生产并发验证
```

观察 WAF、CLB、nginx、`authd`、`sigv4-proxy`、ECS 内存和对象存储错误码，区分 WAF 阻断、SigV4 失败、上游拒绝和 OOM。

## 故障定位

| 现象 | 优先检查 |
|---|---|
| 经 WAF 403，直连网关成功 | 回源 HTTP Host、path/query 规范化、签名头是否被删除或改写。 |
| TLS 回源失败 | 回源 SNI、网关证书 SAN、证书链和 WAF 后端校验策略。 |
| `/healthz` 403 | CLB 健康源 CIDR 是否在 `HEALTH_ALLOW_DIRECTIVES`，健康检查 Host 是否在 `GW_SERVER_NAMES`。 |
| `/healthz` 444/连接关闭 | 请求 Host 未命中 `GW_SERVER_NAMES`。 |
| 大对象被 WAF 拒绝 | WAF body inspection 上限、缓冲策略、idle/upload timeout。 |
| 对象 key 特定字符失败 | WAF path 规范化、解码重编码或托管规则误报。 |
| 所有客户同时被 nginx 429 | nginx 看到的是同一 WAF/CLB 源 IP；主限流应放到 WAF，或安全配置可信代理 IP。 |
| 502/504 | `sigv4-proxy` 状态、容器内存、上游私网 endpoint 和 WAF/CLB 超时。 |

## 最终安全基线

上线前必须同时满足：

- 客户端到 WAF 为 HTTPS。
- WAF 到网关为 HTTPS，并校验后端证书。
- WAF 保留 SigV4 相关 Host、path、query、header 和 body 语义。
- ECS 443 只允许 WAF/CLB 来源。
- 网关到对象存储使用私网/VPC endpoint。
- 客户端只持有虚拟 AK/SK，真实凭证只存在于网关运行态。
- WAF 和网关日志不泄露凭证或完整认证参数。
- 最终域名完成 PUT/GET/HEAD/Multipart、异常凭证和阶梯压测验收。
