// Template T1 "Web + API" (M12 P2, F33; design team/m12-customer-delivery.md 5.1 and 5.5, Omar S12-5 and S12-6).
//
// What one environment of one solution gets, deployed by the platform's deploy workflow under that solution's
// deploy identity for THIS environment (one identity per solution per environment):
//   - Static Web App, Standard: public, Entra sign-in on every route (site/staticwebapp.config.json), no preview
//     environments; linked to the API. Sign-in has NO client secret: the SWA holds only the SITE identity, which
//     the sign-in app registration trusts as a federated credential (OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID;
//     Omar P2A-6).
//   - API: Azure Functions Flex Consumption (Linux, .NET isolated or Node), the app identity only, VNet
//     integration outbound. Inbound stays public as Microsoft requires for a linked backend; the link's own
//     identity provider lets only the Static Web App call it.
//   - Migration runner: a second Flex app under the MIGRATION identity only (DDL on this one database), VNet
//     integrated, called by the deploy job with an Entra token that only the deploy identity can hold (Easy Auth
//     checks the client application AND the deploy identity's object ID, P2A-13). Its package lives in its own
//     container, which the API's identity cannot write (grants.bicep, P2A-2).
//   - Azure SQL (Entra-only, admin = an Entra GROUP, no firewall rules), Key Vault (RBAC) and two storage accounts
//     (host: the Functions packages and host state; data: the solution's own files), all with public network
//     access OFF, reached over private endpoints and private DNS zones.
//   - Log Analytics with a daily cap, Application Insights with local (key) auth off, SQL auditing and Key Vault
//     AuditEvent to that workspace.
//   - prod only: a NAT gateway for outbound (no default outbound access), Defender for SQL on the server.
//
// What this file deliberately does NOT do (S12-5: the deploy identity's role excludes Microsoft.Authorization/*):
//   - no role assignments, locks or policy: the environment owner runs grants.bicep once (landing kit);
//   - no identities: the app, migration and site identities live in the separate identity group (landing.bicep);
//   - no secrets: nothing secret in parameters or app settings, so a what-if never prints one;
//   - no SQL firewall rule, no "allow Azure services", no shared keys, no SQL password anywhere.
//
// Lessons from spike G9 (team/spikes/m12-p0-g9.md section 7, Omar's G9 points in team/security-review-m12-p1.md):
//   - private endpoint -> DNS zone wiring is by NAME through an explicit map, never by position (the items() bug);
//   - the SQL admin given here applies only when the server is created; changing it later is grants.bicep's
//     administrators child resource (an owner step, never the pipeline);
//   - outboundVnetRouting flags are not used or relied on: a probe proves the route (D15);
//   - database users are created inside the VNet (README "Landing"), never from a PC.

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
@description('Which of the four environments this is.')
param environmentName string

@minLength(3)
@maxLength(12)
@description('The solution short name: lower-case letters and digits, 3 to 12 (used in every resource name).')
param solution string

@description('Region for every resource (one region per environment; Central US for internal solutions).')
param location string = 'centralus'

@description('The resource group holding this environment\'s app and migration identities (landing.bicep). The deploy identity has no rights there.')
param identityResourceGroup string

@description('Name of the app\'s user-assigned managed identity (runtime of the API).')
param appIdentityName string

@description('Name of the migration identity (DDL on this one database only).')
param migrationIdentityName string

@description('Client ID of THIS environment\'s deploy identity: the only caller the migration runner accepts.')
param deployIdentityClientId string

@description('Object (principal) ID of THIS environment\'s deploy identity: the only principal the migration runner accepts (P2A-13).')
param deployIdentityPrincipalId string

@description('Client ID of the Entra app registration that protects the migration runner (created by the owner at landing).')
param migrationAuthClientId string

@description('Name of the site identity (landing.bicep): assigned only to the Static Web App, trusted by the sign-in app registration.')
param siteIdentityName string

@description('Client ID of the site\'s sign-in app registration (created by the owner at landing). Not a secret.')
param siteAuthClientId string

@description('Object ID of the Entra GROUP that is the SQL Entra admin (membership through PIM; never a person, never the app).')
param sqlAdminGroupObjectId string

@description('Display name of that Entra group.')
param sqlAdminGroupName string

@allowed(['dotnet-isolated', 'node'])
param apiRuntime string = 'dotnet-isolated'

@description('Runtime version: 10.0 for .NET isolated (8.0 reached end of life on Flex Consumption on 10 Nov 2026), 22 for Node.')
param apiRuntimeVersion string = '10.0'

@description('Address space of this environment\'s VNet (a /24; must not overlap other environments if they are ever peered).')
param vnetPrefix string = '10.60.0.0/24'

@allowed(['free', 'basic', 'serverless'])
@description('dev and qa only: the database offer. free (default) = the free serverless offer, paused when the free amount is used up; basic = Basic, 5 DTU (paid, about 5 USD a month); serverless = serverless Gen5, 1 vCore, auto-pause after 60 minutes (paid by use). Use basic or serverless when the subscription has already used its free databases. uat and prod ignore it.')
param nonProdDatabase string = 'free'

@description('Log Analytics daily ingestion cap in GB (the cost brake).')
param logDailyCapGb string = '0.2'

@description('Extra tags (cost centre, owner). The template adds solution, environment, template and managed-by.')
param extraTags object = {}

var isProd = environmentName == 'prod'
var isNonProd = environmentName == 'dev' || environmentName == 'qa'
var base = '${solution}-${environmentName}'
// Globally unique names: no hyphens for storage and short for vault/SQL.
var uniq = take(uniqueString(subscription().id, resourceGroup().id, solution, environmentName), 6)
var compact = '${take(solution, 10)}${take(environmentName, 4)}${uniq}'

var tags = union(extraTags, {
  solution: solution
  environment: environmentName
  template: 't1'
  'managed-by': 'pipeline'
})

// Database size per environment (section 5.1): dev/QA on the free serverless offer (auto-pause when the free
// amount is used up, never a surprise bill); UAT Basic; production S0.
var dbSkus = {
  dev: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 2 }
  qa: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 2 }
  uat: { name: 'Basic', tier: 'Basic', capacity: 5 }
  prod: { name: 'S0', tier: 'Standard', capacity: 10 }
}
var dbFreeProperties = {
  useFreeLimit: true
  freeLimitExhaustionBehavior: 'AutoPause'
  autoPauseDelay: 60
  minCapacity: json('0.5')
}
var dbPaidProperties = {
  requestedBackupStorageRedundancy: isProd ? 'Zone' : 'Local'
}
// dev and qa when the subscription's free databases are used up (nonProdDatabase): a small paid offer instead.
// uat and prod always use dbSkus.
var nonProdPaidSkus = {
  basic: { name: 'Basic', tier: 'Basic', capacity: 5 }
  serverless: { name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1 }
}
var nonProdPaidProperties = {
  basic: dbPaidProperties
  serverless: union(dbPaidProperties, { autoPauseDelay: 60, minCapacity: json('0.5') })
}
var useFreeDb = !isNonProd || nonProdDatabase == 'free'

// ---------- Identities (created by the environment owner, landing.bicep; referenced only) ----------
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: appIdentityName
}

resource migrationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: migrationIdentityName
}

resource siteIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup(identityResourceGroup)
  name: siteIdentityName
}

// ---------- Network ----------
// prod: outbound through a NAT gateway (a fixed address that an allow-list can name); no default outbound.
// Below prod: Azure's default outbound, so telemetry reaches Application Insights without the NAT cost.
resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (isProd) {
  name: 'pip-${base}-nat'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static', publicIPAddressVersion: 'IPv4' }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = if (isProd) {
  name: 'nat-${base}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: natIp.id }]
  }
}

var funcSubnetEgress = isProd ? { natGateway: { id: nat.id }, defaultOutboundAccess: false } : { defaultOutboundAccess: true }

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${base}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [vnetPrefix] }
    subnets: [
      {
        name: 'snet-api'
        properties: union({
          addressPrefix: cidrSubnet(vnetPrefix, 26, 0)
          // Flex Consumption VNet integration needs this delegation (spike G9 gotcha 7).
          delegations: [{ name: 'flex', properties: { serviceName: 'Microsoft.App/environments' } }]
        }, funcSubnetEgress)
      }
      {
        name: 'snet-migrate'
        properties: union({
          addressPrefix: cidrSubnet(vnetPrefix, 26, 1)
          delegations: [{ name: 'flex', properties: { serviceName: 'Microsoft.App/environments' } }]
        }, funcSubnetEgress)
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: cidrSubnet(vnetPrefix, 26, 2)
          privateEndpointNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

var apiSubnetId = '${vnet.id}/subnets/snet-api'
var migrateSubnetId = '${vnet.id}/subnets/snet-migrate'
var peSubnetId = '${vnet.id}/subnets/snet-pe'

// ---------- Private DNS zones: one per service, mapped by NAME ----------
var zoneNames = {
  sql: 'privatelink${environment().suffixes.sqlServerHostname}'
  vault: 'privatelink.vaultcore.azure.net'
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  queue: 'privatelink.queue.${environment().suffixes.storage}'
}
var zoneList = [zoneNames.sql, zoneNames.vault, zoneNames.blob, zoneNames.queue]
// The explicit map a private endpoint's zone group reads its zone from (never an index into a list).
var zoneIds = {
  sql: resourceId('Microsoft.Network/privateDnsZones', zoneNames.sql)
  vault: resourceId('Microsoft.Network/privateDnsZones', zoneNames.vault)
  blob: resourceId('Microsoft.Network/privateDnsZones', zoneNames.blob)
  queue: resourceId('Microsoft.Network/privateDnsZones', zoneNames.queue)
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for z in zoneList: {
  name: z
  location: 'global'
  tags: tags
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (z, i) in zoneList: {
  parent: zones[i]
  name: 'link-${base}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

// ---------- Monitoring (Entra-only ingestion, capped) ----------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${base}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: isProd ? 90 : 30
    workspaceCapping: { dailyQuotaGb: json(logDailyCapGb) }
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${base}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    DisableLocalAuth: true
  }
}

// ---------- Storage: host (Functions packages and host state) and data (the solution's files) ----------
// Two accounts (Omar G9 point 3): the host account holds the Functions host's own keys, so the solution's data
// lives in a separate account the app reaches with a narrower role (grants.bicep).
var storageCommon = {
  accessTier: 'Hot'
  allowBlobPublicAccess: false
  allowSharedKeyAccess: false
  allowCrossTenantReplication: false
  defaultToOAuthAuthentication: true
  minimumTlsVersion: 'TLS1_2'
  supportsHttpsTrafficOnly: true
  publicNetworkAccess: 'Disabled'
  networkAcls: { defaultAction: 'Deny', bypass: 'None' }
}

resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'sth${compact}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: storageCommon
}

resource hostBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
}

resource apiPackage 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: 'api-package'
}

resource migratePackage 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: 'migrate-package'
}

// The Functions host's own containers, made here so grants.bicep can scope each identity's blob role to them
// (never Blob Data Owner on the whole account, P2A-2).
resource webjobsHosts 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: 'azure-webjobs-hosts'
}

resource webjobsSecrets 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: 'azure-webjobs-secrets'
}

resource dataStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'std${compact}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: isProd ? 'Standard_ZRS' : 'Standard_LRS' }
  properties: storageCommon
}

resource dataBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: dataStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: isProd ? 30 : 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: isProd ? 30 : 7 }
  }
}

resource dataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: dataBlob
  name: 'data'
}

// ---------- Key Vault (RBAC) ----------
// Secrets are written by an owner or through ARM, never into this template's parameters (spike G9 gotcha 8).
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${take(solution, 8)}-${take(environmentName, 4)}-${uniq}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: isProd ? 90 : 7
    // Purge protection cannot be switched off again; production only.
    enablePurgeProtection: isProd ? true : null
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}

resource kvAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: kv
  name: 'audit-to-${law.name}'
  properties: {
    workspaceId: law.id
    logs: [{ category: 'AuditEvent', enabled: true }]
  }
}

// ---------- Azure SQL (Entra-only, admin is a GROUP, private only) ----------
resource sql 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-${base}-${uniq}'
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: 'Disabled'
    // Applied only when the server is first created (spike G9 gotcha 5); later changes: grants.bicep.
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'Group'
      login: sqlAdminGroupName
      sid: sqlAdminGroupObjectId
      tenantId: subscription().tenantId
    }
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sql
  name: 'sqldb-${base}'
  location: location
  tags: tags
  sku: useFreeDb ? dbSkus[environmentName] : nonProdPaidSkus[nonProdDatabase]
  properties: !isNonProd ? dbPaidProperties : (useFreeDb ? dbFreeProperties : nonProdPaidProperties[nonProdDatabase])
}

// SQL auditing to this environment's own workspace (Omar S12-6c, S4-4 parity).
resource sqlAuditing 'Microsoft.Sql/servers/auditingSettings@2023-08-01-preview' = {
  parent: sql
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
  }
}

resource sqlMaster 'Microsoft.Sql/servers/databases@2023-08-01-preview' existing = {
  parent: sql
  name: 'master'
}

resource sqlAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: sqlMaster
  name: 'audit-to-${law.name}'
  properties: {
    workspaceId: law.id
    logs: [{ category: 'SQLSecurityAuditEvents', enabled: true }]
  }
  dependsOn: [sqlAuditing]
}

// Defender for SQL on production (section 10.5). Defender for Key Vault and Storage are subscription plans: owner.
resource sqlDefender 'Microsoft.Sql/servers/advancedThreatProtectionSettings@2023-08-01-preview' = if (isProd) {
  parent: sql
  name: 'Default'
  properties: { state: 'Enabled' }
}

// ---------- Private endpoints: each names its zone by KEY in zoneIds ----------
var peDefs = [
  { name: 'pe-${base}-sql', target: sql.id, group: 'sqlServer', zone: 'sql' }
  { name: 'pe-${base}-kv', target: kv.id, group: 'vault', zone: 'vault' }
  { name: 'pe-${base}-hostblob', target: hostStorage.id, group: 'blob', zone: 'blob' }
  { name: 'pe-${base}-hostqueue', target: hostStorage.id, group: 'queue', zone: 'queue' }
  { name: 'pe-${base}-datablob', target: dataStorage.id, group: 'blob', zone: 'blob' }
]

resource pes 'Microsoft.Network/privateEndpoints@2024-05-01' = [for p in peDefs: {
  name: p.name
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: p.name
        properties: { privateLinkServiceId: p.target, groupIds: [p.group] }
      }
    ]
  }
}]

resource peZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (p, i) in peDefs: {
  parent: pes[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: p.zone, properties: { privateDnsZoneId: zoneIds[p.zone] } }
    ]
  }
  dependsOn: [zones, zoneLinks]
}]

// ---------- Functions: the API (app identity) and the migration runner (migration identity) ----------
var runtime = { name: apiRuntime, version: apiRuntimeVersion }

resource apiPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${base}-api'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource migratePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${base}-migrate'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

// No secrets: every setting below is a name or an address. The App Insights connection string only identifies
// the resource; with local auth off, sending needs the identity's Entra token.
func hostSettings(storageName string, clientId string, appiConn string) array => [
  { name: 'AzureWebJobsStorage__accountName', value: storageName }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  { name: 'AzureWebJobsStorage__clientId', value: clientId }
  { name: 'AZURE_CLIENT_ID', value: clientId }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appiConn }
  { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'ClientId=${clientId};Authorization=AAD' }
]

var dataSettings = [
  { name: 'SQL_SERVER', value: sql.properties.fullyQualifiedDomainName }
  { name: 'SQL_DATABASE', value: sqlDb.name }
  { name: 'KEY_VAULT_URI', value: kv.properties.vaultUri }
  { name: 'DATA_BLOB_URI', value: '${dataStorage.properties.primaryEndpoints.blob}${dataContainer.name}' }
  { name: 'APP_ENVIRONMENT', value: environmentName }
]

var siteHardening = {
  minTlsVersion: '1.2'
  ftpsState: 'Disabled'
  http20Enabled: true
}

resource api 'Microsoft.Web/sites@2024-04-01' = {
  name: 'func-${base}-${uniq}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    serverFarmId: apiPlan.id
    httpsOnly: true
    clientCertEnabled: false
    virtualNetworkSubnetId: apiSubnetId
    siteConfig: union(siteHardening, {
      appSettings: concat(hostSettings(hostStorage.name, appIdentity.properties.clientId, appi.properties.ConnectionString), dataSettings)
    })
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostStorage.properties.primaryEndpoints.blob}${apiPackage.name}'
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: appIdentity.id }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: isProd ? 40 : 2, instanceMemoryMB: 2048 }
      runtime: runtime
    }
  }
  // DNS must be right before the first code deploy (spike G9 gotcha 3).
  dependsOn: [peZoneGroups]
}

resource migrate 'Microsoft.Web/sites@2024-04-01' = {
  name: 'func-${base}-mig-${uniq}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${migrationIdentity.id}': {} }
  }
  properties: {
    serverFarmId: migratePlan.id
    httpsOnly: true
    clientCertEnabled: false
    virtualNetworkSubnetId: migrateSubnetId
    siteConfig: union(siteHardening, {
      appSettings: concat(hostSettings(hostStorage.name, migrationIdentity.properties.clientId, appi.properties.ConnectionString), [
        { name: 'SQL_SERVER', value: sql.properties.fullyQualifiedDomainName }
        { name: 'SQL_DATABASE', value: sqlDb.name }
        { name: 'APP_ENVIRONMENT', value: environmentName }
      ])
    })
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostStorage.properties.primaryEndpoints.blob}${migratePackage.name}'
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: migrationIdentity.id }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 1, instanceMemoryMB: 2048 }
      runtime: runtime
    }
  }
  dependsOn: [peZoneGroups]
}

// No publish profiles or basic-auth deploys on either app: code goes in with the deploy identity's Entra token.
resource apiNoFtp 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: api
  name: 'ftp'
  properties: { allow: false }
}

resource apiNoScmBasic 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: api
  name: 'scm'
  properties: { allow: false }
}

resource migrateNoFtp 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: migrate
  name: 'ftp'
  properties: { allow: false }
}

resource migrateNoScmBasic 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: migrate
  name: 'scm'
  properties: { allow: false }
}

// The migration runner answers only a valid Entra token for its own app registration, issued to THIS
// environment's deploy identity: both its client application and its object ID must match (P2A-13), and the app
// registration has "assignment required" on (an owner step). Anything else gets 401 before any code runs; the
// deploy job's smoke test checks that a signed-out call gets 401.
resource migrateAuth 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: migrate
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: { requireHttps: true }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: migrationAuthClientId
          openIdIssuer: 'https://sts.windows.net/${subscription().tenantId}/'
        }
        validation: {
          allowedAudiences: ['api://${migrationAuthClientId}']
          defaultAuthorizationPolicy: {
            allowedApplications: [deployIdentityClientId]
            allowedPrincipals: { identities: [deployIdentityPrincipalId] }
          }
        }
      }
    }
  }
}

// ---------- Static Web App (Standard), linked to the API ----------
resource swa 'Microsoft.Web/staticSites@2024-04-01' = {
  name: 'swa-${base}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard' }
  // The site identity only: its one job is the federated sign-in assertion (no secret, P2A-6).
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${siteIdentity.id}': {} }
  }
  properties: {
    // Deploys only from the pipeline: no pull-request preview environments (each would be another public site).
    stagingEnvironmentPolicy: 'Disabled'
    allowConfigFileUpdates: true
  }
}

// Sign-in settings named by site/staticwebapp.config.json. Both are client IDs, not secrets: the managed identity
// replaces the client secret (Microsoft Learn, "Custom authentication in Azure Static Web Apps", managed identity
// instead of a secret).
resource swaSettings 'Microsoft.Web/staticSites/config@2024-04-01' = {
  parent: swa
  name: 'appsettings'
  properties: {
    ENTRA_CLIENT_ID: siteAuthClientId
    OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID: siteIdentity.properties.clientId
  }
}

resource swaLink 'Microsoft.Web/staticSites/linkedBackends@2024-04-01' = {
  parent: swa
  name: 'backend'
  properties: {
    backendResourceId: api.id
    region: location
  }
}

output environmentName string = environmentName
output swaName string = swa.name
output swaHostname string = swa.properties.defaultHostname
output apiName string = api.name
output migrateName string = migrate.name
output migrateHostname string = migrate.properties.defaultHostName
output sqlServerName string = sql.name
output sqlDatabaseName string = sqlDb.name
output keyVaultName string = kv.name
output hostStorageName string = hostStorage.name
output dataStorageName string = dataStorage.name
output appInsightsName string = appi.name
