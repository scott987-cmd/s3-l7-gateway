# S3 兼容对象存储网关(aws-sigv4-proxy + authd + nginx)

在**对象存储私有桶不能公读、客户端需要标准 S3 协议接入**的前提下，用一个自建 S3 网关实现：
**真实凭证收口在网关、客户端用虚拟 AK/SK、网关验签后统一重签(SigV4)、L7 统一限流/审计**。

> 关键点：**客户端零改造**——就是一个标准 S3 客户端(boto3 / aws-cli)，
> 只配置 endpoint + 虚拟 AK/SK + path-style，标准 SigV4 签名。网关用同一对虚拟
> SK **验证**该签名，通过后才用真实 S3 凭证重签。虚拟 AK/SK 仅在网关侧有效，
> 可多租户、可审计、可单独吊销。

```
标准 S3 客户端            nginx(8443)                 authd(8081)              aws-sigv4-proxy(8080)         S3 真实端点
(虚拟 AK/SK, SigV4)  --TLS-->  限流/审计/路由  --auth_request-->  用虚拟 SK 验签   --200-->  剥旧签用真凭证重签  --HTTPS-->  S3
                              └—验签不过→403—┘
```

- **自写验签(authd)**：零依赖 **Go 静态二进制**(scratch 镜像，无 shell/无包管理器/无解释器)。nginx 通过 `auth_request` 对每个请求发子请求，authd 用客户端的**虚拟 SK** 重建规范请求并比对签名，200 放行 / 403 拒绝。aws-sigv4-proxy 只重签不验签，故验签必须自建。
- **重签核心**：`aws-sigv4-proxy`(AWS 官方, Go)，剥离客户端旧签名后用本地真实凭证重新签名转发。上游对象存储兼容 S3 SigV4，`region` 与端点对齐即可。
  - **加固**：显式 `--strip Authorization / X-Amz-Security-Token / X-Amz-Date / X-Amz-Content-Sha256 / X-Amz-Sdk-Checksum-Algorithm / X-Amz-Checksum-Mode / X-Amz-Trailer / X-Amz-Decoded-Content-Length`，清除客户端旧的虚拟签名、临时 token、签名时间、payload hash 与 SDK 流式校验尾部头，避免污染上游重签（authd 已完成验签）。上游到对象存储使用 `--unsigned-payload`，保持大对象流式转发。
  - **连接池**：当前 compose 不强行传自定义 transport flags，避免镜像版本不支持时启动失败；如升级到确认支持这些 flags 的 sigv4-proxy 版本，可再启用更高的 keep-alive 连接池参数。
  - **保持关闭的降级开关**：`--no-verify-ssl`（对上游对象存储关证书校验）、`--log-signing-process`（打印签名中间量，敏感）均**不启用**，仅排障时临时开 `--log-failed-requests`。当前明确启用 `--unsigned-payload`，用于清除客户端 payload hash 后保持大对象流式重签；上线前必须用目标 S3 实现验证兼容性。
- **为什么只验头不验体**：SigV4 对 payload 的参与仅通过 `x-amz-content-sha256` 头部的**值**（该值本身在签名集内）。故 authd 只需请求**头**即可验签，nginx 子请求 `proxy_pass_request_body off`，大对象流式转发(`proxy_request_buffering off`)不受影响（客户端大对象常发 `UNSIGNED-PAYLOAD`，authd 原值使用）。
- **真实凭证(可移植, 免固化 env)**：由 `creds` 边车(**Go 静态二进制**, `creds/` 目录, `--serve`)自动获取并**到期前自动续期**，在 `127.0.0.1:8181/credentials` 暴露 AWS container credentials 端点。`sigv4-proxy` 与 `creds` 共享 network namespace，通过 `AWS_CONTAINER_CREDENTIALS_FULL_URI` 按需获取带 `Expiration` 的临时凭证，避免 shared credentials 文件被 SDK 当成静态凭证缓存。凭证源由 `S3_CREDS_SOURCE` 选择(**云 ECS / VMware / 物理机通用**):`imds` 云实例角色 → `sts` 任意主机换临时凭证 → `static` on-prem 静态凭证直用,`auto` 依次回退。**不依赖任何云厂商专属高级功能**——IMDS 仅在支持的云主机上作为可选增强,VMware/物理机走 STS 或 static。

## 目录结构

```
s3gw/
├── docker-compose.yml        # 四服务编排：creds(凭证边车) + authd + sigv4-proxy + nginx
├── .env.example              # 配置模板(复制为 .env)
├── auth/
│   ├── authd.go               # 自写 SigV4 验签服务(零第三方依赖 Go)
│   ├── authd_test.go          # 验签回归测试(合法/重放/错SK/未知AK/过期)
│   ├── Dockerfile             # 运行时 scratch 镜像，复制交付包预编译二进制
│   ├── .dockerignore          # 收敛构建上下文(排除 keys.json/二进制产物)
│   ├── go.mod                 # module s3gw/authd (go 1.21)
│   └── keys.json              # 虚拟 AK/SK 映射(gen_keys.sh 生成，0600，目录 bind mount 热加载)
├── creds/                     # 凭证边车(Go 静态二进制, 凭证边车)
│   ├── main.go                # imds/sts/static 选源 + container credentials endpoint(零第三方依赖)
│   ├── go.mod                 # module s3gw/creds (go 1.21)
│   ├── Dockerfile             # 运行时 scratch 镜像，复制预编译二进制和 CA bundle
│   └── .dockerignore          # 收敛构建上下文
├── nginx/
│   ├── nginx.conf             # 全局：审计日志格式 / 限流 zone / 大对象流式转发
│   ├── s3gw.conf.template    # 入口模板：TLS + auth_request 验签 + Host/health 白名单
│   └── certs/                # 网关证书(gen_cert.sh 生成)
├── docs/
│   ├── deployment.md          # 参数化部署和交付包说明
│   ├── operations.md          # 长期运维和支持包说明
│   ├── testing.md             # 冒烟、吞吐、阶梯压测说明
│   └── security-waf.md        # WAF、TLS 卸载/HTTPS 回源、Host/SNI 和安全验收
└── scripts/
    ├── preflight.sh          # 部署前自检：依赖/端口/上游 S3/compose 配置
    ├── deploy.sh             # 一键部署
    ├── acceptance.sh         # 一键验收：preflight + deploy + health + smoke
    ├── ops.sh                # 长期运维：health/status/log/audit/reload/bundle
    ├── smoke_test.sh         # 端到端冒烟：标准 S3 客户端 + 虚拟 AK/SK 跑 PUT/GET/HEAD
    ├── verify_security.sh    # 安全行为验收：拦截/重放/吊销/泄露/审计/容器加固
    ├── speed_test.sh         # 单对象吞吐压测：PUT/GET/MD5
    ├── stress_test.sh        # 阶梯并发压测：local/CLB、PUT/GET、错误收集
    ├── package.sh            # 生成干净交付包
    ├── gen_cert.sh           # 自签证书(生产换内部 CA)
    ├── gen_keys.sh           # 生成客户端虚拟 AK/SK(委托 keyctl.sh,富元数据格式)
    └── keyctl.sh             # 虚拟 AK/SK 生命周期与快速吊销 CLI(bash+jq: add/list/disable/enable/expire/rm + 审计)
```

## 快速开始

```bash
cd s3gw
cp .env.example .env
# 1) 填写 .env：S3_ENDPOINT_HOST / S3_REGION / TEST_BUCKET

# 2) 真实凭证:按部署环境在 .env 设 S3_CREDS_SOURCE 选源(免把凭证固化进 env):
#    - 通用 S3 兼容对象存储: S3_CREDS_SOURCE=static,填 S3_ACCESS_KEY/S3_SECRET_KEY。
#    - Volcengine 可选: S3_CREDS_SOURCE=imds 或 sts,按附录填写 VOLC_* 参数。
#    可先本地自测取一次凭证(默认打印 credential_process JSON):
#        S3_CREDS_SOURCE=static S3_ACCESS_KEY=... S3_SECRET_KEY=... docker run --rm -e S3_CREDS_SOURCE -e S3_ACCESS_KEY -e S3_SECRET_KEY s3gw-creds:go

# 3) 生成客户端虚拟 AK/SK(写入 auth/keys.json,富元数据格式)
./scripts/gen_keys.sh
#   记下打印的 AK/SK，填入 .env 的 TEST_VIRT_AK / TEST_VIRT_SK(供冒烟测试用)

# 4) 部署(自动生成证书、拉起容器)
./scripts/deploy.sh

# 5) 冒烟测试(标准 S3 客户端, 无需任何额外参数)
./scripts/smoke_test.sh
```

## 客户现场一键交付流程

详细说明见 `docs/deployment.md`、`docs/operations.md`、`docs/testing.md` 和
`docs/security-waf.md`。生产前置 WAF/CLB 时，必须先阅读 `docs/security-waf.md`。

客户现场推荐按以下顺序执行，所有命令都在 `s3gw/` 目录下运行：

```bash
# 0) 首次上机缺 Docker/Compose 时先初始化宿主
sudo bash scripts/init_host.sh

# 1) 参数化生成 .env 和虚拟客户端 AK/SK
./scripts/configure.sh \
  S3_REGION=<region> \
  S3_ENDPOINT_HOST=<s3-endpoint-host> \
  S3_BUCKET_HOST=<bucket>.<s3-endpoint-host> \
  S3_ACCESS_KEY=<real-ak> \
  S3_SECRET_KEY=<real-sk> \
  TEST_BUCKET=<bucket> \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=443 \
  GW_SERVER_NAMES="s3gw.example.com" \
  HEALTH_ALLOW_DIRECTIVES="allow <waf-cidr>; allow <clb-health-cidr>; allow 127.0.0.1; deny all;"

# 2) 一键部署并完成基础验收
./scripts/acceptance.sh

# 3) 安全行为验收（使用专用 TEST_VIRT_AK）
./scripts/verify_security.sh

# 4) 快速吞吐验证
SIZE_MB=64 ./scripts/speed_test.sh

# 5) 阶梯压测到平台期/失败边界
SIZE_MB=64 CONCURRENCY_LIST="1 2 4 8 16 32" ./scripts/stress_test.sh
```

也可以直接把参数传给 `acceptance.sh`，一条命令完成配置、部署、健康检查和冒烟测试：

```bash
./scripts/acceptance.sh \
  S3_REGION=<region> \
  S3_ENDPOINT_HOST=<s3-endpoint-host> \
  S3_BUCKET_HOST=<bucket>.<s3-endpoint-host> \
  S3_ACCESS_KEY=<real-ak> \
  S3_SECRET_KEY=<real-sk> \
  TEST_BUCKET=<bucket> \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=443 \
  GW_SERVER_NAMES="s3gw.example.com"
```

如果不想把真实 AK/SK 放进 shell history，可用环境变量传敏感值：

```bash
export S3_ACCESS_KEY=<real-ak>
export S3_SECRET_KEY=<real-sk>
./scripts/acceptance.sh S3_REGION=<region> S3_ENDPOINT_HOST=<host> S3_BUCKET_HOST=<bucket-host> TEST_BUCKET=<bucket>
```

本交付包已经内置 Linux amd64 运行时二进制，客户机器不需要安装 Go，也不需要现场拉 Go builder 镜像。`scripts/init_host.sh` 会初始化 Docker/Compose，并补装 `aws-cli` 以支持一键验收和压测。

作为 CLB 后端时，`.env` 至少需要：

```bash
GW_BIND_ADDR=0.0.0.0
GW_LISTEN_PORT=443
GW_SERVER_NAMES=s3gw.example.com
HEALTH_ALLOW_DIRECTIVES='allow <waf-cidr>; allow <clb-health-cidr>; allow 127.0.0.1; deny all;'
S3_ENDPOINT_HOST=<s3-endpoint-host>
S3_BUCKET_HOST=<bucket>.<s3-endpoint-host>
```

`preflight.sh` 会检查依赖、端口占用、上游 S3 endpoint 解析、S3 443 连通、compose 语法和关键配置项。`acceptance.sh` 会串起部署和冒烟，适合作为交付验收命令。

生产暴露时必须显式配置 `GW_SERVER_NAMES` 和 `HEALTH_ALLOW_DIRECTIVES`。未知 Host 会被默认 server 关闭；`/healthz` 默认只允许本机和常见内网网段访问。如果需要用 CLB IP 直接测试，请临时把该 IP 加入 `GW_SERVER_NAMES`。

WAF 可以终止客户端 TLS，但推荐 WAF 到网关仍使用 HTTPS 443。TLS 卸载本身不会破坏 SigV4；WAF/CLB 必须保留客户端签名时的 HTTP `Host`、method、path、query、`Authorization` 和 `x-amz-*` 签名头。外网域名和内网回源地址可以不同，但回源 HTTP Host 不能被改成后端 IP。完整配置和验收要求见 `docs/security-waf.md`。

## 长期运维入口

```bash
./scripts/ops.sh health      # 网关和组件健康
./scripts/ops.sh status      # compose 状态和端口监听
./scripts/ops.sh logs        # 服务日志
./scripts/ops.sh audit       # nginx JSON 审计日志
./scripts/ops.sh reload      # SIGHUP authd 热加载 auth/keys.json
./scripts/ops.sh doctor      # 常用诊断汇总
./scripts/ops.sh bundle      # 生成 support/*.tgz 支持包
```

虚拟 AK/SK 生命周期：

```bash
./scripts/keyctl.sh add --owner team-a --note "client-a" --expires 2026-12-31T23:59:59Z --reload
./scripts/keyctl.sh disable AKxxxxx --note "leaked" --reload
./scripts/keyctl.sh list
```

常见长期运维问题和工具覆盖：

| 用户问题 | 工具入口 |
|---|---|
| 机器能不能部署 | `scripts/preflight.sh` |
| 一键部署是否成功 | `scripts/acceptance.sh` |
| 服务是否健康 | `scripts/ops.sh health/status` |
| 谁在访问、状态码是什么 | `scripts/ops.sh audit` |
| 客户端密钥泄露 | `scripts/keyctl.sh disable ... --reload` |
| 真实凭证过期/取不到 | `scripts/ops.sh logs` 查看 `creds` |
| 上游对象存储 403/502/SignatureDoesNotMatch | `scripts/ops.sh audit/logs` 联合定位 |
| 压测容量和失败边界 | `scripts/speed_test.sh` / `scripts/stress_test.sh` |
| 需要给支持同学排查 | `scripts/ops.sh bundle` |
| 生成干净交付包 | `scripts/package.sh` |

## 当前从零交付验证结果

在一台重装后的 Alibaba Cloud Linux 4 ECS 上完成从零验证：机器初始无 Docker、Compose、aws-cli。执行 `scripts/init_host.sh` 后完成依赖初始化，再通过参数化 `acceptance.sh` 完成配置、部署、健康检查和冒烟。

验证命令形态：

```bash
export S3_ACCESS_KEY=<real-ak>
export S3_SECRET_KEY=<real-sk>

./scripts/acceptance.sh \
  S3_REGION=cn-beijing \
  S3_ENDPOINT_HOST=tos-s3-cn-beijing.ivolces.com \
  S3_BUCKET_HOST=private-proxy.tos-s3-cn-beijing.ivolces.com \
  TEST_BUCKET=private-proxy \
  GW_BIND_ADDR=0.0.0.0 \
  GW_LISTEN_PORT=443 \
  TEST_KEY=s3gw-clean-acceptance.txt \
  TEST_REQUIRE_DELETE=0
```

验收结果：

```text
configure passed
preflight PASS=21 WARN=0 FAIL=0
deploy passed
health passed
smoke PASS=7 WARN=0 FAIL=0
acceptance passed
```

部署后状态：

```text
authd healthy
creds healthy
nginx healthy, 0.0.0.0:8443->8443
sigv4-proxy running
```

2026-07-28 的最终回归结果：预检 `21/0/0`，冒烟 `7/0/0`，公网串行功能 `10/10`，安全行为 `23/0/0`。公网功能覆盖空对象、中文/空格/百分号对象键、Metadata、Range、CopyObject、Multipart 和清理；重复执行一键部署后再次全部通过。最终四个容器 restart=0、OOM=0、错误日志=0，测试对象残留=0。公网 `/healthz` 返回 403，未知 Host 直接关闭连接，均符合入口策略。

2026-07-29 又在重装后的 CentOS Stream 9 Volcengine ECS 上使用 TOS `cn-beijing` 内网 S3 endpoint 完成同一流程：`init_host.sh` 从零安装 Docker 29.6.2、Compose 5.3.1 和 AWS CLI 2.36.9；一键验收冒烟 `7/0/0`，公网 IP 串行功能 `10/10`，安全行为 `23/0/0`，重复部署后冒烟再次 `7/0/0`。最终容器 restart=0、OOM=0、错误日志=0、审计 JSON 无无效行、测试对象残留=0；公网健康检查和匿名 S3 请求均为 403，未知 Host 关闭连接。本轮没有执行性能测试。

同一台 4 vCPU / 7.3 GiB 主机的既有容量验证中，64 MiB 对象并发 1–16 的 PUT/GET 全部成功；并发 32 时 31/32 个 PUT 成功且 4 GiB proxy 发生两次 memcg OOM。默认阶梯因此止于 16，更高并发需限流或横向扩容。本轮公网功能回归按要求没有执行性能测试。

客户端（任意标准 S3 SDK）配置示例——零代码改造：

```python
import boto3
s3 = boto3.client(
    "s3",
    endpoint_url="https://网关地址:8443",
    aws_access_key_id="<虚拟AK>",
    aws_secret_access_key="<虚拟SK>",
    region_name="cn-beijing",
    config=boto3.session.Config(s3={"addressing_style": "path"}),
    verify=False,  # 自签证书阶段；生产换内部 CA 后去掉
)
s3.put_object(Bucket="my-bucket", Key="a.txt", Body=b"hello")
```

## 关键设计说明

| 主题 | 说明 |
|---|---|
| 客户端零改造 | 客户端就是标准 S3 客户端，用虚拟 AK/SK 做标准 SigV4。Basic Auth 不属于 S3 协议(SDK 的 SigV4 已占用 Authorization 头)，故改用“验虚拟签名”方案。 |
| 为什么自写 authd | aws-sigv4-proxy 只能重签、不能验签。要让虚拟 AK/SK 真正生效(非法签名拒绝)，必须自建一层 SigV4 验签。 |
| 验签不破坏流式 | 仅用请求头验签(auth_request + proxy_pass_request_body off)，大对象流式上传/下载不受影响。 |
| 域名是否必须一致 | 客户端网关域名与上游对象存储域名天然解耦；生产前置 WAF 时推荐使用客户业务域名。外网域名与内网回源地址可不同，但 WAF 回源 HTTP Host 必须保持客户端签名使用的域名，详见 `docs/security-waf.md`。 |
| 凭证双层隔离 | 客户端只持有虚拟 AK/SK(仅网关侧有效)；真实 S3 凭证只存在于 creds/​sigv4-proxy 侧的内存共享卷。单个虚拟密钥泄露不影响真实凭证,可用 `scripts/keyctl.sh disable <AK> --reload` **秒级单独吊销**(见下)。 |
| 凭证自动续期 | `creds` 边车(Go 二进制 `--serve`)在到期前 `--refresh-margin`(默 300s)刷新缓存，并通过本机 AWS container credentials endpoint 向 sigv4-proxy 返回带 `Expiration` 的凭证；sigv4-proxy 按 provider 语义刷新，避免 shared credentials 静态缓存。 |
| 大对象 | nginx 关闭请求体缓冲(proxy_request_buffering off)流式转发；超时放宽到 300s。 |
| path-style vs virtual-host | 默认 path-style(/<bucket>/<key>)，对无自定义域名场景最稳。 |
| 审计 | nginx 以 JSON 记录调用方 IP、**验签通过的 access_key**、方法、对象 key、状态、耗时到 s3audit.log。 |

## authd 验签具体做什么

1. 解析 `Authorization: AWS4-HMAC-SHA256 Credential=<AK>/<date>/<region>/<service>/aws4_request, SignedHeaders=..., Signature=...`。
2. 校验 credential scope 的 region/service；AK 不在 keys.json → 403；时钟偏差超 `AUTHD_MAX_SKEW`(默 300s) → 403。
3. 按 `SignedHeaders` 从 nginx 透传的原始请求头动态取值，重建规范请求(payload_hash 取 `x-amz-content-sha256` 头值，缺失则 `UNSIGNED-PAYLOAD`)。
4. 用虚拟 SK 推导签名密钥(kDate=HMAC("AWS4"+SK,date)→kRegion→kService=s3→kSigning="aws4_request")，HMAC 后用 `hmac.Equal` **常量时间比对**客户端签名。
5. 匹配 → 200 + 响应头 `X-Access-Key`(供 nginx 审计)；不匹配 → 403。

6. **额外硬化**(Go 版新增)：`x-amz-date` 前缀须与 credential 的 date 一致;SignedHeaders 须全小写、去重、严格升序;`host` 必须在签名头集内。**写操作(PUT/POST/DELETE/PATCH)默认启用一次性 signature 重放缓存**(`AUTHD_REPLAY_WRITES=1`)：因 authd 只验头不验 body、上游又用 `--unsigned-payload`,同一条合法写签名在偏差窗口内可被改包重放覆盖对象,故对写请求强制单次生效;读操作(GET/HEAD)默认不入缓存,避免误拒 SDK 重试与重复读。若确需对全部方法启用可另开 `AUTHD_REPLAY_CACHE=1`。

环境变量：`AUTHD_LISTEN`(0.0.0.0:8081)、`AUTHD_KEYS_FILE`(容器内 `/run/auth/keys.json`)、`AUTHD_REGION`(cn-beijing)、`AUTHD_SERVICE`(s3)、`AUTHD_MAX_SKEW`(默 300s)、`AUTHD_REPLAY_WRITES`(默认 1；写方法一次性 signature 重放防护,设 0 关闭)、`AUTHD_REPLAY_CACHE`(默认 0；设 1 对**所有**方法开启一次性 signature 重放缓存)。

构建 / 测试(本地)：
```bash
cd auth
go test ./...                                  # 验签回归
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o authd .   # 零依赖静态二进制
```
客户交付包预置 Linux amd64 静态二进制；compose 只构建 runtime-only scratch 镜像。若源码目录缺少预编译二进制，`deploy.sh` 仅在本机已安装 Go 时回退构建。

运维能力：
- **健康探针**:内建 `GET /healthz`(无鉴权,返回 200 `ok`)。scratch 无 shell/wget,故容器 healthcheck 用二进制自身探针 `["/authd","-health"]`(向本机 /healthz 发一次 GET,200→exit 0,否则 exit 1);nginx 的 `depends_on` 已设 `condition: service_healthy`,等 authd 就绪再启动。
- **密钥热重载**:向 authd 发 `SIGHUP` 即重新加载 keys(`docker-compose kill -s HUP authd`),无需重启即可吊销/新增虚拟 AK/SK,在途连接不中断。

## 生产加固清单

1. **密钥管理**：`auth/keys.json` 经目录 bind mount 只读挂入容器(`/run/auth/keys.json`)，宿主文件保持 owner=65534 且 0600。虚拟密钥采用富元数据格式(owner/enabled/expires),用 `scripts/keyctl.sh` 管理生命周期并保留审计(`auth/keys_audit.log`),`--reload` 触发 SIGHUP 热重载做到**不重启秒级吊销**。生产可进一步接 KMS/密钥管理后端。
2. **证书**：换成内部 CA 签发，客户端去掉 verify=False / -k。
3. **真实凭证最小权限**：实例角色 / STS 角色 / 静态凭证只授权目标桶的必要动作(GetObject/PutObject/...)。云上优先 `imds`(本机零长期凭证);VMware/物理机优先 `sts`(长期 AK/SK 仅换 STS、不进运行态);`static` 仅用于确无 STS 能力的最简场景。
4. **网络**：authd 与 sigv4-proxy 仅 expose 不 ports，只允许 nginx 访问；网关入口按需加白名单/安全组。
5. **可观测**：审计日志接入日志平台；为 5xx / 上游耗时 / 403 验签失败率配告警。

## 互联网暴露安全基线

> 网关默认**仅绑回环地址**(`127.0.0.1:8443`),不直接对公网开放。若确需公网暴露,先落实以下基线,再逐步放开。

### 已内置的边缘加固(开箱即用)

| 项 | 位置 | 作用 |
|---|---|---|
| 隐藏版本指纹 | `nginx.conf` `server_tokens off` | 不回显 nginx 版本,降低指纹化探测价值。 |
| 抗慢速攻击 | `nginx.conf` `client_header_timeout 10s` / `client_body_timeout 30s` / `send_timeout 30s` | 限制握手与收发阶段的最长停顿,压制 Slowloris / slow-body 连接耗尽。 |
| 请求体上限 | `nginx.conf` `client_max_body_size 5g` | 单请求体封顶,防超大 body 耗尽资源(分片上传不受此单请求限制)。 |
| TLS 收紧 | `s3gw.conf.template` 仅 `TLSv1.2/1.3` + ECDHE-only 前向保密套件 + `ssl_prefer_server_ciphers on` + `ssl_session_tickets off` | 关闭弱协议/弱算法,强制前向保密;关闭会话票据(session ticket),避免票据密钥长期不轮换削弱前向保密。 |
| HSTS | `s3gw.conf.template` `Strict-Transport-Security max-age=31536000; includeSubDomains` | 强制客户端后续走 HTTPS,防 SSL Strip 降级。 |
| 边缘限流兜底 | `s3gw.conf.template` `limit_req`(10r/s+burst20)/ `limit_conn`(64) | 单 IP 请求速率与并发连接兜底。 |
| 未验签先限流 | nginx 阶段序:`limit_req`(PREACCESS)先于 `auth_request`(ACCESS) | 未认证洪泛在触达 authd 的 HMAC 计算前即被限流,降低验签层被打爆的风险。 |
| 供应链固化 | `docker-compose.yml` nginx / sigv4-proxy 镜像**钉 `@sha256:` digest** | 防 `latest` 标签漂移与镜像投毒;升级时同步更新 digest。 |
| 最小权限运行 | 全服务 `read_only` + `cap_drop: ALL` + `no-new-privileges`;nginx 用 `nginx-unprivileged`(UID 101 非 root)监听 8443 高位端口,无需任何 `cap_add`;nginx 的 tmpfs(`/var/cache/nginx` 等)与 `nginx-logs` 卷均按 UID 101 初始化(见 `deploy.sh`) | 容器逃逸/提权面收敛;nginx master/worker 全程非 root,不再需要 CHOWN/SETUID/SETGID/NET_BIND_SERVICE 能力;真实凭证仅在 tmpfs 内存卷。 |
| 内部服务不外露 | authd / sigv4-proxy / creds 仅 `expose` 不 `ports` | 仅 nginx 可访问,不进入宿主端口空间。 |
| Host 白名单 | 默认 server 关闭未知 Host；业务 server 使用 `GW_SERVER_NAMES` | 降低公网泛域名扫描和误配置入口风险。 |
| healthz 白名单 | `HEALTH_ALLOW_DIRECTIVES` 控制 `/healthz` 来源 | 避免公网随意探测实例存活；CLB 源网段需显式加入。 |
| query 脱敏 | 审计日志不记录完整 query，仅记录 `has_query` | 降低预签名参数或业务查询泄露风险。 |
| 资源上限 | `SIGV4_PROXY_MEM_LIMIT` 默认 4g，nginx nofile 提升到 65535 | 限制大对象高并发导致的宿主 OOM 半径，提高连接容量上限。 |
| OCSP stapling(可选) | `s3gw.conf.template` 注释脚手架 | 证书链含 CA 时开启,减少客户端吊销查询往返(自签证书可留关闭)。 |

### 公网暴露前必须由你决策的两项(本仓库只给接入点,不替你选型)

1. **证书身份(替换自签证书)** — 当前 `gen_cert.sh` 生成自签证书,客户端需 `verify=False`(存在中间人风险)。
   - 生产替换为**内部 CA 或公网 CA 签发**的证书,替换 `nginx/certs/server.crt` / `server.key`;因 nginx 已切到 `nginx-unprivileged`(UID 101),私钥需 UID 101 可读——`gen_cert.sh` 已将 `server.key` 置为 `0640` 且 `chown 101:101`(chown 失败时回退 `0644` 并告警);替换证书后请保持同样的属主/权限。
   - 客户端去掉 `verify=False` / `-k`,恢复证书校验;
   - 如需**双向认证(mTLS)**,在 `s3gw.conf.template` 的 `server{}` 内加 `ssl_client_certificate /etc/nginx/certs/ca.crt;` + `ssl_verify_client on;`(接入点已预留,按你的 CA 体系启用)。

2. **前置 WAF / CLB(全局限流 + IP 信誉)** — nginx 的 `limit_req/limit_conn` 是**单 IP 单实例兜底**,无法做全局限流、IP 信誉、Bot 防护与 L3/4 DDoS 清洗。
   - 公网暴露务必前置 **CLB + WAF**:WAF 做 TLS 终止、全局速率限制、IP 黑白名单/信誉库和 Bot/爬虫防护；WAF/CLB 到网关推荐继续使用 HTTPS 443 并校验后端证书，完整要求见 `docs/security-waf.md`;
   - 网关端口保持仅绑回环或仅对 CLB 后端网段开放,**切勿把 `ports` 改成 `0.0.0.0` 直连公网**(`docker-compose.yml` 已在 nginx `ports` 处标注);
   - 多实例部署时注意:写操作重放缓存(`AUTHD_REPLAY_WRITES`)为**进程内内存缓存**,跨实例不共享。单条写签名在偏差窗口(`AUTHD_MAX_SKEW`,默 300s)内只能命中它落到的那个实例;若同一签名被 LB 分发到不同实例仍可能各生效一次。要做到严格跨实例一次性(或引入显式 nonce),需外置共享缓存(如 Redis)。生产建议在 LB 层对写路径开启源 IP/连接粘滞或直接前置 Redis 共享。

> 落实以上两项后,再按灰度逐步放开公网入口,并为 5xx / 403 验签失败率 / 上游耗时配置告警。


### 附录: Volcengine TOS 桶策略只放行网关来源(供应商特定)

网关在应用层完成"验签 + 重签",但**桶策略是最后一道兜底**:即使真实凭证泄露,也应保证只有从网关出口 IP 发起的请求才能碰到桶。这里给出经Volcengine官方文档校对的**正确写法**,以及一个常见的**错误写法**警示。

**关键校对点(踩坑高发区):**

- **源 IP 条件键是全局键 `volc:SourceIp`,不是 `tos:SourceIp`**。Volcengine的 IP 条件键统一走 `volc:` 前缀([条件(Condition)](https://www.volcengine.com/docs/6257/1134320))。写成 `tos:SourceIp` 后请求上下文里根本没有该键,`IpAddress`/`NotIpAddress` 匹配行为不可预期(Allow 可能永不命中,Deny 可能命中所有人)。
- **慎用 `Effect:Deny + Principal:"*" + NotIpAddress` 的兜底 Deny**。官方鉴权规则:**任意显式 Deny 覆盖显式 Allow,请求直接被拒**([TOS 鉴权说明](https://www.volcengine.com/docs/6349/1183370))。控制台/跨区运维/临时排障的出口 IP 往往不在你的 ECS 网段里,一旦条件键又写错,极易变成"拒绝一切"把自己锁死。
- **默认即隐式拒绝**:官方明确"除根账户外,所有请求默认隐式拒绝"([TOS 鉴权说明](https://www.volcengine.com/docs/6349/1183370))。因此**单条 Allow(带 IP 条件)就已实现"只允许网关来源"**,无需再叠显式 Deny。
- **TRN 与操作粒度**:对象级操作(`GetObject`/`PutObject`)Resource 写 `trn:tos:::<bucket>/*`;若客户端还需列举文件,额外加桶级 `tos:ListBucket`,其 Resource 写 `trn:tos:::<bucket>`(不带 `/*`)([资源(Resource)](https://www.volcengine.com/docs/6257/1134319))。

**推荐写法(单条 Allow,靠隐式拒绝兜底,不会误伤运维):**

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AccountId": ["<调用方账号/AK 主体>"]},
      "Action": ["tos:GetObject", "tos:PutObject"],
      "Resource": ["trn:tos:::<bucket-name>/*"],
      "Condition": {
        "IpAddress": {"volc:SourceIp": ["<ECS/VPC 出口 IP 段>"]}
      }
    }
  ]
}
```

**错误写法(务必避免):**

```jsonc
{
  "Condition": {
    "IpAddress": {"tos:SourceIp": ["..."]}
  }
}
```

- `tos:SourceIp` 是无效条件键,应为 `volc:SourceIp`;
- 叠加 `Effect:Deny + Principal:"*" + NotIpAddress` 的兜底 Deny —— 易锁死自己。

> WARN: 如确需保留兜底 Deny(仅在**完全确认白名单网段已覆盖所有合法来源含控制台运维出口**时):把键改为 `volc:SourceIp`,并**先在控制台确认能改回策略**或预留 root/运维账号例外,避免锁死后无法自救。
> `Principal` 的具体格式(`{"AccountId":[...]}` 或 `trn:iam::<账号ID>:user/<用户名>` TRN 字符串)以控制台 JSON 编辑器保存不报错为准,建议贴入验证一次。

## 凭证代理(creds/, Go 静态二进制)—— 跨云/本地可移植,不依赖云厂商专属功能

生产标准要求 **运行态不持有固化的长期 AK/SK**。`creds` 边车运行 Go 二进制 `--serve`,
由 `S3_CREDS_SOURCE` 选源取真实 S3 凭证并通过 AWS container credentials 端点**到期前自动续期**。三种源覆盖所有部署形态:

1. **`imds` 实例角色(仅支持元数据服务的云主机,如Volcengine ECS)**:绑定实例 IAM 角色后,边车经元数据服务
   `http://100.96.0.96/latest/iam/security_credentials/<role>` 取自动轮转的临时凭证。
   支持 IMDSv2(先 PUT 取 token 再带 token GET)与 v1;`VOLC_IMDS_ROLE` 留空则自动列举。
   **本机零长期凭证**。⚠ VMware/物理机无此端点,勿选 imds。
2. **`sts` AssumeRole(任意主机通用,推荐 on-prem 首选)**:VMware/物理机/任意有网主机,
   用长期 AK/SK(仅换 STS、不进运行态)经 Volc V4 签名调用 `sts.volcengineapi.com` 换临时凭证并自动续期。
3. **`static` 静态凭证直用(最简 on-prem)**:客户只提供一把桶 AK/SK 且无 STS 能力时,
   填 `S3_ACCESS_KEY`/`S3_SECRET_KEY`(可选 `S3_SESSION_TOKEN`)直接使用。边车会为静态凭证响应补一个滚动 `Expiration`,让 SDK provider 能按期刷新。

`auto`(默认)按 imds→sts→static 顺序回退,适配云/非云混合;
**通用 S3 兼容对象存储建议显式设 `S3_CREDS_SOURCE=static`,跳过供应商特定的 IMDS/STS 探测。**

客户交付包预置 `creds-linux-amd64` 和 CA bundle，compose 构建的 `s3gw-creds:go`
是 runtime-only scratch 镜像(仅一个静态二进制 + CA 证书),以非 root(65534) 运行。本地调试可直接
`cd creds && CGO_ENABLED=0 go build -o creds .` 后运行,支持三种输出形态:

```bash
# (a) 默认:打印 credential_process 规范 JSON(供 AWS SDK/CLI 的 credential_process 消费)
./creds

# (b) 原子写入 AWS shared credentials 文件([default] 段, 0600)
./creds --write-shared /run/creds/credentials --profile default

# (c) compose 默认:启动 AWS container credentials endpoint,返回带 Expiration 的凭证,
#     sigv4-proxy 通过 AWS_CONTAINER_CREDENTIALS_FULL_URI 按 provider 语义刷新
./creds --serve --listen 127.0.0.1:8181 --refresh-margin 300
```

零三方依赖(仅 Go 标准库),编译为单个静态二进制,可直接塞进任意容器/主机/定时任务。compose 中 `sigv4-proxy` 与 `creds` 共享 network namespace,凭证端点只监听 `127.0.0.1`,不对其他容器或宿主暴露。

## 快速吊销虚拟 AK/SK(keyctl.sh)

虚拟密钥采用富元数据格式,`enabled=false` 或 `expires` 过期即被 authd 立即拒绝(等价吊销)。
`scripts/keyctl.sh`(bash+jq)改本地 keys.json 并可 `--reload` 触发 authd 热加载,**秒级生效、免重启、留审计**:

```bash
# 新增(随机或指定 AK/SK,可带归属/备注/过期)
./scripts/keyctl.sh add --owner team-a --note "client-a" --expires 2026-12-31T23:59:59Z

# 列出所有密钥及状态(ACTIVE / DISABLED / EXPIRED)
./scripts/keyctl.sh list

# 【快速吊销】禁用某把密钥并立即热加载生效
./scripts/keyctl.sh disable AK<xxxxx> --note "疑似泄露" --reload

# 恢复启用 / 设定到期(N 秒后或绝对时刻) / 彻底删除
./scripts/keyctl.sh enable  AK<xxxxx> --reload
./scripts/keyctl.sh expire  AK<xxxxx> --in 3600 --reload
./scripts/keyctl.sh rm      AK<xxxxx> --reload
```

所有写操作追加到 `auth/keys_audit.log`(时间/动作/AK/详情)。吊销优先用 `disable`(保留条目与审计),
而非 `rm`。`--reload` 底层优先执行 `docker compose kill -s HUP authd`,在途连接不中断。

## 常见问题

- **403(网关返回)**：虚拟签名验证未通过。检查客户端 region 与 AUTHD_REGION 是否一致、系统时钟是否同步(SigV4 对时钟敏感)、AK 是否在 keys.json。
- **403 SignatureDoesNotMatch(上游返回)**：真实凭证/S3_REGION 与端点不一致。
- **502/504**：确认 S3_ENDPOINT_HOST 在网关所在网络可解析可达(如使用内网端点需在对应 VPC 内)。
- **大文件失败**：确认 proxy_request_buffering off 生效、超时足够；必要时客户端改用分段上传(Multipart)。
