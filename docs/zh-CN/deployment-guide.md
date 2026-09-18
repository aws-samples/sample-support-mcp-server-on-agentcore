> 属于 [在 Amazon Bedrock AgentCore 上托管 AWS Support MCP Server](../../README.zh-CN.md)。其他文档：[部署指南](deployment-guide.md) · [开发者指南](developer-guide.md) · [安全说明](security.md) · [English](../deployment-guide.md)

# 部署指南（IT / 平台团队）

## 前提条件

| # | 谁 | 需要什么 |
|---|---|---|
| 1 | AWS 账号所有者 | 账号需有 **Business、Enterprise On-Ramp 或 Enterprise Support 计划**（否则 Support API 返回 `SubscriptionRequiredException`）。工单会创建在这个账号下。 |
| 2 | AWS 账号所有者 | 一个 Amazon Bedrock AgentCore 可用的区域。模板在 `us-east-1` 测试过。无论 Runtime 部署在哪个区域，Support API 端点都在 `us-east-1`，模板已为你固定。 |
| 3 | 部署人 | 创建 IAM 角色、AgentCore 资源和 S3 存储桶的权限；本机装好 [`uv`](https://docs.astral.sh/uv/) 和 AWS CLI。**不需要** Docker。 |
| 4 | IdP 管理员 | 为 Kiro 建一个 OIDC **公开**客户端（见下）。你会拿到 **client ID**、IdP 的 **discovery URL**，Okta 还会有 **audience**。 |

## 第 1 步 — 在 IdP 里注册 OIDC 应用

创建一个 *native / public* 类型的 OIDC 应用：

- 授权类型：**Authorization Code** 和 **Refresh Token**；开启 PKCE；**没有 client secret**。
- 登录回调 URI：`http://localhost:<port>/oauth/callback`（同时加上 `http://127.0.0.1:<port>/oauth/callback`）。全公司统一一个端口，作为 `KiroCallbackPort` 传入；默认 `8080`。
- Scopes：`openid`、`email`、`profile`、`offline_access`（刷新令牌）。
- 把应用分配给允许提单的用户或组。应用分配是你的第一层访问控制。

各 IdP 说明：

| IdP | 模板参数 |
|---|---|
| **Okta** | `OidcDiscoveryUrl` = `https://<org>.okta.com/oauth2/default/.well-known/openid-configuration`（或你的自定义授权服务器）；`OidcClientId` = 应用的 client ID；**`OidcAudience` = `api://default`**（或自定义服务器的 audience）。Okta 的 access token 用 `cid` 声明而不是 `client_id` 携带 client ID，所以 Gateway 必须改为校验 audience。 |
| **Microsoft Entra ID** | 在应用注册里 Expose an API，使 access token 的 `aud` 是你的应用。`OidcClientId` 填应用的 client ID（`ExternalOIDC` 模式下必填），若 token 的 `aud` 与 client ID 不同再额外设置 `OidcAudience`。 |
| **Amazon Cognito / Auth0** | `OidcDiscoveryUrl` + `OidcClientId`。 |

## 第 2 步 — 构建代码包

```bash
./build.sh          # -> dist/support-mcp-agentcore.zip (Linux arm64, Python 3.12)
```

代码包包含 `main.py`、vendored 的 `awslabs/` 服务及其依赖。AgentCore Runtime 直接从 S3 运行它，不需要容器镜像，不需要 ECR。

## 第 3 步 — 部署堆栈

用辅助脚本（必要时会创建一个私有、开启版本控制的 S3 存储桶）：

```bash
AWS_PROFILE=<profile> AWS_REGION=us-east-1 \
IDP_MODE=ExternalOIDC \
OIDC_DISCOVERY_URL='https://<tenant>/.well-known/openid-configuration' \
OIDC_CLIENT_ID='<client_id>' \
OIDC_AUDIENCE='api://default' \
KIRO_CALLBACK_PORT=8080 \
./deploy.sh
```

或者把 `dist/support-mcp-agentcore.zip` 上传到你自己的存储桶，在控制台或 CLI 里用 `cfn/support-mcp-agentcore.yaml` 创建堆栈：

```bash
aws cloudformation create-stack --stack-name support-mcp-agentcore --region us-east-1 \
  --template-body file://cfn/support-mcp-agentcore.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=CodeS3Bucket,ParameterValue=<your-bucket> \
    ParameterKey=IdentityProviderMode,ParameterValue=ExternalOIDC \
    ParameterKey=OidcDiscoveryUrl,ParameterValue='https://<tenant>/.well-known/openid-configuration' \
    ParameterKey=OidcClientId,ParameterValue=<client_id> \
    ParameterKey=OidcAudience,ParameterValue=api://default \
    ParameterKey=KiroCallbackPort,ParameterValue=8080
```

Okta 必须填 `OidcAudience`；access token 里带 `client_id` 声明的 IdP 可以省略。堆栈创建约两分钟。不想用默认值时，`deploy.sh` 还支持 `STACK=<堆栈名>` 和 `CODE_BUCKET=<已有存储桶>`。

> AgentCore Runtime 和 Gateway 的名字在同一账号同一区域内必须唯一。要部署第二份（例如生产旁边再建一个测试堆栈），请设置 `RuntimeName` 和 `GatewayName` 参数（`deploy.sh` 里对应 `RUNTIME_NAME` / `GATEWAY_NAME`），否则堆栈创建会报 `AlreadyExists`。

### 模板创建的资源

| 资源 | 用途 |
|---|---|
| `AWS::IAM::Role` *runtime-exec* | 由 AgentCore Runtime 扮演。**唯一**拥有 Support 权限的主体：`support:CreateCase`、`DescribeCases`、`DescribeCommunications`、`AddCommunicationToCase`、`ResolveCase`、`AddAttachmentsToSet`、`DescribeAttachment`，加上只读目录调用（`DescribeServices`、`DescribeSeverityLevels`、`DescribeCreateCaseOptions`、`DescribeSupportedLanguages`）。另有代码包的 `s3:GetObject` 和 CloudWatch Logs / X-Ray / 指标基线权限。信任策略限定为本账号的 `bedrock-agentcore.amazonaws.com`。 |
| `AWS::IAM::Role` *gateway* | 由 AgentCore Gateway 扮演；只允许对这个 Runtime 执行 `bedrock-agentcore:InvokeAgentRuntime`。 |
| `AWS::BedrockAgentCore::Runtime` | 托管 MCP 服务（协议 `MCP`，公网网络模式，来自 S3 的 Python 3.12 代码包）。 |
| `AWS::BedrockAgentCore::Gateway` | 带 `CUSTOM_JWT` 入站授权器的 MCP gateway，绑定到你的 IdP。 |
| `AWS::BedrockAgentCore::GatewayTarget` | 用 Gateway 角色（SigV4）把 Gateway 指向 Runtime 的 MCP 端点。 |
| *（仅 DemoCognito 模式）* Cognito 用户池、域名、应用客户端，以及设置了 `DemoUserEmail` 时的一个用户 | 用于评估的自带 IdP。 |

没有公开的 S3 存储桶，没有公开的资源策略，没有跨账号信任。你可以进一步收紧 Support 权限（例如去掉 `ResolveCase` 或附件相关动作）。工具在 Kiro 里仍会全部列出——上游服务静态注册了全部 11 个——但需要已移除动作的调用会以 `AccessDeniedException` 失败。

## 第 4 步 — 分发 Kiro 配置

堆栈输出 `KiroMcpJson` 是可直接粘贴的片段：

```json
{"mcpServers":{"aws-support":{
  "url":"https://<gateway-id>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
  "oauth":{"clientId":"<client_id>","redirectUri":"localhost:8080","oauthScopes":["openid","email","profile","offline_access"]}
}}}
```

分发方式：

- **试点**：把片段发给需要的开发者，他们加到 `~/.kiro/settings/mcp.json`。[`kiro/mcp.json.example`](../../kiro/mcp.json.example) 是一个还会自动批准只读目录与查单工具的版本。
- **规模化**：通过 **Kiro MCP Registry**（Kiro Pro 档配合 IAM Identity Center）发布服务，用户从列表里选而不是改文件。注意 registry 一旦启用，只有 registry 里列出的服务能运行，先和 Kiro 管理员对齐。
- 可选：把 [`kiro/steering-aws-support.md`](../../kiro/steering-aws-support.md) 作为团队 steering 下发。它让助手查有效的服务/类别代码、保守选择严重级别、带上 Kiro Request ID，并**把报告人邮箱放到 CC**，这样 Support 的回复能直接到达开发者。

## 没有企业 IdP 时的评估方式

设置 `IDP_MODE=DemoCognito DEMO_USER_EMAIL=you@example.com`（或 `IdentityProviderMode=DemoCognito`）。模板会创建一个带托管 UI 的 Cognito 用户池，若设置了 `DemoUserEmail` 还会创建一个用户（临时密码邮件发送）。此模式下 `KiroMcpJson` 输出不含 `offline_access` scope。其他一切相同，适合在拉 IdP 团队进来之前先验证整条链路。

## 运维

- **日志**：Runtime 日志在 CloudWatch 的 `/aws/bedrock-agentcore/runtimes/<runtime-id>-*` 下。Kiro 里用 *Show MCP Logs*。
- **排障**：Gateway 返回 `401` 是令牌或 IdP 配置问题；`421`/`5xx` 是 Runtime 问题。
- **升级**：把新 zip 上传到一个新的对象键，并用该 `CodeS3Key` 更新堆栈，Runtime 会滚动到新版本。同一键名覆盖上传不会触发更新（Runtime 引用的是键名而非对象版本），不改参数重跑 `deploy.sh` 会报 "No updates are to be performed"。
- **成本**：AgentCore Runtime 按活跃处理时间计费，Gateway 按调用计费，没有常驻费用。参见 AgentCore 定价页。
- **卸载**：删除堆栈。你创建的 S3 存储桶自行删除；注意 `deploy.sh` 给它建的桶开了版本控制，`delete-bucket` 前要清空所有对象版本和删除标记（`aws s3api list-object-versions` + `delete-objects`）。
