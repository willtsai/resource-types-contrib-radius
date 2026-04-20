# Azure Container Apps Recipe for Radius.Compute/containers

This recipe deploys containers defined using the `Radius.Compute/containers` resource type to [Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/overview).

## Overview

Azure Container Apps is a fully managed serverless container service that enables you to run containerized applications without managing infrastructure. This recipe maps Radius container definitions to ACA resources.

## Prerequisites

- An Azure subscription
- An existing Azure Container Apps Environment
- Radius environment configured to use this recipe

## Recipe Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `context` | object | Yes | - | Radius context object (provided automatically) |
| `containerAppsEnvironmentId` | string | Yes | - | Resource ID of the Azure Container Apps Environment |
| `ingressExternal` | bool | No | `false` | Enable external (public) ingress. When `false`, ingress is internal only (VNet). |

### Example: Registering the Recipe

```bash
rad recipe register default \
  --environment myenv \
  --resource-type "Radius.Compute/containers" \
  --template-kind bicep \
  --template-path "ghcr.io/radius-project/recipes/azure-aca-containers:latest" \
  --parameters containerAppsEnvironmentId=/subscriptions/.../resourceGroups/.../providers/Microsoft.App/managedEnvironments/myenv \
  --parameters ingressExternal=true
```

## Supported Features

| Feature | Status | Notes |
|---------|--------|-------|
| Container image | ✅ | Direct mapping |
| Container command | ✅ | Direct mapping |
| Container args | ✅ | Direct mapping |
| Environment variables (value) | ✅ | Direct mapping |
| Resource limits (CPU/memory) | ✅ | Converted to ACA format |
| Multiple containers (sidecars) | ✅ | All non-init containers become ACA containers |
| Init containers | ✅ | Mapped to ACA init containers |
| Ports / Ingress | ✅ | First container with ports gets ingress |
| Liveness probes (HTTP/TCP) | ✅ | Direct mapping |
| Readiness probes (HTTP/TCP) | ✅ | Direct mapping |
| Replicas | ✅ | Maps to `minReplicas` |
| Auto-scaling (CPU/memory) | ✅ | KEDA-based scaling |
| Dapr sidecar | ✅ | Native ACA Dapr support |
| Connections (env var injection) | ✅ | `CONNECTION_*` environment variables |

## Limitations & TODOs

The following features are **not yet implemented**:

| Feature | Status | Notes |
|---------|--------|-------|
| Secret references (`env.valueFrom.secretKeyRef`) | 🚧 TODO | Requires mapping to ACA secrets or Key Vault |
| Persistent volumes | 🚧 TODO | Requires Azure Files mount |
| EmptyDir volumes | 🚧 TODO | ACA supports ephemeral volumes |
| Secret volumes | 🚧 TODO | Requires ACA secrets volume mount |
| Volume mounts | 🚧 TODO | Depends on volume support |
| Restart policy | 🚧 TODO | ACA uses revision-based restarts |
| Custom metrics autoscaling | 🚧 TODO | Requires KEDA custom scaler |
| Exec probes | ❌ | ACA doesn't support exec probes |
| Working directory | ❌ | ACA doesn't support `workingDir` |
| terminationGracePeriodSeconds | ❌ | Different handling in ACA |

## Recipe Outputs

| Property | Description |
|----------|-------------|
| `resources` | Array containing the Container App resource ID |
| `values.fqdn` | Fully qualified domain name (if ingress enabled) |
| `values.url` | HTTPS URL (if ingress enabled) |

## Usage Examples

### Basic Container

```bicep
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    containers: {
      main: {
        image: 'nginx:latest'
        ports: {
          http: {
            containerPort: 80
          }
        }
      }
    }
  }
}
```

### Container with Scaling

```bicep
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    containers: {
      main: {
        image: 'myapp:latest'
        ports: {
          http: { containerPort: 8080 }
        }
        resources: {
          requests: {
            cpu: '0.5'
            memoryInMib: 1024
          }
        }
      }
    }
    replicas: 2
    autoScaling: {
      maxReplicas: 10
      metrics: [
        {
          kind: 'cpu'
          target: {
            averageUtilization: 70
          }
        }
      ]
    }
  }
}
```

### Container with Dapr

```bicep
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    containers: {
      main: {
        image: 'myapp:latest'
        ports: {
          http: { containerPort: 3000 }
        }
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'myapp'
        appPort: 3000
      }
    }
  }
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│           Azure Container Apps Environment              │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │              Container App (Recipe Output)        │  │
│  │                                                   │  │
│  │  ┌─────────────┐  ┌─────────────┐                 │  │
│  │  │  Container  │  │  Sidecar    │  (from Radius   │  │
│  │  │  (main)     │  │  Container  │   containers)   │  │
│  │  └─────────────┘  └─────────────┘                 │  │
│  │                                                   │  │
│  │  ┌─────────────┐                                  │  │
│  │  │  Dapr       │  (if extensions.daprSidecar)     │  │
│  │  │  Sidecar    │                                  │  │
│  │  └─────────────┘                                  │  │
│  │                                                   │  │
│  │  Ingress: internal/external (first port)          │  │
│  │  Scale: minReplicas → maxReplicas (KEDA)          │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Troubleshooting

### Container App not starting

1. Check the Container Apps Environment is healthy
2. Verify the container image is accessible
3. Check resource limits are within ACA quotas (max 4 vCPU, 8 GiB per container)

### Ingress not working

1. Verify `ingressExternal` parameter is set correctly
2. Check that a container has `ports` defined
3. Ensure the target port matches what your application listens on

### Dapr not working

1. Verify Dapr is enabled on the Container Apps Environment
2. Check `appPort` matches your application's listening port
3. Review Dapr logs in the Azure portal
