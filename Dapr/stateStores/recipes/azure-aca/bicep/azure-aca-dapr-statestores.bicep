// Azure Container Apps Dapr State Store Recipe for Applications.Dapr/stateStores
// This recipe deploys an Azure Cache for Redis-backed Dapr state store as an ACA Dapr component.
// Aligned with the local-dev recipe (which uses Redis on Kubernetes), but targets ACA.

@description('Radius-provided object containing information about the resource calling the Recipe')
param context object

@description('The name of the Azure Container Apps managed environment to create the Dapr component on.')
param containerAppsEnvironmentName string

@description('The geo-location where the Azure Cache for Redis will be created. Default: resource group location.')
param location string = resourceGroup().location

@description('Sets this Dapr State Store as the actor state store. Only one Dapr State Store can be set as the actor state store. Defaults to false.')
param actorStateStore bool = false

@description('The SKU of the Azure Cache for Redis. Default: Basic C0.')
param redisSku object = {
  name: 'Basic'
  family: 'C'
  capacity: 0
}

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

var daprType = 'state.redis'
var daprVersion = 'v1'
var port = 6380

// ============================================================================
// Azure Cache for Redis
// ============================================================================

resource redis 'Microsoft.Cache/redis@2024-03-01' = {
  name: 'recipe${uniqueString(context.resource.id, resourceGroup().id)}'
  location: location
  tags: union(tags, radiusTags)
  properties: {
    sku: redisSku
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
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
        name: 'redisHost'
        value: '${redis.properties.hostName}:${port}'
      }
      {
        name: 'redisPassword'
        secretRef: 'redis-password'
      }
      {
        name: 'enableTLS'
        value: 'true'
      }
      {
        name: 'actorStateStore'
        value: actorStateStore ? 'true' : 'false'
      }
    ]
    secrets: [
      {
        name: 'redis-password'
        value: redis.listKeys().primaryKey
      }
    ]
    scopes: []
  }
}

// ============================================================================
// Recipe Output
// ============================================================================

output result object = {
  resources: [
    redis.id
    daprComponent.id
  ]
  values: {
    type: daprType
    version: daprVersion
    metadata: daprComponent.properties.metadata
  }
}
