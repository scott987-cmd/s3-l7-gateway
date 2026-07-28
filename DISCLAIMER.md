# 免责声明 / Disclaimer

简体中文 | [English](#disclaimer-english)

## 免责声明

**按「现状」提供。** 本项目及其全部文档按「现状」（AS IS）提供，不附带任何明示或默示的担保，包括但不限于对适销性、特定用途适用性与非侵权的担保。在适用法律允许的最大范围内，作者与贡献者不对因使用或无法使用本项目而产生的任何直接、间接、偶然、特殊、惩罚性或后果性损失承担责任，包括但不限于业务中断、数据丢失与收入损失。完整条款以 [LICENSE](LICENSE)（Apache-2.0）为准；本文件与 LICENSE 不一致时，以 LICENSE 为准。

**性能数据不构成承诺。** 文档中出现的吞吐、巡检与验证结果，来自特定环境下的一次实测——特定的实例规格、网络条件与对象存储组合——仅用于说明方案可行性。这些数字**不代表**你的环境能够达到的性能，也**不构成**任何形式的性能承诺、容量保证或服务等级协议。任何容量结论都必须以你自己环境中的压测为准。

**会修改系统状态。** 部署脚本会安装 Docker、Compose 与 aws-cli，生成证书与虚拟密钥，并以容器方式占用宿主监听端口。请先在非生产环境完整演练，确认你具备相应的变更授权，并准备好回滚方案。真实上游凭证只应通过环境变量或秘密管理系统传入，不要写入交付包或提交到仓库。

**上线前必须自行验证。** 上游兼容性以标准 S3 SigV4 为前提，不代表所有对象存储的实现细节一致。正式承载业务前，必须使用你自己的 SDK/CLI 完成 PUT、GET、HEAD、Multipart 与数据完整性验证，并按自身对象大小与并发完成阶梯压测。

**安全与合规由使用者负责。** 你需要自行评估该架构是否满足你所处行业与地区的安全、合规、数据保护及跨境数据传输要求。文档中的安全建议属于通用工程实践，**不构成法律、合规或审计意见**。涉及个人信息或受监管数据时，请咨询你的法务与合规团队。

**第三方项目，无厂商隶属关系。** 本项目是由个人开发者独立开发与维护的第三方开源项目。它**不是**任何云服务商、对象存储厂商、负载均衡或 WAF 产品提供方或 SaaS 厂商的官方产品、官方参考架构、官方文档或官方支持内容，也未获得上述任何一方的授权、认证、赞助或背书。文档中出现的产品名称、服务名称与商标（包括但不限于各家对象存储与云平台的名称）归各自所有者所有，出现在此仅用于说明数据面兼容性与配置格式。某一厂商被列为「已验证」，仅表示作者恰好在该环境中做过实测，不代表与该厂商存在任何合作或认可关系。

**无支持义务。** 本项目按开源方式发布，不附带任何支持、维护或更新义务，也不保证缺陷会被修复。

---

<a id="disclaimer-english"></a>

## Disclaimer (English)

[简体中文](#免责声明) | English

**Provided as is.** This project and all of its documentation are provided "AS IS", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and non-infringement. To the maximum extent permitted by applicable law, the authors and contributors shall not be liable for any direct, indirect, incidental, special, exemplary or consequential damages arising from the use of or inability to use this project, including business interruption, data loss and loss of revenue. The governing terms are in [LICENSE](LICENSE) (Apache-2.0); where this file and the LICENSE differ, the LICENSE controls.

**Performance figures are not a commitment.** The throughput, inspection and verification results in this documentation come from a single measurement in one specific environment — a particular instance size, network path and object storage combination — and serve only to show that the design works. They do **not** represent what your environment will achieve and do **not** constitute a performance commitment, capacity guarantee or service level agreement. Any capacity conclusion must come from load testing in your own environment.

**It changes system state.** The deployment scripts install Docker, Compose and aws-cli, generate certificates and virtual keys, and bind host listener ports through containers. Rehearse in a non-production environment first, confirm you hold the necessary change authorisation, and have a rollback plan. Real upstream credentials must be supplied through environment variables or a secret manager — never written into a delivery archive or committed to the repository.

**Validate before you go live.** Upstream compatibility assumes standard S3 SigV4 and does not imply that every object storage implementation behaves identically. Before carrying production traffic, complete PUT, GET, HEAD, multipart and integrity verification with your own SDK or CLI, and run a staged load test at your own object sizes and concurrency.

**Security and compliance are your responsibility.** You are responsible for assessing whether this architecture meets the security, compliance, data-protection and cross-border data transfer requirements of your industry and jurisdiction. The security guidance in this documentation is general engineering practice and does **not** constitute legal, compliance or audit advice. Where personal or regulated data is involved, consult your own legal and compliance teams.

**Third-party project, no vendor affiliation.** This is a third-party open-source project developed and maintained by an individual. It is **not** an official product, reference architecture, documentation set or supported offering of any cloud provider, object storage vendor, load balancer or WAF product or SaaS vendor, and it is not authorised, certified, sponsored or endorsed by any of them. Product names, service names and trademarks in this documentation belong to their respective owners and appear only to describe data-plane compatibility and configuration formats. A vendor listed as "verified" means only that the author happened to test in that environment; it implies no partnership or approval.

**No support obligation.** This project is released as open source with no obligation of support, maintenance or updates, and no guarantee that defects will be fixed.
