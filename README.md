# EHCP AI Drafting

An Azure-based, multi-agent solution that turns the professional advice documents used in the
**Education, Health and Care Plan (EHCP)** process into a **draft EHCP document**.

Case officers upload the source advice files (Personal Details, Education Advice, Health Advice,
Social Care Advice) in DOCX or PDF format. The solution extracts the text, structures it into JSON
against per-section schemas, validates and quality-checks the extraction, and then fills the
statutory EHCP DOCX template using a spreadsheet-driven field mapping. The result is a draft EHCP
that a human reviews and finalises â€” the system is a drafting assistant, **not** a decision maker.

---
**NOTE on Location** :- This solution uses swedencentral as AI resource region and Global standard deployment type which means data wil be stored in swedencentral but can be processed outside EU. Please choose the location carefully depending on your data residency and data processing requirements.

**NOTE on Deployment scripts** :- Please try running solution and deployment scripts only in a sandbox/test env.**(Not for Production use)**. We are working on hardening the solution with best practices and making azure deployment as simple as possible and will notify you once the repo is updated.

## Table of contents

- [Key capabilities](#key-capabilities)
- [Technical architecture](#technical-architecture)
- [Azure components used](#azure-components-used)
- [Repository layout](#repository-layout)
- [How the pipelines work](#how-the-pipelines-work)
- [Configuration reference](#configuration-reference)
- [Running locally](#running-locally)
- [API reference](#api-reference)
- [Customising the solution](#customising-the-solution)
- [Test cases](#test-cases)
- [Security, privacy and responsible AI](#security-privacy-and-responsible-ai)
- [Troubleshooting](#troubleshooting)

---

## Key capabilities

| Capability | Description |
|---|---|
| Multi-format ingest | DOCX and PDF advice documents |
| Automatic document typing | File name heuristics plus content-marker scoring classify each upload as Personal / Education / Health / Social Care advice |
| Structured extraction | Microsoft Foundry-hosted model deployments extract JSON that conforms to a per-section JSON schema |
| LLM + rule-based validation | An LLM validator scores extraction accuracy; a deterministic quality checker re-checks fields and computes completeness over critical fields |
| Template writing | The EHCP DOCX template is filled from the extracted JSON using an Excel mapping workbook |
| Writer validation | Deterministic checks compare the filled DOCX against the JSONs, the mapping workbook and (optionally) an expected output |
| Live progress | Server-sent events stream per-agent progress to the UI |
| Session isolation | Every browser session gets its own temp/output directory on the backend; downloads are scoped to the session |
| Auditability | Per-action and per-job records written to Azure Cosmos DB; token usage tracked per run |
| Enterprise auth | Optional Microsoft Entra ID sign-in (MSAL auth-code flow in the UI, JWT validation in the API) |
| Keyless operation | Managed-identity-first access to Foundry, Document Intelligence, Blob Storage and Cosmos DB; Key Vault only for secrets that cannot be eliminated |

---

## Technical architecture

```
                     â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
                     â”‚            Microsoft Entra ID                â”‚
                     â”‚  (frontend app reg + backend API app reg)    â”‚
                     â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                                     â”‚ OAuth2 auth-code flow / JWT
                                     â–¼
  Browser â”€â”€HTTPSâ”€â”€â–º  â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”   internal HTTPS   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
                      â”‚  Frontend Container App  â”‚ â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â–º â”‚  Backend Container App    â”‚
                      â”‚  Streamlit (port 8501)   â”‚  Authorization +   â”‚  FastAPI + Uvicorn (8000) â”‚
                      â”‚  external ingress        â”‚   X-Session-ID     â”‚  internal ingress         â”‚
                      â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜                    â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                                                                                â”‚
                        â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
                        â”‚                        â”‚                    â”‚                     â”‚                   â”‚
                        â–¼                        â–¼                    â–¼                     â–¼                   â–¼
              â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”  â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”  â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
              â”‚ Microsoft         â”‚   â”‚ Azure AI Document  â”‚  â”‚ Azure Blob    â”‚   â”‚ Azure Cosmos DB  â”‚  â”‚ Azure        â”‚
              â”‚ Foundry resource  â”‚   â”‚ Intelligence       â”‚  â”‚ Storage       â”‚   â”‚ (activity-logs,  â”‚  â”‚ Container    â”‚
              â”‚ + project model   â”‚   â”‚ prebuilt-layout    â”‚  â”‚ uploads +     â”‚   â”‚  job-logs)       â”‚  â”‚ Registry     â”‚
              â”‚ deployments       â”‚   â”‚ OCR / layout       â”‚  â”‚ outputs       â”‚   â”‚ audit trail      â”‚  â”‚ images       â”‚
              â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜   â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜  â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜   â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜  â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

### Application layers

1. **Presentation â€” Streamlit (`frontend/`)**
   Single-page app (`app.py`) for upload, document-type confirmation, live analysis progress,
   accuracy/completeness dashboards and draft download. `auth.py` implements the MSAL confidential
   client authorization-code flow. Streamlit runtime settings live in `.streamlit/config.toml`.

2. **API â€” FastAPI (`backend/main.py`, `backend/app/routers/pipeline.py`)**
   All routes are exposed under the `/api` prefix. CORS is enabled, requests carry an
   `X-Session-ID` header, and every route depends on `get_current_user` for authentication and
   audit attribution.

3. **Orchestration (`backend/app/services/orchestrator.py`)**
   `EHCPAgentOrchestrator` runs the reader pipeline per file (files are processed in parallel with
   `asyncio`) and the writer pipeline once per case. For determinism and cost control the
   orchestrator invokes the agents' tool functions directly rather than letting the model choose
   tools, while the agent definitions remain available for agent-driven execution.

4. **Agents (`backend/app/services/agents.py`)**
   Built on the **Microsoft Agent Framework (MAF)** â€” `agent_framework.Agent`, `@tool` functions
   and `agent_framework.openai.OpenAIChatCompletionClient` bound to a Microsoft Foundry-hosted model deployment.

5. **Helpers (`backend/app/services/helpers/`)**
   - `reader_helpers.py` â€” Document Intelligence and PyMuPDF/mammoth text extraction, LLM
     extraction calls, token tracking
   - `validation_helpers.py` â€” re-check rules and completeness scoring
   - `template_filler.py` â€” DOCX template population driven by `ehcp_mapping.xlsx`
   - `writer_validation.py` â€” deterministic post-write validation and JSON report building

6. **Platform services** â€” `blob_storage.py` (durable file storage), `audit_logger.py`
   (per-action logs), `job_logger.py` (one consolidated record per case), `settings.py`
   (configuration and credential helpers), `auth.py` (Entra ID JWT validation).

### Agents

| # | Agent | Tool | Purpose |
|---|---|---|---|
| 1 | `DocumentReaderAgent` | `read_document` | Extract raw text/layout from DOCX or PDF |
| 2 | `ExtractorAgent` | `extract_to_json` | Produce schema-conformant JSON with Microsoft Foundry |
| 3 | `ValidatorAgent` | `validate_extraction` | LLM comparison of JSON against source text, yields an accuracy percentage |
| 4 | `QualityCheckerAgent` | `recheck_validation` | Rule-based correction of false negatives plus completeness scoring |
| 5 | `TemplateWriterAgent` | `fill_template` | Fill the EHCP DOCX template from the four JSONs via the mapping workbook |
| 6 | `WriterValidatorAgent` | `validate_writer_output` | Deterministic validation of the filled DOCX and mapping coverage |

---

## Azure components used

| Azure service | Role in the solution | Where it is configured |
|---|---|---|
| **Microsoft Foundry resource + project** | Hosts the model deployment used for structured extraction and LLM validation. The backend calls the Foundry-hosted deployment through MAF's `OpenAIChatCompletionClient` and the `openai.AzureOpenAI` SDK using managed identity. | `FOUNDRY_*` in `backend/app/settings.py` |
| **Microsoft Agent Framework (MAF)** | The `agent-framework` Python package that defines agents, tools and the chat client abstraction used by every pipeline stage. | `backend/app/services/agents.py`, `backend/requirements.txt` |
| **Azure AI Document Intelligence** | `prebuilt-layout` model for OCR and layout-aware text/table extraction from scanned or complex PDFs and DOCX files. | `AZURE_DOCUMENT_INTELLIGENCE_*` |
| **Azure Blob Storage** | Optional durable store for uploaded source files and generated outputs so container replicas remain stateless and restart-safe. | `AZURE_STORAGE_*` |
| **Azure Cosmos DB (NoSQL)** | Audit trail. `activity-logs` container records individual user actions; `job-logs` records one document per case covering upload â†’ analyse â†’ create EHCP, including token usage and completeness. | `COSMOS_DB_*`, `AUDIT_LOG_ENABLED` |
| **Microsoft Entra ID** | Sign-in for the Streamlit app (MSAL confidential client) and JWT bearer validation for the FastAPI backend, using separate frontend and backend app registrations. | `ENTRA_*`, `AUTH_ENABLED` |
| **Azure Container Registry (ACR)** | Stores the `ehcp-backend` and `ehcp-frontend` container images. | `build-push.ps1` |
| **Azure Key Vault** | Stores secrets that cannot be eliminated from the design, notably the frontend MSAL confidential-client secret. The frontend reads them at runtime using its managed identity. | `frontend/auth.py`, `deploy-infrastructure 1.ps1` |
| **Azure Container Apps (ACA)** | Hosts both containers in one managed environment: frontend with external ingress, backend with internal-only ingress; both apps use system-assigned managed identities and ACR pull via managed identity. | `deploy-aca.ps1` |
| **Managed Identity** | Default authentication path for Foundry, Document Intelligence, Blob Storage, Cosmos DB, ACR pulls, and Key Vault access. `AZURE_CLIENT_ID` remains optional for explicit user-assigned identity selection when needed. | `backend/app/settings.py`, `frontend/auth.py` |

---

## Repository layout

```
.
â”œâ”€â”€ backend/
â”‚   â”œâ”€â”€ main.py                       # FastAPI application entry point
â”‚   â”œâ”€â”€ Dockerfile                    # Python 3.11-slim backend image
â”‚   â”œâ”€â”€ requirements.txt
â”‚   â”œâ”€â”€ .env.example                  # Backend configuration template
â”‚   â”œâ”€â”€ EHCP_LCC_Template.docx        # Statutory EHCP output template
â”‚   â”œâ”€â”€ ehcp_mapping.xlsx             # JSON field â†’ template placeholder mapping
â”‚   â”œâ”€â”€ prompts/                      # Per-section extraction + validation prompts
â”‚   â”œâ”€â”€ schemas/                      # Per-section JSON schemas
â”‚   â””â”€â”€ app/
â”‚       â”œâ”€â”€ settings.py               # Env config + credential helpers
â”‚       â”œâ”€â”€ auth.py                   # Entra ID JWT validation
â”‚       â”œâ”€â”€ dependencies.py           # Ensures temp/ and output/ exist
â”‚       â”œâ”€â”€ models/schemas.py         # Pydantic request/response models
â”‚       â”œâ”€â”€ routers/pipeline.py       # All /api routes
â”‚       â””â”€â”€ services/
â”‚           â”œâ”€â”€ agents.py             # MAF agents + tools
â”‚           â”œâ”€â”€ orchestrator.py       # Reader and writer pipelines
â”‚           â”œâ”€â”€ blob_storage.py       # Azure Blob Storage helpers
â”‚           â”œâ”€â”€ audit_logger.py       # Cosmos DB action logging
â”‚           â”œâ”€â”€ job_logger.py         # Cosmos DB job-level logging
â”‚           â””â”€â”€ helpers/              # Extraction, validation, template filling
â”œâ”€â”€ frontend/
â”‚   â”œâ”€â”€ app.py                        # Streamlit UI
â”‚   â”œâ”€â”€ auth.py                       # MSAL auth-code flow
â”‚   â”œâ”€â”€ Dockerfile                    # Streamlit image
â”‚   â”œâ”€â”€ requirements.txt
â”‚   â””â”€â”€ .streamlit/config.toml
â”œâ”€â”€ Test Cases/                       # Sample inputs, blank templates, expected outputs
â”œâ”€â”€ build-push.ps1                    # Build + push both images to ACR
â””â”€â”€ deploy-aca.ps1                    # Create/update both Azure Container Apps
```

---

## How the pipelines work

### Reader pipeline (per uploaded file, run in parallel)

1. **Upload** â€” `POST /api/upload` saves files into a session-scoped temp directory, optionally
   mirrors them to Blob Storage, auto-detects the document type (file name heuristics first, then
   content-marker scoring on the first ~5000 characters) and records the upload in the job log.
2. **Read** â€” text and layout are extracted with Azure AI Document Intelligence
   (`prebuilt-layout`), with PyMuPDF/mammoth used for direct text extraction where appropriate.
   The extracted text is written to `<name>_doctext.txt`.
3. **Extract** â€” the per-type prompt (`prompts/*.txt`) and JSON schema (`schemas/*.json`) are sent
   to the Foundry-hosted model deployment; the structured result is written to `<name>_output.json`.
4. **Validate** â€” `prompts/validation_prompt.txt` asks the model to compare the JSON with the
   source text and return field-level correctness plus an `accuracy_percentage`.
5. **Quality check** â€” deterministic re-check rules correct known false negatives, and
   completeness is computed over the critical fields for that document type. The validation JSON is
   overwritten with the final accuracy, completeness and missing-field details.

Progress for every stage is streamed to the UI through `POST /api/analyze-stream` (SSE).

### Writer pipeline (once per case)

1. **Fill template** â€” `fill_template` loads `EHCP_LCC_Template.docx` and the `ehcp_mapping.xlsx`
   workbook, resolves each mapped JSON path from the four section JSONs, and writes the completed
   DOCX to the session output directory.
2. **Validate output** â€” `validate_writer_output` re-opens the DOCX, validates each section JSON,
   checks the mapping workbook headers and per-sheet mappings, optionally compares against an
   expected output document, and emits a JSON validation report with a check summary.
3. **Download** â€” the draft is retrieved with `GET /api/results/{filename}`, restricted to the
   requesting session.

---

## Configuration reference

### Backend (`backend/.env`, template in `backend/.env.example`)

| Variable | Default | Description |
|---|---|---|
| `AZURE_CLIENT_ID` | â€“ | Optional client ID when you must target a **user-assigned** managed identity explicitly |
| `FOUNDRY_ENDPOINT` | â€“ | Foundry-backed model endpoint, e.g. `https://<resource>.openai.azure.com/` |
| `FOUNDRY_PROJECT_NAME` | â€“ | Foundry project name used to organise the deployment |
| `FOUNDRY_MODEL_NAME` | â€“ | Deployed model name used by the app |
| `FOUNDRY_API_VERSION` | `2025-04-01-preview` | API version for the Foundry-backed OpenAI-compatible endpoint |
| `MODEL_TEMPERATURE` | `0` | Deterministic extraction is recommended |
| `MODEL_MAX_TOKENS` | `30` | Token cap for the short auxiliary completion used to infer the child's name; extraction and validation calls are not capped by this value |
| `AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT` | â€“ | Document Intelligence endpoint |
| `AZURE_STORAGE_ACCOUNT_URL` | â€“ | Blob account URL used with managed identity |
| `AZURE_STORAGE_CONTAINER_NAME` | `ehcp-outputs` | Blob container name |
| `AUDIT_LOG_ENABLED` | `false` | Enable Cosmos DB audit and job logging |
| `COSMOS_DB_ENDPOINT` | â€“ | e.g. `https://<account>.documents.azure.com:443/` |
| `COSMOS_DB_DATABASE` | `ehcp-audit` | Database name |
| `COSMOS_DB_CONTAINER` | `activity-logs` | Per-action audit container |
| `COSMOS_DB_JOB_CONTAINER` | `job-logs` | Per-case job record container |
| `AUTH_ENABLED` | `false` | Enforce Entra ID JWT validation on the API |
| `ENTRA_TENANT_ID` | â€“ | Directory (tenant) ID |
| `ENTRA_CLIENT_ID` | â€“ | Backend API app registration client ID |
| `BACKEND_HOST` / `BACKEND_PORT` / `BACKEND_WORKERS` | `0.0.0.0` / `8000` / `4` | Uvicorn settings |

### Frontend (`frontend/.env`)

| Variable | Default | Description |
|---|---|---|
| `BACKEND_URL` | `http://localhost:8000` | Backend base URL (injected automatically by `deploy-aca.ps1`) |
| `ENV` | â€“ | Free-form environment label shown in the UI |
| `DEBUG_MODE` | `false` | Expose intermediate JSON/validation downloads |
| `AUTH_ENABLED` | `false` | Enable MSAL sign-in |
| `ENTRA_TENANT_ID` | â€“ | Directory (tenant) ID |
| `ENTRA_FRONTEND_CLIENT_ID` | falls back to `ENTRA_CLIENT_ID` | Frontend app registration |
| `ENTRA_BACKEND_CLIENT_ID` | falls back to `ENTRA_CLIENT_ID` | Backend API app registration (audience) |
| `AZURE_KEY_VAULT_URL` | â€“ | Key Vault URL used by the frontend to read residual secrets at runtime |
| `ENTRA_CLIENT_SECRET_SECRET_NAME` | â€“ | Secret name in Key Vault that stores the frontend app-registration secret |
| `ENTRA_SCOPE` | `api://<backend-client-id>/user_impersonation` | Scope requested for the backend API |
| `ENTRA_REDIRECT_URI` | `FRONTEND_URL` or `http://localhost:8501` | Must match the app registration redirect URI |

> Never commit `.env` files. `.gitignore` already excludes them, and `deploy-aca.ps1` injects
> values at runtime rather than baking them into images.

---

## Running locally

### Prerequisites

- Python 3.11
- Docker (optional, for container parity)
- Azure CLI (`az`) if you plan to deploy
- Provisioned Microsoft Foundry and Document Intelligence resources (Blob Storage, Cosmos DB and
  Entra ID are optional)

### 1. Backend

```bash
cd backend
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
cp .env.example .env             # then fill in your endpoints, resource URLs and deployment names
uvicorn main:app --reload --port 8000
```

Open http://localhost:8000/docs for the interactive OpenAPI documentation and
http://localhost:8000/api/health for a health check.

### 2. Frontend

```bash
cd frontend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
# create .env with at least: BACKEND_URL=http://localhost:8000
streamlit run app.py
```

The UI is served at http://localhost:8501.

### 3. Run with Docker

```bash
docker build -t ehcp-backend ./backend
docker run --env-file backend/.env -p 8000:8000 ehcp-backend

docker build -t ehcp-frontend ./frontend
docker run --env-file frontend/.env -e BACKEND_URL=http://host.docker.internal:8000 -p 8501:8501 ehcp-frontend
```

### 4. Run the local Playwright end-to-end test

The repository includes an offline fixture mode for the backend so the full browser flow can be
tested locally without calling Azure services. The Playwright test uploads the synthetic sample
documents from `Test Cases/Simple Case Inputs/`, runs **Read and Analyse**, creates the draft EHCP
from the repository template, and asserts that the generated DOCX contains the expected child and
school details.

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\Activate.ps1
pip install -r backend/requirements.txt
pip install -r frontend/requirements.txt
pip install -r requirements-dev.txt
python -m playwright install chromium
python -m unittest tests.e2e.test_ehcp_draft_flow
```

---
## API reference

All routes are prefixed with `/api`. Requests should include an `X-Session-ID` header (and an
`Authorization` header carrying the Entra ID access credential when `AUTH_ENABLED=true`).

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness probe |
| `GET` | `/doc-types` | Supported document types |
| `GET` | `/mapping-fields` | Output field definitions from the mapping workbook |
| `POST` | `/upload` | Upload advice documents; returns detected document types |
| `POST` | `/analyze` | Run the reader pipeline and return results |
| `POST` | `/analyze-stream` | Run the reader pipeline with SSE progress events |
| `POST` | `/write-ehcp` | Fill the EHCP template and validate the output |
| `GET` | `/results/{filename}` | Download a session-scoped result file |
| `GET` | `/download/{filepath}` | Download a file by relative path |
| `DELETE` | `/files/{filename}` | Remove an uploaded file from the session |
| `POST` | `/log-browse`, `/log-activity` | Client-side audit events |

Interactive documentation is available at `/docs` on the backend.

---

## Customising the solution

- **Different EHCP template** â€” replace `backend/EHCP_LCC_Template.docx` and update the
  placeholder references in `backend/ehcp_mapping.xlsx`. The mapping workbook holds one sheet per
  section, mapping JSON paths to template fields, so most layout changes need no code edits.
- **New or changed fields** â€” update the relevant `backend/schemas/*_schema.json` and the matching
  `backend/prompts/*_prompt.txt`, then add the field to the mapping workbook.
- **New document type** â€” add a prompt, a schema, an entry in `DOC_TYPE_MAP`, content markers in
  `_CONTENT_MARKERS` (both in `backend/app/routers/pipeline.py`), and a mapping sheet.
- **Model choice** â€” change `FOUNDRY_MODEL_NAME`; keep `MODEL_TEMPERATURE=0` for reproducible
  extraction.
- **Validation strictness** â€” tune the re-check rules and critical-field lists in
  `backend/app/services/helpers/validation_helpers.py`.

---

## Test cases

`Test Cases/` contains fully synthetic material for end-to-end verification:

- `Simple Case Inputs/` and `Complex Case Inputs/` â€” sample advice documents (DOCX and PDF)
- `Blank Templates/` â€” the empty advice forms and the EHCP output template
- `Simple Case Output/` and `Complex Case Output/` â€” reference draft EHCP outputs

Use them to validate a new deployment and to benchmark accuracy/completeness after prompt, schema
or model changes. No real personal data is included.

---

## Security, privacy and responsible AI

- **Human in the loop.** Output is a *draft*. A qualified professional must review, edit and
  approve every plan before it is issued.
- **Sensitive data.** Inputs contain special-category personal data about children. Deploy into a
  tenant and region that meet your organisation's data-residency and DPIA requirements, restrict
  network access, and set retention/lifecycle policies on the blob container and Cosmos DB
  containers.
- **Secrets.** No secrets are committed. Managed identity is the default runtime authentication
  path. If a secret cannot be eliminated, store it in Azure Key Vault and retrieve it via managed
  identity instead of keeping the value in application environment variables.
- **Authentication.** Enable `AUTH_ENABLED=true` in any non-local environment so the API validates
  Entra ID JWTs (signature, audience, issuer and expiry).
- **Network isolation.** The backend is deployed with internal-only ingress; only the frontend is
  publicly reachable. Consider tightening the backend CORS policy in `backend/main.py` from `*` to
  the frontend origin.
- **Session isolation.** Uploads and outputs are written to per-session directories, and result
  downloads are restricted to the owning session.
- **Auditability.** With `AUDIT_LOG_ENABLED=true`, every user action and a consolidated per-case
  job record (including token usage, accuracy and completeness) are persisted to Cosmos DB.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `401 Invalid token audience` | Backend `ENTRA_CLIENT_ID` does not match the audience of the token; check `ENTRA_SCOPE` on the frontend |
| `AZURE_STORAGE_ACCOUNT_URL is not set` | Blob storage is enabled in the deployment design but the storage account URL is missing |
| Empty or partial extraction | Check the Document Intelligence endpoint and RBAC, verify the Foundry deployment is reachable with managed identity, and inspect the `_doctext.txt` artefact |
| Low completeness scores | The source advice document is genuinely missing critical fields â€” review `critical_fields_missing` in the validation JSON |
| Rate-limit / 429 errors from Foundry model inference | Increase the deployment's TPM quota; files are processed in parallel |
| Frontend cannot reach backend | Confirm `BACKEND_URL`; in ACA the backend uses internal ingress and is only reachable from within the environment |
| Sign-in redirect loop | The deployed frontend URL must be registered as a redirect URI and set via `ENTRA_REDIRECT_URI` |
