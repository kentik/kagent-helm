# Kagent Helm Chart

Deploy the [Kentik Universal Agent](https://www.kentik.com) (kagent) on Kubernetes. Supports StatefulSet and DaemonSet patterns with per-capability service port configuration.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.x
- Kentik account with a provisioning token (see `./generate-provisioning-token.sh --help`)

## Quick Start

```bash
# Clone the chart
git clone https://github.com/kentik/kagent-helm.git
cd kagent-helm

# Install with default StatefulSet pattern
helm install kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

Or install directly from the OCI registry without cloning:

```bash
helm install kagent oci://ghcr.io/kentik/kagent-helm \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

Then authorize the agent in the Kentik Portal under Settings → Universal Agents.

## Exposing Capability Ports

The Universal Agent runs multiple capabilities, each listening on specific ports. Enable only what you need:

```yaml
# values-flow-and-syslog.yaml
service:
  enabled: true
  type: LoadBalancer

  flowProxy:
    enabled: true # UDP 9995 - NetFlow/sFlow/IPFIX

  syslog:
    enabled: true # UDP+TCP 514


  # Other capabilities (disabled by default):
  # snmpTrap:         # UDP 162
  # healthCheck:      # TCP 8099

  # Unreleased capabilities (coming soon):
  # bgp:              # TCP 179
  # synthetics:       # UDP 9977 (inbound mesh probes)
```

```bash
helm install kagent . -f values-flow-and-syslog.yaml \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

### Available Service Ports

| Capability    | Port | Protocol | Direction | Description                                    |
| ------------- | ---- | -------- | --------- | ---------------------------------------------- |
| `flowProxy`   | 9995 | UDP      | Inbound   | NetFlow/sFlow/IPFIX from routers/switches      |
| `snmpTrap`    | 162  | UDP      | Inbound   | SNMP traps from network devices                |
| `syslog`      | 514  | UDP+TCP  | Inbound   | Syslog messages from network devices           |
| `bgp`         | 179  | TCP      | Inbound   | BGP peering sessions from routers (unreleased) |
| `synthetics`  | 9977 | UDP      | Inbound   | Agent-to-agent mesh test probes (unreleased)   |
| `healthCheck` | 8099 | TCP      | Inbound   | Health check endpoint                          |

Capabilities that only use outbound connections (DNS OTT Tap, SNMP/Streaming Telemetry polling via ranger, NMS/SSH, synthetics TCP 8877) do not need service ports. These are handled via NetworkPolicy egress rules.

### Port Customization

Override default port numbers or pin NodePort values:

```yaml
service:
  enabled: true
  type: NodePort
  flowProxy:
    enabled: true
    port: 2055 # Listen on 2055 instead of 9995
    nodePort: 30055 # Pin a specific node port
```

### NetworkPolicy Integration

When `networkPolicy.enabled: true`, ingress and egress rules are managed automatically:

- **Ingress**: Opens ports for every enabled service capability
- **Egress**: Always includes DNS (53) and Kentik API (443). Adds synthetics TCP 8877 when synthetics is enabled.
- **Manual egress**: SNMP/ST polling via ranger (UDP 161) and SSH for NMS (TCP 22) are commented-out in defaults since they require CIDR scoping to your network.

```yaml
networkPolicy:
  enabled: true
  # Default egress rules include DNS and Kentik API.
  # Uncomment SNMP/SSH in values.yaml and adjust CIDRs for your network.
```

## Deployment Patterns

### StatefulSet (Default)

Stable pod identities and persistent storage. Best for production.

```bash
helm install kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set replicaCount=1
```

### DaemonSet

One agent per node. Good for node-level monitoring.

```bash
helm install kagent . -f examples/daemon-set.yaml \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

DaemonSet requires `hostPath` or `emptyDir` for persistence (not PVC). See [examples/daemon-set.yaml](examples/daemon-set.yaml).

## Keypair Management

The agent's ed25519 keypair is its identity and must persist across restarts. Storage options via `persistence.keypair.type`:

| Type               | Use Case                                                                      |
| ------------------ | ----------------------------------------------------------------------------- |
| `secret` (default) | Production. Works with external secret managers (Vault, ESO, Sealed Secrets). |
| `pvc`              | StatefulSet with PersistentVolumeClaims.                                      |
| `hostPath`         | DaemonSet with node-local storage.                                            |
| `emptyDir`         | Testing only. Keypair lost on restart.                                        |

### Generating Secrets

```bash
# Generate keypairs for N replicas
./generate-secrets.sh 3

# Apply before installing
kubectl apply -f generated_secrets/generated_secrets.yaml

# Then install
helm install kagent . --set replicaCount=3 \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

Secret naming convention: `<release-name>-kagent-<replica-index>-secret`, each containing `private_key.pem` and `public_key.pem`.

For external secret manager integration (ESO, Vault, Sealed Secrets, SOPS), create Kubernetes secrets matching this naming pattern using your preferred tool.

## Configuration Reference

### Required

| Parameter                  | Description                                      |
| -------------------------- | ------------------------------------------------ |
| `kagent.companyId`         | Kentik company ID                                |
| `kagent.provisioningToken` | Provisioning token (stored as Kubernetes Secret) |

### Core Settings

| Parameter               | Default                   | Description                             |
| ----------------------- | ------------------------- | --------------------------------------- |
| `deploymentType`        | `statefulset`             | `statefulset` or `daemonset`            |
| `replicaCount`          | `1`                       | Replicas (StatefulSet only)             |
| `image.tag`             | `v5.0.19`                 | Agent image tag                         |
| `kagent.releaseChannel` | `stable`                  | Update channel: `stable`, `beta`, `dev` |
| `kagent.logLevel`       | `info`                    | `debug`, `info`, `warn`, `error`        |
| `kagent.apiEndpoint`    | `grpc.api.kentik.com:443` | Kentik API endpoint                     |

### Service

| Parameter                | Default     | Description                                 |
| ------------------------ | ----------- | ------------------------------------------- |
| `service.enabled`        | `false`     | Create a Service resource                   |
| `service.type`           | `ClusterIP` | `ClusterIP`, `NodePort`, or `LoadBalancer`  |
| `service.annotations`    | `{}`        | Service annotations (e.g., cloud LB config) |
| `service.<cap>.enabled`  | `false`     | Enable a specific capability port           |
| `service.<cap>.port`     | varies      | Override the default port                   |
| `service.<cap>.nodePort` | —           | Pin a NodePort (NodePort/LoadBalancer only) |

### Persistence

| Parameter                      | Default  | Description                                |
| ------------------------------ | -------- | ------------------------------------------ |
| `persistence.enabled`          | `true`   | Enable persistent storage                  |
| `persistence.type`             | `pvc`    | `pvc`, `hostPath`, or `emptyDir`           |
| `persistence.pvc.storageClass` | `""`     | Storage class (empty = cluster default)    |
| `persistence.pvc.size`         | `10Gi`   | Data volume size                           |
| `persistence.keypair.type`     | `secret` | `secret`, `pvc`, `hostPath`, or `emptyDir` |

### Security

| Parameter                      | Default | Description           |
| ------------------------------ | ------- | --------------------- |
| `podSecurityContext.runAsUser` | `500`   | Container user ID     |
| `networkPolicy.enabled`        | `false` | Enable NetworkPolicy  |
| `serviceAccount.create`        | `true`  | Create ServiceAccount |
| `rbac.create`                  | `false` | Create RBAC resources |

See [values.yaml](values.yaml) for all options and [contracts/values.schema.json](contracts/values.schema.json) for schema validation.

## Security Contexts

Some UA capabilities require specific Linux capabilities. The defaults drop all capabilities and add back only `NET_RAW`. Adjust based on which capabilities you enable:

| Linux Capability   | UA Capabilities                                                                 |
| ------------------ | ------------------------------------------------------------------------------- |
| `NET_ADMIN`        | DNS OTT Tap (kdns)                                                              |
| `NET_BIND_SERVICE` | BGP Proxy (kbgp), Flow Proxy (kproxy) - binding to ports below 1024             |
| `NET_RAW`          | SNMP/Streaming Telemetry (ranger), Synthetics (ksynth, livesynth) - raw sockets |

## Cloud Storage Classes

| Provider    | Storage Class     |
| ----------- | ----------------- |
| AWS (EKS)   | `gp3`             |
| Azure (AKS) | `managed-premium` |
| GCP (GKE)   | `standard-rwo`    |

```bash
helm install kagent . \
  --set persistence.pvc.storageClass=gp3 \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

## Upgrades

```bash
# Upgrade configuration
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set kagent.logLevel=debug

# Refresh an expired provisioning token
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=NEW_TOKEN
kubectl rollout restart statefulset/kagent
```

Switching between deployment patterns (StatefulSet ↔ DaemonSet) requires `helm uninstall` and a fresh install.

## Development

```bash
# Lint
helm lint . --set-string kagent.companyId=123 --set-string kagent.provisioningToken=tok

# Render templates
helm template kagent . --set-string kagent.companyId=123 --set-string kagent.provisioningToken=tok

# Run unit tests
helm unittest .
```

## Support

- Issues: https://github.com/kentik/kagent-helm/issues
- Kentik Support: support@kentik.com

## License

Copyright © 2025 Kentik
