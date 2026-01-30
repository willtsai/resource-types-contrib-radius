// Azure Container Apps Recipe for Radius.Compute/containers
// This recipe deploys containers to Azure Container Apps (ACA)

@description('Radius context object passed into the recipe.')
param context object

@description('Azure Container Apps Environment resource ID. Required.')
param containerAppsEnvironmentId string

@description('Enable external ingress (public access). Default: false (internal only)')
param ingressExternal bool = false

// ============================================================================
// Variables - Extract from context
// ============================================================================

var resourceName = context.resource.name
var resourceProperties = context.resource.properties ?? {}
var containerItems = items(resourceProperties.containers ?? {})

// Resource naming - use unique suffix to avoid conflicts
var normalizedName = toLower(replace(resourceName, '_', '-'))
var uniqueSuffix = uniqueString(context.resource.id)
var containerAppName = '${take(normalizedName, 24)}-${take(uniqueSuffix, 8)}'

// Environment labels for tracking
var environmentSegments = resourceProperties.environment != null ? split(string(resourceProperties.environment), '/') : []
var environmentLabel = length(environmentSegments) > 0 ? last(environmentSegments) : ''
var applicationName = context.application != null ? context.application.name : ''

// ============================================================================
// Connections - Generate environment variables from connected resources
// ============================================================================

var resourceConnections = context.resource.connections ?? {}
var connectionDefinitions = resourceProperties.connections ?? {}
var excludedProperties = ['recipe', 'status', 'provisioningState']

// Build CONNECTION_<NAME>_<PROPERTY> environment variables from connections
var connectionEnvVars = reduce(items(resourceConnections), [], (acc, conn) => 
  connectionDefinitions[conn.key].?disableDefaultEnvVars != true
    ? concat(acc, 
        reduce(items(conn.value ?? {}), [], (envAcc, prop) => 
          contains(excludedProperties, prop.key)
            ? envAcc 
            : concat(envAcc, [{
                name: toUpper('CONNECTION_${conn.key}_${prop.key}')
                value: string(prop.value)
              }])
        )
      )
    : acc
)

// ============================================================================
// Scaling Configuration
// ============================================================================

var replicaCount = resourceProperties.?replicas != null ? int(resourceProperties.replicas) : 1
var autoScaling = resourceProperties.?autoScaling
var hasAutoScaling = autoScaling != null

// Build KEDA scale rules from autoScaling.metrics
var scaleRules = hasAutoScaling && contains(autoScaling, 'metrics') ? reduce(autoScaling.metrics, [], (acc, metric) => 
  metric.kind == 'cpu' || metric.kind == 'memory' ? concat(acc, [{
    name: '${metric.kind}-scale-rule'
    custom: {
      type: metric.kind
      metadata: {
        type: 'Utilization'
        value: contains(metric.target, 'averageUtilization') ? string(metric.target.averageUtilization) : '70'
      }
    }
  }]) : acc
) : []

// ============================================================================
// Dapr Configuration
// ============================================================================

var daprSidecar = resourceProperties.?extensions.?daprSidecar
var hasDaprSidecar = daprSidecar != null
var effectiveDaprAppId = hasDaprSidecar && daprSidecar.?appId != null && string(daprSidecar.?appId) != '' 
  ? string(daprSidecar.?appId) 
  : normalizedName

// ============================================================================
// Container Specs - Build ACA container definitions
// ============================================================================

// Partition containers into workload and init containers
var workloadContainers = filter(containerItems, item => !(item.value.?initContainer ?? false))
var initContainerItems = filter(containerItems, item => item.value.?initContainer ?? false)

// Find first container with ports for ingress configuration
var containersWithPorts = filter(containerItems, item => contains(item.value, 'ports') && length(items(item.value.ports)) > 0)
var hasIngress = length(containersWithPorts) > 0
var ingressTargetPort = hasIngress ? items(first(containersWithPorts).value.ports)[0].value.containerPort : 80

// Build container specs for ACA
var acaContainers = [for item in workloadContainers: union(
  {
    name: item.key
    image: item.value.image
  },
  // Resources (CPU/Memory) - ACA format
  contains(item.value, 'resources') ? {
    resources: {
      cpu: json(contains(item.value.resources, 'requests') && contains(item.value.resources.requests, 'cpu') 
        ? item.value.resources.requests.cpu 
        : contains(item.value.resources, 'limits') && contains(item.value.resources.limits, 'cpu')
          ? item.value.resources.limits.cpu
          : '0.25')
      memory: contains(item.value.resources, 'requests') && contains(item.value.resources.requests, 'memoryInMib')
        ? '${string(int(item.value.resources.requests.memoryInMib) / 1024)}Gi'
        : contains(item.value.resources, 'limits') && contains(item.value.resources.limits, 'memoryInMib')
          ? '${string(int(item.value.resources.limits.memoryInMib) / 1024)}Gi'
          : '0.5Gi'
    }
  } : {
    resources: {
      cpu: json('0.25')
      memory: '0.5Gi'
    }
  },
  // Command
  contains(item.value, 'command') ? { command: item.value.command } : {},
  // Args
  contains(item.value, 'args') ? { args: item.value.args } : {},
  // Environment variables - container-defined + connection-derived
  {
    env: concat(
      // Container-defined env vars (value only - TODO: secretKeyRef support)
      reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) => 
        contains(envItem.value, 'value') 
          ? concat(envAcc, [{ name: envItem.key, value: envItem.value.value }])
          : envAcc  // TODO: Handle valueFrom.secretKeyRef
      ),
      // Connection-derived env vars
      connectionEnvVars,
      // Radius metadata env vars
      [
        { name: 'RADIUS_APPLICATION', value: applicationName }
        { name: 'RADIUS_ENVIRONMENT', value: environmentLabel }
        { name: 'RADIUS_RESOURCE', value: resourceName }
      ]
    )
  },
  // Health probes
  (contains(item.value, 'livenessProbe') || contains(item.value, 'readinessProbe')) ? {
    probes: concat(
      // Liveness probe
      contains(item.value, 'livenessProbe') ? [union(
        { type: 'Liveness' },
        contains(item.value.livenessProbe, 'httpGet') ? {
          httpGet: {
            port: item.value.livenessProbe.httpGet.port
            path: item.value.livenessProbe.httpGet.?path ?? '/'
            scheme: toUpper(item.value.livenessProbe.httpGet.?scheme ?? 'http')
          }
        } : {},
        contains(item.value.livenessProbe, 'tcpSocket') ? {
          tcpSocket: {
            port: item.value.livenessProbe.tcpSocket.port
          }
        } : {},
        // TODO: exec probes not supported by ACA
        contains(item.value.livenessProbe, 'initialDelaySeconds') ? { initialDelaySeconds: item.value.livenessProbe.initialDelaySeconds } : {},
        contains(item.value.livenessProbe, 'periodSeconds') ? { periodSeconds: item.value.livenessProbe.periodSeconds } : {},
        contains(item.value.livenessProbe, 'timeoutSeconds') ? { timeoutSeconds: item.value.livenessProbe.timeoutSeconds } : {},
        contains(item.value.livenessProbe, 'failureThreshold') ? { failureThreshold: item.value.livenessProbe.failureThreshold } : {},
        contains(item.value.livenessProbe, 'successThreshold') ? { successThreshold: item.value.livenessProbe.successThreshold } : {}
      )] : [],
      // Readiness probe
      contains(item.value, 'readinessProbe') ? [union(
        { type: 'Readiness' },
        contains(item.value.readinessProbe, 'httpGet') ? {
          httpGet: {
            port: item.value.readinessProbe.httpGet.port
            path: item.value.readinessProbe.httpGet.?path ?? '/'
            scheme: toUpper(item.value.readinessProbe.httpGet.?scheme ?? 'http')
          }
        } : {},
        contains(item.value.readinessProbe, 'tcpSocket') ? {
          tcpSocket: {
            port: item.value.readinessProbe.tcpSocket.port
          }
        } : {},
        // TODO: exec probes not supported by ACA
        contains(item.value.readinessProbe, 'initialDelaySeconds') ? { initialDelaySeconds: item.value.readinessProbe.initialDelaySeconds } : {},
        contains(item.value.readinessProbe, 'periodSeconds') ? { periodSeconds: item.value.readinessProbe.periodSeconds } : {},
        contains(item.value.readinessProbe, 'timeoutSeconds') ? { timeoutSeconds: item.value.readinessProbe.timeoutSeconds } : {},
        contains(item.value.readinessProbe, 'failureThreshold') ? { failureThreshold: item.value.readinessProbe.failureThreshold } : {},
        contains(item.value.readinessProbe, 'successThreshold') ? { successThreshold: item.value.readinessProbe.successThreshold } : {}
      )] : []
    )
  } : {}
)]

// Build init container specs
var acaInitContainers = [for item in initContainerItems: union(
  {
    name: item.key
    image: item.value.image
  },
  // Resources
  contains(item.value, 'resources') ? {
    resources: {
      cpu: json(contains(item.value.resources, 'requests') && contains(item.value.resources.requests, 'cpu') 
        ? item.value.resources.requests.cpu 
        : '0.25')
      memory: contains(item.value.resources, 'requests') && contains(item.value.resources.requests, 'memoryInMib')
        ? '${string(int(item.value.resources.requests.memoryInMib) / 1024)}Gi'
        : '0.5Gi'
    }
  } : {
    resources: {
      cpu: json('0.25')
      memory: '0.5Gi'
    }
  },
  // Command
  contains(item.value, 'command') ? { command: item.value.command } : {},
  // Args
  contains(item.value, 'args') ? { args: item.value.args } : {},
  // Environment variables
  {
    env: reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) => 
      contains(envItem.value, 'value') 
        ? concat(envAcc, [{ name: envItem.key, value: envItem.value.value }])
        : envAcc
    )
  }
)]

// ============================================================================
// Azure Container App Resource
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: resourceGroup().location
  tags: {
    'radapp.io/application': applicationName
    'radapp.io/environment': environmentLabel
    'radapp.io/resource': resourceName
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironmentId
    configuration: union(
      {
        activeRevisionsMode: 'Single'
      },
      // Ingress configuration (if container has ports)
      hasIngress ? {
        ingress: {
          external: ingressExternal
          targetPort: ingressTargetPort
          transport: 'auto'
          allowInsecure: false
        }
      } : {},
      // Dapr configuration
      hasDaprSidecar ? {
        dapr: {
          enabled: true
          appId: effectiveDaprAppId
          appPort: daprSidecar.?appPort ?? (hasIngress ? ingressTargetPort : null)
          appProtocol: 'http'
        }
      } : {}
    )
    template: {
      containers: acaContainers
      initContainers: length(acaInitContainers) > 0 ? acaInitContainers : null
      scale: {
        minReplicas: replicaCount
        maxReplicas: hasAutoScaling && contains(autoScaling, 'maxReplicas') ? int(autoScaling.maxReplicas) : max(replicaCount, 10)
        rules: length(scaleRules) > 0 ? scaleRules : null
      }
      // TODO: volumes support
      // volumes: []
    }
  }
}

// ============================================================================
// Recipe Output
// ============================================================================

output result object = {
  resources: [
    containerApp.id
  ]
  values: {
    // Include FQDN if ingress is enabled
    fqdn: hasIngress ? containerApp.properties.configuration.ingress.fqdn : ''
    url: hasIngress ? 'https://${containerApp.properties.configuration.ingress.fqdn}' : ''
  }
}

// ============================================================================
// TODO: Features not yet implemented
// ============================================================================
// 
// The following Radius.Compute/containers features are not yet supported:
//
// 1. Secret references (env.valueFrom.secretKeyRef)
//    - Requires mapping Radius secrets to ACA secrets or Azure Key Vault
//
// 2. Volumes (persistentVolume, emptyDir, secretName)
//    - persistentVolume: Requires Azure Files mount configuration
//    - emptyDir: ACA supports ephemeral volumes, needs mapping
//    - secretName: Requires ACA secrets volume mount
//
// 3. Volume mounts (containers.volumeMounts)
//    - Depends on volume support above
//
// 4. Restart policy (restartPolicy)
//    - ACA has different restart semantics (revision-based)
//
// 5. Custom metrics autoscaling (autoScaling.metrics[].kind: 'custom')
//    - Requires KEDA custom scaler configuration
//
// 6. Exec probes (livenessProbe.exec, readinessProbe.exec)
//    - ACA only supports HTTP and TCP probes
//
// 7. terminationGracePeriodSeconds on probes
//    - ACA has different termination handling
//
// 8. workingDir
//    - ACA doesn't support setting container working directory
//
