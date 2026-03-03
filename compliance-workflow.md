# Compliance Workflow: Runtime Image Chain of Custody

This document describes the steps a compliance analyst would follow to validate the chain of custody for container images — from running workloads in JFrog Runtime all the way back to the CI/CD build that produced them.

## Overview

The chain of custody follows this path:

```
Runtime Cluster → Running Image → Artifactory Artifact → Build Info → CI/CD Source
```

Each step links to the next via image digests (SHA256), tags, and build metadata.

---

## Step 1: Enumerate Runtime Clusters

**Purpose:** Identify all monitored Kubernetes clusters and their health status.

**MCP Tool:** `jfrog_list_runtime_clusters`

**REST API (fallback):**
```
POST /runtime/api/v1/clusters
Content-Type: application/json

{ "limit": 50 }
```

**REST API — Get specific cluster detail (includes nodes):**
```
GET /runtime/api/v1/cluster/{id}
```

**Key fields to record:**
- Cluster ID, name, and status (`running` / `stopped`)
- Provider and region
- Controller version and last-updated timestamp
- Node counts (total, running, failed)

**Example output (current environment):**

| Cluster | ID | Status | Region | Nodes |
|---|---|---|---|---|
| cluster-one | 1 | stopped | — | 0/0 |
| cluster-two | 2 | running | us-west-2 | 1/3 |
| tomj-lab-cluster | 3 | running | us-east-2 | 2/2 |

---

## Step 2: List Running Images Across Clusters

**Purpose:** Identify all container images actively running, their registries, tags, and risk status.

**MCP Tool:** `jfrog_list_running_images` ⚠️ See limitations section — uses incorrect endpoint internally.

**REST API (correct per official docs):**
```
POST /runtime/api/v1/images/tags
Content-Type: application/json

{ "limit": 100, "filters": { "time_period": "now" } }
```

To filter for compliance-relevant images only:
```json
{
  "filters": {
    "risk": ["integrity_violation", "critical_applicable_cve"]
  }
}
```

**Key fields to record:**
- `name` — image name
- `tag` — image tag
- `registry` — registry hostname
- `repository_path` — path as expected in Artifactory
- `image_digest` — **SHA-256 of the running image** (anchor for Step 5a digest comparison)
- `risks` — array: `integrity_violation`, `untrusted_registry`, `critical_applicable_cves`, `malicious`
- `vulnerabilities[]` — per-CVE entries with severity and applicability
- `scan_info.sca` — whether the image was scanned
- `workloads[]` — cluster, namespace, workload name

**Example: Compliance-relevant images from `danielw.jfrog.io`:**

| Image | Tag | Risks | Vulns (C/H/M/L) | Xray Scanned |
|---|---|---|---|---|
| integrity-demo-app | latest | integrity_violation | 0/7/3/2 | Yes |
| insecure-demo-app | 2f5ba65 | critical_and_applicable_cves | 1/9/5/2 | Yes |

**Compliance notes:**
- Images with `integrity_violation` indicate the running digest does not match the digest stored in Artifactory for the same tag — investigate immediately.
- The `image_digest` field is the key link to Step 3: compare it against `checksums.sha256` from Artifactory storage.
- Images from `untrusted_registry` (e.g. ECR system images) are not tracked in Artifactory and cannot be traced to build-info.

---

## Step 3: Locate the Image Artifact in Artifactory

**Purpose:** Find the Docker image layers and manifest in Artifactory to confirm the artifact exists and retrieve its checksums.

**MCP Tool:** `jfrog_execute_aql_query`

**AQL Query:**
```
items.find({
  "repo": "<DOCKER_REPO>",
  "path": {"$match": "<IMAGE_NAME>/*"},
  "name": "manifest.json"
}).include("repo","path","name","type","size","created","modified","sha256")
.sort({"$desc": ["created"]})
.limit(20)
```

**Example (integrity-demo-app):**
```
items.find({
  "repo": "runtimedemo-integrity-demo-app-docker-dev",
  "path": {"$match": "integrity-demo-app/*"},
  "name": "manifest.json"
}).include("repo","path","name","type","size","created","modified","sha256")
.sort({"$desc": ["created"]})
.limit(20)
```

**Key fields to record:**
- Repository key (e.g. `runtimedemo-integrity-demo-app-docker-dev-local`)
- Image path and tag (e.g. `integrity-demo-app/96e3c96`)
- Manifest SHA256 digest
- Created/modified timestamps

**REST API — Get artifact storage info (checksums, creator):**
```
GET /api/storage/<REPO>/<IMAGE>/<TAG>/manifest.json
```

Example:
```
GET /api/storage/runtimedemo-integrity-demo-app-docker-dev-local/integrity-demo-app/96e3c96/manifest.json
```

**Key fields to record:**
- `checksums.sha256` — the manifest digest (links to build-info)
- `createdBy` — the principal that uploaded the artifact
- `created` / `lastModified` timestamps

---

## Step 4: Find the Build That Produced the Image

**Purpose:** Link the artifact back to the CI/CD build via build-info published to Artifactory.

### 4a. List builds in the project

**REST API:**
```
GET /api/build?project=<PROJECT_KEY>
```

Example:
```
GET /api/build?project=runtimedemo
```

**Expected output:** List of build names and their last-started timestamps.

| Build Name | Last Started |
|---|---|
| integrity-demo-app-build | 2026-03-01T21:55:49.936+0000 |
| insecure-demo-app-build | 2026-03-02T14:16:01.437+0000 |
| runtime-demo-app-build | 2026-03-01T13:08:35.480+0000 |

**Note:** The MCP tool `jfrog_list_builds` does not currently support the `project` parameter. Use the REST API via `jf rt curl` as a fallback. The MCP tool `jfrog_get_specific_build` also requires the project parameter but may return unexpected responses — use the REST API for reliability.

### 4b. List build runs

**REST API:**
```
GET /api/build/<BUILD_NAME>?project=<PROJECT_KEY>
```

Example:
```
GET /api/build/integrity-demo-app-build?project=runtimedemo
```

**Key fields:** Build numbers and start timestamps. Select the build run whose timestamp aligns with the artifact creation time.

### 4c. Get full build info

**REST API:**
```
GET /api/build/<BUILD_NAME>/<BUILD_NUMBER>?project=<PROJECT_KEY>
```

Example:
```
GET /api/build/integrity-demo-app-build/14?project=runtimedemo
```

**Key fields to record:**
- `buildInfo.name` and `buildInfo.number` — build identity
- `buildInfo.started` — build timestamp
- `buildInfo.url` — link to CI/CD run (e.g. GitHub Actions URL)
- `buildInfo.artifactoryPrincipal` — who triggered the build
- `buildInfo.agent` — build tool (e.g. `setup-jfrog-cli-github-action v4.8.1`)
- `buildInfo.modules[].properties`:
  - `docker.image.tag` — full image reference with tag
  - `docker.image.id` — image config digest (sha256)
- `buildInfo.modules[].artifacts[]` — published layers with sha1/sha256/md5
- `buildInfo.modules[].dependencies[]` — base image layers consumed

---

## Step 5: Retrieve Evidence Attestations

**Purpose:** Locate and inspect cryptographically-signed evidence records (attestations) attached to the image in Artifactory. Evidence provides an additional, tamper-evident layer of provenance — for example, SLSA provenance generated by the CI pipeline.

> **Important:** Evidence in Artifactory is attached to the **tag-based** multi-arch list manifest (`<image>/<tag>/list.manifest.json`), **not** the digest-based manifest path. Use the image tag from Step 2 (not the digest) when constructing the search path.

### 5a. Search Evidence

**REST API:**
```
GET /evidence/api/v1/evidence-search?repository_key=<REPO>&path=<IMAGE>/<TAG>/list.manifest.json
```

Example:
```
GET /evidence/api/v1/evidence-search
  ?repository_key=runtimedemo-insecure-demo-app-docker-dev-local
  &path=insecure-demo-app/f9a66eb/list.manifest.json
```

Alternatively, search by `sha256` of the `list.manifest.json` artifact (available from Step 4c build-info artifacts):
```
GET /evidence/api/v1/evidence-search
  ?repository_key=runtimedemo-insecure-demo-app-docker-dev-local
  &sha256=<LIST_MANIFEST_SHA256_FROM_BUILD_INFO>
```

**Key fields to record from each evidence item:**
- `id` — unique identifier, used for Get Evidence by ID
- `path` — confirms the subject (image tag + list manifest)
- `predicate_type` — the attestation schema (e.g. `https://slsa.dev/provenance/v1`)
- `predicate_slug` — human-readable shorthand (e.g. `slsa-provenance`)
- `predicate_category` — high-level category (e.g. `Workflow`)
- `verified` — whether Artifactory has validated the signature against the registered public key
- `created_by` — identity that deployed the evidence
- `provider_id` — system that produced it (e.g. `github`)
- `created_at` — timestamp

### 5b. Get Evidence by ID

**REST API:**
```
GET /evidence/api/v1/evidence-by-id/{id}
```

Example:
```
GET /evidence/api/v1/evidence-by-id/c9b3ef629cfe9829e40733d60a933f692f064b9982a13b959357e7f8d688ecc8
```

Returns the same fields as Search, plus `uri` (the full Artifactory path to the `.sigstore.json` file) and `subject.name`.

**Compliance check:** `verified: true` confirms the SLSA attestation signature is valid. The `predicate_type` of `https://slsa.dev/provenance/v1` confirms this is a supply-chain provenance record produced during CI.

---

## Step 6: Validate the Chain

With data from all steps collected, the compliance analyst validates:

### 6a. Digest Match (Runtime ↔ Artifactory)

Compare `image_digest` from the Step 2 response (`POST /runtime/api/v1/images/tags`) with `checksums.sha256` from the Artifactory storage response (Step 3b).

- **Match** → The running image is the same as what's in the registry. No integrity concern.
- **Mismatch** → Integrity violation. The running image does not correspond to the current registry content for that tag. This can happen when a tag is overwritten in the registry but the cluster is still running a cached older image.

### 6b. Build Provenance (Artifactory ↔ Build Info)

Confirm the artifact checksums from Step 3 appear in the build-info artifacts list from Step 4c.

- The `sha256` of the manifest in Artifactory should match an artifact entry in `buildInfo.modules[].artifacts[]`.
- The `docker.image.id` in the build module properties should match the image config layer digest.

### 6c. CI/CD Source Verification

From the build-info (Step 4c):

- `buildInfo.url` links to the specific CI/CD run (e.g. `https://github.com/tomjfrog/runtime-demo/actions/runs/22553629413`)
- Verify the run exists, was triggered from the expected branch, and completed successfully.
- `buildInfo.artifactoryPrincipal` confirms the identity that published the build.

### 6d. Vulnerability and Risk Assessment

From Step 2 (Runtime running images):

- Check `vulnerabilities[]` array for CVE details and severity
- Flag images with `critical_applicable_cves` in `risks[]` for immediate remediation
- Flag images with `integrity_violation` in `risks[]` for investigation
- Note images with `untrusted_registry` in `risks[]` that lack Artifactory provenance

---

## Summary of API Calls

| Step | Description | Method | Endpoint |
|---|---|---|---|
| 1 | List Runtime clusters | `POST` | `/runtime/api/v1/clusters` |
| 1b | Get specific cluster detail | `GET` | `/runtime/api/v1/cluster/{id}` |
| 2 | List running images (with risks/digests) | `POST` | `/runtime/api/v1/images/tags` |
| 2b | List workloads (optional) | `POST` | `/runtime/api/v1/workloads` |
| 3a | Find image manifest in Artifactory | `POST` | `/artifactory/api/search/aql` |
| 3b | Get artifact checksums | `GET` | `/artifactory/api/storage/{repo}/{image}/{digest}/manifest.json` |
| 4a | List builds in project | `GET` | `/artifactory/api/build?project={key}` |
| 4b | List build runs | `GET` | `/artifactory/api/build/{name}?project={key}` |
| 4c | Get full build info | `GET` | `/artifactory/api/build/{name}/{number}?project={key}` |
| 5a | Search evidence for image | `GET` | `/evidence/api/v1/evidence-search?repository_key={repo}&path={image}/{tag}/list.manifest.json` |
| 5b | Get evidence by ID | `GET` | `/evidence/api/v1/evidence-by-id/{id}` |
| 6 | Validation | — | Manual comparison of digests and metadata |

---

## Worked Example: Tracing `insecure-demo-app` to Git Commit

This section documents an end-to-end live execution of the workflow against the `danielw.jfrog.io` environment on **2026-03-03**. All API calls were made with `curl` using a Bearer token loaded from `access-token.txt`.

```bash
# Auth setup (run once per session)
JF_TOKEN=$(tr -d '[:space:]' < access-token.txt)
BASE="https://danielw.jfrog.io"
```

### Step 1 — Enumerate Runtime Clusters

```bash
curl -s -X POST "$BASE/runtime/api/v1/clusters" \
  -H "Authorization: Bearer $JF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "limit": 50 }'
```

**Result:**

| Cluster | Status | Region | Nodes |
|---|---|---|---|
| cluster-one | stopped | — | 0/0 |
| cluster-two | running | us-west-2 | 1/3 |
| `tomj-lab-cluster` | **running** | us-east-2 | 2/2 |

Target cluster: **`tomj-lab-cluster`**

---

### Step 2 — Find Running Image and Digest

Filter for `insecure-demo-app` running in `tomj-lab-cluster`:

```bash
curl -s -X POST "$BASE/runtime/api/v1/images/tags" \
  -H "Authorization: Bearer $JF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "limit": 50,
    "filters": {
      "cluster_names": ["tomj-lab-cluster"],
      "image_names": ["insecure-demo-app"]
    }
  }'
```

**Key fields extracted:**

| Field | Value |
|---|---|
| `name` | `insecure-demo-app` |
| `tag` | `f9a66eb` |
| `registry` | `danielw.jfrog.io` |
| `repository_path` | `runtimedemo-insecure-demo-app-docker-dev` |
| **`image_digest`** | **`1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b`** |
| `risks` | `critical_applicable_cves` |
| `workloads[0].cluster` | `tomj-lab-cluster` |
| `workloads[0].namespace` | `runtime-demo` |

> **`image_digest` is the anchor** — this SHA-256 must match at every subsequent step.

---

### Step 3a — Locate the Manifest in Artifactory via AQL

The Runtime `repository_path` does not include the `-local` suffix. Search by digest to find the exact manifest path and confirm the repository key:

```bash
curl -s -X POST "$BASE/artifactory/api/search/aql" \
  -H "Authorization: Bearer $JF_TOKEN" \
  -H "Content-Type: text/plain" \
  -d 'items.find({
    "repo": {"$match": "runtimedemo-insecure-demo-app*"},
    "path": {"$match": "insecure-demo-app/sha256:1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b"},
    "name": "manifest.json"
  }).include("repo","path","name","sha256","created")'
```

**Result:**

| Field | Value |
|---|---|
| `repo` | `runtimedemo-insecure-demo-app-docker-dev-local` |
| `path` | `insecure-demo-app/sha256:1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b` |
| `name` | `manifest.json` |
| `sha256` | `1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b` ✅ matches runtime digest |
| `created` | `2026-03-03T23:10:38.735Z` |

> Note: Docker images stored by digest use `sha256:<digest>` as the path component, not the tag.

---

### Step 3b — Get Artifact Checksums from Artifactory Storage

```bash
curl -s "$BASE/artifactory/api/storage/runtimedemo-insecure-demo-app-docker-dev-local/insecure-demo-app/sha256:1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b/manifest.json" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Key fields extracted:**

| Field | Value |
|---|---|
| `checksums.sha256` | `1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b` ✅ |
| `createdBy` | `tomj@jfrog.com` |
| `created` | `2026-03-03T23:10:38.735Z` |

**Digest match confirmed:** `image_digest` (Step 2) == `checksums.sha256` (Step 3b). The image in Artifactory is identical to the image running in the cluster.

---

### Step 4a — List Builds in the Project

```bash
curl -s "$BASE/artifactory/api/build?project=runtimedemo" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Result:** `insecure-demo-app-build` last started `2026-03-03T23:10:43.559+0000`, consistent with artifact creation at `2026-03-03T23:10:38`.

---

### Step 4b — List Build Runs

```bash
curl -s "$BASE/artifactory/api/build/insecure-demo-app-build?project=runtimedemo" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Result:** Build **#20** started `2026-03-03T23:10:43.559+0000` — timestamp matches artifact creation. This is the target run.

---

### Step 4c — Get Full Build Info

```bash
curl -s "$BASE/artifactory/api/build/insecure-demo-app-build/20?project=runtimedemo" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Key fields extracted:**

| Field | Value |
|---|---|
| `buildInfo.name` | `insecure-demo-app-build` |
| `buildInfo.number` | `20` |
| `buildInfo.started` | `2026-03-03T23:10:43.559+0000` |
| `buildInfo.artifactoryPrincipal` | `tomj@jfrog.com` |
| `buildInfo.agent` | `setup-jfrog-cli-github-action v4.8.1` |
| **`buildInfo.url`** | **`https://github.com/tomjfrog/runtime-demo/actions/runs/22647015518`** |
| **`buildInfo.vcs[0].revision`** | **`12c9fa540fdc864f70504faf6e13058530c34601`** ✅ |
| `buildInfo.vcs[0].branch` | `main` |
| `buildInfo.vcs[0].message` | `Fix syntax in build metadata collection command` |
| `buildInfo.vcs[0].url` | `https://github.com/tomjfrog/runtime-demo.git` |
| `modules[].id` (amd64) | `linux/amd64/insecure-demo-app:f9a66eb` |
| `modules[].artifacts[].name` | `manifest.json` |
| **`modules[].artifacts[].sha256`** | **`1192b88c1edfd01c1a3de6b063557b2b1bed93b30ce6a5a0f3755a424f522a4b`** ✅ |
| `modules[].artifacts[].path` | `insecure-demo-app/sha256:1192b88c.../manifest.json` |

**Build provenance confirmed:** The `manifest.json` sha256 in the build-info artifacts list matches the runtime `image_digest` exactly. The git commit is available directly from `buildInfo.vcs[0].revision` — no external API call to GitHub is needed.

> **Note on image tags:** The tag `f9a66eb` is a random 7-char hex (`openssl rand -hex 4 | cut -c1-7`), **not** a git commit short-ref. Always use `buildInfo.vcs[0].revision` for the authoritative git commit.

---

### Step 5a — Search Evidence

Search for evidence attached to the image by repository key and tag-based path. Evidence in Artifactory is attached to the **tag-based** `list.manifest.json`, not the digest-based manifest. Use the tag (`f9a66eb`) from Step 2:

```bash
curl -s -X GET \
  "$BASE/evidence/api/v1/evidence-search?repository_key=runtimedemo-insecure-demo-app-docker-dev-local&path=insecure-demo-app/f9a66eb/list.manifest.json" \
  -H "Authorization: Bearer $JF_TOKEN"
```

> Note: Searching by `sha256` requires the checksum of `list.manifest.json` itself (available in Step 4c build-info as `7d22a1bc...`), **not** the image manifest digest (`1192b88c...`). Searching by tag path is simpler and more reliable.

**Result:** One evidence record found:

| Field | Value |
|---|---|
| `id` | `c9b3ef629cfe9829e40733d60a933f692f064b9982a13b959357e7f8d688ecc8` |
| `path` | `insecure-demo-app/f9a66eb/list.manifest.json` |
| `predicate_type` | `https://slsa.dev/provenance/v1` |
| `predicate_slug` | `slsa-provenance` |
| `predicate_category` | `Workflow` |
| `verified` | `true` ✅ |
| `created_by` | `tomj@jfrog.com` |
| `provider_id` | `github` |
| `created_at` | `2026-03-03T23:11:04.715Z` |

---

### Step 5b — Get Evidence by ID

```bash
curl -s -X GET \
  "$BASE/evidence/api/v1/evidence-by-id/c9b3ef629cfe9829e40733d60a933f692f064b9982a13b959357e7f8d688ecc8" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Additional fields returned:**

| Field | Value |
|---|---|
| `subject.name` | `list.manifest.json` |
| `uri` | `runtimedemo-insecure-demo-app-docker-dev-local/.evidence/.../slsa-provenance-1772579464734-8dfe3e18.sigstore.json` |
| `sha256` | `40f04bcffdc23c8e23be5539f4e4562cb6c74e868d441ce859378b940a52f13e` |

**Evidence confirmed:** The SLSA Provenance v1 attestation is cryptographically verified (`verified: true`), was produced by GitHub Actions (`provider_id: github`), and was created at `2026-03-03T23:11:04Z` — 21 seconds after the build completed at `23:10:43Z`. This confirms the attestation was generated in the same CI run that built the image.

---

### Final Validation Summary

| Step | Data Point | Value | Status |
|---|---|---|---|
| 2 | Runtime `image_digest` | `1192b88c...` | anchor |
| 3a | AQL manifest `sha256` | `1192b88c...` | ✅ match |
| 3b | Artifactory `checksums.sha256` | `1192b88c...` | ✅ match |
| 4c | Build-info artifact `sha256` | `1192b88c...` | ✅ match |
| 4c | CI/CD run URL | `github.com/.../runs/22647015518` | ✅ found |
| 4c | **Git commit SHA** | **`12c9fa540fdc864f70504faf6e13058530c34601`** | ✅ from `buildInfo.vcs` |
| 4c | Source branch | `main` | ✅ expected |
| 5a | Evidence `predicate_type` | `https://slsa.dev/provenance/v1` | ✅ found |
| 5a | Evidence `provider_id` | `github` | ✅ expected |
| 5b | Evidence `verified` | `true` | ✅ signature valid |

**Conclusion:** The `insecure-demo-app` pod running in `tomj-lab-cluster/runtime-demo` was built from git commit `12c9fa540fdc864f70504faf6e13058530c34601` (`Fix syntax in build metadata collection command`) on `main` via GitHub Actions run `22647015518`. The image digest is consistent across Runtime, Artifactory, and Build Info — **no integrity violation present**. The image carries `critical_applicable_cves` risk and requires remediation.

---

## MCP Tool Limitations (as of 2026-03-03)

- `jfrog_list_running_images` — Uses incorrect internal endpoint (`GET /runtime/api/v1/live/images`). The correct endpoint per official docs is `POST /runtime/api/v1/images/tags`. Use the REST API directly.
- `jfrog_list_builds` — Does not support `project` parameter; returns error for project-scoped builds.
- `jfrog_get_specific_build` — Returns `Unexpected response type` even with correct build name and project.
- `jfrog_get_artifacts_summary` — Returns empty or errors for Docker manifest paths.
- **Workaround:** Use `jf rt curl` with the REST API endpoints documented in the Summary table above for all Runtime and Artifactory build steps.
