> Part of [AWS Support MCP Server on Amazon Bedrock AgentCore](../README.md). Other guides: [Deployment guide](deployment-guide.md) · [Developer guide](developer-guide.md) · [Security](security.md)

# Deployment guide (IT / platform teams)

## Prerequisites

| # | Who | What you need |
|---|---|---|
| 1 | AWS account owner | An account covered by a **Business, Enterprise On-Ramp, or Enterprise Support plan** (the Support API returns `SubscriptionRequiredException` otherwise). Cases will be created in this account. |
| 2 | AWS account owner | A region where Amazon Bedrock AgentCore is available. The template was tested in `us-east-1`. The Support API endpoint lives in `us-east-1` regardless of where the Runtime is deployed — the template pins that for you. |
| 3 | Deployer | Permissions to create IAM roles, AgentCore resources, an S3 bucket and (Cognito mode) Cognito resources; [`uv`](https://docs.astral.sh/uv/) and the AWS CLI installed locally. Docker is **not** required. |
| 4 | Identity administrator | Depends on the [identity mode](#choose-an-identity-mode): an OIDC **public** client in your IdP (`ExternalOIDC`), an IAM Identity Center administrator who can create a customer managed SAML 2.0 application (`Cognito` + Identity Center), or nothing at all (`Cognito` standalone users). |

## Choose an identity mode

Kiro users always sign in through an OAuth 2.0 authorization-code flow with PKCE, and the Gateway always validates the resulting JWT. *Where* they sign in is set by the `IdentityProviderMode` parameter:

| Mode | Use it when | Users sign in with | Parameters |
|---|---|---|---|
| `ExternalOIDC` | You run Okta, Microsoft Entra ID, Auth0, Ping, ... and can register an OIDC public client | Their corporate account, on the IdP's own login page | `OidcDiscoveryUrl`, `OidcClientId`, `OidcAudience` (Okta) |
| `Cognito` **+ `SamlMetadataUrl`** | Your users live in **AWS IAM Identity Center** (the directory Kiro Pro / Enterprise already uses) or another SAML 2.0 IdP, and you have no OIDC client to offer. **Requires an Identity Center organization instance** — account instances cannot host customer managed SAML 2.0 applications. | Their Identity Center account. A Cognito user pool created by the template acts as the SAML service provider and issues the tokens the Gateway validates. | `SamlMetadataUrl`, `SamlProviderName` |
| `Cognito` (no SAML) | Evaluation, or a pilot of a few dozen users with no usable IdP | A user (e-mail + password) that an administrator creates in the pool | `CognitoFirstUserEmail`, then `scripts/cognito-add-users.sh` |

- `DemoCognito` — the v1.0 name of the Cognito mode — is still accepted and means the same as `Cognito`.
- IAM Identity Center cannot be the Gateway's token issuer directly: its OIDC endpoints are meant for AWS-managed applications (token exchange requires IAM-signed calls that Kiro cannot make), and AgentCore's inbound-identity documentation does not list it. Federating it through a Cognito user pool is the supported path.
- In every mode Kiro's own sign-in is untouched, the application code is identical, and the developer's identity reaches AWS Support as text in the case body and CC (see the [developer guide](developer-guide.md#what-to-expect)).

## Step 1 — Set up the identity provider

### 1a. `ExternalOIDC`: register an OIDC application in your IdP

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

### 1b. `Cognito` + IAM Identity Center (SAML 2.0 federation)

Identity Center lets you create a customer managed SAML 2.0 application **only in the console**, and that application needs two values that exist only after the user pool has been created. The setup is therefore a two-pass deployment:

1. Deploy the stack in `Cognito` mode **without** `SamlMetadataUrl` ([Step 3](#step-3--deploy-the-stack)). Note the outputs `CognitoSamlAcsUrl` and `CognitoSamlAudience`.
2. In the **IAM Identity Center console** of the organization instance (management account or delegated administrator): **Applications → Customer managed tab → Add application → I have an application I want to set up → Application type: SAML 2.0** (not OAuth 2.0) **→ Next**. Enter a display name such as *AWS Support from Kiro*. Copy the **IAM Identity Center SAML metadata file** URL — this becomes `SamlMetadataUrl`. Under **Application metadata** choose *Manually type your metadata values* and enter **Application ACS URL** = `CognitoSamlAcsUrl`, **Application SAML audience** = `CognitoSamlAudience`. Submit.
3. On the application, **Actions → Edit attribute mappings**: keep `Subject` → `${user:subject}` with format *persistent*, and add `email` → `${user:email}` with format *basic*. Submit. (The template maps the SAML attribute `email` to the user pool's `email` attribute; the assistant uses it to put the reporter on CC.)
4. **Assign users and groups** to the application. Assignment is your access-control layer, exactly like application assignment in an OIDC IdP.
5. Update the stack with `SamlMetadataUrl` (and `SamlProviderName` if you want federated usernames prefixed with something other than `IdentityCenter`). The app client now accepts federated sign-in only; the Gateway configuration and the `KiroMcpJson` snippet do not change.

What happens at sign-in: Kiro opens the pool's authorization endpoint, which — because the SAML provider is the only one enabled on the app client — redirects the browser straight to Identity Center without showing a Cognito page (service-provider-initiated SAML). The user authenticates there under your Identity Center policies (including MFA); Cognito then creates or refreshes a profile for them (`<SamlProviderName>_<subject>` with the mapped e-mail) and issues the tokens. `AllowAdminCreateUserOnly` on the pool blocks self sign-up only; federated profiles are always created.

Caveats:

- Organization instances only (see the Identity Center documentation on instance types). If your Identity Center is an account instance, use 1a or 1c.
- Check the instance type directly rather than inferring it from the account it lives in. An organization instance shows **Multi-account permissions** (AWS accounts, Permission sets) in the console navigation pane; on an account instance **Add application** goes straight to the OAuth 2.0 setup wizard and offers no SAML 2.0 option. From the CLI, `aws sso-admin list-permission-sets --instance-arn <instance-arn>` fails with *This operation is not supported for account instances of IAM Identity Center* on an account instance.
- If standalone users with the same e-mail addresses already exist in the pool (for example from an evaluation), delete them before switching to federation or link them with `aws cognito-idp admin-link-provider-for-user`; otherwise their federated sign-in fails with an alias conflict.
- A user removed from the Identity Center application can no longer sign in, but their pool profile remains until you delete it; existing tokens stay valid until they expire (access token 60 min, refresh token 30 days by template default).

### 1c. `Cognito` standalone users

Deploy in `Cognito` mode with `CognitoFirstUserEmail` set to the first user ([Step 3](#step-3--deploy-the-stack)), then add users from a list of e-mail addresses:

```bash
scripts/cognito-add-users.sh --stack support-mcp-agentcore --region us-east-1 users.txt   # one address per line
```

Each user receives a temporary password by e-mail and must set a new one at first sign-in (12+ characters with upper-case, lower-case and digits). Addresses are lower-cased by the script and the pool is case-sensitive, so ask users to type their address in lower case. These users are a **second set of credentials** that is not synchronized with your directory: when someone leaves, disable them in your directory *and* in the pool (`aws cognito-idp admin-disable-user`). This mode suits evaluations and small pilots; for hundreds of users prefer 1a or 1b. Hardening options: enable TOTP MFA on the pool (`MfaConfiguration`), and tighten the password policy in the template.

## Step 2 — Build the code package

```bash
./build.sh          # -> dist/support-mcp-agentcore.zip (Linux arm64, Python 3.12)
```

The package contains `main.py`, the vendored `awslabs/` server and its dependencies. AgentCore Runtime runs it directly from S3 — no container image, no ECR.

## Step 3 — Deploy the stack

Using the helper script (creates a private, versioned S3 bucket if needed):

```bash
# ExternalOIDC
AWS_PROFILE=<profile> AWS_REGION=us-east-1 \
IDP_MODE=ExternalOIDC \
OIDC_DISCOVERY_URL='https://<tenant>/.well-known/openid-configuration' \
OIDC_CLIENT_ID='<client_id>' \
OIDC_AUDIENCE='api://default' \
KIRO_CALLBACK_PORT=8080 \
./deploy.sh

# Cognito, standalone users
AWS_PROFILE=<profile> AWS_REGION=us-east-1 IDP_MODE=Cognito COGNITO_FIRST_USER_EMAIL=you@example.com ./deploy.sh

# Cognito + IAM Identity Center: pass 1 (no SAML), then pass 2 after the SAML application exists (step 1b)
AWS_PROFILE=<profile> AWS_REGION=us-east-1 IDP_MODE=Cognito ./deploy.sh
AWS_PROFILE=<profile> AWS_REGION=us-east-1 IDP_MODE=Cognito \
SAML_METADATA_URL='https://portal.sso.<region>.amazonaws.com/saml/metadata/<id>' ./deploy.sh
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
| `AWS::IAM::Role` *runtime-exec* | Assumed by AgentCore Runtime. The **only** principal with Support permissions: `support:CreateCase`, `DescribeCases`, `DescribeCommunications`, `AddCommunicationToCase`, `ResolveCase`, `AddAttachmentsToSet`, `DescribeAttachment`, plus the read-only catalog calls (`DescribeServices`, `DescribeSeverityLevels`, `DescribeCreateCaseOptions`, `DescribeSupportedLanguages`). Also `s3:GetObject` / `s3:GetObjectVersion` on the code package and CloudWatch Logs / X-Ray / metrics baseline. Trust policy is scoped to `bedrock-agentcore.amazonaws.com` from this account. |
| `AWS::IAM::Role` *gateway* | Assumed by AgentCore Gateway; allows only `bedrock-agentcore:InvokeAgentRuntime` on this Runtime. |
| `AWS::BedrockAgentCore::Runtime` | Hosts the MCP server (protocol `MCP`, public network mode, Python 3.12 code artifact from S3, pinned to the object version when `CodeS3ObjectVersion` is set). |
| `AWS::BedrockAgentCore::Gateway` | MCP gateway with `CUSTOM_JWT` inbound authorizer bound to your IdP (or to the Cognito user pool). |
| `AWS::BedrockAgentCore::GatewayTarget` | Points the Gateway at the Runtime's MCP endpoint using the Gateway role (SigV4). |
| *(Cognito mode only)* Cognito user pool (Essentials tier, admin-created users only), hosted domain, app client (public, PKCE); with `CognitoFirstUserEmail` one user; with `SamlMetadataUrl` a SAML identity provider bound to the app client | Self-contained IdP, standalone or federated to IAM Identity Center. |

No public S3 buckets, no public resource policies, no cross-account trust. Trim the Support permissions further if you like (for example remove `ResolveCase` or the attachment actions). The tools stay listed in Kiro — the upstream server registers all 11 statically — but calls that need a removed action fail with `AccessDeniedException`.

## Step 4 — Distribute the Kiro configuration

The stack output `KiroMcpJson` is a ready-to-paste snippet:

```json
{"mcpServers":{"aws-support":{
  "url":"https://<gateway-id>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
  "oauth":{"clientId":"<client_id>","redirectUri":"localhost:8080","oauthScopes":["openid","email","profile","offline_access"]}
}}}
```

In Cognito mode the snippet omits the `offline_access` scope (Cognito issues refresh tokens without it). Distribution options:

- **Pilot**: hand the snippet to the developers who need it; they add it to `~/.kiro/settings/mcp.json`. See [`kiro/mcp.json.example`](../kiro/mcp.json.example) for a version that also auto-approves the read-only catalog and case-lookup tools.
- **Scale**: publish the server through **Kiro MCP Registry** (Kiro Pro tier with IAM Identity Center) so users pick it from a list instead of editing files. Note that once a registry is active, only registry-listed servers can run — align with your Kiro administrator first.
- Optionally ship [`kiro/steering-aws-support.md`](../kiro/steering-aws-support.md) as team steering. It tells the assistant to look up valid service/category codes, choose severity conservatively, include the Kiro Request ID, and **put the reporter's email on CC** so Support replies reach the developer directly.

## Upgrading a v1.0 stack

- `IdentityProviderMode=DemoCognito` is still accepted. The parameter `DemoUserEmail` was renamed to `CognitoFirstUserEmail`: when you update a v1.0 stack, pass the same address again (or `DEMO_USER_EMAIL` / `COGNITO_FIRST_USER_EMAIL` with `deploy.sh`), otherwise CloudFormation removes the evaluation user.
- Logical resource IDs are unchanged, so the update happens in place: same user pool, domain, app client and Gateway URL — the Kiro snippet keeps working.
- Adding `SamlMetadataUrl` to an existing Cognito-mode stack switches the app client to federated sign-in only (see the caveats in [1b](#1b-cognito--iam-identity-center-saml-20-federation)).

## Operations

- **Logs**: Runtime logs are in CloudWatch under `/aws/bedrock-agentcore/runtimes/<runtime-id>-*`. In Kiro use *Show MCP Logs*. The server logs at `INFO`, set by the Runtime environment variable `FASTMCP_LOG_LEVEL` in the template; switch it to `DEBUG` only while troubleshooting, because debug logs include request parameters such as case IDs and case subjects.
- **Triage**: a `401` from the Gateway means token or IdP configuration; `421`/`5xx` means the Runtime.
- **Upgrade the server**: run `./deploy.sh` again with the same parameters. It uploads the new package and passes the uploaded object's version ID (`CodeS3ObjectVersion`) to the stack, so the Runtime rolls to the new code even though the object key is unchanged. Without the script, pass the new version ID yourself or upload under a new `CodeS3Key`. Every run uploads the package again, and on a versioned bucket (the default for the bucket `deploy.sh` creates) each upload gets a new version ID, so every run rolls the Runtime to a new version even when the code is unchanged. Only on an unversioned bucket with no other parameter change does CloudFormation answer "No updates are to be performed"; the script then exits cleanly.
- **Cost**: AgentCore Runtime bills for active processing time and Gateway per call; there is no always-on charge — see the AgentCore pricing page. In Cognito mode add Amazon Cognito: standalone users have a large free tier, federated (SAML) users a much smaller one (50 monthly active users at the time of writing) before per-user pricing applies — see the Cognito pricing page.
- **Uninstall**: delete the stack (in Cognito mode this deletes the user pool and every profile in it). The S3 bucket you created is yours to remove; note that `deploy.sh` enables versioning on the bucket it creates, so empty all object versions and delete markers (`aws s3api list-object-versions` + `delete-objects`) before `delete-bucket`.
