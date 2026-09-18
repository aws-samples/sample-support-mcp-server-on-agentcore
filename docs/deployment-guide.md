> Part of [AWS Support MCP Server on Amazon Bedrock AgentCore](../README.md). Other guides: [Deployment guide](deployment-guide.md) · [Developer guide](developer-guide.md) · [Security](security.md)

# Deployment guide (IT / platform teams)

## Prerequisites

| # | Who | What you need |
|---|---|---|
| 1 | AWS account owner | An account covered by a **Business, Enterprise On-Ramp, or Enterprise Support plan** (the Support API returns `SubscriptionRequiredException` otherwise). Cases will be created in this account. |
| 2 | AWS account owner | A region where Amazon Bedrock AgentCore is available. The template was tested in `us-east-1`. The Support API endpoint lives in `us-east-1` regardless of where the Runtime is deployed — the template pins that for you. |
| 3 | Deployer | Permissions to create IAM roles, AgentCore resources and an S3 bucket; [`uv`](https://docs.astral.sh/uv/) and the AWS CLI installed locally. Docker is **not** required. |
| 4 | IdP administrator | One OIDC **public** client for Kiro (details below). You receive back a **client ID**, the IdP's **discovery URL**, and — for Okta — the **audience**. |

## Step 1 — Register an OIDC application in your IdP

Create a *native / public* OIDC application with:

- Grant types: **Authorization Code** and **Refresh Token**; PKCE enabled; **no client secret**.
- Sign-in redirect URI: `http://localhost:<port>/oauth/callback` (also add `http://127.0.0.1:<port>/oauth/callback`). Pick one port for the whole company and pass it as `KiroCallbackPort`; the default is `8080`.
- Scopes: `openid`, `email`, `profile`, `offline_access` (refresh tokens).
- Assign the application to the users or groups who should be able to file cases. Assignment is your first access-control layer.

Provider notes:

| IdP | Template parameters |
|---|---|
| **Okta** | `OidcDiscoveryUrl` = `https://<org>.okta.com/oauth2/default/.well-known/openid-configuration` (or your custom authorization server); `OidcClientId` = the app's client ID; **`OidcAudience` = `api://default`** (or your custom server's audience). Okta access tokens carry the client ID in a `cid` claim rather than `client_id`, so the Gateway must validate the audience instead. |
| **Microsoft Entra ID** | Expose an API on the app registration so the access token's `aud` is your application. Set `OidcClientId` to the app's client ID (always required in `ExternalOIDC` mode) and additionally set `OidcAudience` if the token's `aud` differs from the client ID. |
| **Amazon Cognito / Auth0** | `OidcDiscoveryUrl` + `OidcClientId`. |

## Step 2 — Build the code package

```bash
./build.sh          # -> dist/support-mcp-agentcore.zip (Linux arm64, Python 3.12)
```

The package contains `main.py`, the vendored `awslabs/` server and its dependencies. AgentCore Runtime runs it directly from S3 — no container image, no ECR.

## Step 3 — Deploy the stack

Using the helper script (creates a private, versioned S3 bucket if needed):

```bash
AWS_PROFILE=<profile> AWS_REGION=us-east-1 \
IDP_MODE=ExternalOIDC \
OIDC_DISCOVERY_URL='https://<tenant>/.well-known/openid-configuration' \
OIDC_CLIENT_ID='<client_id>' \
OIDC_AUDIENCE='api://default' \
KIRO_CALLBACK_PORT=8080 \
./deploy.sh
```

Or upload `dist/support-mcp-agentcore.zip` to a bucket of your own and create the stack from `cfn/support-mcp-agentcore.yaml` in the console or CLI:

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

`OidcAudience` is required for Okta and can be omitted for IdPs whose access token carries a `client_id` claim. Stack creation takes about two minutes. `deploy.sh` also honours `STACK=<stack name>` and `CODE_BUCKET=<existing bucket>` if you do not want the defaults.

> AgentCore Runtime and Gateway names must be unique per account and region. To deploy a second copy (for example a test stack next to production), set the `RuntimeName` and `GatewayName` parameters (`RUNTIME_NAME` / `GATEWAY_NAME` in `deploy.sh`); otherwise stack creation fails with `AlreadyExists`.

### What the template creates

| Resource | Purpose |
|---|---|
| `AWS::IAM::Role` *runtime-exec* | Assumed by AgentCore Runtime. The **only** principal with Support permissions: `support:CreateCase`, `DescribeCases`, `DescribeCommunications`, `AddCommunicationToCase`, `ResolveCase`, `AddAttachmentsToSet`, `DescribeAttachment`, plus the read-only catalog calls (`DescribeServices`, `DescribeSeverityLevels`, `DescribeCreateCaseOptions`, `DescribeSupportedLanguages`). Also `s3:GetObject` on the code package and CloudWatch Logs / X-Ray / metrics baseline. Trust policy is scoped to `bedrock-agentcore.amazonaws.com` from this account. |
| `AWS::IAM::Role` *gateway* | Assumed by AgentCore Gateway; allows only `bedrock-agentcore:InvokeAgentRuntime` on this Runtime. |
| `AWS::BedrockAgentCore::Runtime` | Hosts the MCP server (protocol `MCP`, public network mode, Python 3.12 code artifact from S3). |
| `AWS::BedrockAgentCore::Gateway` | MCP gateway with `CUSTOM_JWT` inbound authorizer bound to your IdP. |
| `AWS::BedrockAgentCore::GatewayTarget` | Points the Gateway at the Runtime's MCP endpoint using the Gateway role (SigV4). |
| *(DemoCognito mode only)* Cognito user pool, domain, app client, and — when `DemoUserEmail` is set — one user | Self-contained IdP for evaluation. |

No public S3 buckets, no public resource policies, no cross-account trust. Trim the Support permissions further if you like (for example remove `ResolveCase` or the attachment actions). The tools stay listed in Kiro — the upstream server registers all 11 statically — but calls that need a removed action fail with `AccessDeniedException`.

## Step 4 — Distribute the Kiro configuration

The stack output `KiroMcpJson` is a ready-to-paste snippet:

```json
{"mcpServers":{"aws-support":{
  "url":"https://<gateway-id>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
  "oauth":{"clientId":"<client_id>","redirectUri":"localhost:8080","oauthScopes":["openid","email","profile","offline_access"]}
}}}
```

Distribution options:

- **Pilot**: hand the snippet to the developers who need it; they add it to `~/.kiro/settings/mcp.json`. See [`kiro/mcp.json.example`](../kiro/mcp.json.example) for a version that also auto-approves the read-only catalog and case-lookup tools.
- **Scale**: publish the server through **Kiro MCP Registry** (Kiro Pro tier with IAM Identity Center) so users pick it from a list instead of editing files. Note that once a registry is active, only registry-listed servers can run — align with your Kiro administrator first.
- Optionally ship [`kiro/steering-aws-support.md`](../kiro/steering-aws-support.md) as team steering. It tells the assistant to look up valid service/category codes, choose severity conservatively, include the Kiro Request ID, and **put the reporter's email on CC** so Support replies reach the developer directly.

## Evaluation without a corporate IdP

Set `IDP_MODE=DemoCognito DEMO_USER_EMAIL=you@example.com` (or `IdentityProviderMode=DemoCognito`). The template creates a Cognito user pool with a hosted UI and, when `DemoUserEmail` is set, one user (temporary password by email). In this mode the `KiroMcpJson` output omits the `offline_access` scope. Everything else is identical, which makes this a convenient way to validate the pipeline before involving the IdP team.

## Operations

- **Logs**: Runtime logs are in CloudWatch under `/aws/bedrock-agentcore/runtimes/<runtime-id>-*`. In Kiro use *Show MCP Logs*.
- **Triage**: a `401` from the Gateway means token or IdP configuration; `421`/`5xx` means the Runtime.
- **Upgrade**: upload the new zip under a new object key and update the stack with that `CodeS3Key`; the Runtime rolls to the new version. Re-uploading under the same key does not trigger an update (the Runtime references the key, not the object version), and re-running `deploy.sh` unchanged will report "No updates are to be performed".
- **Cost**: AgentCore Runtime bills for active processing time and Gateway per call; there is no always-on charge. See the AgentCore pricing page.
- **Uninstall**: delete the stack. The S3 bucket you created is yours to remove; note that `deploy.sh` enables versioning on the bucket it creates, so empty all object versions and delete markers (`aws s3api list-object-versions` + `delete-objects`) before `delete-bucket`.
