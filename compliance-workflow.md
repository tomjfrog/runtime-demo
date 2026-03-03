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

## Step 5: Validate the Chain

With data from all steps collected, the compliance analyst validates:

### 5a. Digest Match (Runtime ↔ Artifactory)

Compare `image_digest` from the Step 2 response (`POST /runtime/api/v1/images/tags`) with `checksums.sha256` from the Artifactory storage response (Step 3b).

- **Match** → The running image is the same as what's in the registry. No integrity concern.
- **Mismatch** → Integrity violation. The running image does not correspond to the current registry content for that tag. This can happen when a tag is overwritten in the registry but the cluster is still running a cached older image.

### 5b. Build Provenance (Artifactory ↔ Build Info)

Confirm the artifact checksums from Step 3 appear in the build-info artifacts list from Step 4c.

- The `sha256` of the manifest in Artifactory should match an artifact entry in `buildInfo.modules[].artifacts[]`.
- The `docker.image.id` in the build module properties should match the image config layer digest.

### 5c. CI/CD Source Verification

From the build-info (Step 4c):

- `buildInfo.url` links to the specific CI/CD run (e.g. `https://github.com/tomjfrog/runtime-demo/actions/runs/22553629413`)
- Verify the run exists, was triggered from the expected branch, and completed successfully.
- `buildInfo.artifactoryPrincipal` confirms the identity that published the build.

### 5d. Vulnerability and Risk Assessment

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
| 3b | Get artifact checksums | `GET` | `/artifactory/api/storage/{repo}/{image}/{tag}/manifest.json` |
| 4a | List builds in project | `GET` | `/artifactory/api/build?project={key}` |
| 4b | List build runs | `GET` | `/artifactory/api/build/{name}?project={key}` |
| 4c | Get full build info | `GET` | `/artifactory/api/build/{name}/{number}?project={key}` |
| 5 | Validation | — | Manual comparison of digests and metadata |

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
| `tag` | `2f5ba65` |
| `registry` | `danielw.jfrog.io` |
| `repository_path` | `runtimedemo-insecure-demo-app-docker-dev` |
| **`image_digest`** | **`22e66226348ff8cafaaf94ac41aa190f9a7b9c48c479331f8d6945452a6791bf`** |
| `risks` | `critical_applicable_cves` |
| `workloads[0].cluster` | `tomj-lab-cluster` |
| `workloads[0].namespace` | `runtime-demo` |

> **`image_digest` is the anchor** — this SHA-256 must match at every subsequent step.

---

### Step 3a — Locate the Manifest in Artifactory via AQL

The Runtime `repository_path` does not include the `-local` suffix. Determine the actual repository key by searching AQL:

```bash
curl -s -X POST "$BASE/artifactory/api/search/aql" \
  -H "Authorization: Bearer $JF_TOKEN" \
  -H "Content-Type: text/plain" \
  -d 'items.find({
    "repo": {"$match": "runtimedemo-insecure-demo-app*"},
    "path": {"$match": "insecure-demo-app/*"},
    "name": "manifest.json"
  }).include("repo","path","name","sha256","created")
  .sort({"$desc": ["created"]})
  .limit(5)'
```

**Result:**

| Field | Value |
|---|---|
| `repo` | `runtimedemo-insecure-demo-app-docker-dev-local` |
| `path` | `insecure-demo-app/sha256:22e66226348ff8cafaaf94ac41aa190f9a7b9c48c479331f8d6945452a6791bf` |
| `name` | `manifest.json` |
| `sha256` | `22e66226348ff8cafaaf94ac41aa190f9a7b9c48c479331f8d6945452a6791bf` ✅ matches runtime digest |
| `created` | `2026-03-02T14:15:58.096Z` |

> Note: Docker images stored by digest use `sha256:<digest>` as the path component, not the tag.

---

### Step 3b — Get Artifact Checksums from Artifactory Storage

```bash
curl -s "$BASE/artifactory/api/storage/runtimedemo-insecure-demo-app-docker-dev-local/insecure-demo-app/sha256:22e66226348ff8cafaaf94ac41aa190f9a7b9c48c479331f8d6945452a6791bf/manifest.json" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Key fields extracted:**

| Field | Value |
|---|---|
| `checksums.sha256` | `22e66226348ff8cafaaf94ac41aa190f9a7b9c48c479331f8d6945452a6791bf` ✅ |
| `createdBy` | `tomj@jfrog.com` |
| `created` | `2026-03-02T14:15:58.096Z` |

**Digest match confirmed:** `image_digest` (Step 2) == `checksums.sha256` (Step 3b). The image in Artifactory is identical to the image running in the cluster.

---

### Step 4a — List Builds in the Project

```bash
curl -s "$BASE/artifactory/api/build?project=runtimedemo" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Result:** Three builds found. The `insecure-demo-app-build` was last started at `2026-03-02T14:16:01.437+0000`, consistent with the artifact creation timestamp (`2026-03-02T14:15:58`).

---

### Step 4b — List Build Runs

```bash
curl -s "$BASE/artifactory/api/build/insecure-demo-app-build?project=runtimedemo" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Result:** Build **#18** started `2026-03-02T14:16:01.437+0000` — timestamp matches artifact creation. This is the target run.

---

### Step 4c — Get Full Build Info

```bash
curl -s "$BASE/artifactory/api/build/insecure-demo-app-build/18?project=runtimedemo" \
  -H "Authorization: Bearer $JF_TOKEN"
```

**Key fields extracted:**

| Field | Value |
|---|---|
| `buildInfo.name` | `insecure-demo-app-build` |
| `buildInfo.number` | `18` |
| `buildInfo.started` | `2026-03-02T14:16:01.437+0000` |
| `buildInfo.artifactoryPrincipal` | `tomj@jfrog.com` |
| `buildInfo.agent` | `setup-jfrog-cli-github-action v4.8.1` |
| **`buildInfo.url`** | **`https://github.com/tomjfrog/runtime-demo/actions/runs/22579860798`** |
| `modules[].id` (amd64) | `linux/amd64/insecure-demo-app:2f5ba65` |
| `modules[].artifacts[].name` | `manifest.json` |
| **`modules[].artifacts[].sha256`** | **`22e66226348ff8cafaaf94ac41aa190f9a7b9c48c479331f8d6945452a6791bf`** ✅ |
| `modules[].artifacts[].path` | `insecure-demo-app/sha256:22e66226.../manifest.json` |

**Build provenance confirmed:** The `manifest.json` sha256 in the build-info artifacts list matches the runtime `image_digest` exactly.

---

### Step 5 — Retrieve Git Commit from CI/CD Run

The `buildInfo.url` points to a GitHub Actions run. The `buildInfo.vcs` section was not populated by this build, so the git commit was retrieved directly from the GHA API:

```bash
gh run view 22579860798 --repo tomjfrog/runtime-demo \
  --json headSha,headBranch,displayTitle,createdAt,url
```

**Result:**

| Field | Value |
|---|---|
| `headSha` | `d1f153e4506bf87a556c9afcd4e847b6375e84f8` |
| `headBranch` | `main` |
| `displayTitle` | `Build and Deploy insecure-demo-app to Artifactory` |
| `createdAt` | `2026-03-02T14:15:07Z` |

> **Note:** The image tag `2f5ba65` in this workflow is a random 7-char hex generated with `openssl rand -hex 4 | cut -c1-7`, **not** a git commit SHA short-ref. Always retrieve the commit from the GHA run (`headSha`) or by populating `buildInfo.vcs` in the CI pipeline.

---

### Final Validation Summary

| Step | Data Point | Value | Status |
|---|---|---|---|
| 2 | Runtime `image_digest` | `22e66226...` | anchor |
| 3a | AQL manifest `sha256` | `22e66226...` | ✅ match |
| 3b | Artifactory `checksums.sha256` | `22e66226...` | ✅ match |
| 4c | Build-info artifact `sha256` | `22e66226...` | ✅ match |
| 4c | CI/CD run URL | `github.com/.../runs/22579860798` | ✅ found |
| 5 | Git commit SHA | `d1f153e4506bf87a556c9afcd4e847b6375e84f8` | ✅ verified |
| 5 | Source branch | `main` | ✅ expected |

**Conclusion:** The `insecure-demo-app` pod running in `tomj-lab-cluster/runtime-demo` was built from git commit `d1f153e4506bf87a556c9afcd4e847b6375e84f8` on `main` via GitHub Actions run `22579860798`. The image digest is consistent across Runtime, Artifactory, and Build Info — **no integrity violation present**. The image does carry `critical_applicable_cves` risk (glob@11.0.0 / CVE-2025-64756) and requires remediation.

---

## MCP Tool Limitations (as of 2026-03-03)

- `jfrog_list_running_images` — Uses incorrect internal endpoint (`GET /runtime/api/v1/live/images`). The correct endpoint per official docs is `POST /runtime/api/v1/images/tags`. Use the REST API directly.
- `jfrog_list_builds` — Does not support `project` parameter; returns error for project-scoped builds.
- `jfrog_get_specific_build` — Returns `Unexpected response type` even with correct build name and project.
- `jfrog_get_artifacts_summary` — Returns empty or errors for Docker manifest paths.
- **Workaround:** Use `jf rt curl` with the REST API endpoints documented in the Summary table above for all Runtime and Artifactory build steps.
