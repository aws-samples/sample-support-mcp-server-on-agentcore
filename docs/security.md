> Part of [AWS Support MCP Server on Amazon Bedrock AgentCore](../README.md). Other guides: [Deployment guide](deployment-guide.md) · [Developer guide](developer-guide.md) · [Security](security.md)

# Security

- **Authentication boundary**: the Gateway validates JWTs against your IdP's JWKS before any request reaches the Runtime; the Runtime accepts only IAM-authenticated (SigV4) calls; in this template the only role granted `bedrock-agentcore:InvokeAgentRuntime` on it is the Gateway role (principals with broader IAM permissions in the account, such as administrators, could still invoke it directly). `main.py` disables FastMCP's Host-header (DNS rebinding) guard because AgentCore forwards requests with a non-localhost `Host` header and the Gateway/Runtime are the trust boundary — do not run the entrypoint exposed on a network outside AgentCore.
- **Authorization**: access = IdP application assignment. For finer control, add a claim rule (`CustomClaims`) to the Gateway authorizer, for example requiring a `groups` claim to contain a specific group.
- **Least privilege**: Support permissions exist only on the Runtime execution role, with the explicit action list in the [deployment guide](deployment-guide.md#what-the-template-creates). Developers hold no AWS credentials.
- **Data handling**: case content flows through AgentCore to the AWS Support API; AWS Support automatically redacts secret keys and credit card numbers in case text, but do not paste secrets into cases.
- **Attribution**: all cases are created by the same execution role. Reporter identity is added to the body and CC by the assistant (steering). See [Possible extensions](#possible-extensions) for a server-side approach.

## Possible extensions

- **Automatic reporter identity**: have the Runtime read the caller's identity and inject it into `create_support_case` / `add_communication_to_case`, so the CC no longer depends on the assistant. This requires passing the JWT through to the Runtime (`JWT_PASSTHROUGH`), which AgentCore Gateway supports only on HTTP-type targets — not on the `McpServer` target this template uses — so it means a different target type, a different Gateway URL for clients, and different tool naming. Your IdP must also include an email (or equivalent) claim in the access token. Treat it as a separate design, not a drop-in switch.
- **Group-based access** via the Gateway authorizer's `CustomClaims`.
- **Case dashboards** for IT: AWS Support emits `Support Case Update` events to Amazon EventBridge; route them to a chat channel or a table for an account-wide view.
