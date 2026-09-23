> 属于 [在 Amazon Bedrock AgentCore 上托管 AWS Support MCP Server](../../README.zh-CN.md)。其他文档：[部署指南](deployment-guide.md) · [开发者指南](developer-guide.md) · [安全说明](security.md) · [English](../developer-guide.md)

# 开发者指南（在 Kiro 里使用）

你需要：Kiro、企业账号，以及 Kiro MCP 配置里的 `aws-support` 条目（IT 提供，或从 Kiro MCP Registry 里选）。你**不需要** AWS 凭证、IAM 用户或控制台权限。

## 一次性：登录

1. 把 IT 给的片段加到 `~/.kiro/settings/mcp.json`（或在 registry 里选中该服务）。
2. 打开 Kiro 的 **MCP Servers** 面板，找到 `aws-support`，点 **Authenticate**。浏览器会打开，根据 IT 的配置你会看到下面之一：
   - 公司自己的登录页（Okta、Entra ID 等企业 IdP）；
   - 直接进入 AWS 访问门户（IAM Identity Center）——像登录 Kiro 本身那样登录即可；
   - 一个 Amazon Cognito 页面要你输入邮箱和密码——用 IT 邮件发给你的临时密码（邮箱请用小写），首次登录会要求设置新密码。
3. 登录后跳回 Kiro。服务显示为已连接，并列出 11 个 `aws-support___*` 工具。令牌存在 Kiro 的安全存储里并自动刷新。

> 对于 OAuth 保护的服务，Kiro **不会**在启动时自己打开浏览器；在你点 **Authenticate** 之前，服务会显示未认证或未连接。这是一次性操作。

## 提交工单

在 Kiro 对话里描述问题，例如：

> 开一个 AWS Support 工单：从今天早上开始，我们团队所有人的 Kiro 都返回 "model 'auto' not available"。Request ID abc-123。严重级别：系统受损。把我的邮箱 me@example.com 放到 CC。

助手会：

1. 调用 `aws-support___describe_services` 选出有效的服务/类别代码，并保守选择严重级别代码（steering 文件里列了可选值）。
2. 调用 `aws-support___create_support_case`，主题、正文（含你的姓名、邮箱、环境信息和 Request ID）以及 `cc_email_addresses` 里的邮箱。
3. 读回**工单 ID** 和 Support Center 链接。

写操作工具（`create_support_case`、`add_communication_to_case`、`resolve_support_case`、`add_attachments_to_set`）在执行前会请你确认，除非你设置了自动批准；只读工具可以自动批准（见示例配置）。

## 跟踪工单

- 问 Kiro：*"列出我打开的 AWS Support 工单"* → `aws-support___describe_support_cases`（可按状态、时间范围或工单 ID 过滤）。
- 问：*"看一下工单 1234567890 的最新回复"* → `aws-support___describe_communications` 返回往来记录。
- **邮件**：AWS Support 会把每条往来都抄送到工单 CC 列表里的地址（`ccEmailAddresses`，最多 10 个）。如果创建时加了你的邮箱，不打开 Kiro 也能在邮箱里收到每条 Support 回复。AWS 账号的联系邮箱也会收到工单通知，这是 Support 的标准行为，所以建议账号邮箱用共享邮箱。

## 回复或关闭工单

- *"在工单 1234567890 上回复：这是你们要的日志……"* → `aws-support___add_communication_to_case`（这里也可以再加 CC 地址）。
- *"关闭工单 1234567890"* → `aws-support___resolve_support_case`（steering 文件会让助手先确认）。

## 预期行为

- 通过 API 创建的工单使用 **web** 联系方式。需要电话或聊天时，在工单里向 Support 提出，或使用 Support Center。
- 工单的 *Submitted by* 字段显示的是共享执行角色，不是你的名字。你的身份在工单正文和 CC 列表里，Support 工程师就是靠这些和你沟通。
- Kiro 产品 bug（崩溃、界面问题）仍应走 Kiro 的 **Report Issue** 按钮，它会带着 Request ID 给 Kiro 团队开 GitHub issue。

## 已知的客户端坑

| 现象 | 原因 | 解决 |
|---|---|---|
| 浏览器打开了，但跳转失败或约 60 秒后超时 | `mcp.json` 里的 `oauth.redirectUri` 写成了完整 URL。Kiro IDE 期望的是 **`host:port`**（如 `localhost:8080`），否则会退回随机端口，与 IdP 注册的不再匹配。 | 用 `"redirectUri": "localhost:<port>"`。IdP 侧保留完整的 `http://localhost:<port>/oauth/callback`。 |
| Kiro 刚启动服务就显示 *disconnected*，之后没动静 | Kiro 被动启动 OAuth 服务，只在你触发认证时才打开浏览器。 | 在 MCP Servers 面板点一次 **Authenticate**。 |
| 通过 IAM Identity Center 登录成功了，但随后 Cognito 页面报错，或浏览器一直没跳回 Kiro | 你没有被分配到 Identity Center 里的 *AWS Support from Kiro* 应用，或者用户池里还留着一个同邮箱的独立用户。 | 请 IT 把你分配到该应用（并删除或关联那个旧的独立用户）。 |
| 点 Authenticate 后浏览器落到 IdP 错误页（如 `BadRequest`），Kiro 日志里 *Opening authorization URL* 晚了一分钟 | Kiro 对 IdP 的 discovery 请求走了 IPv6 并挂起。某些 VPN 客户端会装一条不可达的 IPv6 默认路由，而多数 IdP 发布了 AAAA 记录。 | 用 `curl -6 -m 5 https://<idp-host>/` 检查。如果挂起，断开 VPN 或让 IT 修 IPv6 路由策略。 |
