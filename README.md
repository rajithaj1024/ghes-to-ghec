# GHES ➜ GitHub.com Migration with GitHub Actions (GEI) — Staged Workflow (Supports Data Residency)

This repository provides workflows and scripts to support the migration of repositories and configurations from **GitHub Enterprise Server (GHES)** to **GitHub Enterprise Cloud (GHEC) (Regular and Data Residency)** using **GitHub Actions**. It integrates repository migrations with both **variables** and **environment synchronization** to ensure complete and consistent setup on the target system.

- ✅ **Stage 1 – Pre‑migration validation** (open PRs, queued/running workflows, open issues)
- 🛂 **Stage 1.1 – Manual approval gate** (issue‑based approval before migration)
- 🚀 **Stage 2 – Migration execution** (parallel migrations, max 5 at a time)
- 🔎 **Stage 3 – Post‑migration validation** (branch count, commit count, latest SHA verification)
- 🛂 **Stage 3.1 – Manual approval gate** (issue‑based approval before variable & Environment migration)
- 🚀 **Stage 4 - Vars Migration (GHES → GHEC)

> **Important**: If your GHES instance is reachable only from your corporate network, run this workflow on a **self‑hosted runner** with network access to GHES.

---
## Overview

### Stage 1: Pre‑Migration Validation
Checks include:
- Open Pull Requests
- Queued/Running Workflows
- Open Issues

### Stage 2: Manual Approval Gate
Requires an approval step before proceeding to migration.

### Stage 3: Migration Execution
- Parallel migrations (up to 5 at a time).

### Stage 4: Post‑Migration Validation
Validates:
- Branch Count
- Commit Count
- Latest SHA
---

## Repository layout

```
.github/workflows/
  ghes-ghec-with-vars-issue-based-approval.yml              # Main staged workflow, this workflow uses issue based approval (pre → approval → migrate → post → approval → Vars & Env migration)
  ghe-sghec-with-vars-approver-gate.yml   # same workflow, this perticular one will create a UI based approval (pre → migrate → post → Vars & Env migration)

Use issue based approval worfklow if you want to log the approvals stage as well for future easy referece. otherwsie approver gate can be used.

repos.csv                          # Migration input list (can be generated via inventory scripts)

scripts/
  2_migration-readiness.sh         # Stage 1: pre-migration checks
  3_migration.sh                   # Stage 3: migration runner (parallel)
  4_post-migration-validation.sh   # Stage 4: post-migration validation

  2_migration-readiness.ps1         # Stage 1: pre-migration checks
  3_migration.ps1                   # Stage 3: migration runner (parallel)
  4_post-migration-validation.ps1   # Stage 4: post-migration validation

  1_inventory-report.sh              # Generates repos.csv (inventory)
  1_inventory-report.ps1             # Generates repos.csv (inventory)

  5_ghes-ghec-var-mig.ps1        # GHEC sync script for org/repo/env variables
  5_ghes-ghec-var-mig.sh         # GHEC sync script for org/repo/env variables (Bash)
```

## Key Features

### Migration
- Migrates repositories from GHES to GHEC with GitHub Actions.
- Moves **Actions variables** at both the org and repo levels.
- Syncs **environment variables** and **protection rules** (e.g., required reviewers, wait timers).

### What It Does Not Migrate
- Environment secrets (requires a separate flow).
- Deployment branch/tag restrictions.
- Some custom protection rules.

### Note:
- login gh first using gh auth login --hostname <ghes-url>  (otherwise script wont run(only if script run outside | in pipeline this is taken care automatically)
- stage 4(migrate vars & env) requires you to manually add the reviewer column and we should add the reviewer handle in the column, but only if you need to migrate protection rules if not needed then can skip adding the column.
- Environment protection rule migration is only supported for Enterprise accounts (both private and public repositories), and for public repositories in regular accounts.

---

## Required secrets

Create these repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Used for |
|---|---|
| `GH_TARGET_HOST` | Add this as a secret only for Data Residency–enabled GHEC instances (e.g., `maayon-enterprise.ghe.com`) |
| `GH_PAT` | Target GitHub token (destination org; needs migrator/owner access) |
| `GH_SOURCE_PAT` | Source GHES token |
| `GHES_API_URL` | GHES REST API base URL, e.g. `https://ghe.example.com/api/v3` |

---
## Approval
`Important`

- Create the migration-approval Environment: The migration job is gated by a required reviewer. Go to Settings → Environments → New environment, name it exactly: migration-approval
- Then add one or more Required reviewers - the migration job will pause and wait for approval before running.
- If a customer wants every approval stage to be logged and summarized—including who approved the migration, when it was approved, and any comments if the migration approval was postponed—then issue-based approval is more suitable.
---

## Inventory (generate repos.csv)

This repository includes:
- `1_inventory-report.sh`
- `1_inventory-report.ps1`

Use these scripts to generate a `repos.csv` inventory file, then commit it before running the migration workflow.

---

## repos.csv format

The scripts expect the following header names (order can vary; extra columns are allowed):

```csv
ghes_org,ghes_repo,repo_url,repo_size_MB,github_org,github_repo,gh_repo_visibility,reviewer
```

Required columns for migration:
- `ghes_org`, `ghes_repo` (source)
- `github_org`, `github_repo`, `gh_repo_visibility` (target)
- `reviewer` (for protection rule migration in ENV)

---
## Running the workflow

1. Generate or update `repos.csv` and commit it to the repository.
2. Go to **Actions → ghes-to-github-migration (staged) or (with vars) → Run workflow**.
   -  (staged) - will not migrate Org/Repo vars & Environments
   -  (With Vars) - will migrate Org/Repo vars & Environments and Protection rule.
3. Provide workflow inputs:
   - `runner selectopr` : Runner selector. Use ubuntu-latest for GitHub-hosted. eg["self-hosted","linux","x64","ghes-migration"].
   - `csv_path`: path to your CSV (default: `repos.csv`)
   - `max_concurrent`: keep `≤ 5`
   - `approver`: GitHub username(s) who must approve the migration gate
4. Select stage toggles as required:
   - `run_pre_validation`
   - `require_approval`
   - `run_migration`
   - `run_post_validation`
   - `migrate org/repo/env`

### Manual approval gate

If `require_approval=true`, the workflow creates an approval issue and **waits** until the approver approves before starting migration of repo and vars/env.

---

## Workflow summaries

Each stage publishes a **Job Summary** in the Actions run UI:

### Pre‑migration summary
- Consolidated counts (repos processed, repos with PRs, workflows, issues)
- **Repo‑wise table** with ✅ / ⚠️ indicators

### Migration summary
- Overall success/failure counts
- **Repo‑wise results table**
- **Clickable GitHub links** for successfully migrated repositories

### Post‑migration validation summary
- **Repo‑wise table** showing ✅ / ❌ for:
  - Branch count match
  - Commit count match
  - SHA match
- Collapsible section with per‑branch mismatch details

### Vars Migration (GHES → GHEC) summary
- Execution status
- Repositories processed
- Org Variables
- Repo Variables
- Environment Rules
- Environment Variables
- Failure point (if any)

---

## Artifacts

Each run uploads artifacts for traceability:

- `precheck.log`
- `repo_migration_output.csv`
- `migration-*.txt`
- `post_validation.log`
- `validation-log-*.txt`, `validation-*.json`
- `vars_migration.log`
---

## Troubleshooting

- **Approval gate does not pause**: ensure `require_approval=true` and a valid `approver` is provided.
- **Cannot reach GHES**: use a self‑hosted runner with network access.
- **401 / 403 errors**: verify PAT scopes and SSO authorization.
- **CSV not found**: workflow copies `csv_path` to `scripts/repos.csv` for pre/post scripts.
- **Post‑validation mismatches**: review repo‑wise summary and validation logs.

### Common Issues:
- **Approval Gate**: Ensure `require_approval=true` and a valid approver.
- **Access Errors**: Verify PATs and scope permissions.
- **Sync Issues**: Double-check required reviewers and their access levels.

---

## License

Add a license if you plan to publish or distribute this repository.
