# APIM AI Gateway 设计 Spec

> **日期：** 2026-03-15
> **状态：** Draft
> **依赖：** 阶段 1-7 已完成的基础设施

## 1. 动机

在多租户 openclaw 环境中，每个 Agent Pod（Kata VM）内的 `/mnt/secrets/azure-openai-key` 存储明文 Azure OpenAI API Key。用户可以通过 AI Agent 的 `exec` tool 执行 `cat /mnt/secrets/azure-openai-key` 获取该密钥。一旦泄露，攻击者可在任意位置直接调用 Azure OpenAI endpoint，无法追踪来源、无法限速、无法撤销单个 agent 的访问权限。

通过启用 APIM AI Gateway（Internal VNet 模式），Pod 内不再存储 Azure OpenAI key，只持有 APIM subscription key。该 key 仅在 VNet 内有效，即使泄露到外部也无法使用。

## 2. 安全模型

### 2.1 现状（直连模式）

```
Agent Pod (Kata VM)
  └─ /mnt/secrets/azure-openai-key    ← 明文 API Key
  └─ config.json: baseUrl = "https://xxx.openai.azure.com"
  └─ 用户让 bot 执行 cat → 泄露 key + endpoint → 任意地方可调用
```

### 2.2 目标（APIM 模式）

```
Agent Pod (Kata VM)
  └─ /mnt/secrets/apim-subscription-key  ← APIM subscription key
  └─ config.json: baseUrl = "https://openclaw-apim.azure-api.net/openai"
  └─ 泄露 subscription key → APIM Internal VNet，外部不可达
  └─ VNet 内滥用 → Rate Limit 60K TPM + App Insights 审计
```

### 2.3 安全保证链

1. Azure OpenAI key 只存在于 APIM Named Value（Key Vault 引用）→ Pod 内无 key
2. APIM subscription key 只在 VNet 内有效（Internal mode + NSG）
3. 即使 subscription key 泄露到外部 → 无法连到 APIM（无公网 IP）
4. 即使从 VNet 内滥用 → 60K TPM rate limit + App Insights 审计追踪到具体 agent

### 2.4 请求流

```
Agent Pod ──443──► APIM (Internal VNet, 10.0.8.0/24)
                    │
                    ├─ 验证 Ocp-Apim-Subscription-Key
                    ├─ Token Rate Limit (60K TPM per subscription)
                    ├─ Emit Token Metrics → App Insights
                    │
                    ├─[API Key 模式]──► set-header api-key = Named Value (KV ref)
                    │                   └──► Azure OpenAI (外部 endpoint)
                    │
                    └─[MI 模式]───────► authentication-managed-identity
                                        └──► Azure OpenAI (同 tenant, RBAC)
```

### 2.5 NSG 规则（已有，无需改动）

| 方向 | 端口 | 源 | 目标 | 效果 |
|------|------|-----|------|------|
| Inbound Allow | 443 | 10.0.0.0/22 (AKS) | 10.0.8.0/24 (APIM) | Pod 可访问 APIM |
| Inbound Allow | 3443 | ApiManagement | VirtualNetwork | APIM 管理面 |
| Inbound Deny | * | * | * | 其他流量全拒 |

**Outbound 假设：** APIM subnet 使用 Azure VNet 默认 outbound 规则（允许出站互联网）。API Key 模式下 APIM 需要访问外部 Azure OpenAI endpoint（公网）。如果将来添加 Azure Firewall 或限制性 outbound NSG，需要显式放行 APIM → Azure OpenAI 的出站流量。

## 3. v1 功能范围

### 包含

- Token Rate Limiting（per-agent 60K TPM）
- Token Metrics（App Insights，per-subscription + per-model 维度）
- Circuit Breaker（429/503 自动熔断，tripDuration 1 分钟，acceptRetryAfter）
- Backend Pool 扩展点（v1 单 endpoint，结构预留多 endpoint）
- 双 auth 模式可切换（API Key / Managed Identity，Terraform 变量控制）

### 不包含（留 v2）

- Semantic Caching（需 Redis Enterprise + embeddings 模型，成本高）
- APIM 多区域部署
- APIM Developer Portal
- 多租户计费

## 4. Terraform 资源改造

### 4.1 变量变化

**修改：**
- `enable_apim`：保持，控制 APIM 实例创建。解耦与 `enable_ai_foundry` 的关系。
- `enable_ai_foundry`：保持，独立控制自管 Cognitive Account。

**新增：**
- `apim_backend_auth_mode`（string，default `"api_key"`）：`"api_key"` 或 `"managed_identity"`。
- `aoai_endpoint`（string，default `""`）：外部 Azure OpenAI endpoint URL，API Key 模式必填。
- `aoai_resource_id`（string，default `""`）：外部 Azure OpenAI 资源 ID，MI 模式下用于 RBAC role assignment。

**删除职责：**
- `agent_ids` 不再用于 APIM subscription 创建（改由 Admin Panel 动态管理）。变量本身保留，以防其他用途。

### 4.2 资源改造清单

| 文件 | 改动类型 | 说明 |
|------|----------|------|
| `apim.tf` | 改造 | 条件从多处 `enable_apim && enable_ai_foundry` 简化为 `enable_apim`。APIM 实例、DNS Zone、A Record、VNet Link、Logger 保持不变。 |
| `apim-api.tf` | 重写 | 条件改为仅 `enable_apim`。`service_url` 根据 auth mode 选择 AI Foundry endpoint 或 `var.aoai_endpoint`。 |
| `apim-subscriptions.tf` | 清空 | 静态 subscription 创建逻辑移除。文件保留，加注释说明 subscription 由 Admin Panel 动态管理。 |
| `apim-backend.tf` | 新增 | `azapi_resource` 创建 Backend entity + Backend Pool + Circuit Breaker（详见 §4.3）。 |
| `apim-named-values.tf` | 新增 | API Key 模式：Named Value 引用 KV 中 `azure-openai-key`。MI 模式：不创建。**注意：** APIM 读取 KV-backed Named Value 需要 APIM MI 拥有 KV 的 `Key Vault Secrets User` 角色（详见 §4.5）。 |
| `policies/ai-gateway.xml` | 重写 | 改为 `policies/ai-gateway.xml.tftpl` 模板文件，Terraform `templatefile()` 渲染 auth 段。 |
| `identity.tf` | 扩展 | 详见 §4.5 完整 RBAC 清单。 |
| `outputs.tf` | 扩展 | 新增 `apim_gateway_url`（Admin Panel config 用）和 `apim_api_id`（Admin Panel subscription scope 用，**输出完整 ARM resource ID**）。 |
| `versions.tf` | 扩展 | 新增 `azapi` provider 依赖。 |

### 4.3 Backend Pool（azapi_resource 详细设计）

需要两个 `azapi_resource`：一个 Backend entity，一个 Backend Pool。

**Backend entity（单个后端）：**
- 类型：`Microsoft.ApiManagement/service/backends@2024-06-01-preview`
- 名称：`openai-backend-1`
- `url`：`var.aoai_endpoint`（API Key 模式）或 AI Foundry PE endpoint（MI 模式）
- `protocol`：`"http"`（APIM backend protocol，不是传输层）
- `credentials`（API Key 模式）：`header: { "api-key": ["{{azure-openai-key}}"] }` — 引用 Named Value
- `credentials`（MI 模式）：`authorization: { scheme: "managed-identity", parameter: "https://cognitiveservices.azure.com" }`
- `circuitBreaker.rules[0]`：
  - `failureCondition`：`statusCodeRanges: [{min:429, max:429}, {min:500, max:503}]`，`count: 3`，`interval: "PT1M"`
  - `tripDuration`：`"PT1M"`
  - `acceptRetryAfter`：`true`

> **注意：** `count: 3` 而非 `1`。单次 429 在 token rate limit 场景很常见（瞬时突发），`count: 3` 更适合生产环境。

**Backend Pool：**
- 类型：`Microsoft.ApiManagement/service/backends@2024-06-01-preview`
- 名称：`openai-backend-pool`
- `type`：`"Pool"`
- `pool.services[0]`：`{ id: "/backends/openai-backend-1", priority: 1, weight: 1 }`

v1 Pool 内仅一个 Backend。将来加 endpoint 只需新增 Backend entity + 注册到 Pool 的 `services` 数组。

**Policy 中引用：** `<set-backend-service backend-id="openai-backend-pool" />` — 引用 Pool 名称，APIM 自动选择 Pool 内的 Backend。

### 4.4 Policy 模板化

将 `policies/ai-gateway.xml` 改为 `policies/ai-gateway.xml.tftpl`，通过 Terraform `templatefile()` 在 apply 时渲染。

**API Key 模式渲染结果：**
```xml
<set-header name="api-key" exists-action="override">
  <value>{{azure-openai-key}}</value>
</set-header>
```

**MI 模式渲染结果：**
```xml
<authentication-managed-identity resource="https://cognitiveservices.azure.com"
    output-token-variable-name="ai-token" />
<set-header name="Authorization" exists-action="override">
  <value>@("Bearer " + (string)context.Variables["ai-token"])</value>
</set-header>
```

两段互斥，由 `var.apim_backend_auth_mode` 决定。

**通用段（两种模式都包含）：**
```xml
<llm-token-limit counter-key="@(context.Subscription.Id)"
    tokens-per-minute="60000"
    estimate-prompt-tokens="true"
    remaining-tokens-variable-name="remainingTokens" />

<llm-emit-token-metric namespace="AzureOpenAI">
  <dimension name="Subscription" value="@(context.Subscription.Id)" />
  <dimension name="Model"
    value="@(context.Request.Headers.GetValueOrDefault("model","unknown"))" />
</llm-emit-token-metric>

<set-backend-service backend-id="openai-backend-pool" />
```

### 4.5 RBAC 完整清单（identity.tf）

| 角色 | 主体 | 作用域 | 条件 | 用途 |
|------|------|--------|------|------|
| `Key Vault Secrets User` | APIM System MI | KV 实例 | `enable_apim && apim_backend_auth_mode == "api_key"` | APIM 读取 KV-backed Named Value（`azure-openai-key`） |
| `Cognitive Services OpenAI User` | APIM System MI | Azure OpenAI 资源 | `enable_apim && apim_backend_auth_mode == "managed_identity"` | APIM MI 认证到 Azure OpenAI |
| `API Management Service Contributor` | Admin MI | APIM 实例 | `enable_apim` | Admin Panel 动态 CRUD subscription |

现有角色（不变）：
- Sandbox MI → KV Secrets User（KV 实例）
- Admin MI → KV Secrets Officer（KV 实例）
- AKS kubelet MI → AcrPull（ACR）

### 4.6 Outputs 精确定义

```hcl
output "apim_gateway_url" {
  description = "APIM gateway base URL for agent config"
  value       = var.enable_apim ? "https://${azurerm_api_management.openclaw[0].name}.azure-api.net" : ""
}

output "apim_api_id" {
  description = "Full ARM resource ID of the Azure OpenAI API in APIM (for subscription scope)"
  value       = var.enable_apim ? azurerm_api_management_api.openai[0].id : ""
  # 输出格式: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{name}/apis/azure-openai
}
```

`apim_api_id` 是完整 ARM resource ID，Admin Panel 的 `az apim subscription create --scope` 直接使用此值。Helm values 中 `apim.apiId` 存储此完整路径。

### 4.7 enable_apim 默认值说明

`variables.tf` 中 `enable_apim` 默认值为 `true`。实际通过 `terraform.tfvars` 覆盖为 `false`。启用 APIM 时将 tfvars 改为 `true`。此默认值保持不变，与现有行为一致。

## 5. Admin Panel 改造

### 5.1 创建 Agent 流程（3 步 SSE）

启用 APIM 后，创建流程从 2 步变为 3 步：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | KV 存储飞书凭据 | 现有逻辑，无变化 |
| 2（新增） | 创建 APIM subscription → key 存入 KV | `az apim subscription create` + `az keyvault secret set` |
| 3 | 创建 K8s 资源（SPC + PVC + Deployment） | 现有逻辑，SPC 引用 APIM subscription key 而非 Azure OpenAI key |

`APIM_ENABLED !== "true"` 时跳过 Step 2，保持原有 2 步流程。

SSE `total` 步数动态设置：`const total = APIM_ENABLED ? 3 : 2`。

### 5.2 APIM Subscription 管理

**创建：**
```bash
az apim subscription create \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --subscription-id "openclaw-agent-<agentId>" \
  --display-name "openclaw-agent-<agentId>" \
  --scope "$APIM_API_ID" \
  --query primaryKey -o tsv
```

> **关键：** 必须显式指定 `--subscription-id`（APIM 内部 SID），设为 `openclaw-agent-<agentId>`。否则 APIM 自动生成随机 SID，删除时无法定位。

返回的 `primaryKey` 存入 KV：`apim-sub-key-<agentId>`。

**删除：**
```bash
az apim subscription delete \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --subscription-id "openclaw-agent-<agentId>"
```

同时删除 KV 中的 `apim-sub-key-<agentId>`。

**超时说明：** `az apim subscription create/delete` 通常在 5-10 秒内完成。Admin Panel 现有 `execFileAsync` 超时 60 秒足够。

### 5.3 Admin MI 权限扩展

| 角色 | 作用域 | 条件 | 用途 |
|------|--------|------|------|
| Key Vault Secrets Officer | KV 实例 | 已有 | 飞书凭据 + APIM sub key 管理 |
| API Management Service Contributor | APIM 实例 | `enable_apim` | subscription CRUD |

Terraform `identity.tf` 新增：
```hcl
resource "azurerm_role_assignment" "admin_apim_contributor" {
  count                = var.enable_apim ? 1 : 0
  scope                = azurerm_api_management.openclaw[0].id
  role_definition_name = "API Management Service Contributor"
  principal_id         = azurerm_user_assigned_identity.admin.principal_id
}
```

### 5.4 APIM 感知环境变量

通过 Helm values 注入 Admin Deployment：

| 环境变量 | 值来源 | 用途 |
|---------|--------|------|
| `APIM_ENABLED` | `apim.enabled` | 控制是否执行 APIM 步骤 |
| `APIM_NAME` | `apim.name` | `az apim subscription` 命令 |
| `APIM_RG` | `apim.resourceGroup` | 同上 |
| `APIM_API_ID` | `apim.apiId` | subscription scope |

### 5.5 删除 Agent 流程

完整删除顺序（APIM 启用时）：
1. 删除 Deployment `openclaw-agent-<agentId>`（已有）
2. 删除 SecretProviderClass `spc-<agentId>`（已有）
3. 删除 PVC `work-disk-<agentId>`（已有）
4. 删除 APIM subscription `openclaw-agent-<agentId>`（**新增**）
5. 删除 KV 中飞书凭据 + `apim-sub-key-<agentId>`（**扩展**）
6. 删除 NFS 数据（已有）

> **顺序约束：** Deployment 必须先删（它引用 SPC 和 KV secret）。APIM subscription 和 KV secret 在 Deployment 删除后再清理。

条件执行：步骤 4 和 `apim-sub-key` 的删除仅在 `APIM_ENABLED === "true"` 时。

## 6. Helm Chart 改造

### 6.1 新增 Values

```yaml
apim:
  enabled: false
  gatewayUrl: ""                # "https://openclaw-apim.azure-api.net"
  apiPath: "openai"
  name: ""                      # APIM 实例名
  resourceGroup: ""             # 资源组
  apiId: ""                     # 完整 ARM resource ID:
                                # /subscriptions/{sub}/resourceGroups/{rg}/providers/
                                # Microsoft.ApiManagement/service/{name}/apis/azure-openai
  model:
    id: "gpt-5.4"
    name: "GPT-5.4 (via APIM)"
```

> `apiId` 存储完整 ARM resource ID（从 Terraform output `apim_api_id` 获取），Admin Panel 直接用于 `az apim subscription create --scope`。

### 6.2 Agent Template ConfigMap（agent-template-cm.yaml）

三处改动：

**A. SecretProviderClass — 条件引用 APIM sub key 或 Azure OpenAI key：**

APIM 模式下挂载 `apim-sub-key-__AGENT_ID__`，直连模式下挂载 `azure-openai-key`。互斥。

**B. Init container — config 构建逻辑分支：**

通过文件是否存在判断模式（KV CSI 挂载是确定性的）：
- `/mnt/secrets/apim-subscription-key` 存在 → APIM 模式 config
- `/mnt/secrets/azure-openai-key` 存在 → 直连模式 config（现有逻辑）

**APIM 模式 config.json 完整结构：**
```json
{
  "gateway": { "mode": "local" },
  "channels": {
    "feishu": {
      "enabled": true,
      "appId": "<from-kv-csi>",
      "appSecret": "<from-kv-csi>"
    }
  },
  "models": {
    "providers": {
      "azure-apim": {
        "baseUrl": "https://openclaw-apim.azure-api.net/openai",
        "apiKey": "<APIM-subscription-key>",
        "api": "openai-responses",
        "headers": {
          "Ocp-Apim-Subscription-Key": "<APIM-subscription-key>",
          "api-version": "2025-04-01-preview"
        },
        "models": [
          {
            "id": "gpt-5.4",
            "name": "GPT-5.4 (via APIM)"
          }
        ]
      }
    }
  }
}
```

> **关键字段说明：**
> - `baseUrl` 包含 `/openai` 路径（APIM API path）
> - `api` 仍为 `"openai-responses"`（openclaw 的 API 协议标识）
> - `apiKey` 是 APIM subscription key（不是 Azure OpenAI key）
> - `Ocp-Apim-Subscription-Key` header 是 APIM 标准认证头
> - 不含 `isDefault` 等 openclaw 不认识的字段（会触发 `validateConfigObjectWithPlugins()` 校验失败）

**C. Deployment env — 无变化。**

### 6.3 Admin Deployment（admin-deployment.yaml）

条件注入 APIM 环境变量：

```yaml
{{- if .Values.apim.enabled }}
- name: APIM_ENABLED
  value: "true"
- name: APIM_NAME
  value: {{ .Values.apim.name | quote }}
- name: APIM_RG
  value: {{ .Values.apim.resourceGroup | quote }}
- name: APIM_API_ID
  value: {{ .Values.apim.apiId | quote }}
{{- end }}
```

### 6.4 install.sh 自动生成 APIM values

从 Terraform outputs 读取 APIM 相关输出，写入临时 values 文件：

```bash
if [ "$ENABLE_APIM" = "true" ]; then
  APIM_NAME=$(cd "$TF_DIR" && terraform output -raw apim_name)
  APIM_URL=$(cd "$TF_DIR" && terraform output -raw apim_private_url)
  # 追加到临时 values 文件
fi
```

## 7. install.sh 集成

### 7.1 新增参数

| 参数 | 说明 | 默认 |
|------|------|------|
| `--enable-apim` | 启用 APIM | 无（默认不启用） |
| `--apim-auth-mode` | `api_key` 或 `managed_identity` | `api_key` |

### 7.2 APIM 部署时间

StandardV2 Internal VNet 部署约 30-45 分钟。发生在 Step 1（Terraform Apply）中。`azurerm_api_management` resource 的 provider 自身会阻塞等待 provisioning 完成（默认 timeout 1h），无需自定义轮询逻辑。install.sh 输出提示信息即可。后续 `--skip-terraform` 跳过。

### 7.3 DNS 解析验证

Helm 安装后验证 AKS Pod 可解析 APIM DNS：

```bash
kubectl run dns-test --rm -it --image=busybox --restart=Never -- \
  nslookup openclaw-apim.azure-api.net
```

### 7.4 terraform.tfvars 示例

```hcl
enable_apim            = true
apim_backend_auth_mode = "api_key"
aoai_endpoint          = "https://xxx.openai.azure.com"
enable_ai_foundry      = false
```

## 8. 迁移策略与向后兼容

### 8.1 迁移路径

启用 APIM 是非破坏性变更：

1. `terraform apply`（`enable_apim=true`）→ APIM 就绪（约 40 分钟）
2. `helm upgrade`（`apim.enabled=true`）→ Agent Template 更新为 APIM 模式
3. 现有 agent（如 `aks-demo`）不受影响 — 已创建的 SPC/Deployment 不会自动变化
4. 新 agent 通过 Admin Panel 创建时自动使用 APIM 模式
5. 迁移现有 agent：Admin Panel 删除 → 重新创建

### 8.2 向后兼容保证

| 场景 | 行为 |
|------|------|
| `apim.enabled=false`（默认） | 完全保持现有行为，零影响 |
| `apim.enabled=true` + 已有 agent | 已有 agent 不变，新 agent 走 APIM |
| `enable_apim=false` in Terraform | APIM 资源不创建 |
| Admin Panel `APIM_ENABLED` 未设置 | 默认 false，走原有 2 步流程 |

### 8.3 回滚方案

1. Helm：`apim.enabled=false` → `helm upgrade` → 新 agent 回到直连模式
2. 已有 APIM 模式 agent：删除重建
3. APIM 实例可保留不删（不产生额外请求费用，仅基础月费）

## 9. 验证清单

| 验证项 | 方法 |
|------|------|
| APIM 部署成功 | `az apim show` 确认 provisioning state |
| DNS 解析 | 从 AKS Pod `nslookup openclaw-apim.azure-api.net` |
| API 可达 | `curl -H "Ocp-Apim-Subscription-Key: xxx" https://openclaw-apim.azure-api.net/openai/models` |
| Agent 创建（APIM 模式） | Admin Panel 创建 → 3 步 SSE 成功 |
| 飞书对话 E2E | 发消息 → bot 回复（通过 APIM → Azure OpenAI） |
| Rate Limit 生效 | App Insights 查看 token metrics per subscription |
| Circuit Breaker | 模拟 429 → APIM 返回 503 + Retry-After |
| 直连模式不受影响 | `apim.enabled=false` 时现有 agent 正常运行 |
| 现有 agent 不受影响 | `aks-demo` 在 APIM 启用后保持运行（直连模式） |

## 10. 参考资料

- [Azure-Samples/AI-Gateway](https://github.com/Azure-Samples/AI-Gateway)：APIM AI Gateway 策略模板、Backend Pool + Circuit Breaker 的 azapi Terraform 模式
- 现有 APIM Terraform 代码：`terraform/apim.tf`、`apim-api.tf`、`apim-subscriptions.tf`
- 现有 APIM Policy：`policies/ai-gateway.xml`
- APIM StandardV2 Internal VNet：已有网络配置（subnet + NSG + DNS Zone）
