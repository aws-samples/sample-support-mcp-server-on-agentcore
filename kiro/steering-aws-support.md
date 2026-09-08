---
inclusion: auto
---
# Opening AWS Support cases from Kiro (aws-support MCP)

Use the `aws-support___*` tools when the user reports an AWS/Kiro service problem that
needs AWS Support (not a Kiro product bug — those go via Kiro "Report Issue" → GitHub).

Workflow:
1. Call `aws-support___describe_services` once to get valid `service_code` / `category_code`.
   For Kiro-related issues use the Kiro service entry if present; otherwise `general-info` / `using-aws`.
2. Pick `severity_code` conservatively: `low` (general guidance) or `normal` (system impaired);
   only use `high`/`urgent`/`critical` when production is down and the user confirms.
3. Always include in `communication_body`:
   - Reporter: the user's name and corporate email (ask if unknown)
   - Kiro version, OS, model selected, exact error text, and the **Request ID** shown by Kiro
   - Timestamps (with timezone) and steps to reproduce
4. Put the user's email in `cc_email_addresses` so AWS Support replies reach them directly.
5. Read back the returned case ID and the Support Center URL. Do not resolve cases without
   explicit confirmation.
