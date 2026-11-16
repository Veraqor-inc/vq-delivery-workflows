// Template T1 parameters for the "dev" environment. Every solution-specific value is read from the deploy job's
// environment (the GitHub environment "dev" variables, set by the environment owner), never from the solution
// repository or the artifact. Nothing here is secret.
using '../main.bicep'

param environmentName = 'dev'
param solution = readEnvironmentVariable('T1_SOLUTION')
param location = readEnvironmentVariable('T1_LOCATION', 'centralus')
param identityResourceGroup = readEnvironmentVariable('T1_IDENTITY_RESOURCE_GROUP')
param appIdentityName = readEnvironmentVariable('T1_APP_IDENTITY_NAME')
param migrationIdentityName = readEnvironmentVariable('T1_MIGRATION_IDENTITY_NAME')
param deployIdentityClientId = readEnvironmentVariable('AZURE_CLIENT_ID')
param deployIdentityPrincipalId = readEnvironmentVariable('T1_DEPLOY_PRINCIPAL_ID')
param migrationAuthClientId = readEnvironmentVariable('T1_MIGRATION_AUTH_CLIENT_ID')
param siteIdentityName = readEnvironmentVariable('T1_SITE_IDENTITY_NAME')
param siteAuthClientId = readEnvironmentVariable('T1_SITE_AUTH_CLIENT_ID')
param sqlAdminGroupObjectId = readEnvironmentVariable('T1_SQL_ADMIN_GROUP_ID')
param sqlAdminGroupName = readEnvironmentVariable('T1_SQL_ADMIN_GROUP_NAME')
param apiRuntime = readEnvironmentVariable('T1_API_RUNTIME', 'dotnet-isolated')
param apiRuntimeVersion = readEnvironmentVariable('T1_API_RUNTIME_VERSION', '10.0')
param vnetPrefix = readEnvironmentVariable('T1_VNET_PREFIX', '10.60.0.0/24')
// free (default), basic or serverless (main.bicep nonProdDatabase). An unset GitHub variable reaches here as "", which reads as free.
param nonProdDatabase = empty(readEnvironmentVariable('T1_NONPROD_DATABASE', '')) ? 'free' : readEnvironmentVariable('T1_NONPROD_DATABASE', 'free')
param logDailyCapGb = '0.1'
