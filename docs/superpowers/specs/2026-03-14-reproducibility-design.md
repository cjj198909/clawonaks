# Reproducibility Design Spec

> 日期: 2026-03-14
> 状态: Draft
> 上下文: OpenClaw on AKS 部署流程当前有 ~10 步手动操作，需要自动化以支持可复制部署。

## 1. 问题陈述

当前部署流程涉及大量手动操作：

| # | 手动步骤 | 痛点 |
|---|----------|------|
| 1 | Terraform apply | ✅ 已自动化 |
| 2 | Kata nodepool CLI workaround | 手动，易遗忘参数 |
| 3 | Docker 镜像构建 ×3 | 脚本过时，镜像名不一致 |
| 4 | kubeconfig 获取 | 手动 |
| 5 | 静态 NFS PV/PVC 创建 | 手动，无 YAML 在 repo |
| 6 | K8s YAML sed 占位符替换 | 易出错，`deploy/` 目录模式混乱 |
| 7 | Admin Panel 部署 | 手动 sed + kubectl apply |
| 8 | azure-openai-key 存入 KV | 手动 |
| 9 | 过时文件混淆 | `agent-statefulset.yaml`、`create-agent.sh` 误导新用户 |

此外，`k8s/` 目录中的占位符（如 `<acr_login_server>`）通过 `sed` + `deploy/` 目录替换模式不够规范，维护两套（YAML 模板 + Admin Panel JS builder）容易不一致。

## 2. 设计决策

| 决策 | 选择 | 备选 | 理由 |
|------|------|------|------|
| K8s 模板化 | Helm Chart | Shell+sed, Kustomize | 社区标准，values.yaml 声明式管理，支持 upgrade/rollback |
| Chart 范围 | 单 Chart 管基础设施 | 双 Chart, Umbrella | per-agent 资源由 Admin Panel 动态创建，不放入 Chart。当前规模不需要 sub-chart |
| install.sh | 全流程一键部署 | 仅 K8s 层, 仅文档 | 最大化可复制性，从 terraform 到 helm install 一步完成 |
| 过时文件 | 标记 DEPRECATED | 删除 | 保留历史参考，不误导新用户 |

## 3. Helm Chart 设计

### 3.1 目录结构

```
charts/openclaw/
├── Chart.yaml                    # name: openclaw, version: 0.1.0, appVersion: 1.0.0
├── values.yaml                   # 所有可配置项 + 合理默认值
├── ci/
│   └── test-values.yaml          # helm lint / template 测试用
└── templates/
    ├── _helpers.tpl              # 通用 helper（fullname, labels, chart metadata）
    ├── namespace.yaml            # openclaw namespace + PSS restricted labels
    ├── storageclass-disk.yaml    # openclaw-disk (Premium_LRS Azure Disk)
    ├── storageclass-files.yaml   # openclaw-files (Premium NFS)
    ├── nfs-pv.yaml               # 静态 NFS PersistentVolume
    ├── nfs-pvc.yaml              # openclaw-shared-data PersistentVolumeClaim
    ├── sandbox-sa.yaml           # ServiceAccount openclaw-sandbox (Workload Identity)
    ├── netpol-sandbox.yaml       # Egress-only NetworkPolicy
    ├── admin-sa.yaml             # ServiceAccount openclaw-admin (Workload Identity)
    ├── admin-rbac.yaml           # Role + RoleBinding (Deployments, PVCs, SPCs, Pods, Pods/exec)
    ├── admin-deployment.yaml     # Admin Panel Deployment + Service
    └── agent-template-cm.yaml   # ConfigMap: 渲染后的 agent YAML 模板
```

### 3.2 values.yaml

```yaml
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
  image:
    tag: latest
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

### 3.3 Agent 模板 ConfigMap

Chart 中 `agent-template-cm.yaml` 生成一个 ConfigMap，内容为渲染后的 agent 三合一 YAML 模板。Helm 注入所有基础设施值（ACR login server、tenant ID、KV name、sandbox MI client ID、AOAI endpoint），只保留一个运行时占位符：`__AGENT_ID__`。

Admin Panel 启动时从 ConfigMap 挂载文件 `/etc/openclaw/agent-template.yaml` 读取模板，创建 agent 时做简单字符串替换后 `kubectl apply`。

**占位符语法选择：使用 `__AGENT_ID__` 而非 `{{AGENT_ID}}`。** Helm 使用 Go template 语法 `{{ }}`，如果 ConfigMap 内容中也使用双花括号，需要 `{{ "{{AGENT_ID}}" }}` 转义，容易出错。改用 `__AGENT_ID__` 下划线语法避免冲突，Admin Panel 做 `replaceAll('__AGENT_ID__', agentId)` 即可。

**Helm 模板注入点清单（agent-template-cm.yaml 中需要渲染的值）：**
- SPC: `clientID` ← `{{ .Values.identity.sandbox.clientId }}`
- SPC: `keyvaultName` ← `{{ .Values.azure.keyvault.name }}`
- SPC: `tenantId` ← `{{ .Values.azure.tenantId }}`
- SPC: `objectName` ← `feishu-app-id-__AGENT_ID__`（运行时替换）
- PVC: `storageClassName` ← `openclaw-disk`
- PVC: `storage` ← `{{ .Values.agent.workDiskSize }}`
- Deployment: `image` ← `{{ .Values.azure.acr.loginServer }}/{{ .Values.images.agent.name }}:{{ .Values.images.agent.tag }}`
- Deployment: persist-sync `image` ← `{{ .Values.azure.acr.loginServer }}/{{ .Values.images.persistSync.name }}:{{ .Values.images.persistSync.tag }}`
- Deployment: `AOAI_ENDPOINT` env ← `{{ .Values.azure.openai.endpoint }}`
- Deployment: `NODE_OPTIONS` env ← `{{ .Values.agent.nodeOptions }}`
- Deployment: resource requests/limits ← `{{ .Values.agent.resources.* }}`
- Deployment: persist-sync `sleep` ← `{{ .Values.agent.persistSync.syncInterval }}`

**运行时替换点清单（Admin Panel `replaceAll('__AGENT_ID__', agentId)` 替换的位置）：**
- SPC name: `spc-__AGENT_ID__`
- SPC objectName: `feishu-app-id-__AGENT_ID__`, `feishu-app-secret-__AGENT_ID__`
- PVC name: `work-disk-__AGENT_ID__`
- PVC label: `openclaw.io/agent-id: __AGENT_ID__`
- Deployment name: `openclaw-agent-__AGENT_ID__`
- Deployment labels/selectors: `openclaw.io/agent-id: __AGENT_ID__`
- Deployment `secretProviderClass`: `spc-__AGENT_ID__`
- Deployment `claimName`: `work-disk-__AGENT_ID__`
- Deployment persist-sync env `AGENT_ID`: `__AGENT_ID__`

### 3.4 NFS 静态 PV/PVC

当前 NFS PV/PVC 是手动创建的，repo 中无 YAML。Helm Chart 将其纳入管理：

**nfs-pv.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: openclaw-nfs-pv
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
      resourceGroup: {{ .Values.azure.storage.resourceGroup }}
      storageAccount: {{ .Values.azure.storage.accountName }}
      shareName: {{ .Values.azure.storage.shareName }}
      protocol: nfs
```

**nfs-pvc.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-shared-data
  namespace: {{ .Values.namespace }}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  volumeName: openclaw-nfs-pv
  storageClassName: ""
```

### 3.5 StorageClass 保留说明

`storageclass-files.yaml`（`openclaw-files` Premium NFS StorageClass）包含在 Chart 中但当前不被任何资源使用——NFS PV 采用静态绑定（`storageClassName: ""`）。保留此 StorageClass 是为未来动态 NFS 卷分配预留。如不需要，可在 values.yaml 中通过条件禁用。

### 3.6 Admin Panel Deployment 改造

Admin Panel Deployment 增加 ConfigMap volume 挂载：

```yaml
volumes:
- name: agent-template
  configMap:
    name: openclaw-agent-template
volumeMounts:
- name: agent-template
  mountPath: /etc/openclaw
  readOnly: true
```

**Admin Panel 最终环境变量列表：**

| 环境变量 | 来源 | 用途 | 变更 |
|----------|------|------|------|
| `KV_NAME` | Helm values | KV 存储飞书凭据 | 保留 |
| `AGENT_TEMPLATE_PATH` | 硬编码 | 模板文件路径 | **新增** |
| `NAMESPACE` | Helm values | kubectl 命令目标 namespace | 保留 |
| ~~`AZURE_OPENAI_ENDPOINT`~~ | — | 已烘焙到 ConfigMap 模板 | **删除** |
| ~~`SANDBOX_MI_CLIENT_ID`~~ | — | 已烘焙到 ConfigMap 模板 | **删除** |
| ~~`TENANT_ID`~~ | — | 已烘焙到 ConfigMap 模板 | **删除** |
| ~~`ACR_LOGIN_SERVER`~~ | — | 已烘焙到 ConfigMap 模板 | **删除** |

删除 4 个环境变量（基础设施值已在 Helm 渲染时烘焙入 ConfigMap），新增 1 个 `AGENT_TEMPLATE_PATH`。

## 4. Admin Panel server.js 改造

### 4.1 变更范围

**删除（~150 行）：**
- `buildSpcYaml()` 函数
- `buildPvcYaml()` 函数
- `buildDeploymentYaml()` 函数

**新增（~30 行）：**
- 启动时读取模板文件：
  ```js
  const TEMPLATE_PATH = process.env.AGENT_TEMPLATE_PATH || '/etc/openclaw/agent-template.yaml';
  let agentTemplate = '';
  // Loaded on startup
  ```
- 模板渲染函数：
  ```js
  function renderAgentYaml(agentId) {
    return agentTemplate.replaceAll('__AGENT_ID__', agentId);
  }
  ```
- POST handler 改为一次性 `kubectlApplyStdin(renderAgentYaml(agentId))`（三个 YAML 文档一起 apply）

### 4.2 创建流程简化

**Before (v2):**
1. KV 存凭据
2. `kubectlApplyStdin(buildSpcYaml(agentId))`
3. `kubectlApplyStdin(buildPvcYaml(agentId))` + `kubectlApplyStdin(buildDeploymentYaml(agentId))`

**After:**
1. KV 存凭据
2. `kubectlApplyStdin(renderAgentYaml(agentId))` — 一次 apply 三个文档

SSE 步骤数从 3 步可简化为 2 步（KV → K8s resources），或保持 3 步以显示细粒度进度。

### 4.3 向后兼容

- 如果 `AGENT_TEMPLATE_PATH` 文件不存在（例如未使用 Helm 部署），回退到内置 builder 函数
- 这样旧部署方式（手动 sed + kubectl apply）仍然可用

**决定：不做回退。** Reproducibility 的目标就是统一到 Helm，不维护两条路径。启动时如果模板文件不存在，打印错误日志并 exit 1。

## 5. install.sh 全流程设计

### 5.1 接口

```bash
./scripts/install.sh \
  --aoai-key "sk-xxx" \
  --aoai-endpoint "https://xxx.openai.azure.com" \
  [--tfvars path/to/terraform.tfvars]   # 默认: terraform/terraform.tfvars
  [--skip-terraform]                     # 跳过 terraform apply（用于仅更新 K8s 层）
  [--skip-images]                        # 跳过镜像构建（用于仅更新 Helm）
```

### 5.2 执行流程

```
Step 1/6: Terraform Init & Apply
  - cd terraform && terraform init && terraform apply -auto-approve
  - 从 output 提取所有值到 shell 变量

Step 2/6: Kata VM Isolation Nodepool
  - 检查: az aks nodepool show --name sandbox → 存在则跳过
  - 创建: az aks nodepool add --workload-runtime KataMshvVmIsolation ...
  - 参数: --node-vm-size Standard_D4s_v3 --enable-cluster-autoscaler
           --min-count 0 --max-count 3 --os-sku AzureLinux
           --labels openclaw.io/role=sandbox
           --node-taints openclaw.io/sandbox=true:NoSchedule

Step 3/6: Build & Push Docker Images
  - az acr build --registry $ACR_NAME --image openclaw-agent:latest docker/
  - az acr build --registry $ACR_NAME --image persist-sync:latest docker/persist-sync/
  - az acr build --registry $ACR_NAME --image openclaw-admin:latest admin/

Step 4/6: Get Kubeconfig
  - az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing

Step 5/6: Store Azure OpenAI Key in Key Vault
  - az keyvault secret set --vault-name $KV_NAME --name azure-openai-key --value $AOAI_KEY

Step 6/6: Helm Install
  - 生成 /tmp/openclaw-values-$$.yaml（从 terraform output 提取）
  - helm upgrade --install openclaw ./charts/openclaw \
      -f /tmp/openclaw-values-$$.yaml \
      --namespace openclaw --create-namespace
  - rm /tmp/openclaw-values-$$.yaml
```

### 5.3 值来源说明

生成 `values-generated.yaml` 时，各值的来源：

| values.yaml 字段 | 来源 | 说明 |
|-------------------|------|------|
| `azure.tenantId` | `az account show --query tenantId -o tsv` | Terraform outputs 中无 tenant_id，从 Azure CLI 获取 |
| `azure.acr.loginServer` | `terraform output -raw acr_login_server` | |
| `azure.keyvault.name` | `terraform output -raw keyvault_name` | |
| `azure.openai.endpoint` | CLI 参数 `--aoai-endpoint` | 非 terraform output，用户手动提供 |
| `azure.storage.accountName` | `terraform output -raw storage_account_name` | |
| `azure.storage.resourceGroup` | `terraform output -raw resource_group` | |
| `identity.sandbox.clientId` | `terraform output -raw sandbox_identity_client_id` | |
| `identity.admin.clientId` | `terraform output -raw admin_identity_client_id` | |

### 5.4 前置条件检查

脚本开头验证：
- 必需命令：`az`, `terraform`, `helm`, `kubectl`
- 必需参数：`--aoai-key`, `--aoai-endpoint`
- Azure 登录状态：`az account show`
- terraform.tfvars 文件存在

### 5.5 幂等性

| 步骤 | 幂等策略 |
|------|----------|
| Terraform | 原生幂等 |
| Kata nodepool | `az aks nodepool show` 存在性检查 |
| 镜像构建 | 覆盖同 tag |
| Kubeconfig | `--overwrite-existing` |
| KV secret | `az keyvault secret set` 覆盖 |
| 资源收养 | annotations --overwrite 幂等 |
| Helm | `helm upgrade --install` 原生幂等 |

### 5.6 已有资源收养（Existing Resource Adoption）

**这是最关键的幂等步骤。** 当前集群中已存在手动创建的 K8s 资源。Helm 默认拒绝管理它未创建的资源（报错 "rendered manifests contain a resource that already exists"）。在 `helm upgrade --install` 之前，`install.sh` 必须检测并收养这些资源。

**需要收养的资源清单：**

| 资源类型 | 名称 | Scope |
|----------|------|-------|
| Namespace | `openclaw` | Cluster |
| PersistentVolume | `openclaw-nfs-pv` | Cluster |
| StorageClass | `openclaw-disk` | Cluster |
| StorageClass | `openclaw-files` | Cluster |
| PersistentVolumeClaim | `openclaw-shared-data` | Namespaced (openclaw) |
| ServiceAccount | `openclaw-sandbox` | Namespaced (openclaw) |
| NetworkPolicy | `sandbox-egress` | Namespaced (openclaw) |

**注意：** Admin Panel 相关资源（ServiceAccount `openclaw-admin`、Role、RoleBinding、Deployment、Service）也需要收养（如果已存在）。

**收养逻辑（install.sh Step 6 helm install 之前执行）：**

```bash
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

echo "=== Step 6a: Adopt existing resources into Helm ==="
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
```

**安全性：** 收养操作只添加 annotation/label，不修改资源 spec。`--overwrite` 确保幂等。如果资源不存在（全新部署），`kubectl get` 返回非零退出码，`adopt_resource` 跳过。

**警告：不要使用 `helm install --force`。** `--force` 会删除并重建资源，可能导致 NFS PV 绑定丢失和数据不可访问。

## 6. 过时文件处理

### 6.1 标记 DEPRECATED

| 文件 | DEPRECATED 注释 |
|------|-----------------|
| `k8s/sandbox/agent-statefulset.yaml` | `# DEPRECATED (2026-03-14): v1 StatefulSet architecture. Replaced by Helm Chart + agent-deployment.template.yaml. See charts/openclaw/` |
| `scripts/create-agent.sh` | `# DEPRECATED (2026-03-14): v1 agent creation script based on StatefulSet + APIM. Replaced by Admin Panel (admin/server.js).` |

### 6.2 build-image.sh 重写

- 镜像名 `openclaw-sandbox` → `openclaw-agent`
- 新增 Admin Panel 镜像构建（`openclaw-admin`）
- 可独立于 install.sh 运行，用于单独重建镜像

### 6.3 install.sh 旧版

旧 `install.sh` 添加 DEPRECATED 注释，重命名为 `install-v1.sh`，新 `install.sh` 为 v2 全流程版本。

**决定：直接覆盖 install.sh。** Git 历史保留旧版本，不需要重命名。

## 7. `k8s/` 目录保留策略

Helm Chart 成为部署的单一入口后，`k8s/` 目录的 YAML 文件不再被 install.sh 使用。保留它们作为参考文档：

- `k8s/sandbox/agent-deployment.template.yaml` — 保留，作为 Chart 模板的原始参考
- `k8s/sandbox/service-account.yaml` — 保留
- `k8s/storage/` — 保留
- `k8s/security/` — 保留
- `k8s/namespaces.yaml` — 保留
- `deploy/` 目录模式 — 完全废弃（.gitignore 中已有）

`k8s/` 目录顶部添加 README：
```
# k8s/ — Reference YAML

These files are historical reference from v1/v2 manual deployment.
The canonical deployment method is now Helm Chart: see charts/openclaw/.
Agent resources are dynamically created by the Admin Panel.
```

## 8. 验证策略

### 8.1 本地验证（无需集群）

```bash
helm lint ./charts/openclaw
helm template openclaw ./charts/openclaw -f charts/openclaw/ci/test-values.yaml
```

`ci/test-values.yaml` 提供完整的测试值，确保模板渲染不报错。

### 8.2 部署后 E2E 验证

与现有验证流程一致（CLAUDE.md §6）：

1. Kata 隔离：`uname -r` 显示 mshv 内核
2. Admin Panel：`kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw`
3. 创建 agent → 飞书 WebSocket 连接成功
4. persist-sync sidecar 运行中
5. NFS 挂载正常：`/persist/agents/<agentId>/` 可写

### 8.3 不做

- 自动化集成测试（成本高，单环境）
- CI/CD pipeline（后续工作）
- Helm 单元测试插件（当前规模不需要）

## 9. 卸载与灾难恢复

### 9.1 helm uninstall 影响

`helm uninstall openclaw` 会删除所有 Chart 管理的资源（namespace, StorageClass, NFS PV/PVC, ServiceAccounts, Admin Panel 等）。**但 per-agent 资源（Deployment、SPC、PVC）由 Admin Panel 动态创建，不受 Helm 管理，会成为孤立资源。**

**安全卸载流程：**
1. 先通过 Admin Panel 删除所有 agent
2. 确认 `kubectl get deploy -n openclaw -l app=openclaw-sandbox` 返回空
3. 然后 `helm uninstall openclaw`

**NFS 数据安全：** NFS PV 的 `reclaimPolicy: Retain` 确保即使 PV 被删除，底层 Azure Files NFS share 数据不丢失（Terraform 管理 storage account 生命周期）。

### 9.2 destroy.sh 更新

`scripts/destroy.sh` 更新为先 `helm uninstall` 再 `terraform destroy`，替代现有的 `kubectl delete namespace` 方式。

## 10. 实现影响总结

> 注：admin/k8s/ 目录中的独立 YAML 文件由 Helm Chart 模板取代，但不删除（标记废弃或保留参考）。

| 组件 | 操作 | 新增/修改行数估算 |
|------|------|-------------------|
| `charts/openclaw/` | 新建 | ~400 行（12 个模板 + Chart.yaml + values.yaml + helpers） |
| `scripts/install.sh` | 重写 | ~150 行 |
| `scripts/build-image.sh` | 重写 | ~15 行 |
| `admin/server.js` | 修改 | -150 / +30 行（删除 YAML builders，添加模板读取） |
| `admin/k8s/deployment.yaml` | Helm Chart 取代 | 保留为参考，不再被 install.sh 使用 |
| `admin/k8s/rbac.yaml` | Helm Chart 取代 | 保留为参考，不再被 install.sh 使用 |
| 过时文件 | 标记 DEPRECATED | ~3 行/文件 |
| `k8s/README.md` | 新建 | ~5 行 |
| CLAUDE.md | 更新 | ~50 行（§4 项目结构、§8 部署操作、§11 进度更新） |
| `docker/persist-sync/Dockerfile` | 微调 | 注释更新（"StatefulSet" → "Deployment"） |

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| Helm Chart 渲染错误导致部署失败 | 高 | `helm lint` + `helm template` 本地验证 |
| Admin Panel 模板读取失败 | 高 | 启动时校验文件存在，exit 1 with 明确错误信息 |
| 已有资源未被 Helm 收养 | 高 | install.sh Step 6a `adopt_resource` 函数在 helm install 前自动收养（§5.6） |
| Kata nodepool add 耗时长（10-15 分钟） | 中 | install.sh 打印提示信息，不超时 |
| 现有 aks-demo agent 在 helm install 时受影响 | 低 | helm install 只管基础设施资源，不触碰 per-agent Deployment |
| `helm uninstall` 导致 agent 孤立 | 中 | 文档化安全卸载流程（§9.1），先删 agent 再卸载 |
