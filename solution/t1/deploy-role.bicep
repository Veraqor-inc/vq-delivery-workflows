// Template T1, landing step 2: the DEPLOY identity's custom role (Omar S12-5c, P2A-4). Run ONCE per solution per
// environment by the environment OWNER (it needs Microsoft.Authorization rights the pipeline never has), into the
// SOLUTION resource group, after landing.bicep.
//
// The role allows the resource types main.bicep deploys, plus what the deploy workflow does after the template
// (zip deploys of the two Function Apps, the Static Web App upload token), and nothing else. It is assignable only
// on this one resource group and is assigned here to this environment's deploy identity only.
//
// notActions: never grant (Microsoft.Authorization/*), never add a federated credential, never change the SQL
// admin, switch SQL back to passwords (azureADOnlyAuthentications) or open its firewall, never read storage or
// workspace keys or make SAS, never read Function App settings, publish profiles or keys, never write Key Vault
// access policies or secrets through ARM. Property changes inside an allowed write (publicNetworkAccess, shared
// keys, enableRbacAuthorization) cannot be stopped by a role: that is the Azure Policy deny of P2A-5.
//
// Kept on purpose: Microsoft.Web/staticSites/listSecrets/action (the deploy job reads the site's upload token) and
// staticSites/resetapikey/action (P2A-7 resets it after UAT and production deploys).

targetScope = 'resourceGroup'

@allowed(['dev', 'qa', 'uat', 'prod'])
param environmentName string

@minLength(3)
@maxLength(12)
param solution string

@description('Object (principal) ID of this environment\'s deploy identity (landing.bicep output deployIdentityPrincipalId).')
param deployIdentityPrincipalId string

// Exactly the providers and types main.bicep and the deploy workflow use (test/infra-t1.test.ts checks both ways).
var deployActions = [
  'Microsoft.Resources/deployments/*'
  'Microsoft.Resources/subscriptions/resourceGroups/read'
  'Microsoft.Network/publicIPAddresses/*'
  'Microsoft.Network/natGateways/*'
  'Microsoft.Network/virtualNetworks/*'
  'Microsoft.Network/privateEndpoints/*'
  'Microsoft.Network/privateDnsZones/*'
  'Microsoft.OperationalInsights/workspaces/*'
  'Microsoft.Insights/components/*'
  'Microsoft.Insights/diagnosticSettings/*'
  'Microsoft.Storage/storageAccounts/*'
  'Microsoft.KeyVault/vaults/*'
  'Microsoft.Sql/servers/*'
  'Microsoft.Web/serverfarms/*'
  'Microsoft.Web/sites/*'
  'Microsoft.Web/staticSites/*'
]

var deployNotActions = [
  'Microsoft.Authorization/*'
  'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/*'
  'Microsoft.Sql/servers/administrators/write'
  'Microsoft.Sql/servers/administrators/delete'
  'Microsoft.Sql/servers/azureADOnlyAuthentications/write'
  'Microsoft.Sql/servers/azureADOnlyAuthentications/delete'
  'Microsoft.Sql/servers/firewallRules/write'
  'Microsoft.Sql/servers/firewallRules/delete'
  'Microsoft.Sql/servers/virtualNetworkRules/write'
  'Microsoft.Storage/storageAccounts/listKeys/action'
  'Microsoft.Storage/storageAccounts/regenerateKey/action'
  'Microsoft.Storage/storageAccounts/ListAccountSas/action'
  'Microsoft.Storage/storageAccounts/listServiceSas/action'
  'Microsoft.Storage/storageAccounts/localUsers/*'
  'Microsoft.OperationalInsights/workspaces/sharedKeys/action'
  'Microsoft.Insights/components/ApiKeys/*'
  'Microsoft.KeyVault/vaults/accessPolicies/write'
  'Microsoft.KeyVault/vaults/secrets/write'
  'Microsoft.Web/sites/config/list/action'
  'Microsoft.Web/sites/publishxml/action'
  'Microsoft.Web/sites/host/listkeys/action'
  'Microsoft.Web/sites/functions/listkeys/action'
  'Microsoft.Web/sites/functions/listsecrets/action'
  'Microsoft.Web/sites/slots/*'
  // Omar P2A-19 (M12 P2 part 2): the Function App master key read (host runtime), host and function key writes,
  // SQL IPv6 firewall rules, and approving private-endpoint connections from elsewhere. (The approval right the
  // template's own endpoints need for automatic approval, privateEndpointConnectionsApproval/action, is kept.)
  'Microsoft.Web/sites/hostruntime/*'
  'Microsoft.Web/sites/host/functionkeys/write'
  'Microsoft.Web/sites/host/systemkeys/write'
  'Microsoft.Web/sites/functions/keys/write'
  'Microsoft.Sql/servers/ipv6FirewallRules/write'
  'Microsoft.Sql/servers/privateEndpointConnections/write'
  'Microsoft.Storage/storageAccounts/privateEndpointConnections/write'
  'Microsoft.KeyVault/vaults/privateEndpointConnections/write'
]

resource deployRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 't1-deploy', solution, environmentName)
  properties: {
    roleName: 't1-deploy-${solution}-${environmentName}-${take(uniqueString(resourceGroup().id), 6)}'
    description: 'T1 deploy identity for ${solution} ${environmentName}: the template\'s resource types only; never grants, never reads keys or settings.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: deployActions
        notActions: deployNotActions
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource deployRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployIdentityPrincipalId, deployRole.id)
  properties: {
    principalId: deployIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: deployRole.id
  }
}

output roleDefinitionId string = deployRole.id
output roleName string = deployRole.properties.roleName
