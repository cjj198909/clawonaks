# CLAUDE.md — OpenClaw on AKS

> 本文件为 AI 助手会话恢复文档。新会话读取此文件即可获得完整项目上下文。

## 1. 项目概述

将 [OpenClaw AI Agent](https://github.com/nicepkg/openclaw) 部署到 Azure Kubernetes Service (AKS)，全部基础设施代码化（Terraform + K8s manifests + Docker + Shell scripts）。

**核心目标：**
- 每个 Agent 沙箱运行在 Kata Containers VM 级别隔离的 Pod 中
- 模型调用通过 APIM AI Gateway 代理（api-version 注入、Responses API rewrite、限流）
- 飞书 Channel 接入使用 **Outbound WebSocket 长连接**（零 Inbound 公网端口）
- 存储分层：Azure Disk（per-Pod 工作区）+ Azure Files NFS（共享持久数据）
- AKS API Server 公网可达（kubectl / CI-CD 管理）
- **Admin Web Panel**（✅ 已完成）：通过 Web UI 创建 Agent，替代手动 CLI 流程

**非目标（v1 不做）：** 多租户计费、Confidential Containers

## 2. 架构决策与技术选型

### 2.1 网络架构

| 决策 | 选择 | 理由 |
|------|------|------|
| VNet CIDR | 10.0.0.0/16，三子网 | AKS(/22) + APIM(/24) + PE(/24)，预留扩展空间 |
| 飞书接入方式 | Outbound WebSocket（非 Webhook） | 零 Inbound 公网端口，无需 Ingress/TLS 证书/公网 IP |
| APIM 部署模式 | Internal VNet（StandardV2）— **当前禁用** | `enable_apim=false`，直接使用 Azure OpenAI 降低成本和部署时间 |
| AKS API Server | 公网可达 | kubectl 管理和 CI/CD 需要，可通过 authorized IP ranges 收紧 |
| AI Foundry 访问 | **当前禁用** (`enable_ai_foundry=false`) | 直接使用外部 Azure OpenAI endpoint |

### 2.2 计算与隔离

| 决策 | 选择 | 理由 |
|------|------|------|
| Pod 隔离 | Kata Containers（`KataVmIsolation`） | VM 级别内核隔离，比 gVisor 更强 |
| 节点 OS | AzureLinux | Kata Containers 必需 |
| K8s 版本 | 1.32 | 支持 Native Sidecar（restartPolicy: Always） |
| 节点池设计 | System(D2s_v3×1) + Sandbox(**D4s_v6**, 0-3 autoscale) | Granite Rapids CPU，2.5x 快于 v3；空闲时缩到 0 节省成本 |

### 2.3 存储设计

| 决策 | 选择 | 理由 |
|------|------|------|
| 工作区（per-Pod） | Azure Disk Premium_LRS via VCT | 随 Pod 生命周期，高 IOPS |
| 持久数据（共享） | Azure Files NFS Premium（静态 PV） | ReadWriteMany，所有 Agent 共享 |
| NFS PV 类型 | **静态 PV + PVC**（非动态） | CSI driver 直连 storage account，无需 StorageClass |
| 数据同步机制 | Native Sidecar persist-sync | 定时 sync（120s interval）+ SIGTERM trap |
| NFS 最小容量 | 100 GiB | Azure Premium NFS 最低要求 |

### 2.4 安全与身份

| 决策 | 选择 | 理由 |
|------|------|------|
| Azure OpenAI Key | 直接 API Key（via K8s Secret 或 NFS config） | APIM 禁用时的临时方案 |
| 飞书凭据 | Key Vault 存储 + NFS `feishu.env`（per-agent） | Admin Panel 写入 KV + NFS |
| ACR 拉取 | AKS kubelet MI + AcrPull RBAC | 无需 admin 密码 |
| Pod 安全标准 | PSS restricted | 所有容器 allowPrivilegeEscalation=false, drop ALL |
| Workload Identity | Sandbox MI（KV Secrets User）+ Admin MI（KV Secrets Officer） | 零密码，RBAC 分级 |

### 2.5 多 Agent 支持（v2 — 独立 Deployment per agent ✅ 已完成）

| 决策 | 选择 | 理由 |
|------|------|------|
| 工作负载类型 | **独立 Deployment per agent** | Agent 无集群关系，独立生命周期，可独立创建/删除/更新 |
| Agent ID 传递 | env var `AGENT_ID` | Deployment 名 `openclaw-agent-<agentId>`，无需 ordinal 映射 |
| Per-Agent 存储 | PVC `work-disk-<agentId>`（Azure Disk） | 独立生命周期，删除 agent 时可选保留 |
| Per-Agent 凭据 | SecretProviderClass `spc-<agentId>`（KV CSI） | KV 密钥自动挂载到 Pod，替代 NFS `feishu.env` |
| 创建流程 | Admin Panel（2 步 SSE） | KV 存储凭据 → 创建 K8s 资源（SPC+PVC+Deployment） |
| 删除流程 | Admin Panel DELETE endpoint | 删除 Deployment + SPC + PVC + KV 凭据 + NFS 数据 |
| Per-Agent 飞书凭据 | KV `feishu-app-id-<agentId>` + `feishu-app-secret-<agentId>` | SPC 挂载到 `/mnt/secrets/`，init container 读取构建 config |
| Azure OpenAI Key | KV `azure-openai-key`（共享） | 所有 agent SPC 引用同一密钥 |

**架构要点：**
- 每个 agent = 1 Deployment（replicas=1）+ 1 PVC `work-disk-<agentId>` + 1 SecretProviderClass `spc-<agentId>`
- Agent ID 通过 env var `AGENT_ID` 直传，消除旧 ConfigMap `agent-mapping` + ordinal 提取逻辑
- Init container 从 KV CSI 挂载点 `/mnt/secrets/` 读取凭据，构建 `config.json`（带 `if [ -f ]` guard 保留运行时状态）
- 互不影响：独立生命周期、独立 rolling update、独立资源配置
- 已删除：共享 StatefulSet、ConfigMap `agent-mapping`、NFS upload Job、并发创建竞态锁

### 2.6 Admin Panel 设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 技术栈 | Node.js Express + 单页 HTML | 零框架依赖，简单可靠 |
| 部署位置 | AKS system nodepool（Deployment） | 共用现有集群 |
| 访问方式 | `kubectl port-forward`（零认证） | 仅管理员使用，无需 Ingress |
| 创建进度 | Server-Sent Events (SSE) | 实时 2 步进度反馈（KV → K8s 资源） |
| Agent 模板 | ConfigMap `agent-template` + `renderAgentYaml()` | Helm 注入 values，Admin 仅替换 `__AGENT_ID__` 占位符 |
| Azure 认证 | 独立 Workload Identity（KV Secrets Officer） | 与 sandbox MI 权限分离 |

### 2.7 Helm Chart 设计决策（Reproducibility）

| 决策 | 选择 | 理由 |
|------|------|------|
| 模板化方案 | Helm Chart（非 Kustomize） | 变量注入 + 条件渲染 + 生态成熟 |
| Agent 模板传递 | ConfigMap `agent-template` 内嵌多文档 YAML | Admin Panel 运行时读取，用 `__AGENT_ID__` 占位符避免 Go template 冲突 |
| 占位符语法 | `__AGENT_ID__`（双下划线） | 不与 Helm `{{ }}` 冲突，`replaceAll()` 简单替换 |
| NFS PV volumeHandle | 可配置 `azure.storage.nfsVolumeHandle` | PV 创建后 volumeHandle 不可变，不同环境值不同 |
| 已有资源迁移 | `adopt_resource()` 函数（annotate + label） | Helm 接管已存在的 K8s 资源，无需删除重建 |
| install.sh 架构 | 7 步全流程（Terraform → KV → APIM Test → Kata → 镜像 → kubeconfig → Helm） | 支持 `--skip-terraform`、`--skip-images`、`--skip-apim-test` 跳过步骤；APIM test 前置验证 |
| install-v2.sh 架构 | 7+1 步（Terraform → **Step 1b: APIM 子资源 az CLI** → KV → APIM Test → Kata → 镜像 → kubeconfig → Helm） | **推荐版本**：APIM 子资源用幂等 `az rest` 创建，彻底消除 provider race condition；无 retry/import 逻辑 |

### 2.8 Kata VM 性能优化决策（✅ 已完成）

| 决策 | 选择 | 理由 |
|------|------|------|
| 文件系统优化 | **tmpfs tar prepack** | Kata VM virtiofs 读 37K 文件需 ~90s；tar 预打包后 tmpfs 解压仅 ~10s |
| WebSocket 超时补丁 | Client 60s / Server 60s / CLI 120s | 插件注册 ~6s(v6) / ~15s(v3)，bot 内部执行有 event loop 竞争再放大 2-3x |
| CLI wrapper 脚本 | `/home/node/bin/openclaw` → tmpfs 路径 | bot exec tool 生成的子进程通过 PATH 找到 tmpfs 版本，避免 virtiofs 慢路径 |
| 硬件升级 | D4s_v**3** → D4s_v**6** (Granite Rapids) | syscall 穿越 hypervisor 是 CPU 瓶颈；v6 比 v3 快 2.5x，同价格 |

**根因分析：**
- openclaw 有 37K 文件（224MB），每次 `require()` 都触发 virtiofs 读取穿越 hypervisor
- 每次 CLI 子进程（如 `openclaw cron add`）连接 gateway 需注册 5 个飞书插件，涉及大量 JS 执行 + syscall
- 当 bot 的 AI agent 通过 `exec` tool 执行 CLI 时，gateway event loop 正忙于处理请求，握手更慢
- **三层优化叠加**：tmpfs 消除文件 I/O 瓶颈 + 超时补丁容忍延迟 + v6 CPU 减少 hypervisor 开销

**基准测试结果（D4s_v6 + tmpfs + timeout patches）：**

| 指标 | D4s_v3 原始 | D4s_v3 + tmpfs | D4s_v6 + tmpfs | 总提升 |
|------|------------|----------------|----------------|--------|
| `openclaw --version` | ~21s | 0.55s | **0.25s** | 84x |
| `openclaw cron list` | timeout | 15.2s | **6.1s** | ∞→6s |
| Bot 内部执行 CLI | timeout | timeout (event loop) | **成功** (~12-18s) | ✅ |

## 3. 关键的已知限制与 Workaround

### 3.1 azurerm 4.x 不支持 Kata workload_runtime

**问题：** `azurerm_kubernetes_cluster_node_pool` 的 `workload_runtime` 在 4.x 只允许 `OCIContainer` | `WasmWasi`，不支持 `KataMshvVmIsolation`。

**Workaround：** `terraform/nodepool.tf` 已删除。Nodepool 完全由 `install.sh` Step 2 通过 `az aks nodepool add --workload-runtime KataVmIsolation` 管理。这避免了 Terraform 创建无 Kata 的 nodepool 导致 install.sh 跳过创建的问题。

**注意：**
- 参数是 `--node-vm-size`（不是 `--vm-size`）
- `--workload-runtime` 值已从 `KataMshvVmIsolation` 改为 `KataVmIsolation`（新版 az CLI）
- 节点池名称为 `sandboxv6`（对应 D4s_v6 硬件升级）

### 3.2 K8s manifest 模板化（✅ 已通过 Helm 解决）

**问题：** K8s YAML 中有占位符（`<sandbox_identity_client_id>`、`<admin_identity_client_id>` 等），需要替换为真实值。

**原方案（v1，已废弃）：** `install.sh` 将 `k8s/` 复制到 `deploy/` 目录，用 `sed` 替换占位符。

**当前方案（v2）：** Helm Chart（`charts/openclaw/`）通过 `values.yaml` 注入所有环境变量。`install.sh` 自动从 Terraform outputs 生成临时 values 文件并执行 `helm upgrade --install`。`k8s/` 目录保留为参考文档。

### 3.3 Premium NFS 最小 100 GiB

**问题：** Azure Premium FileStorage NFS 最低 100 GiB。

**说明：** Terraform 预创建了 100 GiB share（`storage.tf`）。Helm PVC 模板使用 `{{ .Values.azure.storage.nfsQuota }}`（默认 100Gi）匹配实际配额。**注意：** K8s 不允许 PVC storage request 小于 `status.capacity`，所以必须 ≥ 100Gi。

### 3.4 NFS 挂载注意事项（已修复）

| 问题 | 修复 |
|------|------|
| Storage account 需要 service endpoints | `network.tf` AKS 子网添加 `service_endpoints = ["Microsoft.Storage"]` |
| NFS 不使用 HTTPS | `storage.tf` 设置 `https_traffic_only_enabled = false` |
| CSI driver 自动添加 `vers=4,minorversion=1` | PV 中 **不要** 设置 `mountOptions: nfsvers=4.1`，否则冲突报错 |

### 3.5 azurerm Provider 瞬态 Bug（✅ install.sh 已自动处理）

**问题：** `terraform apply` 偶发 "Resource already exists" 错误 — APIM 子资源（backend、named value、logger、backend pool）在 Azure 中创建成功但未写入 Terraform state。

**自动修复（install.sh）：** Step 1 的 retry 逻辑会解析错误输出，提取孤立资源的 TF 地址和 Azure resource ID，自动 `terraform import`（使用 `TF_VAR_ARGS` 不含 `-auto-approve`）后重新 apply。ID 提取使用 `grep -o` 兼容 azurerm（单行）和 azapi（多行）两种错误格式。

**手动 Workaround（如需）：**
1. `az resource list --resource-group openclaw-rg` 找到已创建但不在 state 中的资源
2. `terraform import '<tf_address>' '<azure_resource_id>'`
3. 重新 `terraform apply`

### 3.5.1 APIM Named Value 鸡生蛋问题（✅ 已解决）

**问题：** Named Value 引用 KV secret `azure-openai-key`，但该 secret 由 install.sh 写入，不是 Terraform 资源。首次 apply 时 KV secret 不存在 → Named Value 创建失败 → 引用它的 Policy 也失败。

**修复（三层）：**
1. install.sh 在首次 apply 和 retry 之间写入 KV secret（inter-apply KV write）
2. `apim-api.tf` 中 Policy 资源添加 `depends_on = [azurerm_api_management_named_value.aoai_key]`，消除并行竞态
3. retry 前 `sleep 30` 等待 APIM MI → KV RBAC 传播

### 3.6 Git YAML 与已部署集群状态（✅ 已通过 Helm 完全对齐）

**历史：** Git 版本曾与集群有显著差异，现已通过 Helm Chart 完全对齐：
- ✅ 所有环境变量通过 `values.yaml` 注入，无硬编码
- ✅ Agent 模板通过 ConfigMap 传递给 Admin Panel，保证 Git = 集群
- ✅ `install.sh` 自动从 Terraform outputs 生成 values

**`k8s/` 目录定位：** 仅作为参考文档保留（README 已标注），实际部署使用 `charts/openclaw/`。

**已清理的遗留文件（标记 DEPRECATED）：**
- `k8s/sandbox/agent-statefulset.yaml` — v1 旧 StatefulSet
- `scripts/create-agent.sh` — 已被 Admin Panel 替代
- `admin/k8s/deployment.yaml` — 已被 Helm admin-deployment.yaml 替代
- `admin/k8s/rbac.yaml` — 已被 Helm admin-rbac.yaml + admin-sa.yaml 替代

### 3.7 Key Vault 私网访问限制

**问题：** Key Vault 配置了 private endpoint，`az keyvault secret set` 从 VM 外部执行会失败（"Public network access is disabled"）。

**Workaround：**
- `install.sh` 的 Step 5（KV 写入 AOAI key）可能失败，使用 `--skip-kv` 或从集群内 admin pod 执行
- 已有 AOAI key 可通过 `kubectl exec` 从现有 agent pod 中提取
- Admin Panel 通过 Workload Identity 从集群内部访问 KV，不受此限制

### 3.8 PV volumeHandle 不可变

**问题：** PV 创建后 `spec.csi.volumeHandle` 不可变，不同环境值不同。

**方案：** Helm values 中 `azure.storage.nfsVolumeHandle` 可配置（默认 `openclaw-nfs-unique-id`）。新环境部署时 `install.sh` 自动生成正确值。

### 3.9 Kata VM CLI 命令 gateway timeout（✅ 已修复）

**问题：** 在 Kata VM Pod 中执行 `openclaw cron add` 等 CLI 命令失败：`Error: gateway timeout after 30000ms`。

**根因（三层叠加）：**
1. **virtiofs 慢路径：** 37K 文件通过 virtiofs 加载需 ~21s，event loop 被阻塞 → WebSocket 握手超时
2. **默认超时太短：** Client 2s / Server 3s / CLI 30s — 即使 tmpfs 优化后（~6s 插件注册）仍然紧张
3. **Event loop 竞争：** Bot 的 AI agent 通过 `exec` tool 执行 CLI 时，gateway 正忙于处理请求，握手时间被放大 2-3x

**修复（Dockerfile sed patches + Helm chart + 硬件升级）：**

| 超时 | 原始值 | 修复后 | sed pattern |
|------|--------|--------|-------------|
| Client connect challenge | 2s | **60s** | `rawConnectDelayMs)) : 2e3` → `6e4` |
| Server handshake | 3s | **60s** | `DEFAULT_HANDSHAKE_TIMEOUT_MS = 3e3` → `6e4` |
| CLI RPC timeout | 30s | **120s** | `"Timeout in ms", "30000"` → `"120000"` |

**关键代码位置（容器内 dist 目录）：**
- Client-side：`config-*.js` 中 `queueConnect()` 的 `connectChallengeTimeoutMs`（27 文件）
- Server-side：`gateway-cli-*.js` 中 `getHandshakeTimeoutMs()`（2 文件）
- CLI timeout：`gateway-rpc-*.js` 中 Commander.js option `--timeout`（2 文件）

**辅助优化：**
- tmpfs tar prepack：启动时 `tar xf /opt/openclaw-bundle.tar -C /opt/openclaw-fast/`
- wrapper script：`/home/node/bin/openclaw` → `exec node /opt/openclaw-fast/openclaw/openclaw.mjs "$@"`
- PATH env：容器 env `PATH=/home/node/bin:...` 确保 bot 子进程也使用 tmpfs 版本
- 硬件升级：D4s_v3 → D4s_v6，插件注册从 15s 降到 6s

## 4. 项目结构

```
clawonaks/
├── terraform/                    # Terraform IaC（azurerm ~> 4.0）
│   ├── main.tf                   # Provider + data sources
│   ├── variables.tf              # 输入变量（含 enable_apim / enable_ai_foundry 开关）
│   ├── versions.tf               # Provider 版本约束
│   ├── network.tf                # VNet + 3 子网 + NSG + Storage service endpoint
│   ├── aks.tf                    # AKS 集群 + CSI Secret Store add-on
│   ├── nodepool.tf               # Kata sandbox 节点池（0-3 autoscale）
│   ├── ai-foundry.tf             # Azure OpenAI (Cognitive Account + deployment) — conditional
│   ├── private-endpoints.tf      # 3× PE + 3× DNS Zone + 3× VNet Link — conditional
│   ├── apim.tf                   # APIM StandardV2 Internal — conditional (enable_apim)
│   ├── apim-api.tf               # Azure OpenAI API 导入 + policy — conditional
│   ├── apim-subscriptions.tf     # Per-agent APIM subscription — conditional
│   ├── identity.tf               # RBAC + Workload Identity（sandbox MI + admin MI）
│   ├── monitoring.tf             # Log Analytics + App Insights
│   ├── storage.tf                # Premium FileStorage + NFS share (100 GiB, https_only=false)
│   ├── keyvault.tf               # Key Vault (RBAC auth, public access)
│   ├── acr.tf                    # Container Registry (Basic)
│   ├── outputs.tf                # 12 个输出值（含 admin_identity_client_id）
│   └── terraform.tfvars          # 当前配置（westus2, enable_apim=false）
├── docker/
│   ├── Dockerfile                # node:22-slim + openclaw + Kata VM patches (timeout + tar prepack)
│   └── persist-sync/Dockerfile   # alpine:3.20 + inotify-tools
├── k8s/
│   ├── namespaces.yaml           # openclaw namespace (PSS restricted)
│   ├── storage/
│   │   ├── disk-storageclass.yaml    # Premium_LRS Azure Disk
│   │   └── files-storageclass.yaml   # Premium_LRS NFS via PE
│   ├── sandbox/
│   │   ├── service-account.yaml          # Workload Identity SA（占位符）
│   │   └── agent-deployment.template.yaml # Deployment + SPC + PVC 模板（per-agent，占位符需替换）
│   └── security/
│       └── netpol-sandbox.yaml       # Egress-only NetworkPolicy
├── admin/                        # ✅ 已完成 — Admin Panel
│   ├── Dockerfile                # node:22-slim + kubectl + az CLI
│   ├── package.json              # express dependency
│   ├── server.js                 # Express server: 4 routes + SSE creation flow + pairing approve
│   ├── index.html                # Single-page UI (dark theme)
│   └── k8s/
│       ├── rbac.yaml             # ServiceAccount + Role + RoleBinding
│       └── deployment.yaml       # Deployment + Service
├── policies/
│   └── ai-gateway.xml           # APIM policy（MI auth + 60K TPM + metrics）
├── charts/
│   └── openclaw/                 # Helm Chart（基础设施 K8s 资源）
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── ci/test-values.yaml
│       └── templates/            # 12 个模板（namespace, SC, PV/PVC, SA, netpol, admin, agent-template CM）
├── scripts/
│   ├── install.sh               # 全流程一键部署（旧版，保留参考）
│   ├── install-v2.sh            # 全流程一键部署（推荐）：APIM 子资源用 az CLI，无 race condition
│   ├── build-image.sh           # 构建 3 个镜像（openclaw-agent, persist-sync, openclaw-admin）
│   ├── create-agent.sh          # ⚠️ 已废弃（标记 DEPRECATED）
│   └── destroy.sh               # helm uninstall + terraform destroy
├── docs/
│   └── superpowers/
│       ├── specs/
│       │   ├── 2026-03-13-admin-panel-design.md   # Admin Panel 设计 Spec ✅
│       │   ├── 2026-03-14-v2-migration-design.md  # v2 架构迁移 Spec ✅
│       │   ├── 2026-03-14-pairing-approve-design.md # DM Pairing Approve Spec ✅
│       │   └── 2026-03-14-reproducibility-design.md # Reproducibility 设计 Spec ✅
│       └── plans/
│           ├── 2026-03-13-openclaw-on-aks.md      # 基础设施部署计划（已完成）
│           ├── 2026-03-13-admin-panel.md           # Admin Panel 实现计划 ✅
│           ├── 2026-03-14-pairing-approve.md       # DM Pairing Approve 计划 ✅
│           ├── 2026-03-14-v2-migration.md          # v2 架构迁移计划 ✅
│           └── 2026-03-14-reproducibility.md       # Reproducibility 实现计划 ✅
├── DESIGN.md                    # 详细设计文档（架构、代码、流程）
└── CLAUDE.md                    # 本文件
```

## 5. 代码约定与模式

### 5.1 Terraform

- **Provider:** `azurerm ~> 4.0`（当前锁定 4.64.0）
- **资源组：** 使用 `data.azurerm_resource_group.main.name`（预存在，防止 destroy 误删）
- **变量引用：** 所有 `.tf` 文件使用 `data.azurerm_resource_group.main.name` 而非 `var.resource_group`
- **命名：** 资源名统一 `openclaw-` 前缀 + `random_id.suffix.hex` 后缀
- **Key Vault：** 使用 `rbac_authorization_enabled`（旧名 `enable_rbac_authorization` 已废弃）
- **AKS add-on：** `key_vault_secrets_provider` 必须启用（SecretProviderClass CRD 依赖）
- **条件资源：** APIM / AI Foundry / PE 通过 `count = var.enable_apim ? 1 : 0` 控制
- **Workload Identity：** sandbox MI（KV Secrets User）+ admin MI（KV Secrets Officer），各有独立 federated credential

### 5.2 K8s YAML / Helm Chart

- **Deployment + SPC + PVC 模型：** 每个 agent = 1 Deployment `openclaw-agent-<agentId>` + 1 SecretProviderClass `spc-<agentId>` + 1 PVC `work-disk-<agentId>`
- **Helm Chart（`charts/openclaw/`）：** 12 个模板管理基础设施 K8s 资源（namespace、StorageClass、NFS PV/PVC、SA、netpol、admin deployment、agent-template ConfigMap）
- **Agent 模板：** `agent-template-cm.yaml` 是最复杂的 Helm 模板，内嵌多文档 YAML（SPC+PVC+Deployment），使用 `__AGENT_ID__` 字面占位符（非 Go template 语法），Helm values 在 install 时注入
- **Admin Panel 模板读取：** `server.js` 启动时从 ConfigMap 挂载路径 `AGENT_TEMPLATE_PATH` 读取模板，`renderAgentYaml(agentId)` 仅做 `replaceAll('__AGENT_ID__', agentId)`
- **Per-Agent SecretProviderClass：** KV CSI 注入飞书凭据 + Azure OpenAI key 到 `/mnt/secrets/`，init container 读取构建 config
- **PSS restricted：** 所有容器（init、sidecar、main）都必须有完整 securityContext
- **Native Sidecar：** `persist-sync` 在 `initContainers` 中，通过 `restartPolicy: Always` 标记为 Native Sidecar
- **Init container `if [ -f ]` guard：** 仅在 config 不存在时从 KV CSI 构建，Pod 重启时保留运行时状态（openclaw 自动追加的 meta/token/plugin 字段）
- **静态 NFS PV/PVC：** 不使用 StorageClass 动态分配。PV 名 `openclaw-nfs-pv`，PVC 名 `openclaw-shared-data`
- **tmpfs 优化（agent-template-cm.yaml）：** 主容器启动时 `tar xf` 解压到 tmpfs emptyDir，创建 wrapper script，通过 PATH env 确保 CLI 子进程也使用 tmpfs 版本
- **`k8s/` 目录：** 仅作为参考保留，实际部署使用 Helm Chart

### 5.3 Shell Scripts

- 所有脚本 `set -euo pipefail`，shellcheck 已通过验证
- **`install.sh`（旧版，保留参考）：** 7 步全流程，含复杂 auto-import/retry 逻辑处理 APIM race condition。
- **`install-v2.sh`（✅ 推荐）：** 8 步全流程（增加 Step 1b），APIM 子资源（Logger/Named Value/Backend/Backend Pool/API/Operation/Policy）全部改为 `az rest` 幂等创建，彻底消除 azurerm provider race condition。Step 1 Terraform 单次 apply 无需 retry。支持 `--skip-terraform`、`--skip-images`、`--skip-apim-test` 参数。
- **`build-image.sh`（✅ 已重写）：** 构建 3 个镜像（`openclaw-agent`、`persist-sync`、`openclaw-admin`），使用 `SCRIPT_DIR/ROOT_DIR` 定位
- **`destroy.sh`（✅ 已更新）：** 先 `helm uninstall` 再 `terraform destroy`
- **`create-agent.sh`：** ⚠️ 已废弃（标记 DEPRECATED），Agent 创建/删除由 Admin Panel 接管

### 5.4 Docker / Kata VM 优化

- **Dockerfile 三层 sed 补丁：** `find ... -exec sed -i -e ... -e ... -e ... {} +` 在构建时修补 openclaw dist 文件中的硬编码超时值
- **tar prepack：** `RUN tar cf /opt/openclaw-bundle.tar` 在构建时将 openclaw 打包为 tarball，运行时解压到 tmpfs
- **补丁必须在 tar 之前：** sed 修改源文件 → tar 打包修改后的文件 → 运行时 tmpfs 包含补丁
- **Helm chart tmpfs 支持：** `values.yaml` 中 `agent.tmpfs.enabled=true`，控制 emptyDir volume + wrapper script + PATH env
- **内存容量规划：** tmpfs 需要 ~680MB（openclaw 579MB + 解压开销），Pod memory limits 需相应增加
- **values.yaml 关键参数：** `agent.resources.requests.memory=1.5Gi`, `agent.resources.limits.memory=4Gi`, `agent.tmpfs.sizeLimit=800Mi`

### 5.5 已部署集群的实际路径约定

| 资源 | 实际路径/名称 |
|------|---------------|
| Deployment | `openclaw-agent-<agentId>` |
| SecretProviderClass | `spc-<agentId>` |
| Per-Agent PVC（Azure Disk） | `work-disk-<agentId>` |
| NFS PVC | `openclaw-shared-data` |
| NFS PV | `openclaw-nfs-pv` |
| NFS 上 agent config | `/persist/agents/<agentId>/config.json` |
| KV CSI 挂载点 | `/mnt/secrets/`（`feishu-app-id`、`feishu-app-secret`、`azure-openai-key`） |
| Init container 行为 | 从 `/mnt/secrets/` 读取凭据 → 构建 `$OPENCLAW_DIR/openclaw.json`（`if [ -f ]` guard 保留运行时状态） |
| ConfigMap `agent-mapping` | **已删除**（v2 不再需要） |

## 6. 实施进度

### 阶段 1：基础设施代码 ✅ 已完成

| Task | 内容 | Commit |
|------|------|--------|
| 1-4 | Terraform scaffold + network + monitoring + storage/kv/acr | `49763e5` → `ff21fcb` |
| 5-6 | AKS cluster + Private Endpoints + AI Foundry | `09d3a70`, `ef6a343` |
| 7-9 | APIM + Identity/RBAC + Outputs | `d4a9388` → `8fe69d5` |
| 10-11 | Docker images + K8s namespace/storage | `f067bce`, `d3660db` |
| 12-13 | K8s security + StatefulSet | `bd3f399`, `428681b` |
| 14 | Operational scripts | `234e1b9` |

### 阶段 2：West US 2 部署 ✅ 已完成

| Task | 状态 | 备注 |
|------|------|------|
| Terraform Apply | ✅ | 多次 apply 修复 provider 瞬态 bug + storage 配置 |
| Kata Nodepool 创建 | ✅ | `az aks nodepool add --workload-runtime KataMshvVmIsolation` |
| Docker Images Build+Push | ✅ | `openclaw-agent:latest` + `persist-sync:latest` |
| 静态 NFS PV/PVC 创建 | ✅ | 手动创建（非 StorageClass 动态分配） |
| K8s Resources 部署 | ✅ | namespace, SA, ConfigMap, StatefulSet |
| E2E 验证 | ✅ | Kata 隔离（mshv kernel）+ NFS 挂载 + Azure OpenAI 连通 + persist-sync |

**E2E 验证结果（2026-03-13）：**
- `uname -r` 显示 mshv 内核（Kata VM 隔离确认）
- `curl Azure OpenAI` 返回 HTTP 200
- `config.json` 从 NFS 成功加载
- persist-sync sidecar 运行中
- Agent 主容器启动（需要飞书凭据才能正常运行）

### 阶段 3：Admin Panel ✅ 已完成 + 飞书 E2E 验证通过

| 文档 | 路径 | 状态 |
|------|------|------|
| 设计 Spec | `docs/superpowers/specs/2026-03-13-admin-panel-design.md` | ✅ 已完成 + review |
| 实现计划 | `docs/superpowers/plans/2026-03-13-admin-panel.md` | ✅ 已完成 + review |

**Admin Panel 实现计划概要（13 Tasks，5 Chunks）：**

| Chunk | Tasks | 内容 |
|-------|-------|------|
| 1 | 1 | Terraform: admin MI + KV Secrets Officer role |
| 2 | 2-4 | Application code: server.js + index.html + package.json |
| 3 | 5-7 | Docker image + K8s manifests (RBAC, Deployment, Service) |
| 4 | 8 | StatefulSet update + Git reconciliation for per-agent Feishu |
| 5 | 9-13 | Build, deploy, and E2E test |

**关键设计点：**
- NFS upload Job 写入 `/shared/agents/<agentId>/config.json` + `feishu.env`
- Init container 拷贝 `config.json` + `feishu.env` 到 workspace
- Main container 先 `source feishu.env` 再 `exec openclaw gateway run --verbose`
- `az login` 每 45 分钟刷新 federated token（POST handler 内额外调一次 azLogin 确保 token 不过期）
- 创建互斥锁防止并发 ordinal 冲突
- feishu.env 值单引号转义防注入

**部署过程发现并修复的关键问题（2026-03-14）：**

| 问题 | 根因 | 修复 |
|------|------|------|
| `Missing config` 启动失败 | `OPENCLAW_HOME=/home/node/.openclaw` 被 openclaw 当作 HOME 目录再追加 `.openclaw`，导致 config path 变成 `/home/node/.openclaw/.openclaw/openclaw.json`（双层嵌套） | 移除 `OPENCLAW_HOME` env var，让 openclaw 使用 `HOME=/home/node` 自然解析 |
| `Unrecognized key: isDefault` 配置校验失败 | `buildConfigJson()` 中 model 定义包含 openclaw schema 不认识的 `isDefault` 字段 | 从 model 对象中移除 `isDefault: true` |
| JS heap OOM（1017 MB → 崩溃） | openclaw 包体 224MB + 插件加载内存消耗大，Node.js 默认 heap 不够 | 添加 `NODE_OPTIONS=--max-old-space-size=2048`，容器 memory limit 从 2Gi 提升到 3Gi，requests 从 512Mi 提升到 1Gi |
| `config.json` 只含 `models` 段 | `buildConfigJson()` 缺少 `gateway.mode: "local"` 和 `channels.feishu` 配置 | `buildConfigJson(feishuAppId, feishuAppSecret)` 现在生成完整配置，包含 gateway + channels + models |
| KV AKV10046 Unauthorized | Workload Identity federated token 缓存过期 | POST handler 中 KV 操作前增加 `await azLogin()` 刷新 token |

**openclaw config.json 完整格式（Admin Panel 生成）：**
```json
{
  "gateway": { "mode": "local" },
  "channels": {
    "feishu": {
      "enabled": true,
      "appId": "<from-admin-panel-input>",
      "appSecret": "<from-admin-panel-input>"
    }
  },
  "models": {
    "providers": {
      "azure-openai-direct": {
        "baseUrl": "<AZURE_OPENAI_ENDPOINT>",
        "apiKey": "<AZURE_OPENAI_KEY>",
        "api": "openai-responses",
        "headers": { "api-version": "2025-04-01-preview" },
        "models": [{ "id": "gpt-5.4", "name": "GPT-5.4 (Direct Azure OpenAI)" }]
      }
    }
  }
}
```
> **注意：** openclaw 首次启动后会自动修改 config.json，追加 `meta`、`gateway.auth.token`、`plugins.entries.feishu` 等字段。

**飞书 DM Pairing 机制：**
- openclaw 默认 `dmPolicy="pairing"`，新用户首次私聊 bot 会收到 pairing code
- 需要在对应 agent Pod 中执行 `openclaw pairing approve feishu <CODE>` 批准
- 示例：`kubectl exec deploy/openclaw-agent-aks-demo -c openclaw -n openclaw -- openclaw pairing approve feishu RF55K9QP`
- 可在 config 中设置 `dmPolicy: "open"` 跳过（降低安全性）

**E2E 验证结果（2026-03-14）：**
- Admin Panel 通过 `kubectl port-forward` 访问正常
- 创建 agent `aks-demo` 成功（SSE 进度：KV → K8s 资源）
- Gateway 启动：`listening on ws://127.0.0.1:18789`
- 飞书 WebSocket 连接成功：`feishu[default]: WebSocket client started` → `ws client ready`
- DM pairing approve 成功，可正常对话

### 阶段 4：v2 迁移（StatefulSet → 独立 Deployment）✅ 已完成

| Task | 状态 | 备注 |
|------|------|------|
| K8s Manifests | ✅ | agent-deployment.template.yaml (SPC+PVC+Deployment) |
| Admin RBAC 更新 | ✅ | Deployment/PVC/SPC 权限替换 STS/Job/ConfigMap |
| Admin server.js 重写 | ✅ | 3 步创建 + DELETE endpoint + KV CSI 配置注入 |
| Admin UI 更新 | ✅ | 3 步进度、删除按钮、移除 ordinal |
| azure-openai-key 存入 KV | ✅ | 共享密钥，所有 agent SPC 引用 |
| 迁移 aks-demo | ✅ | Feishu WebSocket 连接成功 |
| 旧 STS + ConfigMap 清理 | ✅ | StatefulSet、agent-mapping、旧 VCT PVCs 已删除 |
| Pod 重启验证 | ✅ | Config 保留，Feishu 自动重连，无需重新配对 |

### 阶段 5：Reproducibility（Helm Chart + 一键部署）✅ 已完成

| Task | 状态 | 备注 |
|------|------|------|
| Helm Chart 脚手架 | ✅ | Chart.yaml, values.yaml, _helpers.tpl, ci/test-values.yaml |
| 基础设施模板 | ✅ | namespace, 2× StorageClass, NFS PV/PVC, SA, netpol（6 templates） |
| Admin Panel 模板 | ✅ | admin-sa, admin-rbac, admin-deployment（3 templates） |
| Agent 模板 ConfigMap | ✅ | agent-template-cm.yaml：最复杂模板，内嵌 SPC+PVC+Deployment multi-doc |
| install.sh 重写 | ✅ | 6-step 全流程 + `adopt_resource()` + arg parsing + trap cleanup |
| build-image.sh 修复 | ✅ | 镜像名更正（openclaw-sandbox → openclaw-agent）+ admin 镜像 |
| destroy.sh 更新 | ✅ | 添加 helm uninstall |
| Admin Panel 改造 | ✅ | 移除 ~210 行 YAML builders → `renderAgentYaml()` 单函数，3 步 SSE → 2 步 |
| 过时文件标记 | ✅ | 4 个文件添加 DEPRECATED header |
| E2E 测试 | ✅ | Helm deploy → agent 创建 → agent 删除 → aks-demo 健康检查 |
| NFS PV/PVC 修复 | ✅ | volumeHandle 可配置 + PVC storage 匹配 quota（commit `a67c12c`） |

**Reproducibility E2E 测试中发现并修复的关键问题：**

| 问题 | 根因 | 修复 |
|------|------|------|
| PV volumeHandle 不匹配 | 模板硬编码 `openclaw-nfs-pv`，但集群用 `openclaw-nfs-unique-id` | `azure.storage.nfsVolumeHandle` 可配置 |
| PVC storage 缩容失败 | 模板写 5Gi，集群 capacity 100Gi | 改用 `{{ .Values.azure.storage.nfsQuota }}`（100Gi） |
| KV 私网访问失败 | install.sh Step 5 从 VM 写 KV | 已知限制，需从集群内执行或 `--skip-kv` |
| Helm 路径错误 | `cd terraform` 后相对路径 `./charts/` 失效 | 改用 `$ROOT_DIR/charts/openclaw` 绝对路径 |

### 阶段 6：合并到 master ✅ 已完成

| Task | 状态 | 备注 |
|------|------|------|
| Pre-merge 验证 | ✅ | helm lint + template render + shellcheck 全部通过 |
| 合并 | ✅ | `git merge --no-ff feat/admin-panel`，merge commit `5ea89fd` |
| Post-merge 验证 | ✅ | master 分支 helm lint 通过 |

**分支状态：** `feat/admin-panel` 已合并到 `master`（93 commits），分支仍保留可手动删除。

### 阶段 7：Kata VM 性能优化 ✅ 已完成

| Task | 状态 | 备注 |
|------|------|------|
| 问题诊断 | ✅ | virtiofs 37K 文件读取 + WebSocket 握手超时 + event loop 竞争 |
| tmpfs tar prepack | ✅ | Dockerfile: `tar cf` 预打包，运行时 `tar xf` 到 emptyDir Memory |
| WebSocket 超时补丁 | ✅ | Client 2s→60s, Server 3s→60s, CLI 30s→120s（sed patches） |
| Helm chart tmpfs 支持 | ✅ | emptyDir volume + wrapper script + PATH env + memory limits |
| CLI wrapper 脚本 | ✅ | `/home/node/bin/openclaw` 确保 bot 子进程使用 tmpfs |
| 硬件升级 D4s_v3→v6 | ✅ | 新 nodepool `sandboxv6` (Standard_D4s_v6, Granite Rapids) |
| 旧 nodepool 清理 | ✅ | `sandbox` (D4s_v3) 已删除 |
| 基准测试 | ✅ | `cron list` 15.2s→6.1s (2.5x), `--version` 0.55s→0.25s (2.2x) |
| Bot 内部 CLI 验证 | ✅ | `openclaw cron add` 通过飞书 bot 执行成功 |

**关键发现：**
- virtiofs 不是唯一瓶颈 — tmpfs 优化后仍需 ~15s(v3)，因为插件注册是 CPU-bound（syscall 穿 hypervisor）
- D4s_v3 (Broadwell 2017) → D4s_v6 (Granite Rapids 2024) 单核性能提升 ~2.5x，**同价格**
- 三层优化缺一不可：tmpfs（消除 I/O）+ timeout（容忍延迟）+ v6 CPU（减少延迟）
- Bot 内部执行比 kubectl exec 慢 2-3x（gateway event loop 竞争）

### 阶段 8：APIM AI Gateway E2E 修复 ✅ 已完成

| Task | 状态 | 备注 |
|------|------|------|
| APIM policy 修复 | ✅ | api-version query param 注入 + Responses API URL rewrite + Authorization header delete |
| Terraform 变量 | ✅ | `aoai_api_version` 变量 + `apim-api.tf` template 传参 |
| nodepool.tf 删除 | ✅ | 避免 Terraform 创建无 Kata nodepool 导致 install.sh 跳过 |
| install.sh APIM retry | ✅ | terraform apply 失败时自动重试一次（APIM policy CREATE→UPDATE 修复） |

**三个 APIM+OpenAI 集成 Bug：**
1. `api-version` 必须作为 query param 传递（SDK 可能只发 header），否则 Azure OpenAI 返回 404
2. Responses API 只支持 `/openai/responses`（model 在 body），不支持 `/openai/deployments/{model}/responses`
3. `api_key` 模式下必须删除 Authorization header，否则 Azure OpenAI 拒绝无效 Bearer token

### openclaw 运行时行为（调试中发现的关键知识）

**路径解析机制：**
- `OPENCLAW_HOME` 是 HOME 目录覆盖（**不是** state 目录），等效于 `HOME` env var
- State 目录 = `path.join(homedir(), '.openclaw')`，即 HOME 目录下追加 `.openclaw`
- 因此 `OPENCLAW_HOME=/home/node/.openclaw` 会导致双层嵌套：`/home/node/.openclaw/.openclaw/`
- **正确做法：** 不设 `OPENCLAW_HOME`，让 `HOME=/home/node` 自然解析到 `/home/node/.openclaw`

**Gateway 启动顺序（Kata VM 中约 2-3 分钟完成）：**
1. Plugin registration（耗时最长，~2 分钟）
2. Config auto-modification（追加 meta、auth token、plugin entries 等）
3. Auth token 生成
4. HTTP server 启动：`listening on ws://127.0.0.1:18789`
5. Feishu WebSocket 连接：`feishu[default]: WebSocket client started` → `ws client ready`

**Config 校验：**
- `validateConfigObjectWithPlugins()` 严格拒绝未知字段（如 `isDefault`）
- 飞书凭据**必须**在 `config.json` 的 `channels.feishu` 段中，**不从 env var 读取**
- `gateway.mode: "local"` 是必需字段，缺少会报 "Missing config"

**内存需求：**
- openclaw 包体 224MB（5278 files），插件加载消耗大量堆内存
- 默认 Node.js heap (~1GB) 不够，需要 `NODE_OPTIONS=--max-old-space-size=2048`
- tmpfs 优化增加 ~680MB 内存占用（openclaw 579MB 解压到 in-VM memory）
- 容器 memory limit 至少 4Gi，requests 至少 1.5Gi（含 tmpfs 开销）
- tmpfs emptyDir sizeLimit: 800Mi

## 7. 当前部署环境

### Azure 环境

```
Subscription:    jiajunchen-subscription-1
Subscription ID: 55a5740e-376a-4d19-9be9-ae2be9c3731e
Tenant ID:       20d50aa8-9f98-45c5-a698-e58be99c390d
User:            admin@MngEnv647263.onmicrosoft.com
Region:          West US 2 (westus2)
Resource Group:  openclaw-rg
```

### Terraform Outputs（West US 2 部署）

```
acr_login_server           = openclawacre2a78886.azurecr.io
acr_name                   = openclawacre2a78886
aks_fqdn                   = openclaw-0z3oo4w4.hcp.westus2.azmk8s.io
aks_name                   = openclaw-aks
keyvault_name              = openclaw-kv-e2a78886
storage_account_name       = openclawste2a78886
sandbox_identity_client_id = 4176b14b-d1dc-4450-ad84-039a5bf7193d
admin_identity_client_id   = ea66b1f7-a40d-437d-be44-50d58dce7518
random_id suffix           = e2a78886
apim_name                  = "" (disabled)
apim_private_url           = "" (disabled)
```

### terraform.tfvars（当前配置）

```hcl
resource_group    = "openclaw-rg"
location          = "westus2"
cluster_name      = "openclaw-aks"
admin_email       = "admin@MngEnv647263.onmicrosoft.com"
agent_ids         = ["alice"]
enable_apim       = false
enable_ai_foundry = false
```

## 8. 部署后操作

### 新环境部署（一键）

```bash
./scripts/install.sh --aoai-key "KEY" --aoai-endpoint "https://xxx.openai.azure.com"
```

### 仅更新 K8s 层（跳过 Terraform 和镜像构建）

```bash
./scripts/install.sh --aoai-key "KEY" --aoai-endpoint "URL" --skip-terraform --skip-images
```

### Helm 升级（修改 values 后）

```bash
helm upgrade openclaw ./charts/openclaw -f values-generated.yaml -n openclaw
```

### 创建新 Agent（Admin Panel）

```bash
kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw
# 打开 http://localhost:3000，填入 Agent ID + Feishu App ID/Secret，点击 Create
# 2 步 SSE 进度：KV 存储凭据 → 创建 K8s 资源（SPC+PVC+Deployment）
```

### 删除 Agent（Admin Panel）

在 Admin Panel 列表中点击「Delete」按钮，自动执行：
1. 删除 Deployment `openclaw-agent-<agentId>`
2. 删除 SecretProviderClass `spc-<agentId>`
3. 删除 PVC `work-disk-<agentId>`
4. 删除 KV 凭据 + NFS 数据

### 凭据轮换

```bash
# 更新 KV 中的飞书凭据后，重启 Pod 使 CSI driver 重新挂载
KV_NAME=$(cd terraform && terraform output -raw keyvault_name)
az keyvault secret set --vault-name "$KV_NAME" --name "feishu-app-id-<agentId>" --value "<new-app-id>"
az keyvault secret set --vault-name "$KV_NAME" --name "feishu-app-secret-<agentId>" --value "<new-app-secret>"
kubectl rollout restart deploy/openclaw-agent-<agentId> -n openclaw
```

### DM Pairing Approve

**方式 1（推荐）：Admin Panel UI**
打开 Admin Panel → Agent 列表 → 点击 Approve 按钮 → 输入 pairing code

**方式 2：CLI**
```bash
kubectl exec deploy/openclaw-agent-<agentId> -c openclaw -n openclaw -- openclaw pairing approve feishu <CODE>
```

### 常用运维命令

```bash
kubectl get deploy -n openclaw -l app=openclaw-sandbox                           # 查看所有 Agent Deployment
kubectl get pods -n openclaw                                                     # 查看所有 Pod
kubectl logs -f deploy/openclaw-agent-<agentId> -c openclaw -n openclaw          # Agent 日志
kubectl logs -f deploy/openclaw-agent-<agentId> -c persist-sync -n openclaw      # Sync 日志
kubectl logs deploy/openclaw-agent-<agentId> -c setup-workspace -n openclaw      # Init 日志
kubectl exec -it deploy/openclaw-agent-<agentId> -c openclaw -n openclaw -- bash # 进入沙箱
kubectl rollout restart deploy/openclaw-agent-<agentId> -n openclaw              # 重启单个 Agent
```

## 9. 飞书接入说明

OpenClaw 使用飞书**长连接模式**（WebSocket Outbound），不需要公网 Inbound 端口。

**接入流程：**
1. 在[飞书开放平台](https://open.feishu.cn)创建企业自建应用
2. 启用「机器人」能力
3. 在「事件与回调」中选择「使用长连接接收事件」模式
4. 获取 App ID 和 App Secret
5. 存入 Key Vault（per-agent 命名：`feishu-app-id-<agentId>`、`feishu-app-secret-<agentId>`）
6. 通过 Admin Panel 或 CLI 创建 agent 时传入凭据

**每个 Agent 对应一个飞书应用**（不同的 bot 身份），实现多 Agent 多 bot 的架构。

## 10. 设计文档参考

| 文档 | 路径 | 内容 |
|------|------|------|
| 详细设计 | `DESIGN.md` | 架构、代码片段、安全模型、成本估算 |
| 基础设施部署计划 | `docs/superpowers/plans/2026-03-13-openclaw-on-aks.md` | 18 个 Task，已完成 |
| Admin Panel Spec | `docs/superpowers/specs/2026-03-13-admin-panel-design.md` | 设计规格 |
| Admin Panel Plan | `docs/superpowers/plans/2026-03-13-admin-panel.md` | 13 Tasks 实现计划 |
| v2 迁移 Spec | `docs/superpowers/specs/2026-03-14-v2-migration-design.md` | StatefulSet → Deployment 迁移设计 |
| DM Pairing Approve Spec | `docs/superpowers/specs/2026-03-14-pairing-approve-design.md` | Approve 按钮设计规格 |
| DM Pairing Approve Plan | `docs/superpowers/plans/2026-03-14-pairing-approve.md` | 3 Tasks 实现计划 |
| Reproducibility Spec | `docs/superpowers/specs/2026-03-14-reproducibility-design.md` | Helm Chart + install.sh 设计 |
| Reproducibility Plan | `docs/superpowers/plans/2026-03-14-reproducibility.md` | 16 Tasks 实现计划 |

## 11. 后续演进（v2）

### 已完成

- [x] **架构重构：共享 StatefulSet → 独立 Deployment per agent** — 每个 agent = Deployment(replicas=1) + PVC `work-disk-<agentId>` + SecretProviderClass `spc-<agentId>`。详见 §2.5 和 §6 阶段 4。
- [x] **Admin Panel: 删除 Agent 功能** — DELETE endpoint 实现：删除 Deployment + SPC + PVC + KV 凭据 + NFS 数据。
- [x] **Admin Panel: DM Pairing Approve 集成** ✅ — Agent 列表行内 Approve 按钮，点击弹出 prompt 输入 pairing code，通过 `POST /api/agents/:id/approve` 调用 `kubectl exec` 在目标 Pod 执行 `openclaw pairing approve feishu <code>`。支持大小写自动转换、非 Running Pod 禁用按钮、行内状态反馈（成功 3s / 错误 5s 自动消失）。Spec: `docs/superpowers/specs/2026-03-14-pairing-approve-design.md`。
- [x] **环境可复制性（Reproducibility）** ✅ — Helm Chart 封装 + install.sh 全流程自动化 + Admin Panel 改造（ConfigMap 模板替代 YAML builders）。Spec: `docs/superpowers/specs/2026-03-14-reproducibility-design.md`。
- [x] **Kata VM 性能优化** ✅ — tmpfs tar prepack + WebSocket 超时补丁(60s/60s/120s) + CLI wrapper + D4s_v3→D4s_v6 硬件升级。`cron list` 从 timeout → 6.1s，bot 内部 CLI 执行正常。详见 §2.8 和 §6 阶段 7。

### 中长期

- [ ] CRD Controller 管理沙箱生命周期
- [x] **启用 APIM AI Gateway** ✅ — api-version query param 注入、Responses API URL rewrite、Authorization header delete、install.sh retry for APIM policy timing
- [ ] APIM 多区域部署
- [ ] 多 Channel（Telegram、Discord）
- [ ] KEDA 基于消息队列的自动扩缩
- [ ] 迁移 Kata workaround 到 `azapi_update_resource`（provider 支持后移除）
- [ ] Key Vault 私网访问优化（install.sh 集群内 KV 写入方案）
- [ ] Helm Chart 发布到 OCI registry（ACR）
- [ ] CI/CD pipeline（GitHub Actions → Helm upgrade）

## 12. 当前集群状态（2026-03-14 最新）

```
Namespace: openclaw

Helm Release:
  openclaw  REVISION 6  STATUS deployed  (charts/openclaw/)

Nodes:
  aks-sandboxv6-*   Standard_D4s_v6  (Granite Rapids, KataVmIsolation)
  aks-system-*      Standard_D2s_v3  (system workloads)

Deployments:
  openclaw-admin            1/1  (system nodepool)  — Admin Panel Web UI + ConfigMap 模板
  openclaw-agent-aks-demo   1/1  (sandboxv6 nodepool, D4s_v6) — 飞书 bot 已连接，可正常对话

ConfigMaps:
  openclaw-agent-template — Agent YAML 模板（SPC+PVC+Deployment），Admin Panel 运行时读取

Agent 镜像优化:
  openclaw-agent:latest — 含 Kata VM 补丁（timeout patches + tar prepack）
  tmpfs 启用 — 主容器启动时解压 579MB 到 in-VM 内存

历史 Agent:
  alice, bob — 用户手动删除，无需重建

已清理的旧资源:
  sandbox nodepool (D4s_v3) — 已删除，替换为 sandboxv6 (D4s_v6)
  StatefulSet openclaw-agent — 已删除
  ConfigMap agent-mapping — 已删除
  旧 VCT PVCs — 已删除
```

## 13. Git 分支与版本状态

```
当前分支:  master (latest commit af6f685)
已合并:    feat/admin-panel (93 commits) — 可手动删除
其他分支:  feat/pingbuddy-implementation — 独立项目，非 clawonaks 相关
```

**关键 commits：**
- `5ea89fd` — Merge feat/admin-panel（阶段 1-5 全部完成）
- `af6f685` — perf(kata): Kata VM 性能优化（tmpfs + timeout patches + D4s_v6）

**所有开发阶段（1-7）已完成并合并到 master。** 项目处于可运维状态。

## 14. 新会话恢复要点

1. 读取本文件获得完整上下文
2. **所有代码在 `master` 分支**，`feat/admin-panel` 已合并
3. 当前唯一活跃 agent 是 `aks-demo`（运行在 D4s_v6 sandboxv6 节点池上）
4. Helm release `openclaw` REVISION 6 已部署
5. Admin Panel 通过 `kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw` 访问
6. KV 私网访问限制：`az keyvault` 写入命令需从集群内 admin pod 执行
7. 新环境部署：`./scripts/install.sh --aoai-key KEY --aoai-endpoint URL`
8. Agent 管理：全部通过 Admin Panel Web UI（创建/删除/Approve）
9. Helm 升级：`helm upgrade openclaw ./charts/openclaw -f values-generated.yaml -n openclaw`
10. **Kata VM 性能优化已就位：** Dockerfile 含三层 timeout sed 补丁 + tar prepack；Helm chart 含 tmpfs emptyDir + wrapper script + PATH env；节点池已升级到 D4s_v6
11. **修改 Dockerfile 后必须重建镜像：** `docker build + push` → `kubectl rollout restart`，等待 2-3 分钟 gateway 完全启动
12. **Bot 内部执行 CLI 需要充裕 timeout：** 60s/60s/120s 的补丁值不建议调小，即使在 D4s_v6 上仍需安全余量
