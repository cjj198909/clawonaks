# v2 Migration Design: StatefulSet to Independent Deployment + Secure Config Injection

> Date: 2026-03-14
> Status: Draft
> Scope: Architecture migration — workload model, config injection, credential security

## 1. Background and Motivation

The current v1 architecture uses a shared StatefulSet for all agents. This creates several pain points:

- **Deletion brittleness:** Removing a middle agent breaks ordinal continuity, requiring remapping of all subsequent agents.
- **Fragile mapping chain:** `hostname → ordinal → ConfigMap agent-mapping → agent-id` has multiple failure modes.
- **Shared Pod template:** All agents share the same resource limits, image, and env — no per-agent customization.
- **Rolling update blast radius:** Any template change restarts all agents.
- **Config injection complexity:** A 6-hop chain (Admin Panel → temp ConfigMap → Job → NFS → init container → work-disk) with credentials exposed in etcd and NFS.

v2 addresses all of these by migrating to independent Deployments with secure Key Vault-based config injection.

## 2. Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Workload model | Independent Deployment per agent (replicas=1) | Agents have no cluster relationship; independent lifecycle, update, deletion |
| Sandbox CRD | Not adopted | v1alpha1 too early; unverified on AKS + Kata; marginal benefit over Deployment |
| AI gateway | Stay with APIM (future enablement) | No LiteLLM; existing APIM strategy unchanged |
| Config injection | B+C hybrid: non-sensitive inline + sensitive via KV CSI | Security + simplicity balance |
| persist-sync sidecar | Retained, frequency reduced to 1h | PVC already persists; sidecar serves as backup only |
| Observability | Deferred to v3 | Prometheus/Grafana not in v2 scope |

## 3. Architecture: Independent Deployment per Agent

### 3.1 Resource Model

Each agent comprises three K8s resources plus associated Key Vault secrets:

```
K8s resources (per agent):
  SecretProviderClass  spc-<agentId>              # per-agent KV secret mapping
  PVC                  work-disk-<agentId>         # per-agent Azure Disk (5Gi, Premium_LRS)
  Deployment           openclaw-agent-<agentId>    # replicas=1

Key Vault secrets (per agent):
  feishu-app-id-<agentId>        # Feishu App ID
  feishu-app-secret-<agentId>    # Feishu App Secret

Key Vault secrets (shared):
  azure-openai-key               # Azure OpenAI API Key (all agents share)

NFS backup data (per agent, created by persist-sync):
  /persist/agents/<agentId>/     # Runtime state backup
```

### 3.2 Standard Label Set

All per-agent Deployments use a consistent label set:

```yaml
metadata:
  labels:
    app: openclaw-sandbox                  # shared across all agents (for listing)
    openclaw.io/agent-id: <agentId>        # unique per agent (for selection)
```

Admin Panel lists agents via `app=openclaw-sandbox`, selects a specific agent via `openclaw.io/agent-id=<agentId>`.

### 3.3 Lifecycle Operations

| Operation | v1 (StatefulSet) | v2 (Deployment) |
|-----------|-----------------|-----------------|
| Create agent | Update ConfigMap → upload NFS via Job → scale STS | Create SPC + PVC + Deployment |
| Delete agent | Nearly impossible (ordinal gap) | Delete Deployment + SPC; optionally delete PVC + KV secrets + NFS backup |
| Update agent config | Update NFS → restart Pod | Update KV secret → delete PVC config → restart Pod (see §4.7) |
| Update agent resources | Impossible (shared template) | Edit Deployment spec → rolling update (only this agent) |
| Scale to 0 | Scale STS affects all | Set replicas=0 on individual Deployment |

### 3.4 What Gets Eliminated

- ConfigMap `agent-mapping` (ordinal-to-agent-id mapping)
- Ordinal extraction logic in init container (`hostname | rev | cut`)
- Temp ConfigMap `agent-config-<agentId>` (credentials in etcd)
- Temp Job `upload-config-<agentId>` (NFS upload)
- Concurrency mutex in Admin Panel (`creating` flag for ordinal race)
- NFS as config delivery channel (credentials on shared filesystem)
- `feishu.env` file generation (credentials now from KV CSI, not env sourcing)

## 4. Architecture: Secure Config Injection (B+C Hybrid)

### 4.1 Principle

**Config template follows code; secrets follow Key Vault.**

- Non-sensitive configuration (gateway.mode, models.baseUrl, api-version, model id) is inlined in the init container shell script within the Deployment spec.
- Sensitive credentials (Feishu App ID/Secret, Azure OpenAI API Key) are stored exclusively in Key Vault and delivered to the Pod via CSI Secret Store driver on a tmpfs mount.

### 4.2 Credential Flow

```
Key Vault (encrypted, RBAC-controlled, audit-logged)
  |
  | CSI Secret Store driver (Workload Identity: Sandbox MI)
  v
tmpfs mount at /secrets (in-memory, ephemeral)
  |
  | init container reads files, assembles config.json
  v
work-disk PVC at /home/node/.openclaw/openclaw.json (encrypted Azure Disk)
  |
  | main container reads config
  v
openclaw gateway run
```

### 4.3 Security Comparison

| Credential location | v1 (current) | v2 (proposed) |
|---------------------|-------------|---------------|
| Key Vault | Present | Present |
| etcd (K8s Secret/ConfigMap) | Exposed (temp ConfigMap) | Never enters etcd |
| NFS shared filesystem | Exposed (config.json + feishu.env) | Never on NFS |
| Pod spec / env vars | Not exposed | Not exposed (CSI mount, not env) |
| `kubectl describe pod` | Not visible | Not visible |
| CSI tmpfs | N/A | Present (ephemeral, memory-only) |
| work-disk (Azure Disk) | Present (config.json) | Present (config.json) |
| Who can access | Anyone with NFS mount or `get cm` | Only Sandbox MI with KV Secrets User role |

### 4.4 Per-Agent SecretProviderClass

Each agent gets a SecretProviderClass that maps KV secret names to local file aliases. Uses the `clientID` parameter (recommended for Workload Identity) instead of the deprecated `useVMManagedIdentity`:

```yaml
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
```

The `objectAlias` ensures the init container script is agent-agnostic — it always reads `/secrets/feishu-app-id` regardless of which agent.

### 4.5 Complete Deployment Template

This is the full, self-contained per-agent Deployment spec. All placeholders are marked with `<angle-brackets>`:

```yaml
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
        azure.workload.identity/use: "true"   # Required for CSI Secret Store
    spec:
      serviceAccountName: openclaw-sandbox
      runtimeClassName: kata-vm-isolation
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

      # --- Init containers ---
      initContainers:

      # 1. Config assembly: reads KV secrets from CSI, writes config.json to PVC
      - name: setup-config
        image: busybox:1.36
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          OPENCLAW_DIR=/home/node/.openclaw
          mkdir -p "$OPENCLAW_DIR/workspace/memory" "$OPENCLAW_DIR/devices" "$OPENCLAW_DIR/sessions"

          # Guard: if PVC already has config (runtime-modified), skip
          if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then
            echo "Config exists on PVC, preserving runtime state"
            exit 0
          fi

          # Read secrets from CSI tmpfs mount
          FEISHU_ID=$(cat /secrets/feishu-app-id)
          FEISHU_SECRET=$(cat /secrets/feishu-app-secret)
          AOAI_KEY=$(cat /secrets/azure-openai-key)

          # Assemble config using printf (avoids heredoc indentation issues in YAML)
          printf '%s\n' "{\"gateway\":{\"mode\":\"local\"},\"channels\":{\"feishu\":{\"enabled\":true,\"appId\":\"$FEISHU_ID\",\"appSecret\":\"$FEISHU_SECRET\"}},\"models\":{\"providers\":{\"azure-openai-direct\":{\"baseUrl\":\"$AOAI_ENDPOINT\",\"apiKey\":\"$AOAI_KEY\",\"api\":\"openai-responses\",\"headers\":{\"api-version\":\"2025-04-01-preview\"},\"models\":[{\"id\":\"gpt-5.4\",\"name\":\"GPT-5.4 (Direct Azure OpenAI)\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
          echo "Config assembled from KV secrets"
        env:
        - name: AOAI_ENDPOINT
          value: "<azure_openai_endpoint>"    # Non-sensitive URL, safe as env var
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

      # 2. persist-sync: Native Sidecar (restartPolicy: Always), backs up runtime state to NFS
      - name: persist-sync
        restartPolicy: Always
        image: <acr_login_server>/persist-sync:latest
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

      # --- Main container ---
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

      # --- Volumes ---
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
      terminationGracePeriodSeconds: 30

---
# Per-agent PVC (created by Admin Panel before the Deployment)
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
```

Key design notes on this template:
- `azure.workload.identity/use: "true"` label on Pod template is mandatory for the Workload Identity webhook to inject the federated token that CSI Secret Store uses to authenticate to Key Vault.
- Config assembly uses `printf` (not heredoc) to avoid shell indentation issues when embedded in YAML `args` blocks. Single-line JSON is deliberate — readability is secondary to correctness in generated config.
- `AOAI_ENDPOINT` is the only env var on the init container — a non-sensitive URL. All credentials come from CSI file reads.
- The main container no longer needs `feishu.env` sourcing — credentials are already embedded in `openclaw.json` by the init container.
- `runtimeClassName`, `nodeSelector`, `tolerations`, and pod-level `securityContext` carry over from v1 unchanged.
- The PVC template includes the same labels as the Deployment, enabling `kubectl get pvc -l openclaw.io/agent-id=<agentId>` for management.

### 4.6 The `if [ -f ]` Guard

This is critical. openclaw modifies `openclaw.json` at runtime, appending:
- `meta` (instance metadata)
- `gateway.auth.token` (auto-generated auth token)
- `plugins.entries.feishu` (plugin registration)

On Pod restart, the PVC retains these modifications. The guard ensures the init container only generates a fresh config on first-ever boot (empty PVC). Subsequent restarts preserve the runtime state.

**Trade-off:** When credentials are rotated and the config is regenerated (see §4.7), the runtime-appended fields are lost. openclaw will re-run its first-boot sequence: re-register plugins, generate a new auth token, and rebuild metadata. This takes 2-3 minutes (the normal Kata VM startup time). If any external system depends on the auth token remaining stable, this would be disruptive. This is an accepted trade-off — token stability is not a current requirement.

### 4.7 Credential Rotation Procedure

When Feishu credentials or the Azure OpenAI key need to be rotated:

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
kubectl logs deploy/openclaw-agent-<agentId> -n openclaw \
  -c setup-config
# Should show: "Config assembled from KV secrets"
```

Future improvement: Admin Panel could provide a "Rotate Credentials" button that automates these steps.

## 5. persist-sync Sidecar (Simplified)

### 5.1 Role Change

| Responsibility | v1 | v2 |
|----------------|----|----|
| Config delivery to Pod | Primary channel | Not involved |
| Runtime state backup | Every 120s to NFS | Every 3600s (1h) to NFS |
| Cross-agent data sharing | Via NFS | Via NFS (unchanged) |

### 5.2 Key Changes from v1

- `AGENT_ID` via direct env var (no ordinal extraction, no `.agent-id` file)
- Sleep interval: 120s → 3600s (PVC itself persists, NFS is just backup)
- Full securityContext added (PSS restricted compliance)
- See §4.5 for complete YAML (integrated into Deployment template)

## 6. NFS Role Change

| Purpose | v1 | v2 |
|---------|----|----|
| Initial config delivery | Primary | Eliminated |
| Feishu credential delivery | Primary (feishu.env) | Eliminated (KV CSI) |
| Runtime state backup | Every 120s | Every 1h (reduced) |
| Shared data across agents | Yes | Yes (unchanged) |

NFS transitions from "config transport hub" to "backup + shared storage."

## 7. Admin Panel Changes

### 7.1 Create Agent Flow

**v1 (5 steps):**
1. Store Feishu creds in Key Vault
2. Generate config → create temp ConfigMap
3. Upload config to NFS via Job → cleanup
4. Update ConfigMap `agent-mapping` (ordinal)
5. Scale StatefulSet

**v2 (3 steps):**
1. Store Feishu creds in Key Vault (unchanged)
2. Create SecretProviderClass `spc-<agentId>` via `kubectl apply`
3. Create PVC `work-disk-<agentId>` + Deployment `openclaw-agent-<agentId>` via `kubectl apply`

### 7.2 Delete Agent Flow (New)

1. Delete Deployment `openclaw-agent-<agentId>`
2. Delete SecretProviderClass `spc-<agentId>`
3. (Optional) Delete PVC `work-disk-<agentId>`
4. (Optional) Delete NFS backup `/persist/agents/<agentId>`
5. (Optional) Delete KV secrets `feishu-app-id-<agentId>`, `feishu-app-secret-<agentId>`

### 7.3 List Agents

Replace ConfigMap `agent-mapping` scan with:
```
kubectl get deployments -n openclaw -l app=openclaw-sandbox -o json
```
Agent ID extracted from label `openclaw.io/agent-id` on each Deployment.

### 7.4 Eliminated from Admin Panel

- `buildUploadJobYaml()` — no more NFS upload Job
- `buildFeishuEnv()` — no more feishu.env generation
- Concurrency mutex (`creating` flag) — no ordinal race condition
- ConfigMap `agent-mapping` reads/writes — no more ordinal mapping
- Temp ConfigMap create/delete — no more credentials in etcd

### 7.5 Updated RBAC for Admin Panel

The Admin Panel's Role must be updated to reflect new resource types. Replace StatefulSet/Job/ConfigMap permissions with Deployment/PVC/SecretProviderClass permissions:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: openclaw-admin
  namespace: openclaw
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

Removed from v1 RBAC:
- `configmaps` — no longer needed (no agent-mapping, no temp configs)
- `statefulsets`, `statefulsets/scale` — replaced by deployments
- `jobs` — no more NFS upload jobs

### 7.6 Admin Panel Deployment Changes

The Admin Panel's own Deployment (in `admin/k8s/deployment.yaml`) should be updated:

- **Remove** env var `AZURE_OPENAI_KEY` and its source Secret `azure-openai-credentials`. The API key now lives exclusively in Key Vault, injected into agent Pods via CSI. Admin Panel no longer needs it.
- **Keep** env var `AZURE_OPENAI_ENDPOINT` — still needed for generating Deployment specs (non-sensitive URL).
- **Keep** env var `KV_NAME` — still needed for storing Feishu credentials.

## 8. Azure OpenAI Key Management

The Azure OpenAI API key should also be stored in Key Vault as a shared secret `azure-openai-key`, referenced by all agents' SecretProviderClasses. This eliminates the current pattern of passing `AZURE_OPENAI_KEY` as an env var to the Admin Panel and embedding it in every config.json.

Admin Panel only needs `AZURE_OPENAI_ENDPOINT` (non-sensitive URL) as an env var for generating Deployment specs.

## 9. Migration Path (Existing Agents)

For the three currently running agents (alice, bob, aks-demo):

### 9.1 Pre-Migration

1. Store `azure-openai-key` in Key Vault (one-time, shared secret)
2. Verify existing Feishu credentials are already in KV (`feishu-app-id-<agentId>`, `feishu-app-secret-<agentId>`)

### 9.2 Per-Agent Migration

For each agent, with the old StatefulSet still running:

1. Create SecretProviderClass `spc-<agentId>`
2. Create new PVC `work-disk-<agentId>` (fresh, empty — init container will assemble config)
3. Create Deployment `openclaw-agent-<agentId>` with new config injection
4. Wait for Pod to be Ready and verify Feishu WebSocket connection in logs
5. If successful: the old StatefulSet replica is now redundant for this agent
6. If failed: delete Deployment → debug → retry; old StatefulSet replica is unaffected

Note on existing PVCs: The v1 VCT-created PVCs are named `work-disk-openclaw-agent-<ordinal>` (e.g., `work-disk-openclaw-agent-0`). These cannot be renamed. v2 creates fresh PVCs named `work-disk-<agentId>`. The old PVCs contain runtime state (sessions, workspace data) but openclaw can rebuild this from scratch. If specific workspace data must be preserved, it can be manually copied from the old PVC to the new PVC via a temporary Pod before cutover.

### 9.3 Cutover

After all three agents are verified on their independent Deployments:

1. Scale down old StatefulSet to 0: `kubectl scale sts openclaw-agent -n openclaw --replicas=0`
2. Verify all agents still function (they run on independent Deployments now)
3. Delete old resources:
   - `kubectl delete sts openclaw-agent -n openclaw`
   - `kubectl delete cm agent-mapping -n openclaw`
   - Old VCT PVCs: `kubectl delete pvc work-disk-openclaw-agent-{0,1,2} -n openclaw`

### 9.4 Rollback

If issues arise after cutover:

1. Re-create StatefulSet with the v1 spec (from Git `k8s/sandbox/agent-statefulset.yaml`)
2. Scale to the original replica count
3. Old PVCs (if not yet deleted) will be re-attached automatically
4. Delete the v2 Deployments

The dual-running period (both StatefulSet and Deployments exist) is safe because each connects to Feishu via independent WebSocket. The only concern is running two bots with the same Feishu App ID simultaneously — this should be avoided by confirming the v2 agent works before scaling down the v1 replica.

## 10. Out of Scope

- Sandbox CRD adoption (revisit when API reaches beta)
- LiteLLM / AI gateway changes (stay with APIM plan)
- Prometheus / Grafana observability (v3)
- Helm Chart packaging (separate effort)
- Multi-channel support beyond Feishu
- Admin Panel authentication/authorization
