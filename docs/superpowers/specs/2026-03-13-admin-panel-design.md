# OpenClaw Admin Panel — Design Spec

## Purpose

A lightweight web UI for creating OpenClaw agents. Replaces the manual `create-agent.sh` + `az` CLI workflow with a single form: enter Agent ID + Feishu App ID/Secret, click Create, and the agent starts running.

## Constraints

- **Single admin user** — no authentication, accessed via `kubectl port-forward`
- **Minimal scope** — create agents only (no edit/delete/monitoring in v1)
- **Feishu credentials only** — Azure OpenAI config reuses a shared template
- **Runs inside AKS** — Deployment on system nodepool, ClusterIP Service

## Architecture

```
Admin's browser
    │
    │  kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw
    ▼
┌─────────────────────────────────────┐
│  admin-panel Pod (system nodepool)  │
│                                     │
│  Node.js (Express)                  │
│  ├─ GET /           → index.html    │
│  ├─ GET /api/agents → list agents   │
│  └─ POST /api/agents → create agent │
│                                     │
│  Uses: kubectl, az CLI              │
│  ServiceAccount: openclaw-admin     │
└─────────────────────────────────────┘
    │
    ├──▶ Key Vault (az keyvault secret set)
    ├──▶ ConfigMap agent-mapping (kubectl patch)
    ├──▶ NFS share (kubectl Job to upload config)
    └──▶ StatefulSet (kubectl scale)
```

## API Design

### GET /

Returns the single-page HTML UI. No static file serving — the HTML is embedded in `server.js` or served from a co-located file.

### GET /api/agents

Returns JSON array of existing agents with pod status.

**Response:**
```json
[
  { "agentId": "alice", "ordinal": 0, "podStatus": "Running", "podReady": "2/2" },
  { "agentId": "bob", "ordinal": 1, "podStatus": "Pending", "podReady": "0/2" }
]
```

**Implementation:** Read ConfigMap `agent-mapping` for agent→ordinal mapping, then `kubectl get pods -n openclaw` for pod status. Join on ordinal.

### POST /api/agents

Creates a new agent. Returns progress via Server-Sent Events (SSE).

**Request body:**
```json
{
  "agentId": "alice",
  "feishuAppId": "cli_abcdef123456",
  "feishuAppSecret": "secret123"
}
```

**Validation:**
- `agentId`: 1-20 chars, lowercase alphanumeric + hyphens, no leading/trailing hyphens
- `feishuAppId`: non-empty string
- `feishuAppSecret`: non-empty string
- Agent ID must not already exist in ConfigMap

**SSE response stream:**
```
Content-Type: text/event-stream

data: {"step":1,"total":5,"status":"running","msg":"Storing Feishu credentials in Key Vault..."}

data: {"step":1,"total":5,"status":"done","msg":"Feishu credentials stored"}

data: {"step":2,"total":5,"status":"running","msg":"Generating agent config..."}

...

data: {"step":5,"total":5,"status":"done","msg":"Agent alice created successfully","done":true}
```

On error at any step:
```
data: {"step":3,"total":5,"status":"error","msg":"Failed to upload config: <error detail>"}
```

## Creation Flow (5 Steps)

Each step is a shell command executed via `child_process.execFile()`:

### Step 1: Store Feishu credentials in Key Vault

```bash
az keyvault secret set --vault-name <KV_NAME> --name "feishu-app-id-<agentId>" --value "<appId>"
az keyvault secret set --vault-name <KV_NAME> --name "feishu-app-secret-<agentId>" --value "<appSecret>"
```

### Step 2: Generate agent config

Build `openclaw.json` from a template with the shared Azure OpenAI endpoint/key. Also generate `feishu.env` with per-agent Feishu credentials. Write both to a temporary ConfigMap:

```bash
kubectl create configmap agent-config-<agentId> -n openclaw \
  --from-literal=openclaw.json="<generated-json>" \
  --from-literal=feishu.env="export FEISHU_APP_ID=<appId>\nexport FEISHU_APP_SECRET=<appSecret>\n"
```

The config template uses environment variables `AZURE_OPENAI_ENDPOINT` and `AZURE_OPENAI_KEY` injected into the admin pod. APIM is currently disabled (`enable_apim=false`), so the config uses the direct Azure OpenAI endpoint.

### Step 3: Upload config to NFS

Create a Job that mounts the NFS PVC and copies the config:

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: upload-config-<agentId>
  namespace: openclaw
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: uploader
        image: alpine:3.20
        command: ["sh", "-c", "mkdir -p /shared/<agentId>/config && cp /config/openclaw.json /shared/<agentId>/config/openclaw.json && cp /config/feishu.env /shared/<agentId>/config/feishu.env"]
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
        volumeMounts:
        - { name: shared-data, mountPath: /shared }
        - { name: config, mountPath: /config }
      volumes:
      - { name: shared-data, persistentVolumeClaim: { claimName: openclaw-shared-data } }
      - { name: config, configMap: { name: agent-config-<agentId> } }
EOF
kubectl wait --for=condition=complete job/upload-config-<agentId> -n openclaw --timeout=120s
kubectl delete configmap agent-config-<agentId> -n openclaw
kubectl delete job upload-config-<agentId> -n openclaw
```

### Step 4: Update ConfigMap agent-mapping

```bash
CURRENT_REPLICAS=$(kubectl get sts openclaw-agent -n openclaw -o jsonpath='{.spec.replicas}')
NEW_ORDINAL=$CURRENT_REPLICAS
kubectl patch configmap agent-mapping -n openclaw --type merge \
  -p "{\"data\":{\"agent-${NEW_ORDINAL}\":\"${agentId}\"}}"
```

### Step 5: Scale StatefulSet

```bash
NEW_REPLICAS=$((CURRENT_REPLICAS + 1))
kubectl scale sts openclaw-agent -n openclaw --replicas=$NEW_REPLICAS
```

## Frontend (index.html)

Single HTML file, no framework, no build step.

**Layout:**
- Header: "OpenClaw Admin"
- Create form: Agent ID, Feishu App ID, Feishu App Secret inputs + Create button
- Progress area: 5-step checklist with status icons (⏳ → ✅ / ❌), hidden until creation starts
- Agent list: Table showing existing agents + pod status, auto-refreshed on page load

**Behavior:**
- Form submit → `fetch('/api/agents', { method: 'POST', body })` with EventSource for SSE
- Each SSE message updates the corresponding step's icon
- On completion, refresh agent list
- On error, show error message, keep form populated for retry
- Disable form during creation to prevent double-submit

**Styling:** Minimal, clean. Dark theme to match terminal aesthetic. CSS variables for theming. No external dependencies.

## Docker Image

```dockerfile
FROM node:22-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -LO "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json server.js index.html ./
RUN npm install --omit=dev

USER 1000
EXPOSE 3000
CMD ["node", "server.js"]
```

Dependencies: `express` only.

Image will be pushed to the existing ACR as `openclaw-admin:latest`.

## K8s Resources

### ServiceAccount + RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openclaw-admin
  namespace: openclaw
  annotations:
    azure.workload.identity/client-id: "<admin_identity_client_id>"
  labels:
    azure.workload.identity/use: "true"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: openclaw-admin
  namespace: openclaw
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "create", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["statefulsets"]
  verbs: ["get", "patch"]
  resourceNames: ["openclaw-agent"]
- apiGroups: ["apps"]
  resources: ["statefulsets/scale"]
  verbs: ["get", "patch"]
  resourceNames: ["openclaw-agent"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["create", "get", "list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: openclaw-admin
  namespace: openclaw
subjects:
- kind: ServiceAccount
  name: openclaw-admin
roleRef:
  kind: Role
  name: openclaw-admin
  apiGroup: rbac.authorization.k8s.io
```

The ServiceAccount needs Key Vault write access via Workload Identity:

1. **Terraform** creates a dedicated `openclaw-admin-identity` User-Assigned MI
2. **Federated Identity Credential** links K8s SA `openclaw:openclaw-admin` to this MI
3. **Role Assignment**: `Key Vault Secrets Officer` on the MI (write access, not just read)
4. **SA annotation**: `azure.workload.identity/client-id: <admin_identity_client_id>`
5. **Pod label**: `azure.workload.identity/use: "true"` — webhook auto-injects env vars + token

The admin pod runs `az login --federated-token` on startup using the injected credentials.

### Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-admin
  namespace: openclaw
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openclaw-admin
  template:
    metadata:
      labels:
        app: openclaw-admin
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: openclaw-admin
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: admin
        image: <ACR>/openclaw-admin:latest
        ports:
        - containerPort: 3000
        env:
        - name: KV_NAME
          value: "<keyvault-name>"
        - name: AZURE_OPENAI_ENDPOINT
          value: "https://ai-admin5311ai774489569826.cognitiveservices.azure.com/openai/v1"
        - name: AZURE_OPENAI_KEY
          valueFrom:
            secretKeyRef:
              name: azure-openai-credentials
              key: api-key
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 500m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: openclaw-admin
  namespace: openclaw
spec:
  selector:
    app: openclaw-admin
  ports:
  - port: 3000
    targetPort: 3000
```

## Configuration

Environment variables injected into the admin pod:

| Variable | Source | Description |
|----------|--------|-------------|
| `KV_NAME` | Terraform output `keyvault_name` | Key Vault name for storing Feishu secrets |
| `AZURE_OPENAI_ENDPOINT` | Hardcoded or ConfigMap | Shared Azure OpenAI endpoint URL |
| `AZURE_OPENAI_KEY` | K8s Secret | Shared Azure OpenAI API key |

## File Structure

```
admin/
├── Dockerfile          # Node.js + kubectl + az-cli
├── package.json        # express dependency
├── server.js           # Express server (~200 lines)
├── index.html          # Single-page UI (~250 lines)
└── k8s/
    ├── deployment.yaml # Deployment + Service
    ├── rbac.yaml       # ServiceAccount + Role + RoleBinding
    └── secret.yaml     # Azure OpenAI key (template with placeholder)
```

## Error Handling

- **Duplicate agent ID**: Checked before step 1 by reading ConfigMap. Returns 409 Conflict.
- **Key Vault failure**: Step 1 fails, SSE reports error, no cleanup needed.
- **NFS upload timeout**: Step 3 fails after 120s. Cleanup: delete ConfigMap + Job.
- **Scale failure**: Step 5 fails. Agent mapping is already set but pod won't start. Admin can retry or check logs.
- **Partial failure recovery**: Each step is idempotent (Key Vault set overwrites, ConfigMap patch merges, Job names include agentId). Re-submitting the same agent ID after partial failure should work.

## Security

- No authentication — security relies on `kubectl port-forward` access control
- Pod runs as non-root (UID 1000), PSS restricted compliant
- Azure OpenAI key stored in K8s Secret, not hardcoded
- Feishu credentials go directly to Key Vault, never persisted on disk
- RBAC scoped to `openclaw` namespace only, minimal verbs

## Access

```bash
kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw
# Then open http://localhost:3000
```

## Out of Scope (v1)

- Edit or delete existing agents
- Agent monitoring / log viewing
- Multiple Azure OpenAI endpoints per agent
- Resource limit configuration per agent
- Authentication / multi-user
- Public-facing ingress
