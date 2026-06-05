# Azure Config Ops Portal

Single-file portal + YAML pipeline templates for Azure network and access configuration tasks.

---

## Package contents

```
azure-ops-portal/
├── index.html                          ← Deployable portal (open in browser or host anywhere)
└── pipelines/
    ├── add-service-endpoint.yml        ← Add service endpoint to subnet
    ├── rg-lock.yml                     ← Create / delete RG lock
    ├── kv-access-policy.yml            ← Key Vault access policy
    ├── attach-nat-gateway.yml          ← Attach NAT gateway to subnet
    └── paas-selected-networks.yml      ← VNet rules for CosmosDB/KV/ADLS/SB/EH
```

---

## Portal setup (index.html)

### Option A — open locally
Just double-click `index.html`. Works in any modern browser. Config is saved in `localStorage`.

### Option B — host on Azure Static Web Apps (recommended)
```bash
az staticwebapp create \
  --name az-ops-portal \
  --resource-group your-rg \
  --source . \
  --location "East US 2" \
  --branch main \
  --app-artifact-location "/"
```

### Option C — host on Azure Blob Storage (static website)
```bash
az storage blob service-properties update \
  --account-name youraccount \
  --static-website \
  --index-document index.html

az storage blob upload \
  --account-name youraccount \
  --container-name '$web' \
  --file index.html \
  --name index.html
```

### Filling in the connection settings
Open the portal and fill in the **ADO Connection** panel on the right:

| Field | Where to find it |
|---|---|
| Organization | Your ADO org name (e.g. `contoso`) |
| Project | Your ADO project name |
| Pipeline ID | Open your pipeline in ADO → URL shows `?definitionId=42` |
| PAT token | ADO → User Settings → Personal Access Tokens → scope: Release (read, write, execute) for classic; Build (read & execute) for YAML |
| Pipeline type | `YAML pipeline` (recommended) or `Classic release` |

Settings are saved in browser `localStorage` — they persist across sessions.

For **Advanced settings** (branch, API version, description template) click the ⚙️ button at the bottom of the sidebar.

---

## Pipeline setup

### 1. Import pipelines into ADO
In ADO: Pipelines → New Pipeline → Azure Repos Git → select your repo → Existing YAML file → pick from `pipelines/`.

Repeat for each of the 5 files.

### 2. Set the service connection variable
Each pipeline expects an ADO **service connection** called `$(AZURE_SERVICE_CONNECTION)`.

To set it: Edit pipeline → Variables → Add variable:
- Name: `AZURE_SERVICE_CONNECTION`
- Value: your service connection name (e.g. `azure-prod`)
- Check: **Keep this value secret**

### 3. Note each pipeline's ID
After importing, open each pipeline. The URL will show `?definitionId=XX`. You can use a single pipeline ID in the portal and route tasks using the `paasService` parameter, or create one pipeline per task type.

### 4. Recommended: one pipeline per task type
Create 5 separate pipelines in ADO (one per YAML file). In the portal sidebar, each task button maps to its own pipeline ID. To support multiple pipeline IDs, fork `index.html` and update the `cfg.pid` lookup per task, or use the `PIPELINE_IDS` map pattern:

```javascript
const PIPELINE_IDS = {
  svcep:   '42',
  natgw:   '43',
  kvpol:   '44',
  rglck:   '45',
  paasnet: '46'
};
```

Then in `triggerPipeline()`, replace `cfg.pid` with `PIPELINE_IDS[activeTask]`.

---

## Security notes

- Store PATs in the browser only for development/personal use. For team deployments, back the portal with an Azure Function that holds the PAT server-side and calls ADO on behalf of the browser.
- Service connections in ADO should use a **Managed Identity** or a **service principal** with minimum required RBAC (e.g. `Network Contributor` for subnet tasks, `Key Vault Contributor` for access policies).
- Enable **pipeline approvals** in ADO for production environments: Pipelines → Environments → create an environment per env → add Approval check.

---

## Extending

To add a new task type:
1. Add an entry to the `TASKS` object in `index.html` (fields, cmd function, params function).
2. Add a `<button class="task-btn">` in the sidebar.
3. Create a new YAML file in `pipelines/`.
4. Import it into ADO and add its ID to `PIPELINE_IDS`.
