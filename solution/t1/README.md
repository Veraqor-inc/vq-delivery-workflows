# Template T1 "Web + API"

A solution's website (Azure Static Web Apps, Standard), its API (Azure Functions, Flex Consumption), a private
Azure SQL database, Key Vault and storage, for one environment (`dev`, `qa`, `uat` or `prod`). Design:
`team/m12-customer-delivery.md` sections 5.1, 5.5 and 6.

## Files

| File | Who runs it | What it does |
|---|---|---|
| `landing.bicep` | The environment owner, once, in the **identity** resource group | Creates the app, migration, site and deploy identities; the deploy identity's one federated credential, **only** if the dry-run subject is exactly the expected one; lets the deploy identity attach the other three (Managed Identity Operator, nothing more) |
| `deploy-role.bicep` | The environment owner, once, in the **solution** resource group | The deploy identity's custom role (the template's resource types only; never grants, keys, settings or SQL admin) and its one assignment |
| `main.bicep` | The platform deploy workflow, on every deploy, in the **solution** resource group | Everything else. It grants nothing and holds no secret |
| `grants.bicep` | The environment owner, once, after the first deploy | The app and migration identities' data-plane roles, each on one resource or container; the SQL admin group |
| `params/<env>.bicepparam` | Read by the deploy workflow | Per-environment sizes; every identifier comes from that GitHub environment's variables |
| `site/staticwebapp.config.json` | Copied over the site by the deploy workflow | Entra sign-in on every route, `/api/*` included, through the site's managed identity (no secret); GitHub and X sign-in switched off |

## Check it on your own computer (nothing is deployed)

1. Install the Azure CLI, then run `az bicep install` once.
2. From the repository root: `npm run infra:build`. It compiles every template, these four included, with `az bicep build`. It makes no Azure call.
3. Run `npm test`. `test/infra-t1.test.ts` checks the security rules in these files, and `test/release-workflows.test.ts` checks the workflows that deploy them.

## Landing one environment (the owner's steps, in order)

1. Create two resource groups: `rg-<solution>-<env>` (the solution) and `rg-<solution>-<env>-id` (the identities).
2. Set the solution repository's OIDC subject customisation to the immutable-ID `repo`, `context` and `job_workflow_ref` claims. Run the OIDC dry run for the repository and environment, and copy the exact subject GitHub issues. Do not type it by hand. It has this shape:
   `repo:<owner>@<owner ID>/<repo>@<repo ID>:environment:<env>:job_workflow_ref:<platform owner>/<platform repo>/.github/workflows/deploy.yml@<40-hex commit>`
3. Deploy `landing.bicep` into the identity group with `environmentName`, `solution`, `deploySubject` (the dry-run string) and its parts: `repositoryOwner`, `repositoryOwnerId`, `repositoryName`, `repositoryId`, `platformRepository` and `platformSha`. The deployment **fails** if the dry-run subject is not exactly the one composed from the parts (for example, no `environment`, no `job_workflow_ref`, a branch instead of a commit, a wildcard). Its `jobWorkflowRef` output must be in the gate's `RELEASE_GATE_DEPLOY_WORKFLOWS`.
4. Deploy `deploy-role.bicep` into the solution group with `environmentName`, `solution` and `deployIdentityPrincipalId` (from step 3). It creates the custom role and assigns it to the deploy identity on that group only. It excludes `Microsoft.Authorization/*`, federated-credential writes, SQL admin, `azureADOnlyAuthentications` and firewall writes, storage `listKeys` and SAS, and Web `config/list`, `publishxml` and `host/listkeys` (Omar S12-5c, P2A-4).
5. Create an Entra app registration for the migration runner, with the Application ID URI `api://<its client ID>` and one application role. Turn **"Assignment required"** on for its enterprise application, and assign that role to the deploy identity only (P2A-13).
6. Create the sign-in app registration for the site, with the redirect URI `https://<site host>/.auth/login/aad/callback`. Add **no client secret**. Instead add a **federated credential** that trusts the site identity: issuer `https://login.microsoftonline.com/<tenant ID>/v2.0`, subject = the site identity's principal (object) ID from step 3, audience `api://AzureADTokenExchange` (Microsoft Learn, "Custom authentication in Azure Static Web Apps", managed identity instead of a secret; Omar P2A-6). Turn "Assignment required" on and assign the people or groups who may sign in (P2A-15).
7. Set the GitHub environment's variables: `AZURE_CLIENT_ID` (the deploy identity), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `T1_RESOURCE_GROUP`, `T1_SOLUTION`, `T1_IDENTITY_RESOURCE_GROUP`, `T1_APP_IDENTITY_NAME`, `T1_MIGRATION_IDENTITY_NAME`, `T1_SITE_IDENTITY_NAME`, `T1_DEPLOY_PRINCIPAL_ID` (the deploy identity's object ID), `T1_MIGRATION_AUTH_CLIENT_ID`, `T1_SITE_AUTH_CLIENT_ID` (the sign-in app registration), `T1_SQL_ADMIN_GROUP_ID` and `T1_SQL_ADMIN_GROUP_NAME`. **Also set `T1_LOCATION`, `T1_API_RUNTIME`, `T1_API_RUNTIME_VERSION` and `T1_VNET_PREFIX`:** a GitHub variable that is not set reaches the deploy job as an empty value, and Bicep then uses the empty value, not the default (checked with `az bicep build-params`). `T1_NONPROD_DATABASE` (dev and qa: `free`, `basic` or `serverless`) is the one that may be left unset; it then means `free`. Use `basic` or `serverless` when the subscription has already used its free databases. None of these values is secret. The gate, release store and verifier addresses are **not** variables: they are fixed in the platform deploy workflow (P2A-1).
8. Run the first deploy through the pipeline. It sets the site's two sign-in settings itself (`ENTRA_CLIENT_ID` and `OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID`, both client IDs). Then deploy `grants.bicep` into the solution group, using the names from that deploy's outputs.
9. Create the database users **inside the VNet**. SQL is private, so no PC can reach it (spike G9 gotcha 4). Use a Bastion or jump host, or have a member of the SQL admin group run it once through the migration runner:
   ```sql
   CREATE USER [id-<solution>-<env>-app] FROM EXTERNAL PROVIDER;   -- or WITH SID = <client ID as binary>, TYPE = E
   ALTER ROLE db_datareader ADD MEMBER [id-<solution>-<env>-app];
   ALTER ROLE db_datawriter ADD MEMBER [id-<solution>-<env>-app];
   CREATE USER [id-<solution>-<env>-migrate] FROM EXTERNAL PROVIDER;
   ALTER ROLE db_ddladmin ADD MEMBER [id-<solution>-<env>-migrate];
   ALTER ROLE db_datareader ADD MEMBER [id-<solution>-<env>-migrate];
   ALTER ROLE db_datawriter ADD MEMBER [id-<solution>-<env>-migrate];
   ```
10. Production only: turn on Defender for Key Vault and Defender for Storage on the subscription (section 10.5).

### Read-back before the rehearsals (Omar, before D9)

- The federated subject read back from Azure passes `checkDeploySubject` (engine, `packages/engine/src/release/subject.ts`) for its environment and the gate's `RELEASE_GATE_DEPLOY_WORKFLOWS`.
- The custom role read back (`az role definition list --name <roleName>`) has the `actions` and `notActions` of `deploy-role.bicep`.
- No identity has a blob role on the whole host account (`az role assignment list --scope <host account ID>` shows only the two Queue Data Contributor assignments).

### D9 probe: settings written INSIDE an allowed parent write (Aisha's question, M12 P2 QA; Omar P2A-5)

The deploy role excludes the dedicated child writes (`Microsoft.KeyVault/vaults/accessPolicies/write`,
`Microsoft.Sql/servers/administrators/write`, `azureADOnlyAuthentications/write`), but it allows the parent writes
`Microsoft.KeyVault/vaults/*` and `Microsoft.Sql/servers/*`, because `main.bicep` creates the vault and the server.
A parent write can carry the same settings **inline**: a vault PUT with `enableRbacAuthorization: false` and an
`accessPolicies` list, or a server PUT with an `administrators` block. An Azure role checks the operation, never the
properties inside it, so `notActions` cannot stop this. (Spike G9 found that a server's inline `administrators` is
applied only when the server is created; a create of a NEW server with the deploy identity as its admin is still
possible, and that is not proven for every API version.) No role-level change closes this without taking the vault
and server writes away from the pipeline, which would move their creation to an owner step; that is a design change
for Omar, not part of this round.

**What closes it is the owner-assigned Azure Policy deny of P2A-5**, which must therefore cover these inline
properties too, on every solution resource group (internal ones included):

- Key Vault: deny `enableRbacAuthorization` other than `true` (this also makes any inline `accessPolicies` dead
  letters), and deny a non-empty `accessPolicies` list.
- SQL: deny a server whose `administrators.azureADOnlyAuthentication` is not `true`, and deny an `administrators`
  `sid` other than the environment's SQL admin group (one assignment per group, with the group's object ID as the
  parameter). Elena confirms the policy aliases exist for the inline `administrators` properties; if one does not,
  she reports it to Omar before P4.

**The D9 `no-standing-rights` probe adds two cases**, run on a scratch resource group with the same custom role
assigned to a test identity (never on a real environment), first without and then with the P2A-5 policy assigned:

1. As the deploy identity, PUT the vault with `enableRbacAuthorization: false` and an access policy for itself.
2. As the deploy identity, PUT a SQL server with an `administrators` block naming itself (and, separately, an update
   of the existing server's `administrators`).

Expected: without the policy, record what Azure allows (this is the gap). With the policy, every case is **denied**
(`RequestDisallowedByPolicy`). The evidence (commands and responses, no tokens) goes into the D9 notes.

### Site sign-in fallback (only if the managed-identity route fails in a rehearsal, and only with Omar's agreement in writing)

Omar's ruling 5: one client secret per environment, created by the owner, valid for at most 90 days, held **only** as
the Static Web App's application setting (never in GitHub, files or chat), rotated before it expires with an expiry
alert to Farrukh and Elena, and the old secret deleted from the app registration. A Key Vault reference is **not** a
fallback here: the Static Web App reads the vault from outside the VNet, and T1's vault is private. Switching to the
fallback changes `clientSecretSettingName` in `site/staticwebapp.config.json`, which is a reviewed platform change.

## What the migration runner must do (the solution's code)

The migration runner is the solution's own `migrate` project. It is a Function with one HTTP route,
`POST /api/migrate`, body `{ "digest", "environment" }`. It applies forward-only migrations as the migration
identity (`AZURE_CLIENT_ID`, `SQL_SERVER`, `SQL_DATABASE`). It answers `{ "ok": true, "applied": <n> }`, or
`{ "ok": false, "message": "..." }` with a non-200 status. Easy Auth already refuses every caller except this
environment's deploy identity (its client application and its object ID); a signed-out call gets 401, which the
deploy job's smoke test checks.
