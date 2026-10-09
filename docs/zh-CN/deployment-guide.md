> 属于 [在 Amazon Bedrock AgentCore 上托管 AWS Support MCP Server](../../README.zh-CN.md)。其他文档：[部署指南](deployment-guide.md) · [开发者指南](developer-guide.md) · [安全说明](security.md) · [English](../deployment-guide.md)

# 部署指南（IT / 平台团队）

## 前提条件

| # | 谁 | 需要什么 |
|---|---|---|
| 1 | AWS 账号所有者 | 账号需有 **Business、Enterprise On-Ramp 或 Enterprise Support 计划**（否则 Support API 返回 `SubscriptionRequiredException`）。工单会创建在这个账号下。 |
| 2 | AWS 账号所有者 | 一个 Amazon Bedrock AgentCore 可用的区域。模板在 `us-east-1` 测试过。无论 Runtime 部署在哪个区域，Support API 端点都在 `us-east-1`，模板已为你固定。 |
| 3 | 部署人 | 创建 IAM 角色、AgentCore 资源、S3 存储桶以及（Cognito 模式）Cognito 资源的权限；本机装好 [`uv`](https://docs.astral.sh/uv/) 和 AWS CLI。**不需要** Docker。 |
| 4 | 身份管理员 | 取决于你选的[身份模式](#选择身份模式)：IdP 里的一个 OIDC **公开**客户端（`ExternalOIDC`）；能在 IAM Identity Center 里创建客户管理的 SAML 2.0 应用的管理员（`Cognito` + Identity Center）；或者什么都不需要（`Cognito` 独立用户）。 |

## 选择身份模式

Kiro 用户始终通过 OAuth 2.0 授权码 + PKCE 登录，Gateway 始终校验拿到的 JWT。*在哪里登录*由 `IdentityProviderMode` 参数决定：

| 模式 | 适用场景 | 用户用什么登录 | 参数 |
|---|---|---|---|
| `ExternalOIDC` | 你有 Okta、Microsoft Entra ID、Auth0、Ping 等，并且能注册一个 OIDC 公开客户端 | 企业账号，在 IdP 自己的登录页上 | `OidcDiscoveryUrl`、`OidcClientId`、`OidcAudience`（Okta） |
| `Cognito` **+ `SamlMetadataUrl`** | 你的用户在 **AWS IAM Identity Center** 里（Kiro Pro / Enterprise 已经在用的目录）或另一个 SAML 2.0 IdP 里，并且没有 OIDC 客户端可用。**要求 Identity Center 是组织实例**——账户实例无法承载客户管理的 SAML 2.0 应用。 | Identity Center 账号。模板创建的 Cognito 用户池充当 SAML 服务提供方，并签发 Gateway 校验的令牌。 | `SamlMetadataUrl`、`SamlProviderName` |
| `Cognito`（不带 SAML） | 评估，或者几十人规模、没有可用 IdP 的试点 | 管理员在用户池里创建的用户（邮箱 + 密码） | `CognitoFirstUserEmail`，之后用 `scripts/cognito-add-users.sh` |

- `DemoCognito`（v1.0 里 Cognito 模式的名字）仍然接受，含义与 `Cognito` 相同。
- IAM Identity Center 不能直接作为 Gateway 的令牌签发方：它的 OIDC 端点面向 AWS 托管应用（换令牌需要 IAM 签名调用，Kiro 做不到），AgentCore 的入站身份文档也没有列出它。经 Cognito 用户池联邦是受支持的路径。
- 任何模式下 Kiro 自身的登录都不动，应用代码完全相同，开发者身份以文本形式进入工单正文和 CC（见[开发者指南](developer-guide.md#预期行为)）。

## 第 1 步 — 配置身份提供商

### 1a. `ExternalOIDC`：在 IdP 里注册 OIDC 应用

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

### 1b. `Cognito` + IAM Identity Center（SAML 2.0 联邦）

Identity Center 里客户管理的 SAML 2.0 应用**只能在控制台创建**，而这个应用需要的两个值只有在用户池建好之后才存在，所以是两轮部署：

1. 以 `Cognito` 模式、**不带** `SamlMetadataUrl` 部署堆栈（[第 3 步](#第-3-步--部署堆栈)）。记下输出 `CognitoSamlAcsUrl` 和 `CognitoSamlAudience`。
2. 在组织实例的 **IAM Identity Center 控制台**（管理账号或委派管理员账号）：**Applications → Customer managed 标签页 → Add application → I have an application I want to set up → Application type 选 SAML 2.0**（不要选 OAuth 2.0）**→ Next**。填一个显示名，如 *AWS Support from Kiro*。复制 **IAM Identity Center SAML metadata file** 的 URL——这就是 `SamlMetadataUrl`。在 **Application metadata** 下选 *Manually type your metadata values*，填 **Application ACS URL** = `CognitoSamlAcsUrl`，**Application SAML audience** = `CognitoSamlAudience`。提交。
3. 在该应用上 **Actions → Edit attribute mappings**：保留 `Subject` → `${user:subject}`，格式 *persistent*；新增 `email` → `${user:email}`，格式 *basic*。提交。（模板把 SAML 属性 `email` 映射到用户池的 `email` 属性，助手用它把报告人放进 CC。）
4. **Assign users and groups**，把用户或组分配给该应用。分配就是你的访问控制层，与 OIDC IdP 里的应用分配完全一样。
5. 用 `SamlMetadataUrl` 更新堆栈（如果想让联邦用户名的前缀不是 `IdentityCenter`，再加 `SamlProviderName`）。应用客户端从此只接受联邦登录；Gateway 配置和 `KiroMcpJson` 片段都不变。

登录时发生什么：Kiro 打开用户池的授权端点；由于应用客户端上只启用了这一个 SAML 提供商，浏览器会被直接重定向到 Identity Center，不显示任何 Cognito 页面（SP 发起的 SAML）。用户在那里按你的 Identity Center 策略（含 MFA）认证，随后 Cognito 为其创建或刷新一份档案（`<SamlProviderName>_<subject>`，邮箱来自映射属性）并签发令牌。用户池上的 `AllowAdminCreateUserOnly` 只是禁止自助注册，联邦档案始终会被创建。

注意事项：

- 仅限组织实例（见 Identity Center 文档里的实例类型说明）。如果你的 Identity Center 是账户实例，请用 1a 或 1c。
- 请直接确认实例类型，不要根据它所在的账号来推断。组织实例的控制台左侧导航里有 **Multi-account permissions**（AWS accounts、Permission sets）；账户实例点 **Add application** 会直接进入 OAuth 2.0 配置向导，没有 SAML 2.0 选项。命令行下，账户实例执行 `aws sso-admin list-permission-sets --instance-arn <instance-arn>` 会报错 *This operation is not supported for account instances of IAM Identity Center*。
- 如果用户池里已经有同邮箱的独立用户（例如评估阶段建的），切换到联邦前先删掉它们，或用 `aws cognito-idp admin-link-provider-for-user` 关联；否则这些人的联邦登录会因别名冲突失败。
- 从 Identity Center 应用里移除的用户不能再登录，但其用户池档案会保留到你删除为止；已签发的令牌到过期前仍然有效（模板默认 access token 60 分钟、refresh token 30 天）。

### 1c. `Cognito` 独立用户

以 `Cognito` 模式部署，`CognitoFirstUserEmail` 填第一个用户（[第 3 步](#第-3-步--部署堆栈)），然后按邮箱列表批量添加：

```bash
scripts/cognito-add-users.sh --stack support-mcp-agentcore --region us-east-1 users.txt   # 每行一个邮箱
```

每个用户会收到一封临时密码邮件，首次登录必须改成自己的密码（12 位以上，含大写、小写和数字）。脚本会把邮箱统一转成小写，而用户池区分大小写，所以请用户输入小写邮箱。这些用户是**第二套凭证**，不与你的目录同步：有人离职时，要在目录里禁用，*同时*在用户池里禁用（`aws cognito-idp admin-disable-user`）。该模式适合评估和小规模试点；上百人请用 1a 或 1b。加固选项：在用户池上开启 TOTP MFA（`MfaConfiguration`），在模板里收紧密码策略。

## 第 2 步 — 构建代码包

```bash
./build.sh          # -> dist/support-mcp-agentcore.zip (Linux arm64, Python 3.12)
```

代码包包含 `main.py`、vendored 的 `awslabs/` 服务及其依赖。AgentCore Runtime 直接从 S3 运行它，不需要容器镜像，不需要 ECR。

## 第 3 步 — 部署堆栈

用辅助脚本（必要时会创建一个私有、开启版本控制的 S3 存储桶）：

```bash
# ExternalOIDC
AWS_PROFILE=<profile> AWS_REGION=us-east-1 \
IDP_MODE=ExternalOIDC \
OIDC_DISCOVERY_URL='https://<tenant>/.well-known/openid-configuration' \
OIDC_CLIENT_ID='<client_id>' \
OIDC_AUDIENCE='api://default' \
KIRO_CALLBACK_PORT=8080 \
./deploy.sh

# Cognito，独立用户
AWS_PROFILE=<profile> AWS_REGION=us-east-1 IDP_MODE=Cognito COGNITO_FIRST_USER_EMAIL=you@example.com ./deploy.sh

# Cognito + IAM Identity Center：第一轮不带 SAML，第二轮在 SAML 应用建好后（第 1b 步）
AWS_PROFILE=<profile> AWS_REGION=us-east-1 IDP_MODE=Cognito ./deploy.sh
AWS_PROFILE=<profile> AWS_REGION=us-east-1 IDP_MODE=Cognito \
SAML_METADATA_URL='https://portal.sso.<region>.amazonaws.com/saml/metadata/<id>' ./deploy.sh
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
| `AWS::IAM::Role` *runtime-exec* | 由 AgentCore Runtime 扮演。**唯一**拥有 Support 权限的主体：`support:CreateCase`、`DescribeCases`、`DescribeCommunications`、`AddCommunicationToCase`、`ResolveCase`、`AddAttachmentsToSet`、`DescribeAttachment`，加上只读目录调用（`DescribeServices`、`DescribeSeverityLevels`、`DescribeCreateCaseOptions`、`DescribeSupportedLanguages`）。另有代码包的 `s3:GetObject` / `s3:GetObjectVersion` 和 CloudWatch Logs / X-Ray / 指标基线权限。信任策略限定为本账号的 `bedrock-agentcore.amazonaws.com`。 |
| `AWS::IAM::Role` *gateway* | 由 AgentCore Gateway 扮演；只允许对这个 Runtime 执行 `bedrock-agentcore:InvokeAgentRuntime`。 |
| `AWS::BedrockAgentCore::Runtime` | 托管 MCP 服务（协议 `MCP`，公网网络模式，来自 S3 的 Python 3.12 代码包；设置了 `CodeS3ObjectVersion` 时固定到该对象版本）。 |
| `AWS::BedrockAgentCore::Gateway` | 带 `CUSTOM_JWT` 入站授权器的 MCP gateway，绑定到你的 IdP（或 Cognito 用户池）。 |
| `AWS::BedrockAgentCore::GatewayTarget` | 用 Gateway 角色（SigV4）把 Gateway 指向 Runtime 的 MCP 端点。 |
| *（仅 Cognito 模式）* Cognito 用户池（Essentials 档，仅管理员建用户）、托管域名、应用客户端（公开、PKCE）；设置了 `CognitoFirstUserEmail` 时一个用户；设置了 `SamlMetadataUrl` 时一个绑定到应用客户端的 SAML 身份提供商 | 自带 IdP，独立使用或联邦到 IAM Identity Center。 |

没有公开的 S3 存储桶，没有公开的资源策略，没有跨账号信任。你可以进一步收紧 Support 权限（例如去掉 `ResolveCase` 或附件相关动作）。工具在 Kiro 里仍会全部列出——上游服务静态注册了全部 11 个——但需要已移除动作的调用会以 `AccessDeniedException` 失败。

## 第 4 步 — 分发 Kiro 配置

堆栈输出 `KiroMcpJson` 是可直接粘贴的片段：

```json
{"mcpServers":{"aws-support":{
  "url":"https://<gateway-id>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
  "oauth":{"clientId":"<client_id>","redirectUri":"localhost:8080","oauthScopes":["openid","email","profile","offline_access"]}
}}}
```

Cognito 模式下片段不含 `offline_access` scope（Cognito 不需要它就会签发刷新令牌）。分发方式：

- **试点**：把片段发给需要的开发者，他们加到 `~/.kiro/settings/mcp.json`。[`kiro/mcp.json.example`](../../kiro/mcp.json.example) 是一个还会自动批准只读目录与查单工具的版本。
- **规模化**：通过 **Kiro MCP Registry**（Kiro Pro 档配合 IAM Identity Center）发布服务，用户从列表里选而不是改文件。注意 registry 一旦启用，只有 registry 里列出的服务能运行，先和 Kiro 管理员对齐。
- 可选：把 [`kiro/steering-aws-support.md`](../../kiro/steering-aws-support.md) 作为团队 steering 下发。它让助手查有效的服务/类别代码、保守选择严重级别、带上 Kiro Request ID，并**把报告人邮箱放到 CC**，这样 Support 的回复能直接到达开发者。

## 从 v1.0 堆栈升级

- `IdentityProviderMode=DemoCognito` 仍然接受。参数 `DemoUserEmail` 改名为 `CognitoFirstUserEmail`：更新 v1.0 堆栈时请再传一次同一个邮箱（用 `deploy.sh` 时传 `DEMO_USER_EMAIL` 或 `COGNITO_FIRST_USER_EMAIL`），否则 CloudFormation 会删掉那个评估用户。
- 资源逻辑 ID 没变，所以是原地更新：同一个用户池、域名、应用客户端和 Gateway URL——Kiro 片段照旧可用。
- 给已有的 Cognito 模式堆栈加上 `SamlMetadataUrl` 会把应用客户端切换成只接受联邦登录（见 [1b](#1b-cognito--iam-identity-centersaml-20-联邦) 的注意事项）。

## 运维

- **日志**：Runtime 日志在 CloudWatch 的 `/aws/bedrock-agentcore/runtimes/<runtime-id>-*` 下。Kiro 里用 *Show MCP Logs*。
- **排障**：Gateway 返回 `401` 是令牌或 IdP 配置问题；`421`/`5xx` 是 Runtime 问题。
- **升级服务**：用同样的参数再跑一次 `./deploy.sh`。脚本上传新代码包，并把上传对象的版本 ID（`CodeS3ObjectVersion`）传给堆栈，因此即使对象键名不变，Runtime 也会滚动到新代码。不用脚本时，自己传新的版本 ID，或者换一个 `CodeS3Key` 上传。脚本每次运行都会重新上传代码包；在开启了版本控制的桶里（`deploy.sh` 自己创建的桶默认开启），每次上传都会得到新的版本 ID，所以即使代码没变，每次运行也会让 Runtime 滚动到一个新版本。只有在未开启版本控制的桶里、且其他参数都没变时，CloudFormation 才会回答 "No updates are to be performed"，此时脚本正常退出。
- **成本**：AgentCore Runtime 按活跃处理时间计费，Gateway 按调用计费，没有常驻费用——见 AgentCore 定价页。Cognito 模式下再加 Amazon Cognito：独立用户免费额度很大，联邦（SAML）用户的免费额度小得多（撰写时为每月 50 个活跃用户），超出后按用户计费——见 Cognito 定价页。
- **卸载**：删除堆栈（Cognito 模式下会连用户池和其中所有档案一起删除）。你创建的 S3 存储桶自行删除；注意 `deploy.sh` 给它建的桶开了版本控制，`delete-bucket` 前要清空所有对象版本和删除标记（`aws s3api list-object-versions` + `delete-objects`）。
