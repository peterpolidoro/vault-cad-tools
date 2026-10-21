# Autodesk Vault + Inventor without the GUIs: a Linux-driven STEP round trip

**Findings as of 2026-10-21.** Everything marked *verified* below was checked directly
against the Vault server `svault5` and the software installed on the Windows workstation.
Everything else is from Autodesk documentation or community sources (links at the end).

---

## 1. Summary

- **Yes, there is a REST interface, and it is already running on our Vault server.**
  Autodesk's *Vault Data API* (REST, JSON) is served by `svault5`. On our Vault 2025
  server it covers authentication, search, browsing, downloads, dependency traversal and
  **queuing Job Processor jobs**. It does **not** yet offer upload or check-in; those
  endpoints only exist from Vault 2027.2 (Beta).
- **The full-featured SOAP web services are also exposed** by `svault5` and can be called
  from Linux (e.g. Python + zeep). They cover checkout, upload and check-in.
- **Inventor -> STEP has to run on Windows** (or in Autodesk's cloud). Inventor files are
  proprietary; no open-source tool reads them. Our Vault 2025 Job Processor already has
  built-in job types `Autodesk.Vault.STEP.Create.ipt` and `Autodesk.Vault.STEP.Create.iam`
  that do the conversion and store the STEP in Vault.
- **No Vault MCP server exists** (official or community). Several community *Inventor* MCP
  servers exist, but they are Windows-only, stdio-based and drive a live Inventor session
  over COM; they suit interactive modeling more than a batch pipeline.
- **Recommended design:** Linux talks REST to find/download files and to queue the STEP
  job; a Windows Job Processor with Inventor 2025 converts; Linux downloads the STEP,
  edits it with open-source tools, and checks it back in via SOAP (or via a small bridge
  on the Windows box).

---

## 2. Environment (verified)

| Item | Value |
|---|---|
| Windows workstation | Inventor 2025 (also Inventor 2023), Vault Client 2025 (includes Job Processor) |
| Vault server | `svault5`, Vault Professional Server **30.4.28.0** (= Vault 2025.x) |
| Vaults | one vault: **IDF VAULT**, id **28** |
| REST base URL | `http://svault5/AutodeskDM/Services/api/vault/v2/` (API version 2.0.16) |
| REST OpenAPI spec | `http://svault5/AutodeskDM/Services/api/vault/v2/openapi-spec.yml` (183 KB, no auth) |
| SOAP WSDLs | `http://svault5/AutodeskDM/Services/v30/*.svc?wsdl` (v28 and v29 also answer) |
| Transport | plain **HTTP**, no TLS (see caveats) |

Unauthenticated sanity checks that work today:

```bash
curl -s http://svault5/AutodeskDM/Services/api/vault/v2/server-info
# {"name":"Vault Professional Server","productVersion":"30.4.28.0"}

curl -s http://svault5/AutodeskDM/Services/api/vault/v2/vaults
# {"pagination":{...},"results":[{"id":"28","name":"IDF VAULT",...}]}
```

---

## 3. Interface inventory

### 3.1 Vault Data API (REST)

Official Autodesk API, available from Vault Server 2025.2 onward. Base URL pattern:
`http(s)://<server>/AutodeskDM/Services/api/vault/v2/`. Responses are JSON with a
`pagination` object (`limit`, `totalResults`, `cursorState` for paging) and a `results`
array.

**Authentication** (three options)

1. Vault account: `POST /sessions`

   ```bash
   curl -s -X POST http://svault5/AutodeskDM/Services/api/vault/v2/sessions \
     -H 'Content-Type: application/json' \
     -d '{"input":{"vault":"IDF VAULT","userName":"USER","password":"PASS","appCode":"linux-step"}}'
   ```

   Response contains `id`, `accessToken` (looks like `V:<guid>`), `vaultInformation`
   (incl. vault id) and `userInformation`. `appCode` is free text for the server audit log.
2. Windows account: `POST /sessions/win-auth` with `{"input":{"vault":"IDF VAULT","appCode":"..."}}`
   (uses the caller's Windows identity; useful from the Windows box).
3. Autodesk ID: an APS 3-legged OAuth token (PKCE flow with an APS app of type
   "Desktop, Mobile, Single-Page App"). Requires Autodesk Account Mapping on the server.
   Not needed for our use.

Send the token on every call: `Authorization: Bearer V:...`. Log out with
`DELETE /sessions/{id}`.

**Endpoints present on svault5 (verified from the served spec)**

| Area | Method and path |
|---|---|
| Info | `GET /server-info`, `GET /openapi-spec.yml` |
| Auth | `POST /sessions`, `POST /sessions/win-auth`, `GET/DELETE /sessions/{id}` |
| Accounts | `GET /users`, `/users/{id}`, `/users/{id}/accounts`, `/groups`, `/groups/{id}`, `/roles`, `/roles/{id}`, `/profile-attribute-definitions` |
| Options | `GET/POST /system-options`, `GET/PATCH/DELETE /system-options/{id}`; same under `/vaults/{vaultId}/vault-options` |
| Vaults | `GET /vaults`, `GET /vaults/{id}` |
| Folders | `GET /vaults/{v}/folders/{id}`, `/folders/{id}/contents`, `/folders/{id}/sub-folders` (`id` may be the keyword `root`) |
| Files | `GET /vaults/{v}/files/{id}` (master id), `/files/{id}/versions`, `/files/{id}/change-orders` |
| File versions | `GET /vaults/{v}/file-versions` (filters), `/file-versions/{id}`, `/content` (download, supports `Range`), `/signedurl`, `/thumbnail`, `/uses` (dependencies + attachments), `/parents` (where used), `/item-versions`, `/markups`, `/visualization-attachments`, `/svf/bubble.json` |
| Items / BOM | `GET /vaults/{v}/items`, `/items/{id}`, `/items/{id}/versions`, `/item-versions`, `/item-versions/{id}/bill-of-materials`, `/associated-files`, `/parents`, `/thumbnail` |
| Change orders | `GET /vaults/{v}/change-orders`, `/{id}`, `/{id}/all-related-files`, `/{id}/associated-entities`, `/{id}/comments`, comment attachments |
| Links | `GET /vaults/{v}/links`, `/links/{id}` |
| Search | `GET /vaults/{v}/search-results?q=...`, `POST /vaults/{v}:advanced-search` |
| **Jobs** | **`POST /vaults/{v}/jobs`** (queue a job), `GET /vaults/{v}/jobs/{id}`, `GET /vaults/{v}/jobs/job-queue-enabled` |

**Not present on our version** (added in Vault 2027.2 as Beta): file upload
(`Create File Upload` / `Upload File Content Part` / `Complete File Upload`), `Add File`,
`Check Out File`, `Undo File Checkout`, `Check In File`, property/category updates,
custom attributes, folder creation. So on Vault 2025, REST is read-only for files, plus the
job queue.

**Useful query options**

- Search: `q=<text>`, `option[latestOnly]`, `option[releasedFilesOnly]`,
  `option[searchSubFolders]`, `option[searchContent]`, `sort=Name asc`, `limit`, `cursorState`.
- File versions list: `filter[State]=Released`, `filter[CategoryName]=...`,
  `filter[CheckoutUserName]=...`, `filter[CreateUserName]=...`.
- Dependencies: `GET /file-versions/{id}/uses?option[recurse]=true` walks the whole
  assembly tree; `option[includeHidden]`, `option[releaseBiased]`, `option[releasedOnly]`,
  `option[getLatestAssocs]` are available.
- ID semantics: `files/{id}` is the **master** id shared by all versions;
  `file-versions/{id}` is one specific version (iteration).

**Job object** (`POST /vaults/{v}/jobs` body and `GET` response):
`jobType` (string), `priority` (number, lower runs first), `description`,
`params` (string-to-string map), `status` in `Ready | Running | Success | Failure`, `id`.

### 3.2 SOAP web services (verified reachable)

The original Vault API (what the .NET SDK wraps) is WCF/SOAP over HTTP. On `svault5` these
WSDLs answer with HTTP 200:

- `http://svault5/AutodeskDM/Services/v30/DocumentService.svc?wsdl` (files, folders, checkout/check-in)
- `http://svault5/AutodeskDM/Services/v30/JobService.svc?wsdl` (job queue)
- `http://svault5/AutodeskDM/Services/Filestore/v30/FilestoreService.svc?wsdl` (chunked upload/download)
- `v28` and `v29` variants also answer (backward compatibility for older clients).
  Other services (security/auth, Item, Property, DocumentServiceExtensions, ...) follow
  the same `/AutodeskDM/Services/v30/<Name>.svc` pattern; directory listing is disabled
  (403) so discover names from the Vault SDK documentation.

Why it matters: SOAP has everything REST lacks on our version, in particular
checkout -> upload -> check-in. Method names to look for in the WSDL/SDK docs:
`CheckoutFile`, `UploadFilePart` (Filestore), `CheckinUploadedFile`, `AddUploadedFile`,
`UndoCheckoutFile`, `GetLatestFileByMasterId`, and `AddJob` on JobService.

Calling it from Linux: Python `zeep` works. The pattern seen in Autodesk forums is: sign in
once, take the returned security token/header, then attach it as a SOAP/HTTP header on
every client created from the WSDL URLs. Expect to spend time on the sign-in header
details; the Vault SDK docs (installed with the SDK on Windows) are the method reference.

### 3.3 Job Processor (verified from the installed client)

`C:\Program Files\Autodesk\Vault Client 2025\Explorer\JobProcessor.exe.config` registers
these built-in job types:

| Job type | Handler |
|---|---|
| `Autodesk.Vault.STEP.Create.ipt`, `Autodesk.Vault.STEP.Create.iam` | `Connectivity.Explorer.JobHandlerStepPublish.StepJobHandler` |
| `Autodesk.Vault.DXF.Create.ipt`, `.idw`, `.dwg` | `DxfJobHandler` |
| `Autodesk.Vault.PDF.Create.idw`, `.dwg` | `PdfJobHandler` |
| `Autodesk.Vault.DWF.Create.ipt`, `.iam`, `.ipn` | `DwfJobHandler` |

The same config queues STEP jobs automatically after property sync for `.ipt`/`.iam`
(`queueStepCreateJob`), which is how the "export STEP on lifecycle transition" feature in
Vault 2024+ works. Export options are stored as vault settings (strings
`PublishSTEPOption` / `PublishOptionXml` appear in `Connectivity.Services.Job.dll`), i.e.
the output folder / save-to-Vault behavior is configured by a Vault administrator in the
export settings, not per job.

Requirements for the STEP job to run:

- A Windows machine running the **Vault Job Processor** (part of Vault Client 2025),
  logged into IDF VAULT, with **Inventor 2025 installed and licensed**.
- STEP job types enabled on that processor (Job Processor > Administration > Job Types).
- `GET /vaults/28/jobs/job-queue-enabled` must return true (server-side queue enabled).

Job parameters for the built-in jobs are **not documented** by Autodesk. Strings found in
the job library include `FileMasterId` and `FileVersionId`; community examples for other
built-in jobs use `EntityClassId=FILE` plus `EntityId=<file id>`. **Confirm before
scripting:** trigger one STEP export manually in Vault Explorer, note the job id in the
Job Queue, and read the exact `params` with `GET /vaults/28/jobs/{id}`.

### 3.4 MCP servers

- **Vault:** none found, official or community. Writing one is straightforward because the
  OpenAPI spec is served by the server; it would be a thin wrapper over section 3.1.
- **Inventor (community, Windows-only, stdio, COM against a running Inventor):**
  - bimwright/ipt-mcp: ~58 tools incl. `inventor_open_document` and `inventor_export_step`;
    Inventor 2022-2027; C#/.NET; local only (loopback TCP / named pipes).
  - NeonGlay/inventor-mcp (fork SambaAnte/inventor-mcp): 34 tools plus a "run arbitrary
    Python against the COM connection" escape hatch.
  - hsavas/inventor-mcp, effectustasi/autodesk-inventor-mcp, tylerwarner33/autodesk-inventor-mcp,
    Modern-CAD/inventor-ai-mcp-server (.NET 8, 470+ tools).
  - To reach any of them from Linux you would wrap stdio in an HTTP/SSE bridge
    (e.g. `mcp-proxy` or `supergateway`) on the Windows box. They need an interactive,
    licensed Inventor session, so they are not a server-side batch solution.

### 3.5 Cloud alternative: Autodesk Platform Services (APS) Model Derivative

Translates Inventor 2025 `.ipt`/`.iam` to STEP without any Windows machine. Costs APS
cloud credits per translation, uploads our design data to Autodesk's cloud, and assemblies
must be uploaded as a zip with a `rootFilename`. Check `GET /modelderivative/v2/designdata/formats`
for the live format matrix. Not recommended as the primary path given the on-prem options.

---

## 4. Recommended pipeline (Linux-driven)

```
Linux                          svault5 (Vault 2025)             Windows Job Processor + Inventor 2025
-----                          --------------------             -------------------------------------
1. POST /sessions  ----------> token
2. search / browse ----------> file + version ids
3. GET .../uses?recurse -----> dependency tree (for assemblies)
4. GET .../content ----------> download .iam/.ipt (optional, for reference)
5. POST /jobs STEP.Create ---> job queued ----------------------> picks job, opens in Inventor,
                                                                  exports STEP, saves into Vault
6. GET /jobs/{id} until Success
7. search for the new .stp ---> GET .../content --> download STEP
8. edit STEP with FreeCAD / CadQuery / OpenCascade
9. check STEP back in: SOAP (CheckoutFile -> UploadFilePart -> CheckinUploadedFile)
   or a Windows-side bridge (section 5)
```

Example calls (vault id 28; `--globoff` keeps curl from interpreting `[ ]`):

```bash
TOKEN='V:...'   # from POST /sessions
B=http://svault5/AutodeskDM/Services/api/vault/v2

# Browse the root folder
curl -s --globoff -H "Authorization: Bearer $TOKEN" "$B/vaults/28/folders/root/contents"

# Search latest versions by text
curl -s --globoff -H "Authorization: Bearer $TOKEN" \
  "$B/vaults/28/search-results?q=bracket&option[latestOnly]=true&limit=50"

# Dependencies of an assembly version
curl -s --globoff -H "Authorization: Bearer $TOKEN" \
  "$B/vaults/28/file-versions/<fileVersionId>/uses?option[recurse]=true"

# Download a file version
curl -s -H "Authorization: Bearer $TOKEN" \
  "$B/vaults/28/file-versions/<fileVersionId>/content" -o part.ipt

# Queue a STEP export (params MUST be confirmed first, see 3.3)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "$B/vaults/28/jobs" \
  -d '{"jobType":"Autodesk.Vault.STEP.Create.iam","description":"STEP export","priority":10,
       "params":{"EntityClassId":"FILE","EntityId":"<fileId>"}}'

# Poll
curl -s -H "Authorization: Bearer $TOKEN" "$B/vaults/28/jobs/<jobId>"
```

---

## 5. Getting a STEP back into Vault (check-in) on Vault 2025

| Option | Where it runs | Notes |
|---|---|---|
| SOAP web services | Linux (Python + zeep) | Full capability, no Windows involvement. Most implementation effort (sign-in headers, chunked upload). |
| Windows bridge via SSH | Windows workstation | Install OpenSSH Server on the box; from Linux run `ssh box powershell -File checkin.ps1 <file>`. Script uses the Vault SDK (`FileManager.AcquireFiles` / `FileManager.CheckinFile`) or coolOrange **powerVault** PowerShell cmdlets (free module; verify license terms). Least code, but the Windows box must be on. |
| Wait for REST write endpoints | Linux | Needs a server upgrade to Vault 2027.2+; endpoints are Beta there. |

Behavioral notes: a STEP produced by the job is a separate Vault file (stored per the
export settings, possibly attached/linked to the source). Checking in an edited STEP means
checkout -> new version -> check-in of **that** file; nothing flows back into the Inventor
model. Files in a released/locked lifecycle state refuse checkout.

---

## 6. Open items to verify before building

1. Exact `params` for `Autodesk.Vault.STEP.Create.*` (read a manually queued job via
   `GET /jobs/{id}`).
2. Whether a Job Processor with Inventor is already running for IDF VAULT, and whether STEP
   job types are enabled on it. If not, run one on this workstation.
3. Where the export settings put the STEP (Vault folder vs local folder) and whether it is
   attached to the source file.
4. Whether HTTPS can be enabled on `svault5` (or a Vault Gateway used). Today credentials
   travel in clear text on the LAN.
5. Lifecycle/permission rules for the account that will do automated check-ins.

---

## 7. Caveats and risks

- Queuing Autodesk's built-in jobs through the API is possible but **not an officially
  documented procedure**; parameter names may change between releases.
- Built-in STEP export uses only the **primary model state** (community report).
- Built-in export jobs all share default priority 10 and run in creation order behind
  DWF/PDF/DXF jobs; a dedicated Job Processor avoids delays.
- One-way trip: STEP edits never update the Inventor source.
- Plain HTTP on `svault5`.
- The REST API does not expose every SDK/SOAP capability yet; Autodesk says more endpoints
  are coming and still recommends the SDK for Job Processor extensions and add-ins.

---

## 8. How this was verified (2026-10-21, from the Windows workstation)

- Listed `C:\Program Files\Autodesk` -> Inventor 2023, Inventor 2025, Vault Client 2025.
- `%APPDATA%\Autodesk\VaultCommon\Servers` -> server name `svault5`.
- `GET http://svault5/AutodeskDM/Services/api/vault/v2/server-info` -> 30.4.28.0.
- `GET .../vaults` -> IDF VAULT, id 28.
- Downloaded `openapi-spec.yml` (v2.0.16) and enumerated every path/method (table in 3.1).
- Probed `/AutodeskDM/Services/v{25..32}/{DocumentService,JobService}.svc?wsdl` and
  `/Filestore/v{..}/FilestoreService.svc?wsdl` -> v28, v29, v30 answer 200.
- Read `JobProcessor.exe.config` and string-scanned `Connectivity.Services.Job.dll` for
  job type and parameter names.

---

## 9. Sources

- Vault Data API overview: https://aps.autodesk.com/en/docs/vaultdataapi/v2/developers_guide/overview/
- Vault Data API authentication: https://aps.autodesk.com/en/docs/vaultdataapi/v2/developers_guide/basics/authentication/
- Vault Data API changelog: https://aps.autodesk.com/en/docs/vaultdataapi/v2/change_history/changelog
- Vault Data API samples (GitHub): https://github.com/autodesk-platform-services/vault-data-api-samples
- Autodesk blog, "A Modern Approach to Vault Integration Using Rest APIs": https://blog.autodesk.io/a-modern-approach-to-vault-integration-using-rest-apis/
- WIIP, Vault Data API walkthrough: https://wiip.fr/en/blog/vault-data-api
- Autodesk blog, Vault SDK Getting Started #3 - Custom Job: https://www.autodesk.com/blogs/design-and-manufacturing/2024/04/02/autodesk-vault-sdk-getting-started-3-custom-job/
- Symetri, What's new in Vault Professional 2024 (STEP/DXF export jobs): https://symetri.co.uk/insights/blog/what-s-new-autodesk-vault-professional-2024
- Autodesk forum, adding default jobs to the queue: https://forums.autodesk.com/t5/vault-customization-forum/how-to-add-an-existing-job-to-jobprocessor/td-p/12435473
- Autodesk forum, Vault and Python (zeep): https://forums.autodesk.com/t5/vault-customization-forum/vault-and-python/m-p/9498113
- Autodesk forum, SDK checkout/check-in: https://forums.autodesk.com/t5/vault-customization-forum/vault-api-check-out-and-check-in-issue/td-p/12533654
- IMAGINiT, Job Processor priorities for STP/DXF: https://resources.imaginit.com/support-blog/how-to-control-what-job-processor-makes-stp-and-dxf-files
- AU class MFG468044, Hack the Vault Job Processor: https://static.au-uw2-prd.autodesk.com/Class_Handout_MFG468044_Thomas_Rambach.pdf
- Model Derivative changelog (Inventor 2025 -> STEP): https://aps.autodesk.com/en/docs/model-derivative/v2/change_history
- Model Derivative supported translations: https://aps.autodesk.com/en/docs/model-derivative/v2/developers_guide/supported-translations
- Inventor MCP servers: https://github.com/bimwright/ipt-mcp , https://github.com/NeonGlay/inventor-mcp , https://github.com/hsavas/inventor-mcp , https://github.com/effectustasi/autodesk-inventor-mcp , https://github.com/tylerwarner33/autodesk-inventor-mcp , https://github.com/Modern-CAD/inventor-ai-mcp-server
- coolOrange powerJobs sample jobs (STEP export reference): https://doc.coolorange.com/projects/powerjobsprocessor/en/stable/jobprocessor/jobs/sample_jobs/
