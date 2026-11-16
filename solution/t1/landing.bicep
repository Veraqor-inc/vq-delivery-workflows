// Template T1, landing step 1 (run ONCE per solution per environment by the environment OWNER, never by the
// pipeline; Omar S12-5b and S12-5d, design 6.4 and 7.2). Deploy it into the separate IDENTITY resource group.
//
// It creates the four identities of one environment:
//   - the APP identity: the API's runtime identity (its roles come from grants.bicep);
//   - the MIGRATION identity: DDL on this environment's one database only (its SQL user is made in the VNet);
//   - the SITE identity: assigned ONLY to the Static Web App. The site's sign-in app registration trusts it as a
//     federated credential, so site sign-in needs no client secret (Omar P2A-6; README step 6);
//   - the DEPLOY identity: the only identity the platform's deploy workflow signs in as, through ONE federated
//     credential whose subject is the exact string from the OIDC dry run (never typed by hand, no wildcard).
//
// The deploy subject is CHECKED here (Omar P2A-4): this file composes the exact subject from its parts (immutable
// owner and repository IDs, environment:<env>, job_workflow_ref = the platform deploy workflow at a full commit
// SHA) and creates the credential only when the dry-run subject is that string, character for character. Any
// other subject (missing environment or job_workflow_ref, a branch ref, a wildcard, a typo) fails the deployment.
//
// The deploy identity gets exactly one right here: Managed Identity Operator on the app, migration and site
// identities, so a deploy can attach them. That role has no federated-credential write, so the deploy identity can
// neither add a credential to itself or to them, nor grant anything (S12-5c). Its own custom role on the solution
// group is deploy-role.bicep (an owner step, README "Landing").

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
param solution string

param location string = 'centralus'

@description('The exact OIDC subject from the dry run for the platform deploy workflow in this repository and environment. It must equal the subject composed from the parts below.')
param deploySubject string

@minLength(1)
@maxLength(39)
@description('The solution repository\'s owner (GitHub organisation) name.')
param repositoryOwner string

@minLength(1)
@maxLength(20)
@description('The owner\'s numeric GitHub ID (immutable).')
param repositoryOwnerId string

@minLength(1)
@maxLength(100)
@description('The solution repository\'s name.')
param repositoryName string

@minLength(1)
@maxLength(20)
@description('The repository\'s numeric GitHub ID (immutable).')
param repositoryId string

@minLength(3)
@maxLength(140)
@description('owner/name of the platform workflow repository.')
param platformRepository string

@minLength(40)
@maxLength(40)
@description('The full commit SHA the solution calls the platform deploy workflow at (its job_workflow_ref).')
param platformSha string

@description('GitHub\'s token issuer.')
param deployIssuer string = 'https://token.actions.githubusercontent.com'

param extraTags object = {}

var base = '${solution}-${environmentName}'
var tags = union(extraTags, {
  solution: solution
  environment: environmentName
  template: 't1'
  'managed-by': 'environment-owner'
})

// ---------- The deploy subject, composed and checked (P2A-4; mirrors checkDeploySubject in the engine) ----------
var digits = '0123456789'
var hex = '0123456789abcdef'
var ownerChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-'
var repoChars = '${ownerChars}._'

@description('True when value is not empty and every character of it is in allowed.')
func onlyChars(value string, allowed string) bool => !empty(value) && empty(filter(map(range(0, length(value)), i => substring(value, i, 1)), c => !contains(allowed, c)))

var platformParts = split(platformRepository, '/')
var jobWorkflowRef = '${platformRepository}/.github/workflows/deploy.yml@${platformSha}'
var expectedSubject = 'repo:${repositoryOwner}@${repositoryOwnerId}/${repositoryName}@${repositoryId}:environment:${environmentName}:job_workflow_ref:${jobWorkflowRef}'

var subjectChecks = [
  { ok: onlyChars(repositoryOwner, ownerChars), problem: 'repositoryOwner is not a GitHub owner name' }
  { ok: onlyChars(repositoryOwnerId, digits), problem: 'repositoryOwnerId is not a numeric ID' }
  { ok: onlyChars(repositoryName, repoChars), problem: 'repositoryName is not a GitHub repository name' }
  { ok: onlyChars(repositoryId, digits), problem: 'repositoryId is not a numeric ID' }
  { ok: length(platformParts) == 2 && onlyChars(first(platformParts), ownerChars) && onlyChars(last(platformParts), repoChars), problem: 'platformRepository is not owner/name' }
  { ok: onlyChars(platformSha, hex), problem: 'platformSha is not a full lower-case commit SHA' }
  { ok: deploySubject == expectedSubject, problem: 'deploySubject is not exactly the expected subject (immutable IDs, environment, platform deploy workflow at its commit)' }
]
var subjectProblems = map(filter(subjectChecks, c => !c.ok), c => c.problem)
// ARM evaluates only the branch taken: with any problem, json() of a non-JSON message fails the deployment
// before the credential exists, and the error carries the message.
var checkedSubject = empty(subjectProblems) ? deploySubject : json('deploy subject refused: ${join(subjectProblems, '; ')}')

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-app'
  location: location
  tags: tags
}

resource migrationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-migrate'
  location: location
  tags: tags
}

resource siteIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-site'
  location: location
  tags: tags
}

resource deployIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${base}-deploy'
  location: location
  tags: tags
}

resource deployCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deployIdentity
  name: 'github-deploy-${environmentName}'
  properties: {
    issuer: deployIssuer
    subject: checkedSubject
    audiences: ['api://AzureADTokenExchange']
  }
}

// Managed Identity Operator: read and assign only (no federatedIdentityCredentials/write).
var managedIdentityOperator = 'f1a07417-d97a-45cb-824c-7a7467783830'

resource deployMayAssignApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appIdentity
  name: guid(appIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignMigration 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: migrationIdentity
  name: guid(migrationIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

resource deployMayAssignSite 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: siteIdentity
  name: guid(siteIdentity.id, deployIdentity.id, managedIdentityOperator)
  properties: {
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
  }
}

output appIdentityName string = appIdentity.name
output appIdentityPrincipalId string = appIdentity.properties.principalId
output appIdentityClientId string = appIdentity.properties.clientId
output migrationIdentityName string = migrationIdentity.name
output migrationIdentityPrincipalId string = migrationIdentity.properties.principalId
output migrationIdentityClientId string = migrationIdentity.properties.clientId
output siteIdentityName string = siteIdentity.name
output siteIdentityPrincipalId string = siteIdentity.properties.principalId
output siteIdentityClientId string = siteIdentity.properties.clientId
output deployIdentityClientId string = deployIdentity.properties.clientId
output deployIdentityPrincipalId string = deployIdentity.properties.principalId
// For the read-back: this must be in the gate's RELEASE_GATE_DEPLOY_WORKFLOWS.
output jobWorkflowRef string = jobWorkflowRef
output deploySubject string = deployCredential.properties.subject
