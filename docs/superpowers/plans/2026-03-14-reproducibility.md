# Reproducibility Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OpenClaw on AKS deployable from scratch via a single `install.sh` command backed by a Helm Chart, eliminating all manual sed/kubectl steps.

**Architecture:** A Helm Chart (`charts/openclaw/`) manages all K8s infrastructure resources (namespace, storage, NFS PV/PVC, service accounts, Admin Panel). Agent resources remain dynamically created by Admin Panel, which reads a Helm-generated ConfigMap template instead of hardcoded YAML builders. `install.sh` orchestrates the full flow from Terraform to `helm upgrade --install`.

**Tech Stack:** Helm 3, Bash (shellcheck-clean), Node.js (Express), Terraform (azurerm ~> 4.0), Azure CLI

**Spec:** `docs/superpowers/specs/2026-03-14-reproducibility-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `charts/openclaw/Chart.yaml` | Chart metadata (name, version, appVersion) |
| `charts/openclaw/values.yaml` | All configurable values with defaults |
| `charts/openclaw/ci/test-values.yaml` | Test values for `helm lint` / `helm template` |
| `charts/openclaw/templates/_helpers.tpl` | Common Helm helpers (labels, fullname) |
| `charts/openclaw/templates/namespace.yaml` | Namespace + PSS restricted labels |
| `charts/openclaw/templates/storageclass-disk.yaml` | Azure Disk Premium StorageClass |
| `charts/openclaw/templates/storageclass-files.yaml` | Azure Files NFS Premium StorageClass |
| `charts/openclaw/templates/nfs-pv.yaml` | Static NFS PersistentVolume |
| `charts/openclaw/templates/nfs-pvc.yaml` | Static NFS PersistentVolumeClaim |
| `charts/openclaw/templates/sandbox-sa.yaml` | Sandbox ServiceAccount (Workload Identity) |
| `charts/openclaw/templates/netpol-sandbox.yaml` | Egress-only NetworkPolicy |
| `charts/openclaw/templates/admin-sa.yaml` | Admin ServiceAccount (Workload Identity) |
| `charts/openclaw/templates/admin-rbac.yaml` | Admin Role + RoleBinding |
| `charts/openclaw/templates/admin-deployment.yaml` | Admin Panel Deployment + Service |
| `charts/openclaw/templates/agent-template-cm.yaml` | ConfigMap with agent YAML template (`__AGENT_ID__` placeholders) |
| `k8s/README.md` | Note that `k8s/` is reference-only; use Helm Chart |

### Modified Files

| File | Change |
|------|--------|
| `admin/server.js` | Delete 3 YAML builder functions (~150 lines), add ConfigMap template reader (~30 lines) |
| `admin/index.html` | Update SSE progress steps from 3 to 2 (match new server.js flow) |
| `scripts/install.sh` | Full rewrite: 6-step automated deploy with resource adoption |
| `scripts/build-image.sh` | Rewrite: fix image names, add admin image |
| `scripts/destroy.sh` | Update: `helm uninstall` before `terraform destroy` |
| `scripts/create-agent.sh` | Add DEPRECATED header (no logic changes) |
| `k8s/sandbox/agent-statefulset.yaml` | Add DEPRECATED header (no logic changes) |
| `admin/k8s/deployment.yaml` | Add DEPRECATED header (replaced by Helm Chart) |
| `admin/k8s/rbac.yaml` | Add DEPRECATED header (replaced by Helm Chart) |
| `docker/persist-sync/Dockerfile` | Comment update: "StatefulSet" → "Deployment" |
| `CLAUDE.md` | Update §4 project structure, §6 progress, §8 deploy operations, §11 roadmap |

---

## Chunk 1: Helm Chart Scaffold + Infrastructure Templates

### Task 1: Chart.yaml + values.yaml + _helpers.tpl

**Files:**
- Create: `charts/openclaw/Chart.yaml`
- Create: `charts/openclaw/values.yaml`
- Create: `charts/openclaw/templates/_helpers.tpl`

- [ ] **Step 1: Create Chart.yaml**

```yaml
# charts/openclaw/Chart.yaml
apiVersion: v2
name: openclaw
description: OpenClaw AI Agent platform on AKS
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] **Step 2: Create values.yaml**

Full content from spec §3.2. Copy exactly:

```yaml
# charts/openclaw/values.yaml

# -- Azure infrastructure (populated by install.sh from terraform output)
azure:
  tenantId: ""
  acr:
    loginServer: ""
  keyvault:
    name: ""
  openai:
    endpoint: ""
  storage:
    accountName: ""
    resourceGroup: ""
    shareName: "openclaw-data"
    nfsQuota: "100Gi"

# -- Identity (from terraform output)
identity:
  sandbox:
    clientId: ""
  admin:
    clientId: ""

# -- Namespace
namespace: openclaw

# -- Agent defaults (embedded in ConfigMap template)
agent:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 3Gi
  nodeOptions: "--max-old-space-size=2048"
  workDiskSize: 5Gi
  persistSync:
    syncInterval: 3600
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi

# -- Admin Panel
admin:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

# -- Container images
images:
  agent:
    name: openclaw-agent
    tag: latest
  persistSync:
    name: persist-sync
    tag: latest
  admin:
    name: openclaw-admin
    tag: latest
```

- [ ] **Step 3: Create _helpers.tpl**

```yaml
{{/*
charts/openclaw/templates/_helpers.tpl
*/}}

{{/*
Common labels applied to all resources.
*/}}
{{- define "openclaw.labels" -}}
app.kubernetes.io/name: openclaw
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
```

- [ ] **Step 4: Create ci/test-values.yaml**

```yaml
# charts/openclaw/ci/test-values.yaml
# Used by: helm lint, helm template
azure:
  tenantId: "00000000-0000-0000-0000-000000000000"
  acr:
    loginServer: "testacr.azurecr.io"
  keyvault:
    name: "test-kv"
  openai:
    endpoint: "https://test.openai.azure.com"
  storage:
    accountName: "teststorage"
    resourceGroup: "test-rg"
    shareName: "openclaw-data"
    nfsQuota: "100Gi"
identity:
  sandbox:
    clientId: "00000000-0000-0000-0000-000000000001"
  admin:
    clientId: "00000000-0000-0000-0000-000000000002"
```

- [ ] **Step 5: Verify Chart scaffolding**

Run: `helm lint ./charts/openclaw`
Expected: "1 chart(s) linted, 0 chart(s) failed" (may warn about missing templates, that's OK)

- [ ] **Step 6: Commit**

```bash
git add charts/openclaw/Chart.yaml charts/openclaw/values.yaml \
  charts/openclaw/templates/_helpers.tpl charts/openclaw/ci/test-values.yaml
git commit -m "feat: scaffold Helm Chart with Chart.yaml, values.yaml, helpers"
```

### Task 2: Namespace + StorageClass Templates

**Files:**
- Create: `charts/openclaw/templates/namespace.yaml`
- Create: `charts/openclaw/templates/storageclass-disk.yaml`
- Create: `charts/openclaw/templates/storageclass-files.yaml`
- Reference: `k8s/namespaces.yaml`, `k8s/storage/disk-storageclass.yaml`, `k8s/storage/files-storageclass.yaml`

- [ ] **Step 1: Create namespace.yaml**

```yaml
# charts/openclaw/templates/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

- [ ] **Step 2: Create storageclass-disk.yaml**

```yaml
# charts/openclaw/templates/storageclass-disk.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openclaw-disk
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

- [ ] **Step 3: Create storageclass-files.yaml**

```yaml
# charts/openclaw/templates/storageclass-files.yaml
# NOTE: Not currently used (NFS PV uses static binding).
# Retained for future dynamic NFS provisioning.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openclaw-files
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
provisioner: file.csi.azure.com
parameters:
  skuName: Premium_LRS
  protocol: nfs
  networkEndpointType: privateEndpoint
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nconnect=4
```

- [ ] **Step 4: Verify templates render**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/namespace.yaml`
Expected: Rendered YAML with `name: openclaw` and PSS labels.

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/storageclass-disk.yaml`
Expected: Rendered StorageClass with `provisioner: disk.csi.azure.com`.

- [ ] **Step 5: Commit**

```bash
git add charts/openclaw/templates/namespace.yaml \
  charts/openclaw/templates/storageclass-disk.yaml \
  charts/openclaw/templates/storageclass-files.yaml
git commit -m "feat(helm): add namespace and StorageClass templates"
```

### Task 3: NFS PV + PVC Templates

**Files:**
- Create: `charts/openclaw/templates/nfs-pv.yaml`
- Create: `charts/openclaw/templates/nfs-pvc.yaml`
- Reference: Spec §3.4

- [ ] **Step 1: Create nfs-pv.yaml**

```yaml
# charts/openclaw/templates/nfs-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: openclaw-nfs-pv
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
spec:
  capacity:
    storage: {{ .Values.azure.storage.nfsQuota }}
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: file.csi.azure.com
    volumeHandle: openclaw-nfs-pv
    volumeAttributes:
      resourceGroup: {{ .Values.azure.storage.resourceGroup | quote }}
      storageAccount: {{ .Values.azure.storage.accountName | quote }}
      shareName: {{ .Values.azure.storage.shareName | quote }}
      protocol: nfs
```

- [ ] **Step 2: Create nfs-pvc.yaml**

```yaml
# charts/openclaw/templates/nfs-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-shared-data
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  volumeName: openclaw-nfs-pv
  storageClassName: ""
```

- [ ] **Step 3: Verify PV/PVC render correctly**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/nfs-pv.yaml`
Expected: PV with `storageAccount: teststorage`, `resourceGroup: test-rg`, `shareName: openclaw-data`.

- [ ] **Step 4: Commit**

```bash
git add charts/openclaw/templates/nfs-pv.yaml charts/openclaw/templates/nfs-pvc.yaml
git commit -m "feat(helm): add static NFS PV and PVC templates"
```

### Task 4: Sandbox ServiceAccount + NetworkPolicy Templates

**Files:**
- Create: `charts/openclaw/templates/sandbox-sa.yaml`
- Create: `charts/openclaw/templates/netpol-sandbox.yaml`
- Reference: `k8s/sandbox/service-account.yaml`, `k8s/security/netpol-sandbox.yaml`

- [ ] **Step 1: Create sandbox-sa.yaml**

```yaml
# charts/openclaw/templates/sandbox-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openclaw-sandbox
  namespace: {{ .Values.namespace }}
  annotations:
    azure.workload.identity/client-id: {{ .Values.identity.sandbox.clientId | quote }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
    azure.workload.identity/use: "true"
```

- [ ] **Step 2: Create netpol-sandbox.yaml**

```yaml
# charts/openclaw/templates/netpol-sandbox.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sandbox-egress
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      app: openclaw-sandbox
  policyTypes: [Egress]
  egress:
  # Feishu WebSocket (Outbound HTTPS)
  - to: []
    ports:
    - protocol: TCP
      port: 443
  # APIM internal network
  - to:
    - ipBlock:
        cidr: 10.0.8.0/24
    ports:
    - protocol: TCP
      port: 443
  # DNS
  - to: []
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

- [ ] **Step 3: Verify renders**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/sandbox-sa.yaml`
Expected: SA with annotation `azure.workload.identity/client-id: "00000000-0000-0000-0000-000000000001"`.

- [ ] **Step 4: Commit**

```bash
git add charts/openclaw/templates/sandbox-sa.yaml \
  charts/openclaw/templates/netpol-sandbox.yaml
git commit -m "feat(helm): add sandbox ServiceAccount and NetworkPolicy"
```

### Task 5: Full Chart lint + template validation

- [ ] **Step 1: Run helm lint**

Run: `helm lint ./charts/openclaw`
Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 2: Run full template render**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml > /dev/null && echo "OK"`
Expected: `OK` (no errors)

- [ ] **Step 3: Visually inspect rendered output**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml`
Verify: Each resource has correct `metadata.namespace`, labels, and values from test-values.yaml.

---

## Chunk 2: Admin Panel Templates + Agent Template ConfigMap

### Task 6: Admin ServiceAccount + RBAC Templates

**Files:**
- Create: `charts/openclaw/templates/admin-sa.yaml`
- Create: `charts/openclaw/templates/admin-rbac.yaml`
- Reference: `admin/k8s/rbac.yaml`

- [ ] **Step 1: Create admin-sa.yaml**

```yaml
# charts/openclaw/templates/admin-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openclaw-admin
  namespace: {{ .Values.namespace }}
  annotations:
    azure.workload.identity/client-id: {{ .Values.identity.admin.clientId | quote }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
    azure.workload.identity/use: "true"
```

- [ ] **Step 2: Create admin-rbac.yaml**

```yaml
# charts/openclaw/templates/admin-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: openclaw-admin
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "create", "delete"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "create", "delete"]
- apiGroups: ["secrets-store.csi.x-k8s.io"]
  resources: ["secretproviderclasses"]
  verbs: ["get", "list", "create", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: openclaw-admin
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
subjects:
- kind: ServiceAccount
  name: openclaw-admin
  namespace: {{ .Values.namespace }}
roleRef:
  kind: Role
  name: openclaw-admin
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 3: Verify RBAC renders**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/admin-rbac.yaml`
Expected: Role with 5 rules + RoleBinding referencing openclaw-admin SA.

- [ ] **Step 4: Commit**

```bash
git add charts/openclaw/templates/admin-sa.yaml \
  charts/openclaw/templates/admin-rbac.yaml
git commit -m "feat(helm): add Admin Panel ServiceAccount and RBAC"
```

### Task 7: Admin Panel Deployment + Service Template

**Files:**
- Create: `charts/openclaw/templates/admin-deployment.yaml`
- Reference: `admin/k8s/deployment.yaml`, Spec §3.6

- [ ] **Step 1: Create admin-deployment.yaml**

This template includes both the Deployment (with ConfigMap volume mount) and the Service. Note: 4 env vars removed per spec, 1 new `AGENT_TEMPLATE_PATH` added.

```yaml
# charts/openclaw/templates/admin-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-admin
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
    app: openclaw-admin
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
        image: {{ .Values.azure.acr.loginServer }}/{{ .Values.images.admin.name }}:{{ .Values.images.admin.tag }}
        ports:
        - containerPort: 3000
        env:
        - name: KV_NAME
          value: {{ .Values.azure.keyvault.name | quote }}
        - name: NAMESPACE
          value: {{ .Values.namespace | quote }}
        - name: AGENT_TEMPLATE_PATH
          value: /etc/openclaw/agent-template.yaml
        volumeMounts:
        - name: agent-template
          mountPath: /etc/openclaw
          readOnly: true
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            cpu: {{ .Values.admin.resources.requests.cpu }}
            memory: {{ .Values.admin.resources.requests.memory }}
          limits:
            cpu: {{ .Values.admin.resources.limits.cpu }}
            memory: {{ .Values.admin.resources.limits.memory }}
      volumes:
      - name: agent-template
        configMap:
          name: openclaw-agent-template
---
apiVersion: v1
kind: Service
metadata:
  name: openclaw-admin
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
spec:
  selector:
    app: openclaw-admin
  ports:
  - port: 3000
    targetPort: 3000
```

- [ ] **Step 2: Verify render**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/admin-deployment.yaml`
Expected: Deployment with `image: testacr.azurecr.io/openclaw-admin:latest`, env vars `KV_NAME`, `NAMESPACE`, `AGENT_TEMPLATE_PATH`, and ConfigMap volume mount. No `AZURE_OPENAI_ENDPOINT`, `SANDBOX_MI_CLIENT_ID`, `TENANT_ID`, or `ACR_LOGIN_SERVER`.

- [ ] **Step 3: Commit**

```bash
git add charts/openclaw/templates/admin-deployment.yaml
git commit -m "feat(helm): add Admin Panel Deployment and Service template"
```

### Task 8: Agent Template ConfigMap

**Files:**
- Create: `charts/openclaw/templates/agent-template-cm.yaml`
- Reference: `k8s/sandbox/agent-deployment.template.yaml`, Spec §3.3

This is the most complex template. It is a ConfigMap whose `data` field contains rendered YAML with `__AGENT_ID__` placeholders for runtime substitution by Admin Panel.

- [ ] **Step 1: Create agent-template-cm.yaml**

The ConfigMap data key `agent-template.yaml` contains three YAML documents (SPC + PVC + Deployment) separated by `---`. Helm injects all infrastructure values. `__AGENT_ID__` is the only runtime placeholder.

```yaml
# charts/openclaw/templates/agent-template-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-agent-template
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "openclaw.labels" . | nindent 4 }}
data:
  agent-template.yaml: |
    ---
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: spc-__AGENT_ID__
      namespace: {{ .Values.namespace }}
    spec:
      provider: azure
      parameters:
        usePodIdentity: "false"
        clientID: {{ .Values.identity.sandbox.clientId | quote }}
        keyvaultName: {{ .Values.azure.keyvault.name | quote }}
        tenantId: {{ .Values.azure.tenantId | quote }}
        objects: |
          array:
            - |
              objectName: feishu-app-id-__AGENT_ID__
              objectType: secret
              objectAlias: feishu-app-id
            - |
              objectName: feishu-app-secret-__AGENT_ID__
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
      name: work-disk-__AGENT_ID__
      namespace: {{ .Values.namespace }}
      labels:
        app: openclaw-sandbox
        openclaw.io/agent-id: __AGENT_ID__
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: openclaw-disk
      resources:
        requests:
          storage: {{ .Values.agent.workDiskSize }}
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: openclaw-agent-__AGENT_ID__
      namespace: {{ .Values.namespace }}
      labels:
        app: openclaw-sandbox
        openclaw.io/agent-id: __AGENT_ID__
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: openclaw-sandbox
          openclaw.io/agent-id: __AGENT_ID__
      template:
        metadata:
          labels:
            app: openclaw-sandbox
            openclaw.io/agent-id: __AGENT_ID__
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
              printf '%s\n' "{\"gateway\":{\"mode\":\"local\"},\"channels\":{\"feishu\":{\"enabled\":true,\"appId\":\"$FEISHU_ID\",\"appSecret\":\"$FEISHU_SECRET\"}},\"models\":{\"providers\":{\"azure-openai-direct\":{\"baseUrl\":\"$AOAI_ENDPOINT\",\"apiKey\":\"$AOAI_KEY\",\"api\":\"openai-responses\",\"headers\":{\"api-version\":\"2025-04-01-preview\"},\"models\":[{\"id\":\"gpt-5.4\",\"name\":\"GPT-5.4 (Direct Azure OpenAI)\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
              echo "Config assembled from KV secrets"
            env:
            - name: AOAI_ENDPOINT
              value: {{ .Values.azure.openai.endpoint | quote }}
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
            image: {{ .Values.azure.acr.loginServer }}/{{ .Values.images.persistSync.name }}:{{ .Values.images.persistSync.tag }}
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
                sleep {{ .Values.agent.persistSync.syncInterval }}
                sync_files
              done
            env:
            - name: AGENT_ID
              value: __AGENT_ID__
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              readOnlyRootFilesystem: false
            resources:
              requests:
                cpu: {{ .Values.agent.persistSync.resources.requests.cpu }}
                memory: {{ .Values.agent.persistSync.resources.requests.memory }}
              limits:
                cpu: {{ .Values.agent.persistSync.resources.limits.cpu }}
                memory: {{ .Values.agent.persistSync.resources.limits.memory }}
            volumeMounts:
            - name: work-disk
              mountPath: /home/node/.openclaw
              readOnly: true
            - name: persist-files
              mountPath: /persist
          containers:
          - name: openclaw
            image: {{ .Values.azure.acr.loginServer }}/{{ .Values.images.agent.name }}:{{ .Values.images.agent.tag }}
            imagePullPolicy: Always
            command: ["/bin/sh", "-c"]
            args:
            - exec openclaw gateway run --verbose
            env:
            - name: NODE_OPTIONS
              value: {{ .Values.agent.nodeOptions | quote }}
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
              readOnlyRootFilesystem: false
            resources:
              requests:
                cpu: {{ .Values.agent.resources.requests.cpu }}
                memory: {{ .Values.agent.resources.requests.memory }}
              limits:
                cpu: {{ .Values.agent.resources.limits.cpu | quote }}
                memory: {{ .Values.agent.resources.limits.memory }}
            volumeMounts:
            - name: work-disk
              mountPath: /home/node/.openclaw
          volumes:
          - name: kv-secrets
            csi:
              driver: secrets-store.csi.k8s.io
              readOnly: true
              volumeAttributes:
                secretProviderClass: spc-__AGENT_ID__
          - name: work-disk
            persistentVolumeClaim:
              claimName: work-disk-__AGENT_ID__
          - name: persist-files
            persistentVolumeClaim:
              claimName: openclaw-shared-data

- [ ] **Step 2: Verify ConfigMap renders**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml -s templates/agent-template-cm.yaml`

Verify:
1. ConfigMap name is `openclaw-agent-template`
2. Data key is `agent-template.yaml`
3. All `__AGENT_ID__` placeholders are literal (not rendered by Helm)
4. All Helm values (`testacr.azurecr.io`, `test-kv`, etc.) are injected correctly
5. `AOAI_ENDPOINT` env value is `"https://test.openai.azure.com"`

- [ ] **Step 3: Full chart validation**

Run: `helm lint ./charts/openclaw && helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml > /dev/null && echo "ALL OK"`
Expected: `ALL OK`

- [ ] **Step 4: Commit**

```bash
git add charts/openclaw/templates/agent-template-cm.yaml
git commit -m "feat(helm): add agent template ConfigMap with __AGENT_ID__ placeholders"
```

---

## Chunk 3: Admin Panel server.js Refactor

### Task 9: Refactor server.js — Replace YAML builders with template reader

**Files:**
- Modify: `admin/server.js`
- Modify: `admin/index.html`
- Reference: Spec §4.1, §4.2, §4.3

This task replaces the hardcoded YAML builder functions with a template-based approach. The Admin Panel reads the agent template from a ConfigMap-mounted file and replaces `__AGENT_ID__` at runtime. The UI progress bar must also be updated to match the new 2-step flow.

- [ ] **Step 1: Add template loading at top of server.js**

After the existing constant declarations (line ~16 in `admin/server.js`), remove the unused env var references and add template loading:

Replace these lines:
```js
const NAMESPACE = process.env.NAMESPACE || 'openclaw';
const KV_NAME = process.env.KV_NAME || '';
const AZURE_OPENAI_ENDPOINT = process.env.AZURE_OPENAI_ENDPOINT || '';
const SANDBOX_MI_CLIENT_ID = process.env.SANDBOX_MI_CLIENT_ID || '';
const TENANT_ID = process.env.TENANT_ID || '';
const ACR_LOGIN_SERVER = process.env.ACR_LOGIN_SERVER || '';
```

With:
```js
const NAMESPACE = process.env.NAMESPACE || 'openclaw';
const KV_NAME = process.env.KV_NAME || '';
const AGENT_TEMPLATE_PATH = process.env.AGENT_TEMPLATE_PATH || '/etc/openclaw/agent-template.yaml';

let agentTemplate = '';
```

- [ ] **Step 2: Delete the 3 YAML builder functions**

Delete `buildSpcYaml()` (lines ~55-82), `buildPvcYaml()` (lines ~84-101), and `buildDeploymentYaml()` (lines ~103-263). These are approximately 210 lines total.

- [ ] **Step 3: Add renderAgentYaml function**

Add this function where the builders were:
```js
function renderAgentYaml(agentId) {
  return agentTemplate.replaceAll('__AGENT_ID__', agentId);
}
```

- [ ] **Step 4: Update POST /api/agents handler**

In the POST handler, replace Steps 2 and 3:

**Old (3-step SSE):**
```js
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
```

**New (2-step SSE):**
```js
    // Step 2: Create K8s resources (SPC + PVC + Deployment)
    currentStep = 2;
    send(2, 'running', 'Creating K8s resources (SPC + PVC + Deployment)...');
    await kubectlApplyStdin(renderAgentYaml(agentId));
    send(2, 'done', `Agent ${agentId} created successfully`, { done: true });
```

Also update `total: 3` to `total: 2` in the `send` helper:
```js
  const send = (step, status, msg, extra = {}) => {
    res.write(`data: ${JSON.stringify({ step, total: 2, status, msg, ...extra })}\n\n`);
  };
```

And update the cleanup logic — currently checks `currentStep >= 3` and `currentStep >= 2`. Simplify to:
```js
  } catch (err) {
    send(currentStep, 'error', `Creation failed: ${err.message}`);
    if (currentStep >= 2) {
      await kubectl('delete', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'pvc', `work-disk-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'secretproviderclass', `spc-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
    }
  }
```

- [ ] **Step 5: Add template loading to main() function**

In the `main()` function, add template loading before the existing `azLogin()`:
```js
async function main() {
  // Load agent template from Helm-generated ConfigMap mount
  try {
    agentTemplate = fs.readFileSync(AGENT_TEMPLATE_PATH, 'utf8');
    console.log(`Agent template loaded from ${AGENT_TEMPLATE_PATH} (${agentTemplate.length} bytes)`);
  } catch (err) {
    console.error(`FATAL: Cannot read agent template at ${AGENT_TEMPLATE_PATH}: ${err.message}`);
    console.error('Ensure the Helm Chart is installed and ConfigMap openclaw-agent-template exists.');
    process.exit(1);
  }

  await azLogin();
  // ... rest unchanged
```

- [ ] **Step 6: Update index.html progress steps from 3 to 2**

In `admin/index.html`, replace the 3-step progress bar (lines 104-108):

**Old:**
```html
    <div class="progress" id="progress">
      <div class="step" data-step="1"><span class="step-icon">⏳</span> Store Feishu credentials in Key Vault</div>
      <div class="step" data-step="2"><span class="step-icon">⏳</span> Create SecretProviderClass</div>
      <div class="step" data-step="3"><span class="step-icon">⏳</span> Create PVC and Deployment</div>
    </div>
```

**New:**
```html
    <div class="progress" id="progress">
      <div class="step" data-step="1"><span class="step-icon">⏳</span> Store Feishu credentials in Key Vault</div>
      <div class="step" data-step="2"><span class="step-icon">⏳</span> Create K8s resources (SPC + PVC + Deployment)</div>
    </div>
```

- [ ] **Step 7: Commit**

```bash
git add admin/server.js admin/index.html
git commit -m "refactor(admin): replace YAML builders with Helm ConfigMap template reader

Delete buildSpcYaml(), buildPvcYaml(), buildDeploymentYaml() (~210 lines).
Add renderAgentYaml() that reads template from ConfigMap mount and
replaces __AGENT_ID__ at runtime. SSE steps reduced from 3 to 2.
Update index.html progress bar to match new 2-step flow."
```

---

## Chunk 4: Scripts (install.sh, build-image.sh, destroy.sh) + Deprecations

### Task 10: Rewrite build-image.sh

**Files:**
- Modify: `scripts/build-image.sh`
- Reference: Spec §6.2

- [ ] **Step 1: Rewrite build-image.sh**

```bash
#!/bin/bash
# Build and push all OpenClaw container images to ACR.
# Usage: build-image.sh <acr-name>
set -euo pipefail

ACR_NAME="${1:?Usage: build-image.sh <acr-name>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Building openclaw-agent image ==="
az acr build --registry "$ACR_NAME" --image openclaw-agent:latest "$ROOT_DIR/docker/"

echo "=== Building persist-sync sidecar image ==="
az acr build --registry "$ACR_NAME" --image persist-sync:latest "$ROOT_DIR/docker/persist-sync/"

echo "=== Building openclaw-admin image ==="
az acr build --registry "$ACR_NAME" --image openclaw-admin:latest "$ROOT_DIR/admin/"

echo "=== Done ==="
az acr repository list --name "$ACR_NAME" -o table
```

- [ ] **Step 2: Commit**

```bash
git add scripts/build-image.sh
git commit -m "fix(scripts): update build-image.sh with correct image names + admin image

Rename openclaw-sandbox → openclaw-agent, add openclaw-admin build."
```

### Task 11: Rewrite install.sh

**Files:**
- Modify: `scripts/install.sh`
- Reference: Spec §5.1-5.6

- [ ] **Step 1: Write the full install.sh**

```bash
#!/bin/bash
# One-command deployment of OpenClaw on AKS.
# Usage: install.sh --aoai-key KEY --aoai-endpoint URL [--tfvars PATH] [--skip-terraform] [--skip-images]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Defaults ---
TFVARS="$ROOT_DIR/terraform/terraform.tfvars"
SKIP_TERRAFORM=false
SKIP_IMAGES=false
AOAI_KEY=""
AOAI_ENDPOINT=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --aoai-key)      AOAI_KEY="$2"; shift 2 ;;
    --aoai-endpoint) AOAI_ENDPOINT="$2"; shift 2 ;;
    --tfvars)        TFVARS="$2"; shift 2 ;;
    --skip-terraform) SKIP_TERRAFORM=true; shift ;;
    --skip-images)   SKIP_IMAGES=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Prereq checks ---
for cmd in az terraform helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
[[ -z "$AOAI_KEY" ]] && { echo "ERROR: --aoai-key is required"; exit 1; }
[[ -z "$AOAI_ENDPOINT" ]] && { echo "ERROR: --aoai-endpoint is required"; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run 'az login' first."; exit 1; }
[[ -f "$TFVARS" ]] || { echo "ERROR: terraform.tfvars not found at $TFVARS"; exit 1; }

# ============================
# Step 1/6: Terraform
# ============================
if [[ "$SKIP_TERRAFORM" == "false" ]]; then
  echo ""
  echo "=== Step 1/6: Terraform Init & Apply ==="
  cd "$ROOT_DIR/terraform"
  terraform init -input=false
  terraform apply -var-file="$TFVARS" -auto-approve -input=false
  cd "$ROOT_DIR"
else
  echo ""
  echo "=== Step 1/6: Terraform (SKIPPED) ==="
fi

# --- Extract terraform outputs ---
echo "  Extracting terraform outputs..."
cd "$ROOT_DIR/terraform"
ACR_NAME=$(terraform output -raw acr_name)
ACR_SERVER=$(terraform output -raw acr_login_server)
AKS_NAME=$(terraform output -raw aks_name)
KV_NAME=$(terraform output -raw keyvault_name)
RG=$(terraform output -raw resource_group)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
SANDBOX_MI_CLIENT_ID=$(terraform output -raw sandbox_identity_client_id)
ADMIN_MI_CLIENT_ID=$(terraform output -raw admin_identity_client_id)
TENANT_ID=$(az account show --query tenantId -o tsv)
cd "$ROOT_DIR"

echo "  ACR: $ACR_SERVER"
echo "  AKS: $AKS_NAME"
echo "  KV:  $KV_NAME"

# ============================
# Step 2/6: Kata Nodepool
# ============================
echo ""
echo "=== Step 2/6: Kata VM Isolation Nodepool ==="
if az aks nodepool show --resource-group "$RG" --cluster-name "$AKS_NAME" --name sandbox &>/dev/null; then
  echo "  Sandbox nodepool already exists, skipping."
else
  echo "  Creating sandbox nodepool (this may take 10-15 minutes)..."
  az aks nodepool add \
    --resource-group "$RG" \
    --cluster-name "$AKS_NAME" \
    --name sandbox \
    --node-vm-size Standard_D4s_v3 \
    --node-count 1 \
    --os-type Linux \
    --os-sku AzureLinux \
    --workload-runtime KataMshvVmIsolation \
    --enable-cluster-autoscaler \
    --min-count 0 \
    --max-count 3 \
    --labels openclaw.io/role=sandbox \
    --node-taints openclaw.io/sandbox=true:NoSchedule
  echo "  Sandbox nodepool created."
fi

# ============================
# Step 3/6: Docker Images
# ============================
if [[ "$SKIP_IMAGES" == "false" ]]; then
  echo ""
  echo "=== Step 3/6: Build & Push Docker Images ==="
  az acr build --registry "$ACR_NAME" --image openclaw-agent:latest "$ROOT_DIR/docker/"
  az acr build --registry "$ACR_NAME" --image persist-sync:latest "$ROOT_DIR/docker/persist-sync/"
  az acr build --registry "$ACR_NAME" --image openclaw-admin:latest "$ROOT_DIR/admin/"
else
  echo ""
  echo "=== Step 3/6: Docker Images (SKIPPED) ==="
fi

# ============================
# Step 4/6: Kubeconfig
# ============================
echo ""
echo "=== Step 4/6: Get Kubeconfig ==="
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing

# ============================
# Step 5/6: Azure OpenAI Key → KV
# ============================
echo ""
echo "=== Step 5/6: Store Azure OpenAI Key in Key Vault ==="
az keyvault secret set --vault-name "$KV_NAME" --name azure-openai-key --value "$AOAI_KEY" --output none
echo "  azure-openai-key stored in $KV_NAME"

# ============================
# Step 6/6: Helm Install
# ============================
echo ""
echo "=== Step 6a/6: Adopt existing resources into Helm ==="

adopt_resource() {
  local kind="$1" name="$2" ns="${3:-}"
  local args=("$kind" "$name")
  [[ -n "$ns" ]] && args+=("-n" "$ns")

  if kubectl get "${args[@]}" &>/dev/null; then
    echo "  Adopting $kind/$name into Helm release..."
    kubectl annotate "${args[@]}" \
      meta.helm.sh/release-name=openclaw \
      meta.helm.sh/release-namespace=openclaw --overwrite
    kubectl label "${args[@]}" \
      app.kubernetes.io/managed-by=Helm --overwrite
  fi
}

# Cluster-scoped
adopt_resource namespace openclaw
adopt_resource pv openclaw-nfs-pv
adopt_resource storageclass openclaw-disk
adopt_resource storageclass openclaw-files
# Namespaced (openclaw)
adopt_resource pvc openclaw-shared-data openclaw
adopt_resource serviceaccount openclaw-sandbox openclaw
adopt_resource networkpolicy sandbox-egress openclaw
adopt_resource serviceaccount openclaw-admin openclaw
adopt_resource role openclaw-admin openclaw
adopt_resource rolebinding openclaw-admin openclaw
adopt_resource deployment openclaw-admin openclaw
adopt_resource service openclaw-admin openclaw

echo ""
echo "=== Step 6b/6: Helm Upgrade --Install ==="
VALUES_FILE=$(mktemp /tmp/openclaw-values-XXXXXX.yaml)
trap 'rm -f "$VALUES_FILE"' EXIT
cat > "$VALUES_FILE" <<EOF
azure:
  tenantId: "$TENANT_ID"
  acr:
    loginServer: "$ACR_SERVER"
  keyvault:
    name: "$KV_NAME"
  openai:
    endpoint: "$AOAI_ENDPOINT"
  storage:
    accountName: "$STORAGE_ACCOUNT"
    resourceGroup: "$RG"
identity:
  sandbox:
    clientId: "$SANDBOX_MI_CLIENT_ID"
  admin:
    clientId: "$ADMIN_MI_CLIENT_ID"
EOF

helm upgrade --install openclaw "$ROOT_DIR/charts/openclaw" \
  -f "$VALUES_FILE" \
  --namespace openclaw \
  --create-namespace

rm -f "$VALUES_FILE"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "  AKS:   $AKS_NAME"
echo "  ACR:   $ACR_SERVER"
echo "  KV:    $KV_NAME"
echo ""
echo "Next steps:"
echo "  1. kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw"
echo "  2. Open http://localhost:3000 to create agents"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/install.sh
git commit -m "feat(scripts): rewrite install.sh for full-flow Helm-based deployment

6-step automated deploy: terraform → Kata nodepool → images → kubeconfig
→ KV secret → helm upgrade --install. Includes resource adoption for
existing clusters and --skip-terraform/--skip-images flags."
```

### Task 12: Update destroy.sh

**Files:**
- Modify: `scripts/destroy.sh`

- [ ] **Step 1: Update destroy.sh**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "WARNING: This will destroy ALL OpenClaw resources"
read -r -p "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

echo "=== Uninstalling Helm release ==="
helm uninstall openclaw --namespace openclaw 2>/dev/null || echo "  No Helm release found, skipping."

echo "=== Deleting K8s namespace (catches orphaned resources) ==="
kubectl delete namespace openclaw --ignore-not-found

echo "=== Destroying Terraform infrastructure ==="
cd "$ROOT_DIR/terraform"
terraform destroy -auto-approve

echo "=== Done ==="
```

- [ ] **Step 2: Commit**

```bash
git add scripts/destroy.sh
git commit -m "fix(scripts): update destroy.sh to helm uninstall before terraform destroy"
```

### Task 13: Mark deprecated files

**Files:**
- Modify: `k8s/sandbox/agent-statefulset.yaml` (add header)
- Modify: `scripts/create-agent.sh` (add header)
- Modify: `admin/k8s/deployment.yaml` (add header)
- Modify: `admin/k8s/rbac.yaml` (add header)
- Modify: `docker/persist-sync/Dockerfile` (comment fix)
- Create: `k8s/README.md`

- [ ] **Step 1: Add DEPRECATED header to agent-statefulset.yaml**

Prepend to the file:
```yaml
# DEPRECATED (2026-03-14): v1 StatefulSet architecture.
# Replaced by Helm Chart + agent-deployment.template.yaml.
# See charts/openclaw/ for the canonical deployment method.
```

- [ ] **Step 2: Add DEPRECATED header to create-agent.sh**

Prepend to the file (after the shebang):
```bash
# DEPRECATED (2026-03-14): v1 agent creation script based on StatefulSet + APIM.
# Replaced by Admin Panel (admin/server.js). Do not use.
```

- [ ] **Step 3: Add DEPRECATED header to admin/k8s/deployment.yaml**

Prepend to the file:
```yaml
# DEPRECATED (2026-03-14): Replaced by Helm Chart template.
# See charts/openclaw/templates/admin-deployment.yaml for the canonical version.
```

- [ ] **Step 4: Add DEPRECATED header to admin/k8s/rbac.yaml**

Prepend to the file:
```yaml
# DEPRECATED (2026-03-14): Replaced by Helm Chart templates.
# See charts/openclaw/templates/admin-sa.yaml and admin-rbac.yaml.
```

- [ ] **Step 5: Update persist-sync Dockerfile comment**

In `docker/persist-sync/Dockerfile`, change the em-dash comment (line 7):
```
# No ENTRYPOINT — command defined in StatefulSet YAML
```
To:
```
# No ENTRYPOINT — command defined in Deployment YAML
```

Note: The file uses an em-dash `—` (U+2014), not double hyphens. Match the exact character.

- [ ] **Step 6: Create k8s/README.md**

```markdown
# k8s/ — Reference YAML

These files are historical reference from v1/v2 manual deployment.
The canonical deployment method is now Helm Chart: see `charts/openclaw/`.
Agent resources are dynamically created by the Admin Panel.
```

- [ ] **Step 7: Commit**

```bash
git add k8s/sandbox/agent-statefulset.yaml scripts/create-agent.sh \
  admin/k8s/deployment.yaml admin/k8s/rbac.yaml \
  docker/persist-sync/Dockerfile k8s/README.md
git commit -m "chore: mark deprecated files, add k8s/ README, fix persist-sync comment"
```

---

## Chunk 5: Validation + Documentation

### Task 14: Local Helm validation

- [ ] **Step 1: Run helm lint**

Run: `helm lint ./charts/openclaw`
Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 2: Run full template render with test values**

Run: `helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml`
Expected: All 12 templates render without error. Manually inspect:
- Namespace has PSS labels
- NFS PV has correct storage account references
- Admin Deployment has ConfigMap volume mount, only 3 env vars (KV_NAME, NAMESPACE, AGENT_TEMPLATE_PATH)
- Agent template ConfigMap contains `__AGENT_ID__` placeholders (literal, not rendered)
- All Helm values from test-values.yaml are correctly injected

- [ ] **Step 3: Verify install.sh passes shellcheck**

Run: `shellcheck scripts/install.sh`
Expected: No errors. (Warnings about quoting are acceptable if intentional.)

Run: `shellcheck scripts/build-image.sh`
Expected: No errors.

Run: `shellcheck scripts/destroy.sh`
Expected: No errors.

### Task 15: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update §4 project structure**

Add `charts/openclaw/` entry to the directory tree (after `scripts/`):
```
├── charts/
│   └── openclaw/                 # Helm Chart（基础设施 K8s 资源）
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── ci/test-values.yaml
│       └── templates/            # 12 个模板（namespace, SC, PV/PVC, SA, netpol, admin, agent-template CM）
```

Update `scripts/` descriptions:
- `install.sh` — 全流程一键部署（Terraform → Kata → 镜像 → Helm install）
- `build-image.sh` — 构建 3 个镜像（openclaw-agent, persist-sync, openclaw-admin）
- `create-agent.sh` — ⚠️ 已废弃（标记 DEPRECATED）
- `destroy.sh` — helm uninstall + terraform destroy

- [ ] **Step 2: Update §6 implementation progress**

Add a new "阶段 5：Reproducibility ✅ 已完成" section after 阶段 4:

| Task | 状态 | 备注 |
|------|------|------|
| Helm Chart | ✅ | 12 templates, values.yaml, agent-template ConfigMap |
| install.sh 重写 | ✅ | 6-step 全流程 + resource adoption |
| build-image.sh 修复 | ✅ | 镜像名更正 + admin 镜像 |
| Admin Panel 改造 | ✅ | YAML builders → ConfigMap template reader |
| 过时文件标记 | ✅ | DEPRECATED headers on 4 files |

- [ ] **Step 3: Update §8 deployment operations**

Add at the top of §8 (before existing "创建新 Agent" section):

```markdown
### 新环境部署（一键）
./scripts/install.sh --aoai-key "KEY" --aoai-endpoint "https://xxx.openai.azure.com"

### 仅更新 K8s 层（跳过 Terraform 和镜像构建）
./scripts/install.sh --aoai-key "KEY" --aoai-endpoint "URL" --skip-terraform --skip-images

### Helm 升级（修改 values 后）
helm upgrade openclaw ./charts/openclaw -f values-generated.yaml -n openclaw
```

Do NOT change the existing agent creation/deletion/approve/ops sections — those are unchanged.

- [ ] **Step 4: Update §11 roadmap**

Move "环境可复制性（Reproducibility）" from "近期优先" (unchecked) to "已完成" (checked):
```
- [x] **环境可复制性（Reproducibility）** ✅ — Helm Chart 封装 + install.sh 全流程自动化 + Admin Panel 改造（ConfigMap 模板替代 YAML builders）
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for Helm-based deployment workflow"
```

### Task 16: Final validation checkpoint

- [ ] **Step 1: Verify git status is clean**

Run: `git status`
Expected: All changes committed, working tree clean.

- [ ] **Step 2: Verify the complete Chart one more time**

Run: `helm lint ./charts/openclaw && helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml > /dev/null && echo "CHART OK"`
Expected: `CHART OK`

- [ ] **Step 3: Verify existing aks-demo agent is unaffected**

If deploying on the existing cluster, verify after `helm upgrade --install`:
Run: `kubectl get deploy openclaw-agent-aks-demo -n openclaw`
Expected: `1/1 READY` (Helm only manages infrastructure resources, not per-agent Deployments)
