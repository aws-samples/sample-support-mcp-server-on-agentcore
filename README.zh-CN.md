# 在 Amazon Bedrock AgentCore 上托管 AWS Support MCP Server

[English](README.md) | **简体中文**

> 英文版为权威版本，两者不一致时以 [README.md](README.md) 为准。

直接在 [Kiro](https://kiro.dev) 里创建、跟踪、回复 AWS Support 工单，**不需要给开发者发放 IAM 凭证，也不需要开放 AWS 管理控制台**。

Enterprise Support 是账号级权益，但提单通常要有控制台权限或带 `support:*` 权限的 IAM 凭证，多数开发者两样都没有。本示例把开源的 [AWS Support MCP Server](https://github.com/awslabs/mcp/tree/main/src/aws-support-mcp-server) 托管在 **Amazon Bedrock AgentCore Runtime** 上，通过 **AgentCore Gateway** 校验企业身份提供商（Okta、Microsoft Entra ID 等）签发的令牌——或者经模板创建的 Amazon Cognito 用户池校验 **AWS IAM Identity Center** 的登录——把 Support API 权限只放在**一个由平台团队掌控的 IAM 执行角色**上。一个 CloudFormation 模板部署到你自己的 AWS 账号。

![架构图](docs/architecture.png)

## 工作原理

1. Kiro 连接 Gateway 地址；首次使用时开发者在浏览器里向企业 IdP 登录（OAuth 2.0 授权码 + PKCE，公开客户端，开发者机器上没有 secret）。
2. 每个 MCP 请求带着拿到的 JWT。Gateway 校验它（`CUSTOM_JWT` 授权器），再用自己的 IAM 角色（SigV4）把调用转给 Runtime。
3. Runtime 托管 vendored 的 `awslabs.aws-support-mcp-server`（只改了一行日志，见 [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES)），前面只有约 30 行的 streamable-HTTP 入口（[`app/main.py`](app/main.py)）。
4. Runtime 的**执行角色**是唯一拥有 Support API 权限的主体。工单在 Support Center 里和其他工单一样可见。

Kiro 自身的登录不动；Kiro 产品 bug 仍走 Kiro 内置的 **Report Issue** 渠道。本示例针对需要走你的 AWS Support 计划的工单。

## 面向 IT / 平台团队 — 四步部署

| 步骤 | 做什么 | 详情 |
|---|---|---|
| 1 | 选一种身份模式并配置：IdP 里的 OIDC **公开**客户端（PKCE、无 secret、回调 `http://localhost:<port>/oauth/callback`），**或**在 IAM Identity Center（组织实例）里建一个 SAML 2.0 应用、经模板的 Cognito 用户池联邦，**或**用独立的 Cognito 用户做试点 | [身份模式](docs/zh-CN/deployment-guide.md#选择身份模式) · [第 1 步](docs/zh-CN/deployment-guide.md#第-1-步--配置身份提供商) |
| 2 | `./build.sh` — 用 `uv` 构建 Linux arm64 代码包（不需要 Docker） | [第 2 步](docs/zh-CN/deployment-guide.md#第-2-步--构建代码包) |
| 3 | `./deploy.sh` 传入 IdP discovery URL / client ID（上传代码包并创建堆栈，约 2 分钟） | [第 3 步](docs/zh-CN/deployment-guide.md#第-3-步--部署堆栈) |
| 4 | 把堆栈输出 `KiroMcpJson` 发给开发者，或通过 Kiro MCP Registry 发布 | [第 4 步](docs/zh-CN/deployment-guide.md#第-4-步--分发-kiro-配置) |

前提条件（Business、Enterprise On-Ramp 或 Enterprise Support 计划、AgentCore 可用区域、身份管理员）、模板创建的资源、三种身份模式、从 v1.0 升级、日常运维，见 **[部署指南](docs/zh-CN/deployment-guide.md)**。

## 面向开发者 — 三步在 Kiro 里使用

1. 把 IT 给的 `aws-support` 片段加到 `~/.kiro/settings/mcp.json`（或在 Kiro MCP Registry 里选）。
2. 在 Kiro 的 **MCP Servers** 面板点一次 **Authenticate**，用企业账号登录，出现 11 个 `aws-support___*` 工具。
3. 用自然语言问 Kiro：*"开一个 AWS Support 工单：…… Request ID abc-123，严重级别系统受损，把 me@example.com 放到 CC"*、*"列出我打开的工单"*、*"在工单 1234567890 上回复：……"*。

提示词写法、预期行为（联系方式、工单归属）、已知的客户端坑，见 **[开发者指南](docs/zh-CN/developer-guide.md)**。

## 仓库结构

| 路径 | 说明 |
|---|---|
| [`cfn/support-mcp-agentcore.yaml`](cfn/support-mcp-agentcore.yaml) | CloudFormation 模板：AgentCore Runtime + Gateway + Gateway target + 2 个 IAM 角色（可选的 Cognito 用户池，独立使用或联邦到 IAM Identity Center） |
| [`app/main.py`](app/main.py) / [`app/awslabs/`](app/awslabs/) | Runtime 入口与 vendored 的上游服务（v0.1.23，Apache-2.0） |
| [`build.sh`](build.sh) / [`deploy.sh`](deploy.sh) | 构建代码包；上传 S3 并创建/更新堆栈 |
| [`scripts/cognito-add-users.sh`](scripts/cognito-add-users.sh) | Cognito 模式：按邮箱列表批量创建独立用户 |
| [`kiro/`](kiro/) | `mcp.json.example` 与可选的 steering 文件（统一提单方式） |
| [`docs/`](docs/) | [部署指南](docs/zh-CN/deployment-guide.md) · [开发者指南](docs/zh-CN/developer-guide.md) · [安全说明](docs/zh-CN/security.md) · [English docs](docs/) |

## 安全要点

- 任何请求到达 Runtime 之前，Gateway 都先用你 IdP 的 JWKS 校验 JWT；Runtime 只接受 IAM（SigV4）认证的调用，而模板里唯一被授予 `InvokeAgentRuntime` 的角色是 Gateway 角色。
- Support 权限只存在于 Runtime 执行角色上，且是 11 个动作的显式列表；开发者不持有任何 AWS 凭证。
- 所有工单由这一个角色创建，报告人身份写进工单正文和 CC。细节、加固选项与扩展见 **[安全说明](docs/zh-CN/security.md)**。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)（英文）。

## 免责声明

本仓库是**用于演示的示例代码，按原样并非生产就绪**。在任何生产使用之前，请按你所在组织的安全、身份、合规与运维要求审阅并调整（例如 IdP 加固、基于声明的访问限制、日志与监控、执行角色权限的变更管理）。

## 安全问题报告

报告安全问题请参见 [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications)。

## 许可

本库采用 MIT-0 许可，见 [LICENSE](LICENSE) 文件。vendored 的 AWS Support MCP Server 采用 Apache License 2.0，见 [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES)。
