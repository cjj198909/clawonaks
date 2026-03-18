# OpenClaw on AKS — 设计文档

## 1. 概述

将 OpenClaw AI Agent 部署到 Azure Kubernetes Service (AKS)，参考 [AWS EKS 方案](https://aws.amazon.com/cn/blogs/china/deploying-openclaw-ai-agent-on-amazon-eks/)，适配 Azure 生态。

### 目标
- 每个 Agent 沙箱运行在 VM 级别隔离的 Pod 中（Kata Containers）
- 模型调用统一通过 Azure API Management AI Gateway（VNet 内网部署）
- 存储分层：Azure Disk（工作区）+ Azure Files（持久数据）
- 基础设施代码化（Terraform）
- 飞书 Channel 接入（WebSocket 长连接，零 Inbound 公网端口）
- AKS API Server 公网可达（kubectl / CI-CD 管理）

### 非目标（v1 不做）
- 多租户计费
- Confidential Containers（已 sunset）

---

## 2. 架构总览

```
              ┌═══════════════════════════════════════════╗
              ║              VNet (10.0.0.0/16)           ║
              ║                                           ║
              ║  ┌────────────────────────────────────┐   ║
              ║  │  AKS Cluster (10.0.0.0/22)         │   ║
              ║  │  API Server: 公网（kubectl 管理）    │   ║
              ║  │                                    │   ║
              ║  │  System Pool    Sandbox Pool        │   ║
              ║  │  (D2s_v3×1)    (D4s_v3, Kata)      │   ║
              ║  │  Container      ┌─────────────┐    │   ║
              ║  │  Insights       │ Agent Pod 1 │    │   ║
              ║  │                 │ (Kata VM)   │────┼───╫──→ 飞书 WS (wss://open.feishu.cn)
              ║  │                 └─────────────┘    │   ║     Outbound 长连接
              ║  │                 ┌─────────────┐    │   ║
              ║  │                 │ Agent Pod 2 │    │   ║
              ║  │                 │ (Kata VM)   │────┼───╫──→ 飞书 WS
              ║  │                 └─────────────┘    │   ║
              ║  └───────────┬────────────────────────┘   ║
              ║              │ 内网                         ║
              ║  ┌───────────▼────────────────────────┐   ║
              ║  │  APIM Subnet (10.0.8.0/24)         │   ║
              ║  │  Azure APIM AI Gateway             │   ║
              ║  │  (StandardV2, VNet 注入)            │   ║
              ║  │  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄   │   ║
              ║  │  • Managed Identity → AI Foundry   │   ║
              ║  │  • Token 限流 / 语义缓存 / 审计    │   ║
              ║  │  • 内网 IP 仅限 AKS 子网访问       │   ║
              ║  └────────────────────────────────────┘   ║
              ║              │ Private Endpoint             ║
              ║  ┌───────────▼────────────────────────┐   ║
              ║  │  Private Endpoints Subnet           │   ║
              ║  │  (10.0.12.0/24)                    │   ║
              ║  │  • Azure AI Foundry (GPT-5.x)      │   ║
              ║  │  • Azure Files (持久数据)           │   ║
              ║  │  • Key Vault (凭据)                 │   ║
              ║  └────────────────────────────────────┘   ║
              ╚═══════════════════════════════════════════╝

  无 Ingress / 无公网 Inbound
  飞书接入：Pod 主动 Outbound WebSocket 连接飞书服务器
  集群管理：AKS API Server 公网可达（kubectl / CI-CD）
```

### 网络设计

| 子网 | CIDR | 用途 |
|---|---|---|
| `aks-subnet` | 10.0.0.0/22 | AKS 节点和 Pod |
| `apim-subnet` | 10.0.8.0/24 | APIM VNet 注入（需要 /24 以上） |
| `pe-subnet` | 10.0.12.0/24 | Private Endpoints (AI Foundry, Files, KV) |

**关键原则：**
- **零 Inbound 公网入口** — 无 Ingress、无 LoadBalancer Service、无公网 IP
- **飞书接入走 Outbound WebSocket** — Pod 主动拨出到 `wss://open.feishu.cn`，NAT 出站
- **AI 模型调用全部走内网** — APIM → Private Endpoint → AI Foundry
- **AKS API Server 公网可达** — 用于 kubectl 管理和 CI/CD 流水线

---

## 3. 组件详细设计

### 3.1 VNet + 子网

```hcl
# terraform/network.tf

resource "azurerm_virtual_network" "main" {
  name                = "openclaw-vnet"
  location            = var.location
  resource_group_name = var.resource_group
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/22"]
}

resource "azurerm_subnet" "apim" {
  name                 = "apim-subnet"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.8.0/24"]

  delegation {
    name = "apim-delegation"
    service_delegation {
      name = "Microsoft.ApiManagement/service"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "pe-subnet"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.12.0/24"]
}

# NSG: APIM 子网只允许 AKS 子网访问
resource "azurerm_network_security_group" "apim" {
  name                = "apim-nsg"
  location            = var.location
  resource_group_name = var.resource_group

  security_rule {
    name                       = "allow-aks-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "10.0.0.0/22"    # AKS 子网
    destination_address_prefix = "10.0.8.0/24"
  }

  security_rule {
    name                       = "allow-apim-management"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}
```

### 3.2 AKS 集群

```hcl
# terraform/aks.tf

resource "azurerm_kubernetes_cluster" "openclaw" {
  name                = "openclaw-aks"
  location            = var.location
  resource_group_name = var.resource_group
  dns_prefix          = "openclaw"
  kubernetes_version  = "1.30"

  default_node_pool {
    name                = "system"
    vm_size             = "Standard_D2s_v3"   # 2核8G，够跑系统组件
    node_count          = 1
    os_sku              = "AzureLinux"
    vnet_subnet_id      = azurerm_subnet.aks.id
    temporary_name_for_rotation = "systemtmp"
  }

  identity {
    type = "SystemAssigned"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  network_profile {
    network_plugin      = "azure"
    service_cidr        = "10.1.0.0/16"
    dns_service_ip      = "10.1.0.10"
  }

  # Azure Monitor Container Insights（替代自建 Prometheus）
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.openclaw.id
  }
}
```

### 3.3 Sandbox Node Pool（Pod Sandboxing + 自动缩放）

```hcl
# terraform/nodepool.tf

resource "azurerm_kubernetes_cluster_node_pool" "sandbox" {
  name                  = "sandbox"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.openclaw.id
  vm_size               = "Standard_D4s_v3"
  os_sku                = "AzureLinux"
  workload_runtime      = "KataVmIsolation"
  vnet_subnet_id        = azurerm_subnet.aks.id

  # 自动缩放：空闲时缩到 0
  enable_auto_scaling   = true
  min_count             = 0
  max_count             = 3

  node_labels = {
    "openclaw.io/role" = "sandbox"
  }

  node_taints = [
    "openclaw.io/sandbox=true:NoSchedule"
  ]
}
```

### 3.4 存储设计

#### 3.4.1 Azure Disk（工作区 — per-Pod）

```yaml
# k8s/storage/disk-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openclaw-disk
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

#### 3.4.2 Azure Files（持久数据 — 通过 Private Endpoint）

```yaml
# k8s/storage/files-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openclaw-files
provisioner: file.csi.azure.com
parameters:
  skuName: Premium_LRS
  protocol: nfs
  # 通过 Private Endpoint 访问，不走公网
  networkEndpointType: privateEndpoint
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nconnect=4
```

#### 3.4.3 挂载映射

| Azure Files 路径 | 容器挂载点 | 内容 |
|---|---|---|
| `/{agent-id}/config/openclaw.json` | `/home/node/.openclaw/openclaw.json` | Agent 配置 |
| `/{agent-id}/config/auth-profiles.json` | `/home/node/.openclaw/auth-profiles.json` | 模型认证 |
| `/{agent-id}/workspace/MEMORY.md` | `/home/node/.openclaw/workspace/MEMORY.md` | 长期记忆 |
| `/{agent-id}/workspace/SOUL.md` | `/home/node/.openclaw/workspace/SOUL.md` | 身份文件 |
| `/{agent-id}/workspace/USER.md` | `/home/node/.openclaw/workspace/USER.md` | 用户信息 |
| `/{agent-id}/workspace/AGENTS.md` | `/home/node/.openclaw/workspace/AGENTS.md` | 行为规则 |
| `/{agent-id}/workspace/TOOLS.md` | `/home/node/.openclaw/workspace/TOOLS.md` | 工具笔记 |
| `/{agent-id}/workspace/IDENTITY.md` | `/home/node/.openclaw/workspace/IDENTITY.md` | 身份定义 |
| `/{agent-id}/workspace/memory/` | `/home/node/.openclaw/workspace/memory/` | 每日记忆 |
| `/{agent-id}/devices/` | `/home/node/.openclaw/devices/` | 配对设备 |
| `/{agent-id}/sessions/` | `/home/node/.openclaw/sessions/` | 会话历史 |

| Azure Disk 路径 | 容器挂载点 | 内容 |
|---|---|---|
| `/workspace/` | `/home/node/.openclaw/workspace/` (其余文件) | Skills, node_modules 等 |
| `/tmp/` | `/tmp` | 临时文件 |

### 3.5 Azure APIM AI Gateway（VNet 内网部署）

APIM 通过 VNet 注入部署到内网，仅 AKS 子网可访问。通过 Managed Identity 连接 AI Foundry（也走 Private Endpoint）。

#### 3.5.1 APIM 资源

```hcl
# terraform/apim.tf

resource "azurerm_api_management" "openclaw" {
  name                = "openclaw-apim"
  location            = var.location
  resource_group_name = var.resource_group
  publisher_name      = "OpenClaw"
  publisher_email     = var.admin_email
  sku_name            = "StandardV2_1"    # VNet 集成需要 StandardV2

  identity {
    type = "SystemAssigned"
  }

  # VNet 注入 — 内部模式（无公网 IP）
  virtual_network_type = "Internal"

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }
}

# Private DNS Zone for APIM internal access
resource "azurerm_private_dns_zone" "apim" {
  name                = "azure-api.net"
  resource_group_name = var.resource_group
}

resource "azurerm_private_dns_a_record" "apim" {
  name                = "openclaw-apim"
  zone_name           = azurerm_private_dns_zone.apim.name
  resource_group_name = var.resource_group
  ttl                 = 300
  records             = [azurerm_api_management.openclaw.private_ip_addresses[0]]
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  name                  = "apim-vnet-link"
  resource_group_name   = var.resource_group
  private_dns_zone_name = azurerm_private_dns_zone.apim.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

# APIM Managed Identity → Azure AI Foundry
resource "azurerm_role_assignment" "apim_ai_user" {
  scope                = azurerm_cognitive_account.ai_foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.openclaw.identity[0].principal_id
}
```

#### 3.5.2 AI Foundry Private Endpoint

```hcl
# terraform/private-endpoints.tf

# AI Foundry — 只能通过 VNet 内网访问
resource "azurerm_private_endpoint" "ai_foundry" {
  name                = "pe-ai-foundry"
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "ai-foundry-connection"
    private_connection_resource_id = azurerm_cognitive_account.ai_foundry.id
    is_manual_connection           = false
    subresource_names              = ["account"]
  }

  private_dns_zone_group {
    name                 = "ai-foundry-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.cognitive.id]
  }
}

# Azure Files — Private Endpoint
resource "azurerm_private_endpoint" "storage_files" {
  name                = "pe-storage-files"
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "files-connection"
    private_connection_resource_id = azurerm_storage_account.openclaw.id
    is_manual_connection           = false
    subresource_names              = ["file"]
  }

  private_dns_zone_group {
    name                 = "files-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_file.id]
  }
}

# Key Vault — Private Endpoint
resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-keyvault"
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "kv-connection"
    private_connection_resource_id = azurerm_key_vault.openclaw.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.keyvault.id]
  }
}

# Private DNS Zones
resource "azurerm_private_dns_zone" "cognitive" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = var.resource_group
}

resource "azurerm_private_dns_zone" "storage_file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = var.resource_group
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group
}

# Link all DNS zones to VNet
resource "azurerm_private_dns_zone_virtual_network_link" "cognitive" {
  name                  = "cognitive-vnet-link"
  resource_group_name   = var.resource_group
  private_dns_zone_name = azurerm_private_dns_zone.cognitive.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file" {
  name                  = "storage-file-vnet-link"
  resource_group_name   = var.resource_group
  private_dns_zone_name = azurerm_private_dns_zone.storage_file.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "keyvault-vnet-link"
  resource_group_name   = var.resource_group
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.main.id
}
```

#### 3.5.3 APIM Policy 配置

```xml
<!-- policies/ai-gateway.xml -->
<!-- 认证 + 限流 + 语义缓存 -->
<policies>
  <inbound>
    <!-- Managed Identity 认证到 Azure AI Foundry -->
    <authentication-managed-identity
      resource="https://cognitiveservices.azure.com"
      output-token-variable-name="ai-token" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["ai-token"])</value>
    </set-header>

    <!-- Token 限流：每个 Agent 60K TPM（GPT-5 单轮约 5K-20K tokens） -->
    <llm-token-limit
      counter-key="@(context.Subscription.Id)"
      tokens-per-minute="60000"
      estimate-prompt-tokens="true"
      remaining-tokens-variable-name="remainingTokens" />

    <!-- Token 消耗指标 -->
    <llm-emit-token-metric namespace="AzureOpenAI">
      <dimension name="Subscription" value="@(context.Subscription.Id)" />
      <dimension name="Model" value="@(context.Request.Headers.GetValueOrDefault("model","unknown"))" />
    </llm-emit-token-metric>

    <!-- 后端路由 -->
    <set-backend-service backend-id="ai-foundry-pool" />
  </inbound>

  <outbound>
    <base />
  </outbound>
</policies>
```

#### 3.5.4 Per-Agent Subscription

```hcl
# terraform/apim-subscriptions.tf

resource "azurerm_api_management_subscription" "agent" {
  for_each = var.agent_ids

  resource_group_name = var.resource_group
  api_management_name = azurerm_api_management.openclaw.name
  display_name        = "openclaw-agent-${each.value}"
  api_id              = azurerm_api_management_api.openai.id
  state               = "active"
}
```

#### 3.5.5 OpenClaw Agent 配置

```json
{
  "models": {
    "providers": {
      "azure-apim": {
        "baseUrl": "https://openclaw-apim.azure-api.net/openai/v1",
        "apiKey": "<apim-subscription-key>",
        "api": "openai-responses",
        "headers": {
          "Ocp-Apim-Subscription-Key": "<apim-subscription-key>",
          "api-version": "2025-04-01-preview"
        },
        "authHeader": false,
        "models": [
          {
            "id": "gpt-5.4",
            "name": "GPT-5.4 (via APIM)",
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 16384
          },
          {
            "id": "gpt-5.2",
            "name": "GPT-5.2 (via APIM)",
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 16384
          }
        ]
      }
    }
  }
}
```

### 3.6 预构建容器镜像

避免每次 Pod 启动都 `npm install`，预构建镜像推到 ACR。

```hcl
# terraform/acr.tf

resource "azurerm_container_registry" "openclaw" {
  name                = "openclawacr"
  resource_group_name = var.resource_group
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
}

# AKS → ACR 拉取权限
resource "azurerm_role_assignment" "aks_acr" {
  scope                = azurerm_container_registry.openclaw.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.openclaw.kubelet_identity[0].object_id
}
```

```dockerfile
# docker/Dockerfile
FROM node:22-slim

# 安装 OpenClaw + 常用工具
RUN npm install -g openclaw@latest && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      git python3 curl ca-certificates imagemagick && \
    rm -rf /var/lib/apt/lists/*

# 非 root 用户
USER 1000
WORKDIR /home/node/.openclaw/workspace

ENTRYPOINT ["openclaw", "gateway", "run"]
```

```bash
# 构建 & 推送
az acr build --registry openclawacr --image openclaw-sandbox:latest docker/
```

### 3.7 Agent 沙箱 StatefulSet

用 StatefulSet 替代裸 Pod，获得自愈能力和滚动更新。

```yaml
# k8s/sandbox/agent-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openclaw-agent
  namespace: openclaw
spec:
  serviceName: openclaw
  replicas: 1                    # 按需调整 Agent 数量
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: openclaw-sandbox
  template:
    metadata:
      labels:
        app: openclaw-sandbox
    spec:
      runtimeClassName: kata-vm-isolation
      serviceAccountName: openclaw-sandbox

      nodeSelector:
        openclaw.io/role: sandbox
      tolerations:
      - key: "openclaw.io/sandbox"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"

      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000

      # Init: 解析 agent-id 并从 Azure Files 恢复持久数据
      #
      # Agent ID 映射机制：
      #   ConfigMap "agent-mapping" 存储 ordinal→agent-id 映射
      #   Pod hostname (e.g. openclaw-agent-0) → 提取 ordinal 0 → 查 ConfigMap
      #   Azure Files 路径: /{agent-id}/config/, /{agent-id}/workspace/ ...
      initContainers:
      - name: setup-workspace
        image: busybox:1.36
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          OPENCLAW_DIR=/home/node/.openclaw
          PERSIST=/persist

          # 从 Pod hostname 提取 ordinal（openclaw-agent-0 → 0）
          ORDINAL=$(hostname | rev | cut -d'-' -f1 | rev)
          # 从 ConfigMap 映射文件读取 agent-id
          AGENT_ID=$(cat /config/agent-mapping/agent-${ORDINAL} 2>/dev/null)

          if [ -z "$AGENT_ID" ]; then
            echo "ERROR: No agent-id mapping for ordinal $ORDINAL"
            echo "Please add 'agent-${ORDINAL}: <agent-id>' to ConfigMap agent-mapping"
            exit 1
          fi

          echo "Pod ordinal=$ORDINAL → agent-id=$AGENT_ID"
          # 写入 agent-id 供主容器和 sidecar 读取
          echo "$AGENT_ID" > $OPENCLAW_DIR/.agent-id

          # 按 agent-id 隔离持久路径
          AGENT_PERSIST="$PERSIST/$AGENT_ID"
          mkdir -p $OPENCLAW_DIR/workspace/memory $OPENCLAW_DIR/devices $OPENCLAW_DIR/sessions
          mkdir -p $AGENT_PERSIST/config $AGENT_PERSIST/workspace/memory $AGENT_PERSIST/devices $AGENT_PERSIST/sessions

          for f in openclaw.json auth-profiles.json; do
            [ -f "$AGENT_PERSIST/config/$f" ] && cp "$AGENT_PERSIST/config/$f" "$OPENCLAW_DIR/$f"
          done

          for f in MEMORY.md SOUL.md USER.md AGENTS.md TOOLS.md IDENTITY.md HEARTBEAT.md; do
            [ -f "$AGENT_PERSIST/workspace/$f" ] && cp "$AGENT_PERSIST/workspace/$f" "$OPENCLAW_DIR/workspace/$f"
          done

          cp -r $AGENT_PERSIST/workspace/memory/* $OPENCLAW_DIR/workspace/memory/ 2>/dev/null || true
          cp -r $AGENT_PERSIST/devices/* $OPENCLAW_DIR/devices/ 2>/dev/null || true
          cp -r $AGENT_PERSIST/sessions/* $OPENCLAW_DIR/sessions/ 2>/dev/null || true

          echo "Workspace setup complete for agent=$AGENT_ID"
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
        - name: persist-files
          mountPath: /persist
        - name: agent-mapping
          mountPath: /config/agent-mapping
          readOnly: true

      containers:
      # 主容器：OpenClaw Gateway
      - name: openclaw
        image: openclawacr.azurecr.io/openclaw-sandbox:latest
        ports:
        - containerPort: 3000
          name: webhook
        env:
        - name: OPENCLAW_HOME
          value: /home/node/.openclaw
        # Pod name 通过 Downward API 注入
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 2000m
            memory: 2Gi

      # Native Sidecar: 持久数据同步（K8s 1.29+）
      # 改进：原子写入（cp→tmp 再 mv）+ inotifywait 事件驱动 + SIGTERM 兜底
      initContainers:
      - name: persist-sync
        restartPolicy: Always       # ← Native Sidecar
        image: openclawacr.azurecr.io/persist-sync:latest  # 基于 alpine + inotify-tools
        command: ["/bin/sh", "-c"]
        args:
        - |
          OPENCLAW_DIR=/home/node/.openclaw

          # 等待 initContainer 写入 agent-id
          while [ ! -f "$OPENCLAW_DIR/.agent-id" ]; do sleep 1; done
          AGENT_ID=$(cat "$OPENCLAW_DIR/.agent-id")
          PERSIST="/persist/$AGENT_ID"
          echo "[persist-sync] Agent ID: $AGENT_ID, persist path: $PERSIST"

          # 原子拷贝：先写 .tmp 再 mv，避免读到写了一半的文件
          atomic_cp() {
            src="$1"; dst="$2"
            tmp="${dst}.tmp.$$"
            cp "$src" "$tmp" && mv "$tmp" "$dst"
          }

          sync_files() {
            for f in openclaw.json auth-profiles.json; do
              [ -f "$OPENCLAW_DIR/$f" ] && atomic_cp "$OPENCLAW_DIR/$f" "$PERSIST/config/$f"
            done

            for f in MEMORY.md SOUL.md USER.md AGENTS.md TOOLS.md IDENTITY.md HEARTBEAT.md; do
              [ -f "$OPENCLAW_DIR/workspace/$f" ] && atomic_cp "$OPENCLAW_DIR/workspace/$f" "$PERSIST/workspace/$f"
            done

            mkdir -p $PERSIST/workspace/memory $PERSIST/devices $PERSIST/sessions
            cp -r $OPENCLAW_DIR/workspace/memory/* $PERSIST/workspace/memory/ 2>/dev/null || true
            cp -r $OPENCLAW_DIR/devices/* $PERSIST/devices/ 2>/dev/null || true
            cp -r $OPENCLAW_DIR/sessions/* $PERSIST/sessions/ 2>/dev/null || true
          }

          # SIGTERM 处理：Pod 终止前执行最终同步
          graceful_shutdown() {
            echo "[persist-sync] SIGTERM received, final sync..."
            sync_files
            echo "[persist-sync] Final sync done, exiting."
            exit 0
          }
          trap graceful_shutdown TERM INT

          # 初始同步一次
          sync_files

          # 事件驱动：监听关键文件变化，去抖 5 秒后同步
          inotifywait -m -r \
            -e close_write,moved_to \
            --exclude '\.(tmp|swp)' \
            "$OPENCLAW_DIR" 2>/dev/null | \
          while read -r _dir _event _file; do
            # 去抖：收到事件后等 5 秒，合并密集写入
            sleep 5
            sync_files
          done &

          # 兜底：每 120 秒全量同步一次（防止 inotifywait 漏事件）
          while true; do
            sleep 120
            sync_files
          done
        volumeMounts:
        - name: work-disk
          mountPath: /home/node/.openclaw
          readOnly: true
        - name: persist-files
          mountPath: /persist
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi

      volumes:
      - name: persist-files
        persistentVolumeClaim:
          claimName: openclaw-files   # 共享 PVC
      - name: agent-mapping
        configMap:
          name: agent-mapping         # ordinal→agent-id 映射

  # Azure Disk — StatefulSet 自动创建 per-Pod PVC
  volumeClaimTemplates:
  - metadata:
      name: work-disk
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: openclaw-disk
      resources:
        requests:
          storage: 5Gi

---
# Azure Files PVC（所有 Agent 共享）
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-files
  namespace: openclaw
spec:
  accessModes: [ReadWriteMany]
  storageClassName: openclaw-files
  resources:
    requests:
      storage: 5Gi

---
# Agent ID 映射：Pod ordinal → agent-id
# 扩容时先更新此 ConfigMap，再 scale replicas
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-mapping
  namespace: openclaw
data:
  agent-0: "alice"        # openclaw-agent-0 → alice
  agent-1: "bob"          # openclaw-agent-1 → bob
  agent-2: "charlie"      # openclaw-agent-2 → charlie
```

#### 创建新 Agent 的流程

```bash
# scripts/create-agent.sh
#!/bin/bash
set -euo pipefail

AGENT_ID="$1"
NAMESPACE="${2:-openclaw}"

# 1. 获取当前 replicas 数
CURRENT=$(kubectl get sts openclaw-agent -n $NAMESPACE -o jsonpath='{.spec.replicas}')
NEW_ORDINAL=$CURRENT
NEW_REPLICAS=$((CURRENT + 1))

echo "=== Creating agent '$AGENT_ID' at ordinal $NEW_ORDINAL ==="

# 2. 更新 ConfigMap：添加 ordinal→agent-id 映射
kubectl patch configmap agent-mapping -n $NAMESPACE \
  --type merge -p "{\"data\":{\"agent-${NEW_ORDINAL}\": \"${AGENT_ID}\"}}"

# 3. 在 Azure Files 初始化 agent 目录结构
# （通过一个临时 Pod 或 az storage file 命令）
echo "Initializing persistent storage for agent '$AGENT_ID'..."

# 4. 在 APIM 创建 per-agent subscription（通过 Terraform 或 az CLI）
echo "TODO: Create APIM subscription for agent '$AGENT_ID'"

# 5. 扩容 StatefulSet
kubectl scale sts openclaw-agent -n $NAMESPACE --replicas=$NEW_REPLICAS

echo "=== Agent '$AGENT_ID' created as openclaw-agent-${NEW_ORDINAL} ==="
echo "Monitor: kubectl logs -f openclaw-agent-${NEW_ORDINAL} -c openclaw -n $NAMESPACE"
```

### 3.8 安全设计

#### 3.8.1 Pod 安全

```yaml
# k8s/security/pod-security.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openclaw
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

#### 3.8.2 凭据管理

| 凭据 | 存储方式 | 说明 |
|---|---|---|
| 模型 API Key | **不暴露** — APIM Managed Identity | 仅 APIM 内部持有 |
| APIM Subscription Key | Key Vault → CSI Secret Store | 低权限，受 TPM 限额约束 |
| 飞书 App ID/Secret | Key Vault → CSI Secret Store | WebSocket 认证用 |
| ACR 拉取 | AKS Managed Identity | AcrPull RBAC |

```hcl
# terraform/keyvault.tf
resource "azurerm_key_vault" "openclaw" {
  name                = "openclaw-kv"
  location            = var.location
  resource_group_name = var.resource_group
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization = true

  # 关闭公网访问
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}
```

### 3.9 可观测性

用 Azure 原生监控栈，不自建 Prometheus。

```hcl
# terraform/monitoring.tf

resource "azurerm_log_analytics_workspace" "openclaw" {
  name                = "openclaw-logs"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "openclaw" {
  name                = "openclaw-insights"
  location            = var.location
  resource_group_name = var.resource_group
  workspace_id        = azurerm_log_analytics_workspace.openclaw.id
  application_type    = "web"
}

# APIM → App Insights
resource "azurerm_api_management_logger" "insights" {
  name                = "app-insights-logger"
  api_management_name = azurerm_api_management.openclaw.name
  resource_group_name = var.resource_group

  application_insights {
    instrumentation_key = azurerm_application_insights.openclaw.instrumentation_key
  }
}
```

监控分工：
| 层 | 工具 | 指标 |
|---|---|---|
| 模型调用 | APIM + App Insights | Token 消耗、延迟、错误率、限流触发 |
| 集群/Pod | Container Insights | CPU、Memory、Disk、重启、网络 |
| 日志 | Log Analytics | Agent 日志、APIM 日志、审计日志 |

---

## 4. 部署流程

### 4.1 目录结构

```
openclaw-on-aks/
├── terraform/
│   ├── main.tf              # Provider, backend
│   ├── variables.tf         # 输入变量
│   ├── network.tf           # VNet + 子网 + NSG
│   ├── aks.tf               # AKS 集群
│   ├── nodepool.tf          # Sandbox 节点池
│   ├── apim.tf              # APIM AI Gateway (VNet 内部)
│   ├── apim-api.tf          # AI API 导入
│   ├── apim-subscriptions.tf # Per-Agent Subscription
│   ├── private-endpoints.tf # PE: AI Foundry, Files, Key Vault
│   ├── acr.tf               # Container Registry
│   ├── keyvault.tf          # Key Vault
│   ├── storage.tf           # Storage Account
│   ├── identity.tf          # Managed Identity + Workload Identity
│   ├── monitoring.tf        # App Insights + Log Analytics
│   └── outputs.tf           # 输出值
├── docker/
│   └── Dockerfile           # 预构建 OpenClaw 镜像
├── k8s/
│   ├── namespaces.yaml
│   ├── storage/
│   │   ├── disk-storageclass.yaml
│   │   └── files-storageclass.yaml
│   ├── sandbox/
│   │   ├── agent-statefulset.yaml
│   │   └── feishu-secret-provider.yaml
│   └── security/
│       ├── pod-security.yaml
│       └── netpol-sandbox.yaml          # NetworkPolicy (可选)
├── policies/
│   └── ai-gateway.xml       # APIM AI Gateway policy
├── scripts/
│   ├── install.sh           # 一键部署
│   ├── build-image.sh       # 构建 OpenClaw 镜像
│   ├── create-agent.sh      # 创建新 Agent
│   └── destroy.sh           # 清理
├── DESIGN.md                # 本文档
└── README.md
```

### 4.2 一键部署脚本

```bash
# scripts/install.sh
#!/bin/bash
set -euo pipefail

REGION="${1:-eastasia}"
CLUSTER_NAME="${2:-openclaw-aks}"
RG="${3:-openclaw-rg}"

echo "=== Step 1: Terraform - 基础设施 ==="
echo "  - VNet + 子网 + NSG"
echo "  - AKS 集群 + Sandbox 节点池"
echo "  - APIM AI Gateway (VNet 内部)"
echo "  - Private Endpoints (AI Foundry, Files, KV)"
echo "  - ACR, Key Vault, Storage, Monitoring"
cd terraform
terraform init
terraform apply \
  -var="location=$REGION" \
  -var="cluster_name=$CLUSTER_NAME" \
  -var="resource_group=$RG" \
  -auto-approve

echo "=== Step 2: 构建 OpenClaw 镜像 ==="
ACR_NAME=$(terraform output -raw acr_name)
az acr build --registry $ACR_NAME --image openclaw-sandbox:latest ../docker/

echo "=== Step 3: 获取 kubeconfig ==="
az aks get-credentials --resource-group $RG --name $CLUSTER_NAME --overwrite-existing

echo "=== Step 4: 部署 K8s 资源 ==="
kubectl apply -f ../k8s/namespaces.yaml
kubectl apply -f ../k8s/storage/
kubectl apply -f ../k8s/security/

echo "=== Step 5: 部署 Agent StatefulSet ==="
kubectl apply -f ../k8s/sandbox/

echo "=== 完成 ==="
echo ""
echo "APIM Internal URL: $(terraform output -raw apim_private_url)"
echo "AKS: $(terraform output -raw aks_fqdn)"
echo ""
echo "运行 scripts/create-agent.sh <agent-id> 配置新 Agent"
```

---

## 5. 飞书接入（WebSocket 长连接）

飞书开放平台支持 **长连接模式**（WebSocket），应用主动与飞书建立 `wss://` 连接，无需暴露公网 Inbound 端口。

### 连接模型

```
Agent Pod (AKS VNet)
    │
    │  Outbound WSS (443)
    │  通过 Azure Load Balancer SNAT
    │
    ▼
wss://open.feishu.cn/open-apis/...
飞书长连接网关
```

- **无需 Ingress / 公网 IP / TLS 证书** — Pod 主动拨出
- **断线自动重连** — OpenClaw 飞书 Channel 内置重连逻辑
- **NAT 友好** — WebSocket 是标准 HTTPS 升级，通过 Azure LB 的 outbound SNAT 即可

### 飞书 App 配置

在飞书开放平台创建企业自建应用：

1. **启用长连接模式**：开发配置 → 事件订阅 → 选择「使用长连接接收事件」
2. **所需权限**：`im:message`（接收消息）、`im:message:send`（发送消息）
3. **获取凭据**：App ID + App Secret → 存入 Key Vault

### Agent 配置

```json
{
  "channels": {
    "feishu": {
      "enabled": true,
      "mode": "websocket",
      "appId": "<from-keyvault>",
      "appSecret": "<from-keyvault>"
    }
  }
}
```

### 凭据注入（Key Vault → CSI Secret Store → 环境变量）

```yaml
# k8s/sandbox/feishu-secret-provider.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: feishu-secrets
  namespace: openclaw
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: "<workload-identity-client-id>"
    keyvaultName: "openclaw-kv"
    tenantId: "<tenant-id>"
    objects: |
      array:
        - |
          objectName: feishu-app-id
          objectType: secret
        - |
          objectName: feishu-app-secret
          objectType: secret
  secretObjects:
  - secretName: feishu-credentials
    type: Opaque
    data:
    - objectName: feishu-app-id
      key: FEISHU_APP_ID
    - objectName: feishu-app-secret
      key: FEISHU_APP_SECRET
```

在 StatefulSet 主容器中引用：

```yaml
# 追加到 openclaw 容器的 env 部分
env:
- name: FEISHU_APP_ID
  valueFrom:
    secretKeyRef:
      name: feishu-credentials
      key: FEISHU_APP_ID
- name: FEISHU_APP_SECRET
  valueFrom:
    secretKeyRef:
      name: feishu-credentials
      key: FEISHU_APP_SECRET
# 追加 volume 和 volumeMount
volumes:
- name: feishu-secrets
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: feishu-secrets
```

### NetworkPolicy（可选，最小权限出站）

```yaml
# k8s/security/netpol-sandbox.yaml
# 限制 sandbox Pod 的出站目标
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sandbox-egress
  namespace: openclaw
spec:
  podSelector:
    matchLabels:
      app: openclaw-sandbox
  policyTypes: [Egress]
  egress:
  # 飞书 WebSocket（Outbound HTTPS）
  - to: []            # 任意外部 IP（飞书 CDN IP 不固定）
    ports:
    - protocol: TCP
      port: 443
  # APIM 内网
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

---

## 6. 运维操作

| 操作 | 命令 |
|---|---|
| 查看所有沙箱 | `kubectl get pods -n openclaw` |
| 查看 Agent 日志 | `kubectl logs -f openclaw-agent-0 -c openclaw -n openclaw` |
| 进入 Agent 沙箱 | `kubectl exec -it openclaw-agent-0 -c openclaw -n openclaw -- bash` |
| 扩容 Agent 数量 | `kubectl scale sts openclaw-agent -n openclaw --replicas=3` |
| 升级 OpenClaw 镜像 | `az acr build ...` 然后 `kubectl rollout restart sts openclaw-agent -n openclaw` |
| 查看 APIM 指标 | Azure Portal → APIM → Analytics |
| 查看 Pod 指标 | Azure Portal → AKS → Insights |
| 查看日志 | Azure Portal → Log Analytics → Logs |
| 全部清理 | `scripts/destroy.sh` |

---

## 7. 成本估算

| 资源 | 规格 | 月成本 (东亚区) |
|---|---|---|
| AKS System 节点 | Standard_D2s_v3 × 1 | ~$70 |
| AKS Sandbox 节点 | Standard_D4s_v3 × 0-3（自动缩放） | $0-420 |
| Azure APIM | StandardV2（VNet 集成） | ~$175 |
| ACR | Basic | ~$5 |
| Azure Disk | Premium SSD 5Gi / Agent | ~$1 |
| Azure Files | Premium NFS 5Gi 共享 | ~$0.8 |
| Key Vault | 标准版 | ~$0.1 |
| Log Analytics | 前 5GB/月免费 | ~$0 |
| Private Endpoints | 3 个 × ~$7.3 | ~$22 |
| **空闲时最低** | sandbox 缩到 0 | **~$273/月** |
| **1 个 Agent 运行** | 1 sandbox 节点 | **~$413/月** |
| **满载 3 Agent** | 3 sandbox 节点 | **~$693/月** |

---

## 8. 安全总结

```
外部攻击面：
  零 Inbound 公网端口 — 无 Ingress / 无 LoadBalancer Service / 无公网 IP
  飞书接入 → Pod Outbound WebSocket，不暴露任何监听端口
  AKS API Server → 公网可达（kubectl 管理），可通过 authorized IP ranges 收紧

内部隔离：
  Agent Pod → Kata VM 内核隔离
  APIM → VNet 内部，NSG 限制仅 AKS 子网
  AI Foundry → Private Endpoint，无公网
  Key Vault → Private Endpoint，无公网
  Azure Files → Private Endpoint，无公网
  模型 Key → APIM Managed Identity，集群零凭据
  飞书凭据 → Key Vault → CSI Secret Store，不硬编码
  NetworkPolicy（可选）→ 限制 Pod 出站仅 443 + APIM + DNS

审计：
  APIM → App Insights（模型调用全量记录）
  AKS → Container Insights（Pod 行为记录）
  Key Vault → Diagnostic Logs（凭据访问记录）
```

---

## 9. 后续演进（v2）

- [ ] Helm Chart 封装，`helm install openclaw-agent --set agentId=xxx`
- [ ] CRD Controller 管理沙箱生命周期
- [ ] APIM 语义缓存（需要 Azure Managed Redis）
- [ ] APIM 多区域部署 + Traffic Manager 全局负载均衡
- [ ] 多 Channel（Telegram、Discord）
- [ ] KEDA 基于消息队列的沙箱自动扩缩
- [ ] APIM Developer Portal 内部自助申请
