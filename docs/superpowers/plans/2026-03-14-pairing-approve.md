# DM Pairing Approve Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an inline "Approve Pairing" button to the Admin Panel agent list that executes `openclaw pairing approve feishu <code>` in the target agent pod.

**Architecture:** New `POST /api/agents/:id/approve` Express route uses existing `kubectl()` helper to find the Running pod by label selector and exec into it. Frontend adds an Approve button per agent row with `prompt()` input and inline status feedback.

**Tech Stack:** Node.js Express (existing), vanilla JS frontend (existing), kubectl CLI (existing in admin pod)

**Spec:** `docs/superpowers/specs/2026-03-14-pairing-approve-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `admin/server.js` | Modify (add route after DELETE handler, ~line 419) | New `POST /api/agents/:id/approve` endpoint |
| `admin/index.html` | Modify (add CSS + JS function + table column update) | Approve button UI + interaction logic |

No new files. No dependency changes. No infrastructure changes.

---

## Chunk 1: Implementation

### Task 1: Add backend approve endpoint

**Files:**
- Modify: `admin/server.js` (insert new route after the DELETE route at ~line 419)

- [ ] **Step 1: Add the POST /api/agents/:id/approve route**

Insert after the `app.delete('/api/agents/:id', ...)` handler's closing `});` and before the `// --- Startup ---` comment. Note: relies on existing `app.use(express.json())` middleware (server.js line 9) and the `kubectl()` helper's 30s timeout (line 20-23), which is sufficient for the `pairing approve` command:

```javascript
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
```

- [ ] **Step 2: Verify server.js parses correctly**

Run: `node -c admin/server.js`
Expected: No output (clean syntax check)

- [ ] **Step 3: Commit backend change**

```bash
git add admin/server.js
git commit -m "feat(admin): add POST /api/agents/:id/approve endpoint

Executes kubectl exec to run openclaw pairing approve in the agent pod.
Validates agent ID and pairing code, finds Running pod by label selector."
```

---

### Task 2: Add frontend approve button and interaction

**Files:**
- Modify: `admin/index.html` (CSS section + JS section + table template)

- [ ] **Step 1: Add .btn-approve and .approve-status CSS**

In `admin/index.html`, after the `.btn-delete:hover` rule (line ~70, before `</style>`), add:

```css
    .btn-approve {
      background: transparent; color: var(--accent); border: 1px solid var(--accent);
      border-radius: 4px; padding: 0.2rem 0.6rem; font-size: 0.75rem; cursor: pointer;
      margin-right: 0.4rem;
    }
    .btn-approve:hover { background: rgba(88, 166, 255, 0.15); }
    .btn-approve:disabled { opacity: 0.4; cursor: not-allowed; }
    .approve-status { font-size: 0.75rem; margin-left: 0.3rem; }
```

- [ ] **Step 2: Add approveAgent() function**

In the `<script>` section, after the `deleteAgent()` function and before `loadAgents();`, add:

```javascript
    async function approveAgent(agentId) {
      const code = prompt(`Enter pairing code for "${agentId}":`);
      if (!code || !code.trim()) return;

      const statusEl = document.getElementById(`approve-status-${agentId}`);
      const btn = document.getElementById(`approve-btn-${agentId}`);
      if (statusEl) statusEl.textContent = '⏳';
      if (btn) btn.disabled = true;

      try {
        const resp = await fetch(`/api/agents/${agentId}/approve`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ code: code.trim() }),
        });
        const data = await resp.json();
        if (!resp.ok) throw new Error(data.error || `HTTP ${resp.status}`);
        if (statusEl) {
          statusEl.textContent = '✅ Approved';
          statusEl.style.color = 'var(--green)';
          setTimeout(() => { statusEl.textContent = ''; if (btn) btn.disabled = false; }, 3000);
        } else {
          if (btn) btn.disabled = false;
        }
      } catch (err) {
        if (statusEl) {
          statusEl.textContent = `❌ ${err.message}`;
          statusEl.style.color = 'var(--red)';
          setTimeout(() => { statusEl.textContent = ''; if (btn) btn.disabled = false; }, 5000);
        } else {
          if (btn) btn.disabled = false;
        }
      }
    }
```

- [ ] **Step 3: Update agent table to include Approve button**

In the `loadAgents()` function, replace the `<td>` for Actions. Change the template literal that renders each agent row. The current Actions cell is:

```javascript
<td><button class="btn-delete" onclick="deleteAgent('${esc(a.agentId)}')">Delete</button></td>
```

Replace with:

```javascript
<td><button id="approve-btn-${esc(a.agentId)}" class="btn-approve"${a.podStatus !== 'Running' ? ' disabled' : ''} onclick="approveAgent('${esc(a.agentId)}')">Approve</button><button class="btn-delete" onclick="deleteAgent('${esc(a.agentId)}')">Delete</button><span id="approve-status-${esc(a.agentId)}" class="approve-status"></span></td>
```

This adds:
- Approve button (disabled when pod is not Running)
- Inline status span for feedback
- Existing Delete button preserved

- [ ] **Step 4: Verify index.html is well-formed**

Open `admin/index.html` in a browser or validate manually. Check that the HTML structure is valid.

- [ ] **Step 5: Commit frontend change**

```bash
git add admin/index.html
git commit -m "feat(admin): add Approve Pairing button to agent list

Inline button per agent row with prompt() for pairing code input.
Shows transient status feedback (success 3s, error 5s auto-dismiss).
Button disabled when pod is not Running."
```

---

### Task 3: Build, deploy, and E2E test

**Files:**
- No code changes — build and deploy existing changes

- [ ] **Step 1: Build and push updated admin Docker image**

```bash
cd /home/vmadmin/clawonaks
ACR=$(cd terraform && terraform output -raw acr_login_server)
docker build -t "$ACR/openclaw-admin:latest" -f admin/Dockerfile admin/
docker push "$ACR/openclaw-admin:latest"
```

Expected: Build succeeds, push completes.

- [ ] **Step 2: Restart admin deployment to pull new image**

```bash
kubectl rollout restart deployment openclaw-admin -n openclaw
kubectl rollout status deployment openclaw-admin -n openclaw --timeout=120s
```

Expected: Deployment rolls out successfully.

- [ ] **Step 3: Port-forward and verify UI**

```bash
kubectl port-forward svc/openclaw-admin 3001:3000 -n openclaw &
```

Open http://localhost:3001 — verify:
- Agent list loads with Approve + Delete buttons
- Approve button is blue/accent colored, Delete is red
- If aks-demo is Running, Approve button is enabled
- Click Approve → prompt dialog appears
- Enter a test code → inline status shows result

- [ ] **Step 4: E2E test with a real pairing code (if available)**

If a user has triggered a DM pairing and you have the code:
1. Click Approve on the agent row
2. Enter the pairing code
3. Verify ✅ Approved status appears
4. Verify the Feishu bot can now respond to DMs

If no pairing code is available, test error handling:
1. Click Approve, enter `TESTCODE1`
2. Verify ❌ error feedback appears with openclaw CLI message
3. Verify error disappears after 5 seconds

- [ ] **Step 5: Commit any fixes and update CLAUDE.md**

If any fixes were needed during testing, commit them. Then update CLAUDE.md §11 to mark "Admin Panel: DM Pairing Approve 集成" as completed.

```bash
git add admin/server.js admin/index.html CLAUDE.md
git commit -m "chore: deploy and verify Pairing Approve feature"
```
