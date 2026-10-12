# Changelog

## v1.2 — Identity Center federation, Cognito mode, dependency updates

- **IAM Identity Center support** (Cognito mode): set `SamlMetadataUrl` (and optionally `SamlProviderName`) to federate the template's Cognito user pool to a customer managed SAML 2.0 application in IAM Identity Center — organization instances only — or to any other SAML 2.0 IdP. New outputs `CognitoUserPoolId`, `CognitoSamlAcsUrl`, `CognitoSamlAudience` provide the values the Identity Center application needs. Two-pass deployment; see the deployment guide, step 1b.
- `IdentityProviderMode=Cognito` replaces `DemoCognito` (the old value is still accepted). Parameter `DemoUserEmail` is renamed `CognitoFirstUserEmail` (`deploy.sh` still honours `DEMO_USER_EMAIL`). Resource logical IDs are unchanged, so v1.0 stacks update in place.
- New `scripts/cognito-add-users.sh`: create standalone Cognito users from a list of e-mail addresses (temporary password by e-mail; `--resend`, `--dry-run`).
- `deploy.sh` passes the uploaded object's S3 version ID (`CodeS3ObjectVersion`) to the stack, so re-deploying under the same key rolls the Runtime to the new package; "No updates are to be performed" now exits cleanly.
- `kiro/mcp.json.example` also auto-approves `describe_attachment` (read-only).
- `app/main.py` sets the server's log level to `INFO` (from `FASTMCP_LOG_LEVEL`), matching the upstream server's default. v1.0 bypassed the upstream `main()` and therefore logged at `DEBUG`, which writes request parameters such as case IDs and subjects to CloudWatch.
- Dependencies: `pyjwt` 2.13.0 → 2.15.1 and `urllib3` 2.7.0 → 2.8.0 in `app/requirements.lock` (published security advisories); no other package changes.
- Documentation: identity-mode comparison, Identity Center walkthrough (including how to check the instance type), upgrade notes, Cognito security notes (English and Simplified Chinese).

## v1.1 — documentation

- README split into role-based guides (`docs/deployment-guide.md`, `docs/developer-guide.md`, `docs/security.md`) plus a Simplified Chinese translation (`README.zh-CN.md`, `docs/zh-CN/`).
- `kiro/steering-aws-support.md`: `name` / `description` front-matter required by Kiro for `inclusion: auto`.

## v1.0 — 2026-09-18

- Initial public release: AWS Support MCP Server on AgentCore Runtime behind an AgentCore Gateway (`CUSTOM_JWT`), one CloudFormation template, `ExternalOIDC` and evaluation (`DemoCognito`) identity modes, Kiro configuration and steering samples.
