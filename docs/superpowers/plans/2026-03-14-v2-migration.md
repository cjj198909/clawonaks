# v2 Migration Implementation Plan: StatefulSet → Independent Deployment + KV CSI Config

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate from shared StatefulSet to independent Deployments per agent, with KV CSI-based credential injection replacing the NFS config chain.

**Architecture:** Each agent becomes a Deployment (replicas=1) + PVC + SecretProviderClass. Non-sensitive config is inlined in the init container shell script. Sensitive credentials (Feishu, Azure OpenAI key) are pulled from Key Vault via CSI Secret Store driver to a tmpfs mount. The init container reads the tmpfs files and assembles `openclaw.json` on the work-disk PVC. persist-sync sidecar is retained at 1h interval for NFS backup.

**Tech Stack:** Kubernetes manifests (YAML), Node.js/Express (admin server.js), HTML/CSS/JS (admin index.html), Azure Key Vault CSI Secret Store, Azure CLI, kubectl.

**Spec:** `docs/superpowers/specs/2026-03-14-v2-migration-design.md`

---

## File Map

### Files to Create

| File | Responsibility |
|------|---------------|
| `k8s/sandbox/agent-deployment.template.yaml` | Per-agent Deployment + SPC + PVC template (3 YAML documents) with `<placeholders>`. This is the canonical manifest; the JS builders in `server.js` are derived from it. |

### Files to Modify

| File | What Changes |
|------|-------------|
| `admin/server.js` | Rewrite POST/GET/DELETE routes: eliminate STS/ConfigMap/Job logic, add SPC+PVC+Deployment YAML generation, add DELETE endpoint |
| `admin/index.html` | Update progress steps (5→3), add delete button, remove ordinal column, update agent list |
| `admin/k8s/rbac.yaml` | Replace STS/Job/ConfigMap permissions with Deployment/PVC/SPC permissions |
| `admin/k8s/deployment.yaml` | Remove `AZURE_OPENAI_KEY` env var and `azure-openai-credentials` Secret ref |
| `k8s/sandbox/feishu-secret-provider.yaml` | Delete (replaced by per-agent SPC in template) |
| `CLAUDE.md` | Update §2.5, §4, §5, §6, §8 to reflect v2 architecture |

### Canonical Template vs JS Builders

`k8s/sandbox/agent-deployment.template.yaml` is the **canonical source of truth** for the per-agent manifest. The JS builder functions in `admin/server.js` (`buildSpcYaml`, `buildPvcYaml`, `buildDeploymentYaml`) are derived from this template and must stay in sync. When modifying the Deployment spec, update the template file first, then mirror the change to the JS builders. The template file is used for manual `sed`-based deployment; the JS builders are used by the Admin Panel.

### Files Unchanged

| File | Why |
|------|-----|
| `k8s/sandbox/service-account.yaml` | SA + Workload Identity annotation unchanged |
| `k8s/namespaces.yaml` | Namespace unchanged |
| `k8s/storage/disk-storageclass.yaml` | StorageClass unchanged |
| `k8s/storage/files-storageclass.yaml` | NFS StorageClass unchanged |
| `k8s/security/netpol-sandbox.yaml` | NetworkPolicy unchanged |
| `admin/Dockerfile` | No changes needed |
| `admin/package.json` | No changes needed |
| `docker/Dockerfile` | Agent image unchanged |
| `docker/persist-sync/Dockerfile` | Sidecar image unchanged |

---

## Chunk 1: K8s Manifests + RBAC

### Task 1: Create per-agent Deployment template

**Files:**
- Create: `k8s/sandbox/agent-deployment.template.yaml`

This file is the v2 replacement for `k8s/sandbox/agent-statefulset.yaml`. It contains the complete Deployment + PVC YAML from the spec §4.5 with `<placeholders>` for `sed` substitution (matching the existing project convention documented in CLAUDE.md §3.2).

- [ ] **Step 1: Create the Deployment + PVC template file**

```yaml
# k8s/sandbox/agent-deployment.template.yaml
#
# Per-agent Deployment template. Placeholders:
#   <agentId>                    - Agent identifier (e.g. alice)
#   <acr_login_server>           - ACR login server (e.g. openclawacre2a78886.azurecr.io)
#   <azure_openai_endpoint>      - Azure OpenAI endpoint URL
#   <sandbox_identity_client_id> - Sandbox MI client ID
#   <keyvault_name>              - Key Vault name
#   <tenant-id>                  - Azure tenant ID
#
# Usage: sed -e 's/<agentId>/alice/g' -e 's/<acr_login_server>/xxx/g' ... < template > deploy/agent-alice.yaml
# Then:  kubectl apply -f deploy/agent-alice.yaml
#
# This file contains THREE documents separated by ---:
#   1. SecretProviderClass (spc-<agentId>)
#   2. PVC (work-disk-<agentId>)
#   3. Deployment (openclaw-agent-<agentId>)
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: spc-<agentId>
  namespace: openclaw
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "<sandbox_identity_client_id>"
    keyvaultName: "<keyvault_name>"
    tenantId: "<tenant-id>"
    objects: |
      array:
        - |
          objectName: feishu-app-id-<agentId>
          objectType: secret
          objectAlias: feishu-app-id
        - |
          objectName: feishu-app-secret-<agentId>
          objectType: secret
          objectAlias: feishu-app-secret
        - |
          objectName: azure-openai-key
          objectType: secret
          objectAlias: azure-openai-key
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: work-disk-<agentId>
  namespace: openclaw
  labels:
    app: openclaw-sandbox
    openclaw.io/agent-id: <agentId>
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: openclaw-disk
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-agent-<agentId>
  namespace: openclaw
  labels:
    app: openclaw-sandbox
    openclaw.io/agent-id: <agentId>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openclaw-sandbox
      openclaw.io/agent-id: <agentId>
  template:
    metadata:
      labels:
        app: openclaw-sandbox
        openclaw.io/agent-id: <agentId>
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: openclaw-sandbox
      runtimeClassName: kata-vm-isolation
      terminationGracePeriodSeconds: 30
      nodeSelector:
        openclaw.io/role: sandbox
      tolerations:
      - key: openclaw.io/sandbox
        operator: Equal
        value: "true"
        effect: NoSchedule
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      # 1. Config assembly: reads KV secrets from CSI, writes config.json to PVC
      - name: setup-config
        image: busybox:1.36
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          OPENCLAW_DIR=/home/node/.openclaw
          mkdir -p "$OPENCLAW_DIR/workspace/memory" "$OPENCLAW_DIR/devices" "$OPENCLAW_DIR/sessions"
          if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then
            echo "Config exists on PVC, preserving runtime state"
            exit 0
          fi
          FEISHU_ID=$(cat /secrets/feishu-app-id)
          FEISHU_SECRET=$(cat /secrets/feishu-app-secret)
          AOAI_KEY=$(cat /secrets/azure-openai-key)
          printf '%s\n' "{\"gateway\":{\"mode\":\"local\"},\"channels\":{\"feishu\":{\"enabled\":true,\"appId\":\"$FEISHU_ID\",\"appSecret\":\"$FEISHU_SECRET\"}},\"models\":{\"providers\":{\"azure-openai-direct\":{\"baseUrl\":\"$AOAI_ENDPOINT\",\"apiKey\":\"$AOAI_KEY\",\"api\":\"openai-responses\",\"headers\":{\"api-version\":\"2025-04-01-preview\"},\"models\":[{\"id\":\"gpt-5.4\",\"name\":\"GPT-5.4 (Direct Azure OpenAI)\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
          echo "Config assembled from KV secrets"
        env:
        - name: AOAI_ENDPOINT
          value: "<azure_openai_endpoint>"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 200m
            memory: 64Mi
        volumeMounts:
        - name: kv-secrets
          mountPath: /secrets
          readOnly: true
        - name: work-disk
          mountPath: /home/node/.openclaw
      # 2. persist-sync: Native Sidecar, backs up runtime state to NFS every 1h
      - name: persist-sync
        restartPolicy: Always
        image: <acr_login_server>/persist-sync:latest
        imagePullPolicy: Always
        command: ["/bin/sh", "-c"]
        args:
        - |
          OPENCLAW_DIR=/home/node/.openclaw
          PERSIST="/persist/agents/$AGENT_ID"
          echo "[persist-sync] Agent: $AGENT_ID, backup path: $PERSIST"
          mkdir -p "$PERSIST"
          sync_files() {
            for f in openclaw.json auth-profiles.json; do
              [ -f "$OPENCLAW_DIR/$f" ] && cp "$OPENCLAW_DIR/$f" "$PERSIST/$f" 2>/dev/null || true
            done
          }
          trap 'echo "[persist-sync] SIGTERM, final sync..."; sync_files; exit 0' TERM INT
          while true; do
            sleep 3600
            sync_files
          done
        env:
        - name: AGENT_ID
          value: "<agentId>"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
          readOnly: true
        - name: persist-files
          mountPath: /persist
      containers:
      - name: openclaw
        image: <acr_login_server>/openclaw-agent:latest
        imagePullPolicy: Always
        command: ["/bin/sh", "-c"]
        args:
        - exec openclaw gateway run --verbose
        env:
        - name: NODE_OPTIONS
          value: "--max-old-space-size=2048"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 3Gi
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
      volumes:
      - name: kv-secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: spc-<agentId>
      - name: work-disk
        persistentVolumeClaim:
          claimName: work-disk-<agentId>
      - name: persist-files
        persistentVolumeClaim:
          claimName: openclaw-shared-data
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml, sys; list(yaml.safe_load_all(open(sys.argv[1])))" k8s/sandbox/agent-deployment.template.yaml && echo "YAML OK"`
Expected: `YAML OK` (no errors)

- [ ] **Step 3: Commit**

```bash
git add k8s/sandbox/agent-deployment.template.yaml
git commit -m "feat(k8s): add v2 per-agent Deployment+SPC+PVC template

Replaces shared StatefulSet with independent Deployment per agent.
Includes SecretProviderClass for KV CSI credential injection."
```

### Task 2: Update Admin Panel RBAC

**Files:**
- Modify: `admin/k8s/rbac.yaml` (lines 16-37: Role rules)

Replace all five `rules` entries. Keep ServiceAccount and RoleBinding unchanged.

- [ ] **Step 1: Replace the Role rules**

Replace the entire `rules:` section (lines 16-37) with:

```yaml
rules:
# Deployments: create, list, delete agent Deployments
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "create", "delete"]
# PVCs: create, list, delete agent work disks
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "create", "delete"]
# SecretProviderClasses: create, delete per-agent SPC
- apiGroups: ["secrets-store.csi.x-k8s.io"]
  resources: ["secretproviderclasses"]
  verbs: ["get", "list", "create", "delete"]
# Pods: list for agent status
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
# Pods/exec: for credential rotation (delete config file)
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
```

- [ ] **Step 2: Commit**

```bash
git add admin/k8s/rbac.yaml
git commit -m "feat(admin): update RBAC for v2 Deployment model

Replace StatefulSet/Job/ConfigMap permissions with
Deployment/PVC/SecretProviderClass permissions."
```

### Task 3: Update Admin Panel Deployment manifest

**Files:**
- Modify: `admin/k8s/deployment.yaml` (lines 30-34: AZURE_OPENAI_KEY env)

- [ ] **Step 1: Remove the AZURE_OPENAI_KEY env var block**

Delete lines 30-34 from `admin/k8s/deployment.yaml`:

```yaml
        - name: AZURE_OPENAI_KEY
          valueFrom:
            secretKeyRef:
              name: azure-openai-credentials
              key: api-key
```

The Admin Panel no longer needs the Azure OpenAI key — it is now injected directly into agent Pods via KV CSI.

- [ ] **Step 2: Commit**

```bash
git add admin/k8s/deployment.yaml
git commit -m "feat(admin): remove AZURE_OPENAI_KEY from Admin Panel deployment

API key now lives exclusively in Key Vault, injected into
agent Pods via CSI Secret Store driver."
```

### Task 4: Remove old feishu-secret-provider.yaml

**Files:**
- Delete: `k8s/sandbox/feishu-secret-provider.yaml`

This file defined a single shared SecretProviderClass. v2 uses per-agent SPCs generated dynamically.

- [ ] **Step 1: Delete the file**

```bash
git rm k8s/sandbox/feishu-secret-provider.yaml
```

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor(k8s): remove shared feishu-secret-provider

Replaced by per-agent SecretProviderClass (spc-<agentId>)
generated by Admin Panel from template."
```

---

## Chunk 2: Admin Panel server.js Rewrite

### Task 5: Rewrite YAML builder functions in server.js

**Files:**
- Modify: `admin/server.js` (lines 54-133: remove `buildConfigJson`, `buildFeishuEnv`, `buildUploadJobYaml`; add `buildSpcYaml`, `buildPvcYaml`, `buildDeploymentYaml`)

This task replaces the three v1 builder functions with three v2 builder functions that generate K8s YAML strings for `kubectl apply -f -`.

- [ ] **Step 1: Remove old builder functions and add new ones**

Remove `buildConfigJson` (lines 54-81), `buildFeishuEnv` (lines 83-88), `buildUploadJobYaml` (lines 90-133).

Remove the `AZURE_OPENAI_KEY` constant from line 14.

Remove the `creating` mutex from lines 16-17.

Add the following new functions and constants after `validateAgentId`:

```javascript
// --- Additional env vars for v2 YAML generation ---
const SANDBOX_MI_CLIENT_ID = process.env.SANDBOX_MI_CLIENT_ID || '';
const TENANT_ID = process.env.TENANT_ID || '';
const ACR_LOGIN_SERVER = process.env.ACR_LOGIN_SERVER || '';

function buildSpcYaml(agentId) {
  return `apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: spc-${agentId}
  namespace: ${NAMESPACE}
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "${SANDBOX_MI_CLIENT_ID}"
    keyvaultName: "${KV_NAME}"
    tenantId: "${TENANT_ID}"
    objects: |
      array:
        - |
          objectName: feishu-app-id-${agentId}
          objectType: secret
          objectAlias: feishu-app-id
        - |
          objectName: feishu-app-secret-${agentId}
          objectType: secret
          objectAlias: feishu-app-secret
        - |
          objectName: azure-openai-key
          objectType: secret
          objectAlias: azure-openai-key
`;
}

function buildPvcYaml(agentId) {
  return `apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: work-disk-${agentId}
  namespace: ${NAMESPACE}
  labels:
    app: openclaw-sandbox
    openclaw.io/agent-id: "${agentId}"
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: openclaw-disk
  resources:
    requests:
      storage: 5Gi
`;
}

function buildDeploymentYaml(agentId) {
  return `apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-agent-${agentId}
  namespace: ${NAMESPACE}
  labels:
    app: openclaw-sandbox
    openclaw.io/agent-id: "${agentId}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openclaw-sandbox
      openclaw.io/agent-id: "${agentId}"
  template:
    metadata:
      labels:
        app: openclaw-sandbox
        openclaw.io/agent-id: "${agentId}"
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: openclaw-sandbox
      runtimeClassName: kata-vm-isolation
      terminationGracePeriodSeconds: 30
      nodeSelector:
        openclaw.io/role: sandbox
      tolerations:
      - key: openclaw.io/sandbox
        operator: Equal
        value: "true"
        effect: NoSchedule
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      - name: setup-config
        image: busybox:1.36
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          OPENCLAW_DIR=/home/node/.openclaw
          mkdir -p "$OPENCLAW_DIR/workspace/memory" "$OPENCLAW_DIR/devices" "$OPENCLAW_DIR/sessions"
          if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then
            echo "Config exists on PVC, preserving runtime state"
            exit 0
          fi
          FEISHU_ID=$(cat /secrets/feishu-app-id)
          FEISHU_SECRET=$(cat /secrets/feishu-app-secret)
          AOAI_KEY=$(cat /secrets/azure-openai-key)
          printf '%s\\n' "{\\"gateway\\":{\\"mode\\":\\"local\\"},\\"channels\\":{\\"feishu\\":{\\"enabled\\":true,\\"appId\\":\\"$FEISHU_ID\\",\\"appSecret\\":\\"$FEISHU_SECRET\\"}},\\"models\\":{\\"providers\\":{\\"azure-openai-direct\\":{\\"baseUrl\\":\\"${AZURE_OPENAI_ENDPOINT}\\",\\"apiKey\\":\\"$AOAI_KEY\\",\\"api\\":\\"openai-responses\\",\\"headers\\":{\\"api-version\\":\\"2025-04-01-preview\\"},\\"models\\":[{\\"id\\":\\"gpt-5.4\\",\\"name\\":\\"GPT-5.4 (Direct Azure OpenAI)\\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
          echo "Config assembled from KV secrets"
        env:
        - name: AOAI_ENDPOINT
          value: "${AZURE_OPENAI_ENDPOINT}"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 200m
            memory: 64Mi
        volumeMounts:
        - name: kv-secrets
          mountPath: /secrets
          readOnly: true
        - name: work-disk
          mountPath: /home/node/.openclaw
      - name: persist-sync
        restartPolicy: Always
        image: ${ACR_LOGIN_SERVER}/persist-sync:latest
        imagePullPolicy: Always
        command: ["/bin/sh", "-c"]
        args:
        - |
          OPENCLAW_DIR=/home/node/.openclaw
          PERSIST="/persist/agents/$AGENT_ID"
          echo "[persist-sync] Agent: $AGENT_ID, backup path: $PERSIST"
          mkdir -p "$PERSIST"
          sync_files() {
            for f in openclaw.json auth-profiles.json; do
              [ -f "$OPENCLAW_DIR/$f" ] && cp "$OPENCLAW_DIR/$f" "$PERSIST/$f" 2>/dev/null || true
            done
          }
          trap 'echo "[persist-sync] SIGTERM, final sync..."; sync_files; exit 0' TERM INT
          while true; do
            sleep 3600
            sync_files
          done
        env:
        - name: AGENT_ID
          value: "${agentId}"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
          readOnly: true
        - name: persist-files
          mountPath: /persist
      containers:
      - name: openclaw
        image: ${ACR_LOGIN_SERVER}/openclaw-agent:latest
        imagePullPolicy: Always
        command: ["/bin/sh", "-c"]
        args:
        - exec openclaw gateway run --verbose
        env:
        - name: NODE_OPTIONS
          value: "--max-old-space-size=2048"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 3Gi
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
      volumes:
      - name: kv-secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: spc-${agentId}
      - name: work-disk
        persistentVolumeClaim:
          claimName: work-disk-${agentId}
      - name: persist-files
        persistentVolumeClaim:
          claimName: openclaw-shared-data
`;
}
```

- [ ] **Step 2: Commit**

```bash
git add admin/server.js
git commit -m "feat(admin): replace v1 builders with v2 SPC+PVC+Deployment YAML generators"
```

### Task 6: Rewrite GET /api/agents route

**Files:**
- Modify: `admin/server.js` (lines 141-173: GET `/api/agents` handler)

Replace ConfigMap `agent-mapping` lookup with Deployment label selector query.

- [ ] **Step 1: Replace the GET handler**

Replace the entire `app.get('/api/agents', ...)` handler with:

```javascript
app.get('/api/agents', async (_req, res) => {
  try {
    const deploymentsRaw = await kubectl(
      'get', 'deployments', '-n', NAMESPACE, '-l', 'app=openclaw-sandbox', '-o', 'json'
    );
    const deployments = JSON.parse(deploymentsRaw);

    const podsRaw = await kubectl(
      'get', 'pods', '-n', NAMESPACE, '-l', 'app=openclaw-sandbox', '-o', 'json'
    );
    const pods = JSON.parse(podsRaw);

    const agents = (deployments.items || []).map(dep => {
      const agentId = dep.metadata.labels?.['openclaw.io/agent-id'] || dep.metadata.name.replace('openclaw-agent-', '');
      const pod = pods.items?.find(p =>
        p.metadata.labels?.['openclaw.io/agent-id'] === agentId
      );
      const ready = pod?.status?.containerStatuses?.filter(c => c.ready).length || 0;
      const total = pod?.spec?.containers?.length || 0;
      return {
        agentId,
        podStatus: pod?.status?.phase || 'Not Found',
        podReady: `${ready}/${total}`,
        replicas: dep.spec?.replicas || 0,
      };
    }).sort((a, b) => a.agentId.localeCompare(b.agentId));

    res.json(agents);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
```

- [ ] **Step 2: Commit**

```bash
git add admin/server.js
git commit -m "feat(admin): rewrite GET /api/agents to query Deployments instead of ConfigMap"
```

### Task 7: Rewrite POST /api/agents route

**Files:**
- Modify: `admin/server.js` (lines 175-278: POST `/api/agents` handler)

Replace the 5-step flow (KV → ConfigMap → Job → mapping → scale STS) with 3-step flow (KV → SPC → PVC+Deployment). Remove the `creating` mutex.

- [ ] **Step 1: Replace the POST handler**

Replace the entire `app.post('/api/agents', ...)` handler with:

```javascript
app.post('/api/agents', async (req, res) => {
  const { agentId, feishuAppId, feishuAppSecret } = req.body || {};

  // --- Validation ---
  const idErr = validateAgentId(agentId);
  if (idErr) return res.status(400).json({ error: idErr });
  if (!feishuAppId || typeof feishuAppId !== 'string')
    return res.status(400).json({ error: 'Feishu App ID is required' });
  if (!feishuAppSecret || typeof feishuAppSecret !== 'string')
    return res.status(400).json({ error: 'Feishu App Secret is required' });

  // Check duplicate: does Deployment already exist?
  try {
    await kubectl('get', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE);
    return res.status(409).json({ error: `Agent '${agentId}' already exists` });
  } catch {
    // 404 = not found = good, proceed
  }

  // --- SSE stream ---
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  const send = (step, status, msg, extra = {}) => {
    res.write(`data: ${JSON.stringify({ step, total: 3, status, msg, ...extra })}\n\n`);
  };

  let currentStep = 0;
  try {
    // Step 1: Store Feishu credentials in Key Vault
    currentStep = 1;
    send(1, 'running', 'Storing Feishu credentials in Key Vault...');
    await azLogin();
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
      '--name', `feishu-app-id-${agentId}`, '--value', feishuAppId);
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
      '--name', `feishu-app-secret-${agentId}`, '--value', feishuAppSecret);
    send(1, 'done', 'Feishu credentials stored in Key Vault');

    // Step 2: Create SecretProviderClass
    currentStep = 2;
    send(2, 'running', 'Creating SecretProviderClass...');
    await kubectlApplyStdin(buildSpcYaml(agentId));
    send(2, 'done', 'SecretProviderClass created');

    // Step 3: Create PVC + Deployment
    currentStep = 3;
    send(3, 'running', 'Creating PVC and Deployment...');
    await kubectlApplyStdin(buildPvcYaml(agentId));
    await kubectlApplyStdin(buildDeploymentYaml(agentId));
    send(3, 'done', `Agent ${agentId} created successfully`, { done: true });
  } catch (err) {
    send(currentStep, 'error', `Creation failed: ${err.message}`);
    // Best-effort cleanup on failure
    if (currentStep >= 3) {
      await kubectl('delete', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'pvc', `work-disk-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
    }
    if (currentStep >= 2) {
      await kubectl('delete', 'secretproviderclass', `spc-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
    }
  }

  res.end();
});
```

- [ ] **Step 2: Commit**

```bash
git add admin/server.js
git commit -m "feat(admin): rewrite POST /api/agents for v2 (KV → SPC → Deployment)"
```

### Task 8: Add DELETE /api/agents/:id route

**Files:**
- Modify: `admin/server.js` (add new route after POST handler)

This is a new endpoint for deleting agents — previously impossible with the StatefulSet model.

- [ ] **Step 1: Add the DELETE handler**

Add after the POST handler:

```javascript
app.delete('/api/agents/:id', async (req, res) => {
  const agentId = req.params.id;
  const idErr = validateAgentId(agentId);
  if (idErr) return res.status(400).json({ error: idErr });

  const deletePvc = req.query.deletePvc === 'true';
  const deleteKv = req.query.deleteKv === 'true';

  try {
    // Verify agent exists
    await kubectl('get', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE);
  } catch {
    return res.status(404).json({ error: `Agent '${agentId}' not found` });
  }

  const results = [];
  try {
    await kubectl('delete', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE);
    results.push('Deployment deleted');

    await kubectl('delete', 'secretproviderclass', `spc-${agentId}`, '-n', NAMESPACE, '--ignore-not-found');
    results.push('SecretProviderClass deleted');

    if (deletePvc) {
      await kubectl('delete', 'pvc', `work-disk-${agentId}`, '-n', NAMESPACE, '--ignore-not-found');
      results.push('PVC deleted');
    }

    if (deleteKv) {
      await azLogin();
      await az('keyvault', 'secret', 'delete', '--vault-name', KV_NAME,
        '--name', `feishu-app-id-${agentId}`).catch(() => {});
      await az('keyvault', 'secret', 'delete', '--vault-name', KV_NAME,
        '--name', `feishu-app-secret-${agentId}`).catch(() => {});
      results.push('KV secrets deleted');
    }

    // Note: NFS backup at /persist/agents/<agentId>/ is NOT auto-deleted.
    // This is intentional — backup data may be needed for recovery.
    // Manual cleanup: kubectl exec into any pod with NFS mount and rm -rf the directory.

    res.json({ ok: true, results });
  } catch (err) {
    res.status(500).json({ error: err.message, results });
  }
});
```

- [ ] **Step 2: Commit**

```bash
git add admin/server.js
git commit -m "feat(admin): add DELETE /api/agents/:id endpoint for agent removal"
```

### Task 9: Clean up server.js top-level (remove dead code)

**Files:**
- Modify: `admin/server.js` (top-level constants and imports)

- [ ] **Step 1: Final cleanup**

Ensure the top of `server.js` has these constants (remove `AZURE_OPENAI_KEY` and `creating` mutex):

```javascript
const NAMESPACE = process.env.NAMESPACE || 'openclaw';
const KV_NAME = process.env.KV_NAME || '';
const AZURE_OPENAI_ENDPOINT = process.env.AZURE_OPENAI_ENDPOINT || '';
const SANDBOX_MI_CLIENT_ID = process.env.SANDBOX_MI_CLIENT_ID || '';
const TENANT_ID = process.env.TENANT_ID || '';
const ACR_LOGIN_SERVER = process.env.ACR_LOGIN_SERVER || '';
```

Verify no references remain to:
- `AZURE_OPENAI_KEY`
- `creating` (mutex)
- `buildConfigJson`
- `buildFeishuEnv`
- `buildUploadJobYaml`
- `agent-mapping` (ConfigMap name)
- `statefulset` / `sts` (any STS references)

Verify these functions are **preserved unchanged**:
- `kubectlApplyStdin()` (lines 32-44) — used by POST handler
- `azLogin()` (lines 282-301) — used by POST, DELETE, and startup
- `main()` (lines 303-316) — startup + token refresh interval

- [ ] **Step 2: Commit**

```bash
git add admin/server.js
git commit -m "refactor(admin): clean up dead v1 references from server.js"
```

---

## Chunk 3: Admin Panel UI + Admin Deployment + CLAUDE.md + Build + Migration

### Task 10: Update index.html for v2

**Files:**
- Modify: `admin/index.html`

Changes: progress steps 5→3, remove ordinal column, add delete button per agent.

- [ ] **Step 1: Update progress step labels**

Replace lines 92-96 (the 5 progress step divs) with 3 steps:

```html
      <div class="step" data-step="1"><span class="step-icon">⏳</span> Store Feishu credentials in Key Vault</div>
      <div class="step" data-step="2"><span class="step-icon">⏳</span> Create SecretProviderClass</div>
      <div class="step" data-step="3"><span class="step-icon">⏳</span> Create PVC and Deployment</div>
```

- [ ] **Step 2: Update the agent list table**

Replace the `loadAgents` function (lines 199-223) with:

```javascript
    async function loadAgents() {
      const el = document.getElementById('agentList');
      try {
        const resp = await fetch('/api/agents');
        const agents = await resp.json();
        if (!agents.length) {
          el.innerHTML = '<p class="empty">No agents yet</p>';
          return;
        }
        el.innerHTML = `<table>
          <tr><th>Agent ID</th><th>Status</th><th>Ready</th><th>Actions</th></tr>
          ${agents.map(a => {
            const cls = a.podStatus === 'Running' ? 'running' : a.podStatus === 'Pending' ? 'pending' : 'other';
            return `<tr>
              <td><strong>${esc(a.agentId)}</strong></td>
              <td><span class="badge badge-${cls}">${esc(a.podStatus)}</span></td>
              <td>${esc(a.podReady)}</td>
              <td><button class="btn-delete" onclick="deleteAgent('${esc(a.agentId)}')">Delete</button></td>
            </tr>`;
          }).join('')}
        </table>`;
      } catch (err) {
        el.innerHTML = `<p class="empty">Failed to load agents: ${esc(err.message)}</p>`;
      }
    }
```

- [ ] **Step 3: Add deleteAgent function and button style**

Add `deleteAgent` function before the `loadAgents()` call:

```javascript
    async function deleteAgent(agentId) {
      if (!confirm(`Delete agent "${agentId}"? The PVC (workspace data) will be preserved.`)) return;
      try {
        const resp = await fetch(`/api/agents/${agentId}`, { method: 'DELETE' });
        const data = await resp.json();
        if (!resp.ok) throw new Error(data.error || `HTTP ${resp.status}`);
        loadAgents();
      } catch (err) {
        alert(`Delete failed: ${err.message}`);
      }
    }
```

Add CSS for the delete button (inside the `<style>` block):

```css
    .btn-delete {
      background: transparent; color: var(--red); border: 1px solid var(--red);
      border-radius: 4px; padding: 0.2rem 0.6rem; font-size: 0.75rem; cursor: pointer;
    }
    .btn-delete:hover { background: rgba(248, 81, 73, 0.15); }
```

- [ ] **Step 4: Commit**

```bash
git add admin/index.html
git commit -m "feat(admin): update UI for v2 (3-step progress, delete button, remove ordinal)"
```

### Task 11: Update Admin Panel deployment.yaml with new env vars

**Files:**
- Modify: `admin/k8s/deployment.yaml`

Add the new env vars needed by v2 builder functions: `SANDBOX_MI_CLIENT_ID`, `TENANT_ID`, `ACR_LOGIN_SERVER`.

- [ ] **Step 1: Add new env vars to admin container**

After the `AZURE_OPENAI_ENDPOINT` env entry (which remains), add:

```yaml
        - name: SANDBOX_MI_CLIENT_ID
          value: "<sandbox_identity_client_id>"
        - name: TENANT_ID
          value: "<tenant-id>"
        - name: ACR_LOGIN_SERVER
          value: "<acr_login_server>"
```

- [ ] **Step 2: Commit**

```bash
git add admin/k8s/deployment.yaml
git commit -m "feat(admin): add v2 env vars for Deployment YAML generation"
```

### Task 12: Build and deploy Admin Panel image

**Files:** None (operational steps only)

- [ ] **Step 1: Build new admin image**

```bash
ACR=$(cd terraform && terraform output -raw acr_login_server)
az acr build --registry "${ACR%%.*}" --image openclaw-admin:latest admin/
```

Expected: `Run ID: ... was successful after ...`

- [ ] **Step 2: Apply updated RBAC**

```bash
# Substitute placeholders and apply
ADMIN_MI=$(cd terraform && terraform output -raw admin_identity_client_id)
sed "s/<admin_identity_client_id>/$ADMIN_MI/g" admin/k8s/rbac.yaml | kubectl apply -f -
```

Expected: `role.rbac.authorization.k8s.io/openclaw-admin configured`

- [ ] **Step 3: Apply updated Admin Deployment**

```bash
ACR=$(cd terraform && terraform output -raw acr_login_server)
KV=$(cd terraform && terraform output -raw keyvault_name)
SANDBOX_MI=$(cd terraform && terraform output -raw sandbox_identity_client_id)
TENANT="20d50aa8-9f98-45c5-a698-e58be99c390d"
AOAI_ENDPOINT="<azure_openai_endpoint>"   # from current cluster config

sed -e "s|<acr_login_server>|$ACR|g" \
    -e "s|<keyvault_name>|$KV|g" \
    -e "s|<azure_openai_endpoint>|$AOAI_ENDPOINT|g" \
    -e "s|<sandbox_identity_client_id>|$SANDBOX_MI|g" \
    -e "s|<tenant-id>|$TENANT|g" \
    admin/k8s/deployment.yaml | kubectl apply -f -
```

Expected: `deployment.apps/openclaw-admin configured`

- [ ] **Step 4: Restart Admin Panel to pick up new image**

```bash
kubectl rollout restart deployment/openclaw-admin -n openclaw
kubectl rollout status deployment/openclaw-admin -n openclaw --timeout=120s
```

Expected: `deployment "openclaw-admin" successfully rolled out`

- [ ] **Step 5: Commit** (no code changes, just a checkpoint)

No commit needed — this was operational.

### Task 13: Store azure-openai-key in Key Vault (pre-migration)

**Files:** None (operational step)

- [ ] **Step 1: Store the shared Azure OpenAI key in KV**

```bash
KV=$(cd terraform && terraform output -raw keyvault_name)
# Get the current key from the existing K8s secret
AOAI_KEY=$(kubectl get secret azure-openai-credentials -n openclaw -o jsonpath='{.data.api-key}' | base64 -d)
az keyvault secret set --vault-name "$KV" --name azure-openai-key --value "$AOAI_KEY"
```

Expected: `"id": "https://openclaw-kv-e2a78886.vault.azure.net/secrets/azure-openai-key/..."`

### Task 14: Migrate existing agents (one at a time)

**Files:** None (operational steps using Admin Panel)

Migrate the three existing agents: alice, bob, aks-demo. For each:

- [ ] **Step 1: Verify Feishu credentials exist in KV and extract them**

```bash
KV=$(cd terraform && terraform output -raw keyvault_name)
# Verify existence
az keyvault secret show --vault-name "$KV" --name "feishu-app-id-alice" --query "name" -o tsv
az keyvault secret show --vault-name "$KV" --name "feishu-app-secret-alice" --query "name" -o tsv

# Extract values (needed for Admin Panel re-entry)
FEISHU_ID=$(az keyvault secret show --vault-name "$KV" --name "feishu-app-id-alice" --query "value" -o tsv)
FEISHU_SECRET=$(az keyvault secret show --vault-name "$KV" --name "feishu-app-secret-alice" --query "value" -o tsv)
echo "Feishu App ID: $FEISHU_ID"
```

Expected: Both return the secret name (not an error). Values are available for the Admin Panel create step.

- [ ] **Step 2: Scale down the v1 StatefulSet replica for this agent**

Before creating the v2 Deployment, scale down the specific agent's StatefulSet replica to avoid running two bots with the same Feishu App ID simultaneously:

```bash
# For alice (ordinal 0), scale from 3 → keep others running
# IMPORTANT: Only do this one agent at a time, starting from the highest ordinal
kubectl scale sts openclaw-agent -n openclaw --replicas=2   # removes ordinal 2 (aks-demo)
# Then create aks-demo v2 Deployment first
```

Strategy: migrate in reverse ordinal order (aks-demo → bob → alice) to avoid ordinal gaps.

- [ ] **Step 3: Create v2 agent via Admin Panel**

```bash
kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw
# Open http://localhost:3000
# Enter: Agent ID = aks-demo, Feishu App ID = <from KV>, Feishu App Secret = <from KV>
# Click Create → observe 3-step SSE progress
```

Or via curl:
```bash
curl -X POST http://localhost:3000/api/agents \
  -H 'Content-Type: application/json' \
  -d '{"agentId":"aks-demo","feishuAppId":"<id>","feishuAppSecret":"<secret>"}'
```

- [ ] **Step 4: Verify v2 agent is running**

```bash
kubectl get pods -n openclaw -l openclaw.io/agent-id=aks-demo
kubectl logs deploy/openclaw-agent-aks-demo -n openclaw -c setup-config
kubectl logs deploy/openclaw-agent-aks-demo -n openclaw -c openclaw --tail=20
```

Expected:
- setup-config: `Config assembled from KV secrets`
- openclaw: `feishu[default]: WebSocket client started` → `ws client ready`

- [ ] **Step 5: Repeat for remaining agents**

Repeat steps 2-4 for bob, then alice.

### Task 15: Cutover — delete old StatefulSet resources

**Files:** None (operational steps)

Only proceed after ALL three agents are verified on v2 Deployments.

- [ ] **Step 1: Delete StatefulSet (already scaled to 0)**

```bash
kubectl delete sts openclaw-agent -n openclaw
kubectl delete cm agent-mapping -n openclaw
```

- [ ] **Step 2: Delete old VCT PVCs**

```bash
kubectl delete pvc work-disk-openclaw-agent-0 work-disk-openclaw-agent-1 work-disk-openclaw-agent-2 -n openclaw
```

- [ ] **Step 3: Verify all agents still running**

```bash
kubectl get pods -n openclaw -l app=openclaw-sandbox
```

Expected: Three pods, all Running.

- [ ] **Step 4: Commit cleanup**

```bash
git add -A
git commit -m "docs: v2 migration complete — StatefulSet removed, independent Deployments active"
```

### Task 16: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

Update the following sections to reflect v2 reality:
- §2.5 Multi Agent 支持: replace "共享 StatefulSet" with "独立 Deployment per agent" as current, move v2 plan to "已完成"
- §4 项目结构: update `k8s/sandbox/` file listing
- §5.2 K8s YAML: update conventions for Deployment + SPC + PVC
- §5.4 已部署集群的实际路径约定: update resource names
- §6 实施进度: add Phase 4 (v2 migration)
- §8 部署后操作: update commands for Deployment-based agents
- §11 后续演进: mark StatefulSet→Deployment as completed

- [ ] **Step 1: Update CLAUDE.md**

Make the edits described above. Key changes:
- Replace all StatefulSet operation commands with Deployment equivalents
- Remove references to `agent-mapping` ConfigMap
- Add new Admin Panel env vars to the deployment info
- Add v2 migration to 实施进度

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for v2 architecture (Deployment + KV CSI)"
```

---

## Reference: Operational Procedures (from spec, not implemented as code)

These procedures are documented in the spec (§4.7 and §9.4) and should be included in the updated CLAUDE.md. They are not separate implementation tasks.

### Credential Rotation

```bash
# 1. Update the secret in Key Vault
az keyvault secret set --vault-name <KV_NAME> \
  --name feishu-app-secret-<agentId> --value "<new-secret>"

# 2. Delete the existing config from the PVC to trigger re-assembly
kubectl exec deploy/openclaw-agent-<agentId> -n openclaw \
  -c openclaw -- rm /home/node/.openclaw/openclaw.json

# 3. Restart the Pod (triggers init container with fresh KV secrets)
kubectl rollout restart deploy/openclaw-agent-<agentId> -n openclaw

# 4. Verify
kubectl logs deploy/openclaw-agent-<agentId> -n openclaw -c setup-config
# Should show: "Config assembled from KV secrets"
```

### Rollback to v1 StatefulSet

If issues arise after cutover and old VCT PVCs have not been deleted:

```bash
# 1. Re-create StatefulSet from Git
kubectl apply -f k8s/sandbox/agent-statefulset.yaml   # (after sed placeholder substitution)
kubectl scale sts openclaw-agent -n openclaw --replicas=3

# 2. Delete v2 Deployments
kubectl delete deploy -n openclaw -l app=openclaw-sandbox

# 3. Re-create agent-mapping ConfigMap
kubectl create configmap agent-mapping -n openclaw \
  --from-literal=agent-0=alice --from-literal=agent-1=bob --from-literal=agent-2=aks-demo
```
