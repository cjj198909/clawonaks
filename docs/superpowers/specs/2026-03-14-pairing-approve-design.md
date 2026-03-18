# DM Pairing Approve — Design Spec

**Date:** 2026-03-14
**Status:** Approved
**Scope:** Add inline "Approve Pairing" button to Admin Panel agent list

## Problem

After creating an agent via Admin Panel, the Feishu bot requires DM pairing approval. Currently this requires manually running `kubectl exec` into the agent pod — a friction point that breaks the otherwise self-service Admin Panel workflow.

## Solution

Add a one-click Approve button per agent row in the Admin Panel. Clicking it prompts for a pairing code, calls a new backend endpoint, which executes `openclaw pairing approve feishu <code>` inside the agent pod via `kubectl exec`.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| UI placement | Inline button per agent row | Contextual, no page navigation, consistent with existing Delete button |
| Backend execution | `kubectl exec` via `execFileAsync` | Reuses existing `kubectl()` helper pattern, zero new dependencies |
| Code input | Browser `prompt()` dialog | Zero-framework approach, consistent with project philosophy |
| Result feedback | Inline status text (success 3s, error 5s auto-dismiss) | Lightweight, non-intrusive, errors get longer read time |
| Code validation | `/^[A-Z0-9]{6,10}$/` regex + `.toUpperCase()` | Prevents command injection; `execFileAsync` array args add defense-in-depth; accepts lowercase input gracefully |

## API Design

### `POST /api/agents/:id/approve`

**Request:**
```json
{ "code": "RF55K9QP" }
```

**Success Response (200):**
```json
{ "ok": true, "output": "Pairing approved for feishu RF55K9QP" }
```

**Error Responses:**
- `400`: Invalid agent ID or code format
- `404`: Agent deployment or pod not found
- `500`: `kubectl exec` failed (returns stderr as error message)

### Backend Logic

1. Validate `agentId` (reuse `validateAgentId()`) and `code` (`.toUpperCase()` then regex `/^[A-Z0-9]{6,10}$/`)
2. Find target pod via `execFileAsync` argument array (not shell interpolation):
   ```javascript
   kubectl('get', 'pods', '-n', NAMESPACE,
     '-l', `openclaw.io/agent-id=${agentId}`,
     '--field-selector', 'status.phase=Running',
     '-o', 'jsonpath={.items[0].metadata.name}')
   ```
3. If no running pod found, return 404 with descriptive message
4. Execute via argument array:
   ```javascript
   kubectl('exec', podName, '-c', 'openclaw', '-n', NAMESPACE,
     '--', 'openclaw', 'pairing', 'approve', 'feishu', code)
   ```
5. Return stdout on success, stderr on failure

### Security

- **Command injection prevention:** `execFileAsync` passes arguments as an array (not shell-interpolated). Code is additionally regex-validated to only allow `[A-Z0-9]`.
- **RBAC:** `pods/exec` permission already granted in `admin/k8s/rbac.yaml` (originally for credential rotation).
- **Agent ID validation:** Existing `validateAgentId()` function (lowercase alphanumeric + hyphens, max 20 chars).

## Frontend Changes

### Agent Table — Actions Column

Current:
```
| Agent ID | Status  | Ready | Actions        |
|----------|---------|-------|----------------|
| aks-demo | Running | 1/1   | [Delete]       |
```

After:
```
| Agent ID | Status  | Ready | Actions                 |
|----------|---------|-------|-------------------------|
| aks-demo | Running | 1/1   | [Approve] [Delete]      |
```

### Interaction Flow

1. User clicks **Approve** button (disabled when pod status is not Running)
2. Browser `prompt('Enter pairing code for "aks-demo":')` dialog appears
3. User enters code (e.g., `RF55K9QP` or `rf55k9qp`), clicks OK
4. Frontend early-return if code is empty/cancelled; otherwise `POST /api/agents/aks-demo/approve` with `{ "code": "RF55K9QP" }` (uppercased by backend)
5. Button shows inline status:
   - ⏳ during request
   - ✅ `Approved` on success (green, 3s auto-dismiss)
   - ❌ `Failed: <reason>` on error (red, 5s auto-dismiss for readability)
6. If prompt is cancelled or empty, no action taken

### New CSS

- `.btn-approve`: Accent-colored border button (matches `--accent: #58a6ff`), visually distinct from red `.btn-delete`
- `.approve-status`: Small inline text element for transient feedback

## Files Changed

| File | Change | Lines |
|------|--------|-------|
| `admin/server.js` | New `POST /api/agents/:id/approve` route | ~25 |
| `admin/index.html` | `.btn-approve` CSS + `approveAgent()` function + Actions column update | ~30 |

**No changes to:** `rbac.yaml`, `deployment.yaml`, `Dockerfile`, `package.json`

## Edge Cases

| Case | Behavior |
|------|----------|
| Pod not running (Pending/CrashLoopBackOff) | Approve button disabled in UI; API returns 404: "No running pod found for agent 'xxx'" |
| Pod Running but openclaw still initializing (~2-3 min startup) | `kubectl exec` returns openclaw CLI error; 500 with stderr message. User retries after startup. |
| Invalid code format | 400: "Code must be 6-10 alphanumeric characters" |
| Lowercase code input | Uppercased automatically before validation and sending |
| openclaw CLI returns error | 500: Forward stderr message (e.g., "Unknown pairing code") |
| Agent doesn't exist | 404: "Agent 'xxx' not found" |
| Multiple pods for same agent | Use first Running pod (should only be 1 with replicas=1) |
| Empty code (user hits OK without typing) | Frontend early-return, no API call |

## Future Considerations

- **Multi-channel support:** Currently hardcodes `feishu` as the channel. When Telegram/Discord channels are added (v2 mid-term), the API could accept an optional `channel` parameter defaulting to `feishu`.
