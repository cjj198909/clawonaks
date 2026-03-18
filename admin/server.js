const express = require('express');
const fs = require('fs');
const path = require('path');
const { execFile, spawn } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);
const app = express();
app.use(express.json());

const NAMESPACE = process.env.NAMESPACE || 'openclaw';
const KV_NAME = process.env.KV_NAME || '';
const AGENT_TEMPLATE_PATH = process.env.AGENT_TEMPLATE_PATH || '/etc/openclaw/agent-template.yaml';
const APIM_ENABLED = process.env.APIM_ENABLED === 'true';
const APIM_NAME = process.env.APIM_NAME || '';
const APIM_RG = process.env.APIM_RG || '';
const APIM_API_ID = process.env.APIM_API_ID || '';

// Extract Azure subscription ID from APIM_API_ID for REST API calls
// Format: /subscriptions/{azSubId}/resourceGroups/.../apis/azure-openai;rev=1
const AZURE_SUB_ID = APIM_API_ID.match(/\/subscriptions\/([^/]+)/)?.[1] || '';

/** Build APIM subscription management REST URL */
function apimSubUrl(agentId) {
  return `https://management.azure.com/subscriptions/${AZURE_SUB_ID}/resourceGroups/${APIM_RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/openclaw-agent-${agentId}?api-version=2024-06-01-preview`;
}

let agentTemplate = '';

// --- Helpers ---

async function kubectl(...args) {
  const { stdout } = await execFileAsync('kubectl', args, { timeout: 30000 });
  return stdout.trim();
}

async function az(...args) {
  const { stdout } = await execFileAsync('az', args, { timeout: 60000 });
  return stdout.trim();
}

/** Set a KV secret, auto-purging soft-deleted secrets with the same name */
async function kvSecretSet(name, value) {
  try {
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME, '--name', name, '--value', value);
  } catch (err) {
    if (err.message.includes('ObjectIsDeletedButRecoverable')) {
      await az('keyvault', 'secret', 'purge', '--vault-name', KV_NAME, '--name', name);
      await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME, '--name', name, '--value', value);
    } else {
      throw err;
    }
  }
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

function renderAgentYaml(agentId) {
  return agentTemplate.replaceAll('__AGENT_ID__', agentId);
}

// --- Routes ---

app.get('/', (_req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

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

  const total = APIM_ENABLED ? 3 : 2;
  const send = (step, status, msg, extra = {}) => {
    res.write(`data: ${JSON.stringify({ step, total, status, msg, ...extra })}\n\n`);
  };

  let currentStep = 0;
  try {
    // Step 1: Store Feishu credentials in Key Vault
    currentStep = 1;
    send(1, 'running', 'Storing Feishu credentials in Key Vault...');
    await azLogin();
    await kvSecretSet(`feishu-app-id-${agentId}`, feishuAppId);
    await kvSecretSet(`feishu-app-secret-${agentId}`, feishuAppSecret);
    send(1, 'done', 'Feishu credentials stored in Key Vault');

    // Step 2 (APIM only): Create APIM subscription via REST API, store key in KV
    // NOTE: Uses `az rest` instead of `az apim subscription create` because the
    // apim CLI extension takes >60s to load in the container, exceeding the
    // execFileAsync timeout.  The REST API completes in <1s.
    if (APIM_ENABLED) {
      currentStep = 2;
      send(2, 'running', 'Creating APIM subscription...');
      const apiScope = APIM_API_ID.replace(/;rev=\d+$/, ''); // strip revision suffix
      const body = JSON.stringify({
        properties: {
          displayName: `openclaw-agent-${agentId}`,
          scope: apiScope,
          state: 'active',
        },
      });
      await az('rest', '--method', 'PUT',
        '--url', apimSubUrl(agentId), '--body', body);
      // PUT response doesn't include keys — use listSecrets API
      const secretsUrl = apimSubUrl(agentId).replace(/\?/, '/listSecrets?');
      const secretsResult = await az('rest', '--method', 'POST', '--url', secretsUrl);
      const secretsData = JSON.parse(secretsResult);
      const subKey = secretsData?.primaryKey;
      if (!subKey) {
        throw new Error('APIM subscription listSecrets returned empty key');
      }
      await kvSecretSet(`apim-sub-key-${agentId}`, subKey);
      send(2, 'done', 'APIM subscription created, key stored in KV');
    }

    // Step 2 or 3: Create K8s resources (SPC + PVC + Deployment)
    currentStep = total;
    send(total, 'running', 'Creating K8s resources (SPC + PVC + Deployment)...');
    await kubectlApplyStdin(renderAgentYaml(agentId));
    send(total, 'done', `Agent ${agentId} created successfully`, { done: true });
  } catch (err) {
    send(currentStep, 'error', `Creation failed: ${err.message}`);
    // Cleanup on failure
    if (currentStep >= total) {
      await kubectl('delete', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'pvc', `work-disk-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'secretproviderclass', `spc-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
    }
    if (APIM_ENABLED && currentStep >= 2) {
      await az('rest', '--method', 'DELETE', '--url', apimSubUrl(agentId)).catch(() => {});
      await az('keyvault', 'secret', 'delete', '--vault-name', KV_NAME,
        '--name', `apim-sub-key-${agentId}`).catch(() => {});
    }
  }

  res.end();
});

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

    // Delete APIM subscription via REST API (if APIM enabled)
    if (APIM_ENABLED) {
      await azLogin();
      await az('rest', '--method', 'DELETE', '--url', apimSubUrl(agentId)).catch(() => {});
      await az('keyvault', 'secret', 'delete', '--vault-name', KV_NAME,
        '--name', `apim-sub-key-${agentId}`).catch(() => {});
      results.push('APIM subscription + KV key deleted');
    }

    // Note: NFS backup at /persist/agents/<agentId>/ is NOT auto-deleted.
    // This is intentional — backup data may be needed for recovery.
    // Manual cleanup: kubectl exec into any pod with NFS mount and rm -rf the directory.

    res.json({ ok: true, results });
  } catch (err) {
    res.status(500).json({ error: err.message, results });
  }
});

app.post('/api/agents/:id/approve', async (req, res) => {
  const agentId = req.params.id;
  const idErr = validateAgentId(agentId);
  if (idErr) return res.status(400).json({ error: idErr });

  let { code } = req.body || {};
  if (!code || typeof code !== 'string') {
    return res.status(400).json({ error: 'Pairing code is required' });
  }
  code = code.trim().toUpperCase();
  if (!/^[A-Z0-9]{6,10}$/.test(code)) {
    return res.status(400).json({ error: 'Code must be 6-10 alphanumeric characters' });
  }

  // Find running pod for this agent
  let podName;
  try {
    podName = await kubectl(
      'get', 'pods', '-n', NAMESPACE,
      '-l', `openclaw.io/agent-id=${agentId}`,
      '--field-selector', 'status.phase=Running',
      '-o', 'jsonpath={.items[0].metadata.name}'
    );
  } catch {
    return res.status(404).json({ error: `No running pod found for agent '${agentId}'` });
  }

  if (!podName) {
    return res.status(404).json({ error: `No running pod found for agent '${agentId}'. Wait for pod to be Running.` });
  }

  try {
    const output = await kubectl(
      'exec', podName, '-c', 'openclaw', '-n', NAMESPACE,
      '--', 'openclaw', 'pairing', 'approve', 'feishu', code
    );
    res.json({ ok: true, output });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- Startup ---

async function azLogin() {
  if (!process.env.AZURE_FEDERATED_TOKEN_FILE) {
    console.warn('AZURE_FEDERATED_TOKEN_FILE not set — skipping az login (dev mode)');
    return false;
  }
  try {
    const token = fs.readFileSync(
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

  // Refresh az login every 45 minutes (federated tokens expire after ~1 hour)
  setInterval(() => {
    azLogin().catch(err => console.error('Token refresh failed:', err.message));
  }, 45 * 60 * 1000);

  app.listen(3000, () => {
    console.log('OpenClaw Admin Panel running on http://localhost:3000');
  });
}

main();
