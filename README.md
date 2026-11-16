# vq-delivery-workflows

Veraqor's platform-owned delivery workflows. Solution repositories call them by **full commit SHA**; nobody calls them by branch or tag.

| Path | What it is |
|---|---|
| `.github/workflows/build-and-test.yml` | Reusable CI for pull requests: no identity, `npm ci --ignore-scripts`, tests, a JUnit/trx report as the `test-report` artifact |
| `.github/workflows/release.yml` | Reusable release: builds `release.tar` once on a push to `main` (no identity), then a separate job attests its provenance and SBOM |
| `.github/workflows/deploy.yml` | Reusable deploy, one environment per run: checks itself, asks the release gate (uat, prod), verifies the digest and the attestation, deploys template T1 under the environment's own OIDC identity, runs migrations, deploys the API and the site, smoke-tests signed out |
| `solution/t1/` | Template T1 "Web + API" (Bicep), checked out by `deploy.yml` at the same commit. `main.bicep` and `params/` are used by the pipeline; `landing.bicep`, `deploy-role.bicep` and `grants.bicep` are the environment owner's one-time steps (see `solution/t1/README.md`) |

## Rules

- Every change here is a new commit. A solution only uses it once its caller workflow names that commit, and the Azure federated subjects and the release gate's allow-list name it too.
- `deploy.yml` holds the release gate and release store addresses and audiences as fixed constants. They are not secrets.
- Nothing in this repository is secret. No secrets are used by any workflow.
