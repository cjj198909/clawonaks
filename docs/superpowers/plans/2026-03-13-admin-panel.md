# Admin Panel Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a lightweight admin web UI for creating OpenClaw agents in AKS, replacing the manual `create-agent.sh` workflow.

**Architecture:** Node.js Express server running as a Deployment on AKS system nodepool. Single HTML page with Server-Sent Events for real-time creation progress. The server shells out to `kubectl` and `az` CLI to orchestrate agent creation across Key Vault, NFS storage, ConfigMap, and StatefulSet. Workload Identity provides passwordless Azure Key Vault access.

**Tech Stack:** Node.js 22, Express, kubectl, az CLI, SSE

**Spec:** `docs/superpowers/specs/2026-03-13-admin-panel-design.md`

---

## Spec Errata (addressed in this plan)

The design spec had several issues found during review. This plan incorporates all fixes:

| Issue | Spec Says | Correct |
|-------|-----------|---------|
| NFS path | `/shared/agents/<agentId>/config.json` | `/shared/agents/<agentId>/config.json` — matches deployed init container (`AGENT_PERSIST="$PERSIST/agents/$AGENT_ID"` reads `$AGENT_PERSIST/config.json`) |
| PVC name | `openclaw-shared-data` | `openclaw-shared-data` ✅ (matches actual cluster) |
| Admin SA auth | "use VM identity or sandbox MI" | Dedicated `openclaw-admin-identity` MI with `Key Vault Secrets Officer` |
| ConfigMap RBAC | get, list, patch | get, list, create, patch, delete — needs create/delete for temp ConfigMaps |
| APIM | Not mentioned | APIM disabled (`enable_apim=false`). Config uses direct Azure OpenAI endpoint |
| Per-agent Feishu | KV only | KV + `feishu.env` on NFS. StatefulSet updated to source per-agent credentials |
| Config filename | `openclaw.json` | `config.json` — deployed init container reads `$AGENT_PERSIST/config.json` (Git YAML differs from deployed state) |
| Git vs deployed | N/A | Git YAML diverged from deployed StatefulSet. Plan targets **deployed** state. Git YAML should be reconciled separately. |

## File Structure

```
admin/                              # NEW directory (all new files)
├── Dockerfile                      # Node.js 22-slim + kubectl + az CLI
├── package.json                    # express dependency only
├── server.js                       # Express server: 3 routes + creation flow
├── index.html                      # Single-page UI: form + progress + agent list
└── k8s/
    ├── rbac.yaml                   # ServiceAccount + Role + RoleBinding (placeholders)
    └── deployment.yaml             # Deployment + Service (placeholders)

terraform/
├── identity.tf                     # MODIFY: add admin MI + federated credential + KV role
└── outputs.tf                      # MODIFY: add admin_identity_client_id output

k8s/sandbox/
└── agent-statefulset.yaml          # MODIFY: per-agent Feishu env support in init + main containers
```

---

## Chunk 1: Terraform — Admin Identity

### Task 1: Add admin Managed Identity to Terraform

**Files:**
- Modify: `terraform/identity.tf` (append 3 resources after existing content)
- Modify: `terraform/outputs.tf` (append 1 output)

- [ ] **Step 1: Add admin MI + federated credential + KV role to identity.tf**

Append to end of `terraform/identity.tf`:

```hcl
# Admin Panel: User-Assigned MI for Key Vault write access
resource "azurerm_user_assigned_identity" "admin" {
  name                = "openclaw-admin-identity"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "admin" {
  name                = "openclaw-admin-fedcred"
  resource_group_name = data.azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.admin.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.openclaw.oidc_issuer_url
  subject             = "system:serviceaccount:openclaw:openclaw-admin"
}

# Admin Panel -> Key Vault Secrets Officer (read + write secrets)
resource "azurerm_role_assignment" "admin_kv_officer" {
  scope                = azurerm_key_vault.openclaw.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.admin.principal_id
}
```

- [ ] **Step 2: Add admin_identity_client_id to outputs.tf**

Append to end of `terraform/outputs.tf`:

```hcl
output "admin_identity_client_id" {
  value = azurerm_user_assigned_identity.admin.client_id
}
```

- [ ] **Step 3: Validate Terraform**

Run: `cd /home/vmadmin/clawonaks/terraform && terraform validate`
Expected: Success

- [ ] **Step 4: Apply Terraform changes**

Run: `cd /home/vmadmin/clawonaks/terraform && terraform apply -auto-approve`
Expected: 3 resources added (MI, federated credential, role assignment), 1 output added.
Save the output: `terraform output -raw admin_identity_client_id` — needed for K8s manifests.

- [ ] **Step 5: Commit**

```bash
git add terraform/identity.tf terraform/outputs.tf
git commit -m "feat(terraform): add admin panel Managed Identity with KV Secrets Officer role"
```

---

## Chunk 2: Admin Application Code

### Task 2: Create package.json

**Files:**
- Create: `admin/package.json`

- [ ] **Step 1: Create admin directory and package.json**

```json
{
  "name": "openclaw-admin",
  "version": "1.0.0",
  "private": true,
  "description": "OpenClaw Admin Panel — create agents via web UI",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.21.0"
  }
}
```

### Task 3: Create server.js

**Files:**
- Create: `admin/server.js`

The server has 3 routes and a 5-step agent creation flow. Key design decisions:
- Uses `child_process.execFile` for kubectl commands (no shell injection)
- Uses `child_process.spawn` for piping Job YAML to `kubectl apply -f -`
- Runs `az login` on startup using Workload Identity injected credentials
- SSE for streaming creation progress to the browser

- [ ] **Step 1: Create server.js**

```javascript
const express = require('express');
const path = require('path');
const { execFile, spawn } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);
const app = express();
app.use(express.json());

const NAMESPACE = process.env.NAMESPACE || 'openclaw';
const KV_NAME = process.env.KV_NAME || '';
const AZURE_OPENAI_ENDPOINT = process.env.AZURE_OPENAI_ENDPOINT || '';
const AZURE_OPENAI_KEY = process.env.AZURE_OPENAI_KEY || '';

// Mutex to prevent concurrent agent creation (ordinal race condition)
let creating = false;

// --- Helpers ---

async function kubectl(...args) {
  const { stdout } = await execFileAsync('kubectl', args, { timeout: 30000 });
  return stdout.trim();
}

async function az(...args) {
  const { stdout } = await execFileAsync('az', args, { timeout: 60000 });
  return stdout.trim();
}

/** Pipe string content to `kubectl apply -f -` */
function kubectlApplyStdin(yaml) {
  return new Promise((resolve, reject) => {
    const proc = spawn('kubectl', ['apply', '-f', '-'], { timeout: 30000 });
    let stdout = '', stderr = '';
    proc.stdout.on('data', d => (stdout += d));
    proc.stderr.on('data', d => (stderr += d));
    proc.on('close', code =>
      code === 0 ? resolve(stdout.trim()) : reject(new Error(stderr.trim() || `exit ${code}`))
    );
    proc.stdin.write(yaml);
    proc.stdin.end();
  });
}

function validateAgentId(id) {
  if (!id || typeof id !== 'string') return 'Agent ID is required';
  if (id.length > 20) return 'Agent ID must be 1-20 characters';
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(id))
    return 'Agent ID: lowercase alphanumeric + hyphens, no leading/trailing hyphens';
  return null;
}

function buildConfigJson() {
  return JSON.stringify({
    models: {
      providers: {
        'azure-openai': {
          baseUrl: AZURE_OPENAI_ENDPOINT,
          apiKey: AZURE_OPENAI_KEY,
          api: 'openai-responses',
          headers: { 'api-version': '2025-04-01-preview' },
          models: [{
            id: 'gpt-5',
            name: 'GPT-5 (Azure OpenAI)',
            reasoning: true,
            input: ['text', 'image'],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 200000,
            maxTokens: 16384,
          }],
        },
      },
    },
  }, null, 2);
}

function buildFeishuEnv(appId, appSecret) {
  // Single-quote values to prevent shell metacharacter injection
  const safeId = appId.replace(/'/g, "'\\''");
  const safeSecret = appSecret.replace(/'/g, "'\\''");
  return `export FEISHU_APP_ID='${safeId}'\nexport FEISHU_APP_SECRET='${safeSecret}'\n`;
}

function buildUploadJobYaml(agentId) {
  // NFS directory structure matches deployed init container:
  // AGENT_PERSIST="$PERSIST/agents/$AGENT_ID" → reads $AGENT_PERSIST/config.json
  // Upload Job mounts same PVC at /shared, so path is /shared/agents/<agentId>/
  return `apiVersion: batch/v1
kind: Job
metadata:
  name: upload-config-${agentId}
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: uploader
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          mkdir -p /shared/agents/${agentId}
          cp /config/config.json /shared/agents/${agentId}/config.json
          cp /config/feishu.env /shared/agents/${agentId}/feishu.env
          echo "Upload complete for ${agentId}"
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          seccompProfile:
            type: RuntimeDefault
        volumeMounts:
        - name: shared-data
          mountPath: /shared
        - name: config
          mountPath: /config
      volumes:
      - name: shared-data
        persistentVolumeClaim:
          claimName: openclaw-shared-data
      - name: config
        configMap:
          name: agent-config-${agentId}
`;
}

// --- Routes ---

app.get('/', (_req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

app.get('/api/agents', async (_req, res) => {
  try {
    const mappingRaw = await kubectl(
      'get', 'configmap', 'agent-mapping', '-n', NAMESPACE, '-o', 'json'
    );
    const mapping = JSON.parse(mappingRaw);
    const data = mapping.data || {};

    const podsRaw = await kubectl(
      'get', 'pods', '-n', NAMESPACE, '-l', 'app=openclaw-sandbox', '-o', 'json'
    );
    const pods = JSON.parse(podsRaw);

    const agents = Object.entries(data)
      .map(([key, agentId]) => {
        const ordinal = parseInt(key.replace('agent-', ''), 10);
        const pod = pods.items?.find(p => p.metadata.name === `openclaw-agent-${ordinal}`);
        const ready = pod?.status?.containerStatuses?.filter(c => c.ready).length || 0;
        const total = pod?.spec?.containers?.length || 0;
        return {
          agentId,
          ordinal,
          podStatus: pod?.status?.phase || 'Not Found',
          podReady: `${ready}/${total}`,
        };
      })
      .sort((a, b) => a.ordinal - b.ordinal);

    res.json(agents);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/agents', async (req, res) => {
  const { agentId, feishuAppId, feishuAppSecret } = req.body || {};

  // --- Validation ---
  const idErr = validateAgentId(agentId);
  if (idErr) return res.status(400).json({ error: idErr });
  if (!feishuAppId) return res.status(400).json({ error: 'Feishu App ID is required' });
  if (!feishuAppSecret) return res.status(400).json({ error: 'Feishu App Secret is required' });

  // Concurrency guard
  if (creating) return res.status(429).json({ error: 'Another agent is being created. Please wait.' });

  // Check duplicate
  try {
    const raw = await kubectl('get', 'configmap', 'agent-mapping', '-n', NAMESPACE, '-o', 'json');
    if (Object.values(JSON.parse(raw).data || {}).includes(agentId)) {
      return res.status(409).json({ error: `Agent '${agentId}' already exists` });
    }
  } catch (err) {
    return res.status(500).json({ error: `Pre-check failed: ${err.message}` });
  }

  creating = true;

  // --- SSE stream ---
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  const send = (step, status, msg, extra = {}) => {
    res.write(`data: ${JSON.stringify({ step, total: 5, status, msg, ...extra })}\n\n`);
  };

  try {
    // Step 1: Store Feishu credentials in Key Vault
    send(1, 'running', 'Storing Feishu credentials in Key Vault...');
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
      '--name', `feishu-app-id-${agentId}`, '--value', feishuAppId);
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
      '--name', `feishu-app-secret-${agentId}`, '--value', feishuAppSecret);
    send(1, 'done', 'Feishu credentials stored');

    // Step 2: Generate config + create temp ConfigMap
    send(2, 'running', 'Generating agent config...');
    const configJson = buildConfigJson();
    const feishuEnv = buildFeishuEnv(feishuAppId, feishuAppSecret);
    await kubectl('create', 'configmap', `agent-config-${agentId}`, '-n', NAMESPACE,
      `--from-literal=config.json=${configJson}`,
      `--from-literal=feishu.env=${feishuEnv}`);
    send(2, 'done', 'Agent config generated');

    // Step 3: Upload config to NFS via Job
    send(3, 'running', 'Uploading config to shared storage...');
    const jobYaml = buildUploadJobYaml(agentId);
    await kubectlApplyStdin(jobYaml);
    await kubectl('wait', '--for=condition=complete',
      `job/upload-config-${agentId}`, '-n', NAMESPACE, '--timeout=120s');
    // Cleanup temp resources
    await kubectl('delete', 'configmap', `agent-config-${agentId}`, '-n', NAMESPACE).catch(() => {});
    await kubectl('delete', 'job', `upload-config-${agentId}`, '-n', NAMESPACE).catch(() => {});
    send(3, 'done', 'Config uploaded to shared storage');

    // Step 4: Update ConfigMap agent-mapping
    send(4, 'running', 'Updating agent mapping...');
    const replicasStr = await kubectl(
      'get', 'sts', 'openclaw-agent', '-n', NAMESPACE,
      '-o', 'jsonpath={.spec.replicas}'
    );
    const currentReplicas = parseInt(replicasStr, 10);
    if (isNaN(currentReplicas)) throw new Error('Could not determine current replica count');
    const newOrdinal = currentReplicas;
    await kubectl('patch', 'configmap', 'agent-mapping', '-n', NAMESPACE,
      '--type', 'merge', '-p',
      JSON.stringify({ data: { [`agent-${newOrdinal}`]: agentId } }));
    send(4, 'done', `Agent mapping updated (ordinal ${newOrdinal})`);

    // Step 5: Scale StatefulSet
    send(5, 'running', 'Scaling StatefulSet...');
    const newReplicas = currentReplicas + 1;
    await kubectl('scale', 'sts', 'openclaw-agent', '-n', NAMESPACE,
      `--replicas=${newReplicas}`);
    send(5, 'done', `Agent ${agentId} created successfully`, { done: true });
  } catch (err) {
    send(0, 'error', `Creation failed: ${err.message}`);
  } finally {
    creating = false;
  }

  res.end();
});

// --- Startup ---

async function azLogin() {
  if (!process.env.AZURE_FEDERATED_TOKEN_FILE) {
    console.warn('AZURE_FEDERATED_TOKEN_FILE not set — skipping az login (dev mode)');
    return false;
  }
  try {
    const token = require('fs').readFileSync(
      process.env.AZURE_FEDERATED_TOKEN_FILE, 'utf8'
    ).trim();
    await az('login', '--service-principal',
      '-u', process.env.AZURE_CLIENT_ID,
      '-t', process.env.AZURE_TENANT_ID,
      '--federated-token', token);
    console.log('Azure login successful (Workload Identity)');
    return true;
  } catch (err) {
    console.error('Azure login failed:', err.message);
    return false;
  }
}

async function main() {
  await azLogin();

  // Refresh az login every 45 minutes (federated tokens expire after ~1 hour)
  setInterval(() => {
    azLogin().catch(err => console.error('Token refresh failed:', err.message));
  }, 45 * 60 * 1000);

  app.listen(3000, () => {
    console.log('OpenClaw Admin Panel running on http://localhost:3000');
  });
}

main();
```

### Task 4: Create index.html

**Files:**
- Create: `admin/index.html`

- [ ] **Step 1: Create index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OpenClaw Admin</title>
  <style>
    :root {
      --bg: #0d1117; --surface: #161b22; --border: #30363d;
      --text: #e6edf3; --text-dim: #8b949e; --accent: #58a6ff;
      --green: #3fb950; --red: #f85149; --yellow: #d29922;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: var(--bg); color: var(--text); padding: 2rem; max-width: 800px; margin: 0 auto;
    }
    h1 { margin-bottom: 0.5rem; font-size: 1.5rem; }
    .subtitle { color: var(--text-dim); margin-bottom: 2rem; }
    .card {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem;
    }
    h2 { font-size: 1.1rem; margin-bottom: 1rem; }
    .form-group { margin-bottom: 1rem; }
    label { display: block; margin-bottom: 0.3rem; color: var(--text-dim); font-size: 0.85rem; }
    input {
      width: 100%; padding: 0.6rem 0.8rem; background: var(--bg); border: 1px solid var(--border);
      border-radius: 6px; color: var(--text); font-size: 0.9rem;
    }
    input:focus { outline: none; border-color: var(--accent); }
    input:disabled { opacity: 0.5; }
    button {
      background: var(--accent); color: #fff; border: none; border-radius: 6px;
      padding: 0.6rem 1.5rem; font-size: 0.9rem; cursor: pointer; font-weight: 600;
    }
    button:hover { opacity: 0.9; }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
    .progress { display: none; margin-top: 1rem; }
    .progress.visible { display: block; }
    .step {
      display: flex; align-items: center; gap: 0.6rem; padding: 0.4rem 0;
      color: var(--text-dim); font-size: 0.9rem;
    }
    .step.running { color: var(--yellow); }
    .step.done { color: var(--green); }
    .step.error { color: var(--red); }
    .step-icon { width: 1.2rem; text-align: center; }
    .error-msg {
      background: rgba(248, 81, 73, 0.1); border: 1px solid var(--red);
      border-radius: 6px; padding: 0.8rem; color: var(--red); margin-top: 1rem;
      display: none; font-size: 0.9rem;
    }
    .error-msg.visible { display: block; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th { text-align: left; color: var(--text-dim); padding: 0.5rem; border-bottom: 1px solid var(--border); }
    td { padding: 0.5rem; border-bottom: 1px solid var(--border); }
    .badge {
      display: inline-block; padding: 0.15rem 0.5rem; border-radius: 12px;
      font-size: 0.75rem; font-weight: 600;
    }
    .badge-running { background: rgba(63, 185, 80, 0.15); color: var(--green); }
    .badge-pending { background: rgba(210, 153, 34, 0.15); color: var(--yellow); }
    .badge-other { background: rgba(139, 148, 158, 0.15); color: var(--text-dim); }
    .empty { color: var(--text-dim); text-align: center; padding: 2rem; }
  </style>
</head>
<body>
  <h1>OpenClaw Admin</h1>
  <p class="subtitle">Create and manage OpenClaw agents</p>

  <div class="card">
    <h2>Create Agent</h2>
    <form id="createForm">
      <div class="form-group">
        <label for="agentId">Agent ID</label>
        <input type="text" id="agentId" placeholder="e.g. alice" required
               pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" maxlength="20">
      </div>
      <div class="form-group">
        <label for="feishuAppId">Feishu App ID</label>
        <input type="text" id="feishuAppId" placeholder="cli_..." required>
      </div>
      <div class="form-group">
        <label for="feishuAppSecret">Feishu App Secret</label>
        <input type="password" id="feishuAppSecret" placeholder="Secret" required>
      </div>
      <button type="submit" id="submitBtn">Create Agent</button>
    </form>

    <div class="progress" id="progress">
      <div class="step" data-step="1"><span class="step-icon">⏳</span> Store Feishu credentials in Key Vault</div>
      <div class="step" data-step="2"><span class="step-icon">⏳</span> Generate agent config</div>
      <div class="step" data-step="3"><span class="step-icon">⏳</span> Upload config to shared storage</div>
      <div class="step" data-step="4"><span class="step-icon">⏳</span> Update agent mapping</div>
      <div class="step" data-step="5"><span class="step-icon">⏳</span> Scale StatefulSet</div>
    </div>
    <div class="error-msg" id="errorMsg"></div>
  </div>

  <div class="card">
    <h2>Agents</h2>
    <div id="agentList"><p class="empty">Loading...</p></div>
  </div>

  <script>
    const form = document.getElementById('createForm');
    const submitBtn = document.getElementById('submitBtn');
    const progressEl = document.getElementById('progress');
    const errorEl = document.getElementById('errorMsg');

    function setFormDisabled(disabled) {
      submitBtn.disabled = disabled;
      form.querySelectorAll('input').forEach(i => (i.disabled = disabled));
    }

    function resetProgress() {
      progressEl.classList.remove('visible');
      errorEl.classList.remove('visible');
      progressEl.querySelectorAll('.step').forEach(s => {
        s.className = 'step';
        s.querySelector('.step-icon').textContent = '⏳';
      });
    }

    function updateStep(step, status) {
      const el = progressEl.querySelector(`[data-step="${step}"]`);
      if (!el) return;
      el.className = `step ${status}`;
      const icons = { running: '⏳', done: '✅', error: '❌' };
      el.querySelector('.step-icon').textContent = icons[status] || '⏳';
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      resetProgress();
      progressEl.classList.add('visible');
      setFormDisabled(true);

      const body = {
        agentId: document.getElementById('agentId').value.trim(),
        feishuAppId: document.getElementById('feishuAppId').value.trim(),
        feishuAppSecret: document.getElementById('feishuAppSecret').value.trim(),
      };

      try {
        const resp = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });

        if (!resp.ok && resp.headers.get('content-type')?.includes('json')) {
          const err = await resp.json();
          throw new Error(err.error || `HTTP ${resp.status}`);
        }

        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          const lines = buffer.split('\n');
          buffer = lines.pop(); // keep incomplete line

          for (const line of lines) {
            if (!line.startsWith('data: ')) continue;
            try {
              const msg = JSON.parse(line.slice(6));
              if (msg.status === 'error') {
                updateStep(msg.step || 0, 'error');
                errorEl.textContent = msg.msg;
                errorEl.classList.add('visible');
              } else {
                updateStep(msg.step, msg.status);
              }
              if (msg.done) loadAgents();
            } catch {}
          }
        }
      } catch (err) {
        errorEl.textContent = err.message;
        errorEl.classList.add('visible');
      }

      setFormDisabled(false);
    });

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
          <tr><th>Agent ID</th><th>Ordinal</th><th>Status</th><th>Ready</th></tr>
          ${agents.map(a => {
            const cls = a.podStatus === 'Running' ? 'running' : a.podStatus === 'Pending' ? 'pending' : 'other';
            return `<tr>
              <td><strong>${a.agentId}</strong></td>
              <td>${a.ordinal}</td>
              <td><span class="badge badge-${cls}">${a.podStatus}</span></td>
              <td>${a.podReady}</td>
            </tr>`;
          }).join('')}
        </table>`;
      } catch (err) {
        el.innerHTML = `<p class="empty">Failed to load agents: ${err.message}</p>`;
      }
    }

    loadAgents();
  </script>
</body>
</html>
```

- [ ] **Step 2: Commit admin application code**

```bash
git add admin/package.json admin/server.js admin/index.html
git commit -m "feat(admin): add Express server with SSE creation flow and single-page UI"
```

---

## Chunk 3: Docker Image + K8s Manifests

### Task 5: Create Dockerfile

**Files:**
- Create: `admin/Dockerfile`

- [ ] **Step 1: Create Dockerfile**

```dockerfile
FROM node:22-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg && \
    # kubectl
    curl -fsSL "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    # az CLI
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json server.js index.html ./
RUN npm install --omit=dev

USER 1000
EXPOSE 3000
CMD ["node", "server.js"]
```

### Task 6: Create K8s RBAC manifest

**Files:**
- Create: `admin/k8s/rbac.yaml`

Placeholders use the same `<placeholder>` convention as other K8s manifests. The `install.sh` or manual deploy will substitute them.

- [ ] **Step 1: Create rbac.yaml**

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
# ConfigMaps: read agent-mapping + create/delete temp configs
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "create", "patch", "delete"]
# Pods: list for agent status
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
# StatefulSet: read replicas + scale
- apiGroups: ["apps"]
  resources: ["statefulsets"]
  verbs: ["get", "patch"]
  resourceNames: ["openclaw-agent"]
- apiGroups: ["apps"]
  resources: ["statefulsets/scale"]
  verbs: ["get", "patch"]
  resourceNames: ["openclaw-agent"]
# Jobs: create/manage upload jobs
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["create", "get", "list", "delete", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: openclaw-admin
  namespace: openclaw
subjects:
- kind: ServiceAccount
  name: openclaw-admin
  namespace: openclaw
roleRef:
  kind: Role
  name: openclaw-admin
  apiGroup: rbac.authorization.k8s.io
```

### Task 7: Create K8s Deployment + Service manifest

**Files:**
- Create: `admin/k8s/deployment.yaml`

- [ ] **Step 1: Create deployment.yaml**

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
        image: <acr_login_server>/openclaw-admin:latest
        ports:
        - containerPort: 3000
        env:
        - name: KV_NAME
          value: "<keyvault_name>"
        - name: AZURE_OPENAI_ENDPOINT
          value: "<azure_openai_endpoint>"
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
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
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

- [ ] **Step 2: Commit Docker + K8s manifests**

```bash
git add admin/Dockerfile admin/k8s/
git commit -m "feat(admin): add Dockerfile with kubectl/az-cli and K8s deployment manifests"
```

---

## Chunk 4: StatefulSet — Per-Agent Feishu Credentials

The current StatefulSet reads shared Feishu credentials from a K8s Secret (mounted via CSI SecretProviderClass). For per-agent Feishu apps, each agent needs its own credentials. The admin panel writes `feishu.env` to each agent's NFS directory. The init container and main container are updated to use it.

### Task 8: Update StatefulSet for per-agent Feishu

> **IMPORTANT**: The Git-tracked `k8s/sandbox/agent-statefulset.yaml` has **diverged** from the deployed StatefulSet. The deployed version uses a simpler init script with different paths (`/persist/agents/$AGENT_ID/config.json`). This task targets the **deployed** state and patches it via `kubectl`. The Git YAML should be reconciled separately as a housekeeping task.

**Approach:** Use `kubectl patch` or `kubectl edit` to update the deployed StatefulSet directly, then export the result back to Git.

- [ ] **Step 1: Update init container to also copy feishu.env**

The deployed init container currently reads only `config.json`. We add `feishu.env` support:

```bash
# Export current deployed StatefulSet
kubectl get sts openclaw-agent -n openclaw -o yaml > /tmp/current-sts.yaml
```

Edit the init container args in `/tmp/current-sts.yaml`. Find the section:

```sh
# Copy agent config if it exists
if [ -f "$AGENT_PERSIST/config.json" ]; then
  cp "$AGENT_PERSIST/config.json" "$OPENCLAW_DIR/openclaw.json"
  echo "Copied agent config from $AGENT_PERSIST/config.json"
fi
```

Change to:

```sh
# Copy agent config if it exists
if [ -f "$AGENT_PERSIST/config.json" ]; then
  cp "$AGENT_PERSIST/config.json" "$OPENCLAW_DIR/openclaw.json"
  echo "Copied agent config from $AGENT_PERSIST/config.json"
fi

# Copy per-agent Feishu credentials if they exist
if [ -f "$AGENT_PERSIST/feishu.env" ]; then
  cp "$AGENT_PERSIST/feishu.env" "$OPENCLAW_DIR/feishu.env"
  echo "Copied per-agent Feishu credentials"
fi
```

- [ ] **Step 2: Update main container to source feishu.env**

In the same file, update the `openclaw` container to use a command override instead of the Docker ENTRYPOINT. Remove the `FEISHU_APP_ID` and `FEISHU_APP_SECRET` env entries (secretKeyRef to `feishu-credentials`). Add:

```yaml
        command: ["/bin/sh", "-c"]
        args:
        - |
          if [ -f "$OPENCLAW_HOME/feishu.env" ]; then
            . "$OPENCLAW_HOME/feishu.env"
            echo "Loaded per-agent Feishu credentials from feishu.env"
          elif [ -n "$FEISHU_APP_ID" ]; then
            echo "Using shared Feishu credentials from env vars"
          else
            echo "WARNING: No Feishu credentials found"
          fi
          exec openclaw gateway run
```

Keep the `OPENCLAW_HOME` and `POD_NAME` env vars.

This is backward-compatible: if `feishu.env` exists (written by admin panel), it's sourced. Otherwise falls through to env vars if the old `feishu-credentials` K8s Secret still exists.

- [ ] **Step 3: Apply the updated StatefulSet**

```bash
kubectl apply -f /tmp/current-sts.yaml
```

Note: This triggers a rolling restart. The existing agent-0 (alice) will restart. Since alice doesn't have a `feishu.env` file on NFS yet, the fallback logic applies — it uses whatever `FEISHU_APP_ID`/`FEISHU_APP_SECRET` env vars or `feishu-credentials` Secret provides. If neither exists (as may be the case since the deployed StatefulSet references `feishu-credentials` secret which may or may not exist), alice may lose Feishu connectivity until you create her `feishu.env` via the admin panel or restore the old shared secret.

**Mitigation:** Before applying, create alice's `feishu.env` on NFS:
```bash
# If alice has known Feishu credentials, write them to NFS first
kubectl run upload-feishu-alice --rm -i --restart=Never -n openclaw \
  --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"upload","image":"busybox:1.36","command":["sh","-c","mkdir -p /persist/agents/alice && cat > /persist/agents/alice/feishu.env"],"stdin":true,"volumeMounts":[{"name":"files","mountPath":"/persist"}]}],"volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"openclaw-shared-data"}}]}}' \
  <<< "export FEISHU_APP_ID='<alice-app-id>'
export FEISHU_APP_SECRET='<alice-app-secret>'"
```

- [ ] **Step 4: Update Git YAML to match deployed state**

```bash
# Export the clean deployed state back to Git
kubectl get sts openclaw-agent -n openclaw -o yaml | \
  grep -v 'creationTimestamp\|resourceVersion\|uid\|generation\|selfLink\|kubectl.kubernetes.io/last-applied-configuration' \
  > k8s/sandbox/agent-statefulset.yaml
```

Review the exported file and clean up any cluster-specific annotations.

- [ ] **Step 5: Commit StatefulSet changes**

```bash
git add k8s/sandbox/agent-statefulset.yaml
git commit -m "feat(statefulset): support per-agent Feishu credentials via feishu.env on NFS

Reconcile Git YAML with deployed cluster state. Init container now copies
feishu.env alongside config.json. Main container sources feishu.env before
starting openclaw, with backward-compatible fallback to env vars."
```

---

## Chunk 5: Build, Deploy, and Test

### Task 9: Build and push admin Docker image

**Files:** None (operational commands only)

- [ ] **Step 1: Build admin Docker image**

```bash
ACR=$(cd /home/vmadmin/clawonaks/terraform && terraform output -raw acr_login_server)
az acr login --name "${ACR%%.*}"
cd /home/vmadmin/clawonaks/admin
docker build -t "$ACR/openclaw-admin:latest" .
docker push "$ACR/openclaw-admin:latest"
```

Expected: Image pushed to ACR successfully.

### Task 10: Create Azure OpenAI K8s Secret

The admin pod needs the Azure OpenAI API key as a K8s Secret. This is a one-time setup step if the secret doesn't already exist.

- [ ] **Step 1: Check if secret exists, create if not**

```bash
# Check if secret already exists
kubectl get secret azure-openai-credentials -n openclaw 2>/dev/null || \
  kubectl create secret generic azure-openai-credentials -n openclaw \
    --from-literal=api-key="<AZURE_OPENAI_KEY_VALUE>"
```

The key value comes from Terraform or the Azure portal. For now, this is a manual step. Future improvement: pull from Key Vault via CSI.

### Task 11: Deploy K8s resources

- [ ] **Step 1: Substitute placeholders and apply RBAC**

```bash
# Get values from Terraform
ADMIN_CLIENT_ID=$(cd /home/vmadmin/clawonaks/terraform && terraform output -raw admin_identity_client_id)
ACR=$(cd /home/vmadmin/clawonaks/terraform && terraform output -raw acr_login_server)
KV_NAME=$(cd /home/vmadmin/clawonaks/terraform && terraform output -raw keyvault_name)

# Create deploy directory
mkdir -p /home/vmadmin/clawonaks/deploy/admin/k8s

# Substitute placeholders
sed "s|<admin_identity_client_id>|${ADMIN_CLIENT_ID}|g" \
  /home/vmadmin/clawonaks/admin/k8s/rbac.yaml > /home/vmadmin/clawonaks/deploy/admin/k8s/rbac.yaml

sed -e "s|<acr_login_server>|${ACR}|g" \
    -e "s|<keyvault_name>|${KV_NAME}|g" \
    -e "s|<azure_openai_endpoint>|https://ai-admin5311ai774489569826.cognitiveservices.azure.com/openai/v1|g" \
  /home/vmadmin/clawonaks/admin/k8s/deployment.yaml > /home/vmadmin/clawonaks/deploy/admin/k8s/deployment.yaml

# Apply
kubectl apply -f /home/vmadmin/clawonaks/deploy/admin/k8s/rbac.yaml
kubectl apply -f /home/vmadmin/clawonaks/deploy/admin/k8s/deployment.yaml
```

Expected: ServiceAccount, Role, RoleBinding, Deployment, Service created.

- [ ] **Step 2: Wait for admin pod to be ready**

```bash
kubectl rollout status deployment/openclaw-admin -n openclaw --timeout=120s
kubectl get pods -n openclaw -l app=openclaw-admin
```

Expected: Pod in Running state.

- [ ] **Step 3: Check admin pod logs for az login success**

```bash
kubectl logs -l app=openclaw-admin -n openclaw --tail=20
```

Expected: "Azure login successful (Workload Identity)" in logs.

### Task 12: Verify StatefulSet is running with per-agent Feishu support

StatefulSet was already updated in Task 8. Verify it's healthy.

- [ ] **Step 1: Verify StatefulSet rollout**

```bash
kubectl rollout status sts openclaw-agent -n openclaw --timeout=180s
kubectl get pods -n openclaw -l app=openclaw-sandbox
```

Expected: agent-0 (alice) pod is Running with the updated init container.

- [ ] **Step 2: Check init container logs for feishu.env handling**

```bash
kubectl logs openclaw-agent-0 -c setup-workspace -n openclaw
```

Expected: Should show workspace setup messages. If feishu.env was pre-staged for alice, should show "Copied per-agent Feishu credentials".

### Task 13: E2E Test — Create agent via admin panel

- [ ] **Step 1: Port-forward to admin panel**

```bash
kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw &
```

- [ ] **Step 2: Test GET /api/agents**

```bash
curl -s http://localhost:3000/api/agents | python3 -m json.tool
```

Expected: JSON array with existing agent `alice` at ordinal 0.

- [ ] **Step 3: Test POST /api/agents (create a new agent)**

```bash
curl -N -X POST http://localhost:3000/api/agents \
  -H 'Content-Type: application/json' \
  -d '{"agentId":"bob","feishuAppId":"cli_test123","feishuAppSecret":"secret_test123"}'
```

Expected: SSE stream with 5 steps completing successfully.

- [ ] **Step 4: Verify agent was created**

```bash
# Check ConfigMap
kubectl get configmap agent-mapping -n openclaw -o json | python3 -m json.tool

# Check StatefulSet replicas
kubectl get sts openclaw-agent -n openclaw

# Check pods
kubectl get pods -n openclaw

# Check KV secrets
KV_NAME=$(cd /home/vmadmin/clawonaks/terraform && terraform output -raw keyvault_name)
az keyvault secret show --vault-name "$KV_NAME" --name "feishu-app-id-bob" --query value -o tsv
```

Expected:
- ConfigMap has `agent-0: alice` and `agent-1: bob`
- StatefulSet replicas = 2
- Two openclaw-agent pods running
- Key Vault has `feishu-app-id-bob` secret

- [ ] **Step 5: Test the web UI**

Open http://localhost:3000 in browser. Verify:
- Agent list shows alice and bob with pod status
- Create form works with validation
- Dark theme renders correctly

- [ ] **Step 6: Test duplicate agent rejection**

```bash
curl -s -X POST http://localhost:3000/api/agents \
  -H 'Content-Type: application/json' \
  -d '{"agentId":"bob","feishuAppId":"x","feishuAppSecret":"y"}'
```

Expected: HTTP 409 with `{"error":"Agent 'bob' already exists"}`

- [ ] **Step 7: Test validation**

```bash
# Empty agent ID
curl -s -X POST http://localhost:3000/api/agents \
  -H 'Content-Type: application/json' \
  -d '{"agentId":"","feishuAppId":"x","feishuAppSecret":"y"}'

# Invalid characters
curl -s -X POST http://localhost:3000/api/agents \
  -H 'Content-Type: application/json' \
  -d '{"agentId":"Alice","feishuAppId":"x","feishuAppSecret":"y"}'
```

Expected: HTTP 400 with validation error messages.

---

## Summary

| Chunk | Tasks | Description |
|-------|-------|-------------|
| 1 | 1 | Terraform: admin MI + KV Secrets Officer role |
| 2 | 2-4 | Application code: server.js + index.html + package.json |
| 3 | 5-7 | Docker image + K8s manifests (RBAC, Deployment, Service) |
| 4 | 8 | StatefulSet update + Git reconciliation for per-agent Feishu credentials |
| 5 | 9-13 | Build, deploy, and E2E test |

**Total: 13 tasks, ~5 commits**

After E2E passes, the admin panel is accessible via:
```bash
kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw
# Open http://localhost:3000
```
