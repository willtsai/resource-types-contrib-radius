// Azure Container Apps Dapr Secret Store Recipe for Applications.Dapr/secretStores
// This recipe deploys an Azure Key Vault-backed Dapr secret store as an ACA Dapr component.
// Aligned with the local-dev recipe (which uses secretstores.kubernetes), but targets ACA
// using the secretstores.azure.keyvault Dapr component authenticated via a user-assigned
// managed identity.

@description('Radius-provided object containing information about the resource calling the Recipe')
param context object

@description('The name of the Azure Container Apps managed environment to create the Dapr component on.')
param containerAppsEnvironmentName string

@description('The geo-location where the Azure Key Vault and managed identity will be created. Default: resource group location.')
param location string = resourceGroup().location

@description('The user-defined tags that will be applied to the resource. Default is null')
param tags object = {}

// ============================================================================
// Variables
// ============================================================================

var radiusTags = {
  'radapp.io-environment': context.environment.id
  'radapp.io-application': context.application == null ? '' : context.application.id
  'radapp.io-resource': context.resource.id
}

var daprType = 'secretstores.azure.keyvault'
var daprVersion = 'v1'

// Key Vault names must be 3-24 chars, alphanumeric and hyphens, start with a letter.
var keyVaultName = 'kv${uniqueString(context.resource.id, resourceGroup().id)}'
var identityName = 'recipe-${uniqueString(context.resource.id, resourceGroup().id)}'

// Built-in role: Key Vault Secrets User (read secret contents)
// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#key-vault-secrets-user
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// ============================================================================
// User-assigned managed identity
// ============================================================================
// The container app(s) consuming this Dapr secret store must be configured with
// this user-assigned managed identity so that Dapr can authenticate to Key Vault.
// The identity's resource ID is returned in the recipe output for that purpose.

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: union(tags, radiusTags)
}

// ============================================================================
// Azure Key Vault
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: union(tags, radiusTags)
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Grant the managed identity permission to read secrets from the Key Vault.
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, identity.id, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// ACA Dapr Component
// ============================================================================

resource acaEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource daprComponent 'Microsoft.App/managedEnvironments/daprComponents@2024-03-01' = {
  parent: acaEnvironment
  name: context.resource.name
  properties: {
    componentType: daprType
    version: daprVersion
    metadata: [
      {
        name: 'vaultName'
        value: keyVault.name
      }
      {
        name: 'azureClientId'
        value: identity.properties.clientId
      }
    ]
    scopes: []
  }
  dependsOn: [
    keyVaultRoleAssignment
  ]
}

// ============================================================================
// Recipe Output
// ============================================================================

output result object = {
  resources: [
    identity.id
    keyVault.id
    daprComponent.id
  ]
  values: {
    type: daprType
    version: daprVersion
    metadata: daprComponent.properties.metadata
    // Resource ID of the user-assigned managed identity that consuming container
    // apps must be configured with in order to authenticate to Key Vault via Dapr.
    identityId: identity.id
    identityClientId: identity.properties.clientId
  }
}
