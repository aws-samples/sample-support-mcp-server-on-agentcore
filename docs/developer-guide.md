> Part of [AWS Support MCP Server on Amazon Bedrock AgentCore](../README.md). Other guides: [Deployment guide](deployment-guide.md) · [Developer guide](developer-guide.md) · [Security](security.md)

# Developer guide (using it from Kiro)

You need: Kiro, your corporate account, and the `aws-support` entry in your Kiro MCP configuration (provided by IT or selected from the Kiro MCP Registry). You do **not** need AWS credentials, an IAM user, or Console access.

## One-time: sign in

1. Add the snippet from IT to `~/.kiro/settings/mcp.json` (or select the server in the registry).
2. Open Kiro's **MCP Servers** panel, find `aws-support`, and click **Authenticate**. A browser window opens. Depending on how IT set it up you see one of:
   - your company's own sign-in page (corporate IdP such as Okta or Entra ID);
   - the AWS access portal (IAM Identity Center) directly — sign in there as you do for Kiro itself;
   - an Amazon Cognito page asking for e-mail and password — use the temporary password IT e-mailed you (type your address in lower case); the first sign-in asks you to set a new one.
3. After signing in you are redirected back to Kiro. The server shows as connected and lists 11 `aws-support___*` tools. The token is stored in Kiro's secret storage and refreshed automatically.

> Kiro does **not** open the browser on its own at startup for OAuth-protected servers — until you click **Authenticate** the server appears unauthenticated or disconnected. This is a one-time step.

> Kiro waits about 60 seconds for the browser sign-in to finish. A first Cognito sign-in that includes setting a new password can take longer; if the browser then shows *localhost refused to connect*, close that tab and click **Authenticate** once more — you are already signed in, so it completes in a few seconds. Click **Authenticate** once and use only the most recently opened sign-in tab.

## Submit a case

Describe the problem in the Kiro chat, for example:

> Open an AWS Support case: since this morning Kiro returns "model 'auto' not available" for everyone on my team. Request ID abc-123. Severity: system impaired. Put my email me@example.com on CC.

The assistant will:

1. Call `aws-support___describe_services` to pick a valid service/category code and choose a severity code conservatively (the steering file lists them).
2. Call `aws-support___create_support_case` with the subject, a body that includes your name, email, environment details and Request ID, and your email in `cc_email_addresses`.
3. Read back the **case ID** and the Support Center link.

Write tools (`create_support_case`, `add_communication_to_case`, `resolve_support_case`, `add_attachments_to_set`) ask for your confirmation before running unless you auto-approve them; the read-only tools can be auto-approved (see the example config).

## Monitor a case

- Ask Kiro: *"List my open AWS Support cases"* → `aws-support___describe_support_cases` (filter by status, time range, or case ID).
- Ask: *"Show the latest reply on case 1234567890"* → `aws-support___describe_communications` returns the correspondence thread.
- **Email**: AWS Support copies every correspondence to the addresses on the case's CC list (`ccEmailAddresses`, up to 10). If your email was added at creation time, you receive each Support reply in your inbox without opening Kiro. The AWS account's contact email also receives case notifications — that is standard Support behavior and is why a shared mailbox is recommended for the account email.

## Reply to or close a case

- *"Reply on case 1234567890: here are the logs you asked for ..."* → `aws-support___add_communication_to_case` (you can add CC addresses again here).
- *"Resolve case 1234567890"* → `aws-support___resolve_support_case` (the steering file asks the assistant to confirm first).

## What to expect

- Cases created through the API use the **web** contact method. If you need a phone or chat session, ask Support in the case or use the Support Center.
- The case's *Submitted by* field shows the shared execution role, not your name. Your identity is carried in the case body and the CC list, which is what Support engineers use to communicate with you.
- Kiro product bugs (crashes, UI issues) should still go through Kiro's **Report Issue** button, which files a GitHub issue with the Request ID for the Kiro team.

## Known client-side pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| After setting a new password the browser shows *localhost refused to connect*, or a later tab says *This authorization request has expired or already completed* | Kiro stopped waiting (about 60 s) before the first sign-in finished, or an older sign-in tab completed after a newer one | Close all sign-in tabs and click **Authenticate** once; the second attempt completes in seconds because you are already signed in. |
| Browser opens, but the redirect fails or times out after ~60 s | `oauth.redirectUri` in `mcp.json` was written as a full URL. Kiro IDE expects **`host:port`** (e.g. `localhost:8080`) and falls back to a random port otherwise, which no longer matches the IdP registration. | Use `"redirectUri": "localhost:<port>"`. The IdP keeps the full `http://localhost:<port>/oauth/callback`. |
| Server shows *disconnected* right after Kiro starts and nothing happens | Kiro starts OAuth servers passively and only opens the browser when you trigger authentication. | Click **Authenticate** in the MCP Servers panel once. |
| Sign-in through IAM Identity Center succeeds but the Cognito page then shows an error, or the browser never returns to Kiro | You are not assigned to the *AWS Support from Kiro* application in Identity Center, or a standalone user with your e-mail address still exists in the pool. | Ask IT to assign you to the application (and to remove or link the old standalone user). |
| After clicking Authenticate the browser lands on an IdP error page (e.g. `BadRequest`), and Kiro's log shows *Opening authorization URL* a minute late | Kiro's discovery requests to the IdP went out over IPv6 and hung. Some VPN clients install an unreachable IPv6 default route; most IdPs publish AAAA records. | Check with `curl -6 -m 5 https://<idp-host>/`. If it hangs, disconnect the VPN or have IT fix the IPv6 route policy. |
