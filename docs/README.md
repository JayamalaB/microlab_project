# MicroLab documentation

Start with the [project README](../README.md), then read in this order:

| # | Document | Status |
|---|---|---|
| 1 | [Architecture overview](architecture/overview.md): systems, server structure, login, the main flows, socket events, jobs, troubleshooting | ✅ Draft |
| 2 | [Data dictionary](database/data-dictionary.md): tables, columns, statuses, `ip_settings`, migrations | ✅ Draft (confirm against a schema dump) |
| 3 | `onboarding.md`: first-week checklist | ⏳ To write |
| 4 | `runbooks/deploy-vps.md`, `runbooks/run-migration.md`, `runbooks/troubleshoot-dispatch.md` | ⏳ To write |
| 5 | `api/openapi.yaml` (REST) and `api/socket-events.md` | ⏳ To write |
| 6 | `integrations/asmx.md`, `razorpay.md`, `google-maps.md`, `sms.md` | ⏳ To write |
| 7 | `decisions/`: one ADR per decision (see the overview, §10) | ⏳ To write |
| 8 | `glossary.md` (the overview's §4 is the start of it) | ⏳ To write |

## Rules for these docs

- **Docs change in the same PR as the code.** A new table, column, endpoint, setting or flow means an update here.
- **Never put secret values here:** no keys, passwords, tokens, OTPs, `.env` values or real patient data. Name the variable instead (for example "`RAZORPAY_KEY_SECRET` in `server/.env`").
- Keep diagrams in Mermaid, inside the Markdown, so they can be diffed and reviewed.
- If something here is wrong, fix it. Don't work around it.
