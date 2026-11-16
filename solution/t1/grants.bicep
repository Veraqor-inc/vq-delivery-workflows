// Template T1, landing step 3 (run ONCE per environment by the environment OWNER after the first pipeline deploy
// of main.bicep, never by the pipeline; Omar S12-5d, design 6.4). Deploy it into the SOLUTION resource group.
//
// The app identity's and migration identity's Azure roles, each scoped to one resource (never the group), and on
// the shared Functions HOST account never to the whole account for blobs (Omar P2A-2):
//   app identity:       Blob Data Owner on its own deployment container "api-package" and on the two host
//                       containers "azure-webjobs-hosts" and "azure-webjobs-secrets"; Queue Data Contributor on
//                       the host account; Blob Data Contributor on the data account's "data" container only;
//                       Key Vault Secrets User on the vault; Monitoring Metrics Publisher on Application Insights;
//   migration identity: Blob Data Owner on its own deployment container "migrate-package" and on the two host
//                       containers; Queue Data Contributor on the host account; Monitoring Metrics Publisher.
//                       Its DDL right is a SQL role on the one database (README "Landing"), never an Azure role.
// So the API cannot write the migration runner's package (and the runner cannot write the API's). The two host
// containers stay shared, because both Function Apps use the one host account; Easy Auth, not host keys, guards
// the runner. The preferred, separate host account for the runner is a decision for Farrukh (build notes).
// The site identity gets no Azure role at all. The SQL Entra admin GROUP is set here too: the inline admin in
// main.bicep applies only when the server is first created (spike G9 gotcha 5), and the deploy identity may not
// write SQL admins (S12-5c).

targetScope = 'resourceGroup'

param appIdentityPrincipalId string
param migrationIdentityPrincipalId string
param hostStorageName string
param dataStorageName string
param keyVaultName string
param appInsightsName string
param sqlServerName string
param sqlAdminGroupObjectId string
param sqlAdminGroupName string

var roles = {
  blobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  blobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  queueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  kvSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  metricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: hostStorageName
}

resource hostBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: hostStorage
  name: 'default'
}

resource apiPackage 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: hostBlob
  name: 'api-package'
}

resource migratePackage 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: hostBlob
  name: 'migrate-package'
}

resource webjobsHosts 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: hostBlob
  name: 'azure-webjobs-hosts'
}

resource webjobsSecrets 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: hostBlob
  name: 'azure-webjobs-secrets'
}

resource dataStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: dataStorageName
}

resource dataBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: dataStorage
  name: 'default'
}

resource dataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: dataBlob
  name: 'data'
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource sql 'Microsoft.Sql/servers@2023-08-01-preview' existing = {
  name: sqlServerName
}

resource sqlAdmin 'Microsoft.Sql/servers/administrators@2023-08-01-preview' = {
  parent: sql
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: sqlAdminGroupName
    sid: sqlAdminGroupObjectId
    tenantId: subscription().tenantId
  }
}

func ra(scopeId string, principalId string, role string) object => {
  name: guid(scopeId, principalId, role)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
  }
}

// ---------- App identity ----------
resource appPackageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apiPackage
  name: ra(apiPackage.id, appIdentityPrincipalId, roles.blobDataOwner).name
  properties: ra(apiPackage.id, appIdentityPrincipalId, roles.blobDataOwner).properties
}

resource appHostsBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: webjobsHosts
  name: ra(webjobsHosts.id, appIdentityPrincipalId, roles.blobDataOwner).name
  properties: ra(webjobsHosts.id, appIdentityPrincipalId, roles.blobDataOwner).properties
}

resource appSecretsBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: webjobsSecrets
  name: ra(webjobsSecrets.id, appIdentityPrincipalId, roles.blobDataOwner).name
  properties: ra(webjobsSecrets.id, appIdentityPrincipalId, roles.blobDataOwner).properties
}

resource appHostQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostStorage
  name: ra(hostStorage.id, appIdentityPrincipalId, roles.queueDataContributor).name
  properties: ra(hostStorage.id, appIdentityPrincipalId, roles.queueDataContributor).properties
}

resource appData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataContainer
  name: ra(dataContainer.id, appIdentityPrincipalId, roles.blobDataContributor).name
  properties: ra(dataContainer.id, appIdentityPrincipalId, roles.blobDataContributor).properties
}

resource appVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: ra(kv.id, appIdentityPrincipalId, roles.kvSecretsUser).name
  properties: ra(kv.id, appIdentityPrincipalId, roles.kvSecretsUser).properties
}

resource appMetrics 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appi
  name: ra(appi.id, appIdentityPrincipalId, roles.metricsPublisher).name
  properties: ra(appi.id, appIdentityPrincipalId, roles.metricsPublisher).properties
}

// ---------- Migration identity ----------
resource migratePackageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: migratePackage
  name: ra(migratePackage.id, migrationIdentityPrincipalId, roles.blobDataOwner).name
  properties: ra(migratePackage.id, migrationIdentityPrincipalId, roles.blobDataOwner).properties
}

resource migrateHostsBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: webjobsHosts
  name: ra(webjobsHosts.id, migrationIdentityPrincipalId, roles.blobDataOwner).name
  properties: ra(webjobsHosts.id, migrationIdentityPrincipalId, roles.blobDataOwner).properties
}

resource migrateSecretsBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: webjobsSecrets
  name: ra(webjobsSecrets.id, migrationIdentityPrincipalId, roles.blobDataOwner).name
  properties: ra(webjobsSecrets.id, migrationIdentityPrincipalId, roles.blobDataOwner).properties
}

resource migrateHostQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostStorage
  name: ra(hostStorage.id, migrationIdentityPrincipalId, roles.queueDataContributor).name
  properties: ra(hostStorage.id, migrationIdentityPrincipalId, roles.queueDataContributor).properties
}

resource migrateMetrics 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appi
  name: ra(appi.id, migrationIdentityPrincipalId, roles.metricsPublisher).name
  properties: ra(appi.id, migrationIdentityPrincipalId, roles.metricsPublisher).properties
}
