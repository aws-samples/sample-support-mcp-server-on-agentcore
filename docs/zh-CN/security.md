> 属于 [在 Amazon Bedrock AgentCore 上托管 AWS Support MCP Server](../../README.zh-CN.md)。其他文档：[部署指南](deployment-guide.md) · [开发者指南](developer-guide.md) · [安全说明](security.md) · [English](../security.md)

# 安全说明

- **认证边界**：任何请求到达 Runtime 之前，Gateway 都会用你 IdP 的 JWKS 校验 JWT；Runtime 只接受 IAM（SigV4）认证的调用；本模板中唯一被授予 `bedrock-agentcore:InvokeAgentRuntime` 的角色是 Gateway 角色（账号内拥有更宽 IAM 权限的主体，如管理员，仍可直接调用）。`main.py` 关闭了 FastMCP 的 Host 头（DNS rebinding）防护，因为 AgentCore 转发的请求带的是非 localhost 的 `Host` 头，且 Gateway/Runtime 才是信任边界。不要把这个入口暴露在 AgentCore 之外的网络上运行。
- **授权**：访问权 = IdP 应用分配。需要更细粒度时，给 Gateway 授权器加声明规则（`CustomClaims`），例如要求 `groups` 声明包含某个组。
- **最小权限**：Support 权限只存在于 Runtime 执行角色上，动作列表见[部署指南](deployment-guide.md#模板创建的资源)。开发者不持有任何 AWS 凭证。
- **数据处理**：工单内容经 AgentCore 流向 AWS Support API；AWS Support 会自动脱敏工单文本中的密钥和信用卡号，但仍不要把机密粘进工单。
- **归属**：所有工单由同一个执行角色创建。报告人身份由助手（steering）加进正文和 CC。服务端方案见[可能的扩展](#可能的扩展)。

## 可能的扩展

- **自动注入报告人身份**：让 Runtime 读取调用者身份并注入 `create_support_case` / `add_communication_to_case`，CC 不再依赖助手。这需要把 JWT 透传到 Runtime（`JWT_PASSTHROUGH`），而 AgentCore Gateway 只在 HTTP 类型 target 上支持透传，本模板用的是 `McpServer` target——意味着要换 target 类型、客户端的 Gateway URL 会变、工具命名也会变。你的 IdP 还需要在 access token 里包含 email（或等价）声明。这是一个独立设计，不是一个开关。
- **基于组的访问控制**：通过 Gateway 授权器的 `CustomClaims`。
- **给 IT 的工单看板**：AWS Support 会向 Amazon EventBridge 发出 `Support Case Update` 事件，可路由到聊天频道或一张表，形成账号级视图。
