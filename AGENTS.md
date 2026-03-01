# Runtime Demo — Agent Guide

## Overview
This project contains the configuration and tooling for a demo environment running on AWS EKS.

## AWS Account & Authentication
- **Account ID:** YOUR_ACCOUNT_ID
- **Auth method:** AWS IAM Identity Center (SSO)
- **SSO start URL:** https://d-90670a2202.awsapps.com/start/#
- **SSO region:** us-east-1
- **CLI profile:** See `aws-profile` (changes frequently)
- **SSO session name:** `RuntimeDemo`

### Profile Configuration

**The AWS profile name changes frequently** (company policy). Do not assume a fixed profile name.

**How to fetch the current profile name:**
1. **Primary source:** Read `aws-profile` in the project root — it contains the active profile name.
2. **Fallback:** Read `~/.aws/config` and look for `[profile ...]` sections; the AdministratorAccess profile for account YOUR_ACCOUNT_ID is the one used for EKS.

Commands that use `$(cat aws-profile)` must be run from the project root.

**Using the profile:**
```bash
export AWS_PROFILE=$(cat aws-profile)
```

When the user reports a profile change, update `aws-profile` with the new name. Do not attempt to re-authenticate to AWS unless explicitly asked.

### Logging In
SSO sessions expire every **8 hours** (company policy). When your session expires, you must re-authenticate:
```
aws sso login --profile $(cat aws-profile)
```
If `aws sso login` fails with a session error, re-run the full SSO configuration instead:
```
aws configure sso --profile $(cat aws-profile)
```
After re-authenticating, also refresh your kubeconfig for kubectl access:
```
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile $(cat aws-profile)
```

> **Note:** The SSO session name in `~/.aws/config` must not contain spaces (use `RuntimeDemo` not `Runtime Demo`). If you get "The specified sso-session does not exist", ensure the `[sso-session RuntimeDemo]` section exists and matches `sso_session = RuntimeDemo` in profiles.

## EKS Cluster
- **Cluster name:** `demo-cluster`
- **Region:** `us-east-2`
- **Kubernetes version:** 1.34
- **Created:** 2026-02-24

### Node Group
- **Node group name:** `demo-nodes`
- **Instance type:** `t3.medium` (2 vCPU, 4 GB RAM)
- **Node count:** 2
- **OS:** Amazon Linux 2023
- **Nodes:**
  - `ip-192-168-25-22.us-east-2.compute.internal` (AZ: us-east-2a)
  - `ip-192-168-63-72.us-east-2.compute.internal` (AZ: us-east-2b)

### Networking
- **VPC CIDR:** 192.168.0.0/16
- **Availability Zones:** us-east-2a, us-east-2b, us-east-2c
- **API endpoint access:** Public only
- **Subnets:**
  - us-east-2a — public: 192.168.0.0/19, private: 192.168.96.0/19
  - us-east-2c — public: 192.168.32.0/19, private: 192.168.128.0/19
  - us-east-2b — public: 192.168.64.0/19, private: 192.168.160.0/19

### Installed Addons
- vpc-cni
- kube-proxy
- coredns
- metrics-server

### CloudFormation Stacks
- `eksctl-demo-cluster-cluster`
- `eksctl-demo-cluster-nodegroup-demo-nodes`

### Cluster Creation Command
```
eksctl create cluster \
  --name demo-cluster \
  --region us-east-2 \
  --profile $(cat aws-profile) \
  --nodegroup-name demo-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --managed
```

### Known Issues
- CloudWatch logging is not enabled. Enable with:
  ```
  eksctl utils update-cluster-logging --enable-types=all --region=us-east-2 --cluster=demo-cluster --profile $(cat aws-profile)
  ```
- OIDC is not enabled on the cluster, so vpc-cni addon IAM permissions are using the node role rather than pod identity. If fine-grained pod IAM is needed later, enable OIDC or configure pod identity associations.

## CLI Prerequisites
- `aws` CLI v2
- `eksctl`
- `kubectl`
- `helm` (required for JFrog Runtime)

## JFrog Runtime

### Helm

Helm is required for installing JFrog Runtime sensors. Ensure it is installed and up to date:

```bash
helm version
brew upgrade helm   # if installed via Homebrew
```

### Installation

The registration token is **secret** — do not export it, commit it, or persist it anywhere. Fetch it from the Platform UI each time.

1. In the JFrog Platform, go to **Administration → Runtime → Cluster Management**
2. Click **Install Runtime** to open the wizard
3. Provide cluster name and namespace
4. Select **Controller only** or **Controller and Sensors**
5. Copy the command and replace the token with `$JF_RUNTIME_REGISTRATION_TOKEN` (set it in your shell, never in a file)

```bash
kubectl create ns jfrog-runtime

helm repo add jfrog https://charts.jfrog.io
helm repo update jfrog

# Set token in shell only; do not persist
export JF_RUNTIME_REGISTRATION_TOKEN="<paste-from-Platform-UI>"

helm upgrade --install jf-sensors jfrog/runtime-sensors \
  --namespace=jfrog-runtime \
  --set sensors.enabled=true \
  --set clusterName=tomj-lab-cluster \
  --set jfrogUrl=danielw.jfrog.io:443 \
  --set registrationToken="$JF_RUNTIME_REGISTRATION_TOKEN"
```

Prerequisites: `kubectl` and `helm` with cluster access; an ingress controller (Nginx preferred) if needed.

### Installed

JFrog Runtime sensors are installed in the cluster:

- **Namespace:** `jfrog-runtime`
- **Helm release:** `jf-sensors` (runtime-sensors chart)
- **Cluster name (in Platform):** `tomj-lab-cluster`
- **JFrog URL:** `danielw.jfrog.io:443`

**Registry source of truth:** `danielw.jfrog.io` — CI pushes to `runtimedemo-integrity-demo-app-docker-dev/integrity-demo-app`; deployment pulls from there.

Verify sensors are running:
```bash
kubectl get pods -n jfrog-runtime
```

## Interacting with the Cluster

### Kubectl Setup

After logging in via SSO, configure kubectl to use the EKS cluster:

```
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile $(cat aws-profile)
```

This adds the context `arn:aws:eks:us-east-2:YOUR_ACCOUNT_ID:cluster/demo-cluster` to `~/.kube/config`. Run this after a new SSO session or on a new machine.

Set the AWS profile for kubectl (required for EKS auth):

```
export AWS_PROFILE=$(cat aws-profile)
```

Verify connectivity:

```
kubectl get nodes
kubectl get pods -A
```

## Demo Application

A basic Node.js application used for the JFrog Runtime Integrity demo. The goal is to build a CI/CD workflow that pushes a "good" image to Artifactory and deploys it to EKS.

**End-to-end flow:** GitHub Actions builds the image → pushes to Artifactory (`docker-local/integrity-demo-app`) → cluster pulls via `imagePullSecrets` (JFrog Access Token) → deployment runs the image.

### Project Structure
- **`integrity-demo-app/`** — Node.js application for integrity demo
  - `server.js` — HTTP server on port 3000; `/` returns greeting, `/health` and `/healthz` return JSON health status
  - `package.json` — Minimal config, no external dependencies
  - `Dockerfile` — Uses `node:20-alpine`; copies app and exposes port 3000
- **`insecure-demo-app/`** — Node.js app with vulnerable glob@11.0.0 (CVE-2025-64756) for security scan demo
  - `server.js` — Express server; `/files` uses `glob -c` (exploitable path); `/health`, `/healthz`
  - `package.json` — express, lodash, glob@11.0.0
  - `Dockerfile` — Same pattern as integrity-demo-app; creates malicious filename for PoC
- **`k8s/`** — Kubernetes manifests
  - `namespace.yaml` — `runtime-demo` namespace
  - `integrity-demo-app/deployment.yaml` — Deployment for integrity-demo-app
  - `integrity-demo-app/service.yaml` — ClusterIP service for integrity-demo-app
  - `insecure-demo-app/deployment.yaml` — Deployment for insecure-demo-app
  - `insecure-demo-app/service.yaml` — ClusterIP service for insecure-demo-app
- **`DEPLOY.md`** — Step-by-step deploy instructions
- **`docs/IMAGE-PULL-TROUBLESHOOTING.md`** — Triage steps for image pull failures
- **`deploy.sh`** — Script to apply manifests (`kubectl apply -f k8s/`)
- **`scripts/create-artifactory-secret.sh`** — Creates `artifactory-registry` imagePullSecrets (requires `JFROG_ACCESS_TOKEN`)

### Configuring kubectl for EKS
```
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile $(cat aws-profile)
```

### Artifactory Integration

The deployment pulls images from Artifactory. Before deploying:

1. **Update the image path** in `k8s/integrity-demo-app/deployment.yaml` if needed (registry: `danielw.jfrog.io`).
2. **Create the cluster secret** using a long-lived JFrog Access Token (create in Artifactory: Administration → Identity and Access → Access Tokens). Namespace must exist first; set `JFROG_ACCESS_TOKEN`, then:

   ```bash
   kubectl apply -f k8s/namespace.yaml   # required before secret
   export JFROG_ACCESS_TOKEN="<your-token>"
   kubectl create secret docker-registry artifactory-registry \
     --docker-server=danielw.jfrog.io \
     --docker-username=tomj@jfrog.com \
     --docker-password="$JFROG_ACCESS_TOKEN" \
     -n runtime-demo
   ```

3. **Apply manifests:** `kubectl apply -f k8s/` or `./deploy.sh`

See `DEPLOY.md` for full step-by-step instructions.

### Deploying (manual build)

If not using GitHub Actions: build locally, push to Artifactory, then apply manifests as above.

### GitHub Actions

**`.github/workflows/build-deploy-artifactory.yml`** — Builds integrity-demo-app and pushes to Artifactory.

**`.github/workflows/build-deploy-artifactory-insecure-demo-app.yml`** — Builds insecure-demo-app and pushes to Artifactory. Contains glob@11.0.0 (CVE-2025-64756); Artifactory security scan will detect the vulnerability. See [GHSA-5j98-mcp5-4vw2](https://github.com/isaacs/node-glob/security/advisories/GHSA-5j98-mcp5-4vw2).

- **Triggers:** `workflow_dispatch` (manual), `push` to `main` (insecure-demo-app: only when `insecure-demo-app/**` changes)
- **Auth:** JFrog OIDC (`oidc-provider-name: github-oidc-integration`, `oidc-audience: jfrog-github`)
- **Image tags:** `:<unique_hex>` and `:latest` (unique value is random 7-char hex, same for both workflows)
- **Build info:** Published to JFrog via `jf rt build-docker-create` and `jf rt build-publish`

### Repository Variables

Configure these in **Settings → Secrets and variables → Actions → Variables**:

| Variable | Used by | Purpose |
|----------|---------|---------|
| `AWS_REGION` | integrity-demo-* | AWS region for EKS (e.g. `us-east-2`) |
| `DOCKER_REPOSITORY` | build-deploy-artifactory-insecure (vars) | Artifactory repository path; integrity/insecure use env vars |
| `EKS_CLUSTER_NAME` | integrity-demo-* | EKS cluster name (e.g. `demo-cluster`) |
| `IMAGE_NAME` | build-deploy-artifactory, integrity-demo-trigger | Docker image name (e.g. `integrity-demo-app`). insecure-demo-app uses hardcoded name. |
| `JF_DOCKER_REGISTRY` | build-deploy-artifactory*, integrity-demo-trigger | JFrog registry host (e.g. `danielw.jfrog.io`) |
| `JF_PROJECT` | build-deploy-artifactory*, integrity-demo-trigger | JFrog project key for OIDC |
| `JF_URL` | build-deploy-artifactory*, integrity-demo-trigger | JFrog Platform URL (e.g. `https://danielw.jfrog.io`) |
| `K8S_DEPLOYMENT` | integrity-demo-* | Kubernetes deployment name (e.g. `integrity-demo-app`) |
| `K8S_NAMESPACE` | integrity-demo-* | Kubernetes namespace (e.g. `runtime-demo`) |

### Planned

- Add deploy-to-EKS job to the workflow

## JFrog Runtime Integrity Violation Demo

This workflow demonstrates how JFrog Runtime detects an **integrity violation** when the image running in the cluster does not match the image in Artifactory for the same tag. The scenario relies on Kubernetes `imagePullPolicy: IfNotPresent` and node affinity so the pod reuses a cached image instead of pulling the updated one.

### Prerequisites

- Deployment uses `imagePullPolicy: IfNotPresent` (not `Always`)
- Node affinity pins the pod to a specific node (e.g. `ip-192-168-63-72.us-east-2.compute.internal`) so redeploys land on the same node that has the cached image
- Image pull secret `artifactory-registry` exists in namespace `runtime-demo`

### Workflow Diagram

[`docs/integrity-violation-workflow.mmd`](docs/integrity-violation-workflow.mmd) — Mermaid flowchart for Sync → Setup → Trigger → Sync.

### Step-by-Step Instructions

#### 1. Sync with Artifactory (optional — start from clean state)

Ensure the cluster runs the same image as Artifactory:

1. In `k8s/integrity-demo-app/deployment.yaml`, set `imagePullPolicy: Always`
2. Apply and redeploy:
   ```bash
   kubectl apply -f k8s/integrity-demo-app/
   kubectl rollout restart deployment/integrity-demo-app -n runtime-demo
   ```
3. Wait for rollout: `kubectl rollout status deployment/integrity-demo-app -n runtime-demo`

#### 2. Setup (run after every Sync, before Trigger)

Set `imagePullPolicy: IfNotPresent` so the pod will use cached images on redeploy. Required before each Trigger because Sync resets to `Always`.

- **GitHub Actions:** Run `integrity-demo-setup.yml`
- **Manual:** In `k8s/integrity-demo-app/deployment.yaml`, set `imagePullPolicy: IfNotPresent`, then `kubectl apply -f k8s/integrity-demo-app/` and `kubectl rollout restart deployment/integrity-demo-app -n runtime-demo`

#### 3. Trigger the integrity violation

1. Verify the pod is running and has pulled the image (it will be cached on the pinned node)
2. Build and push a **new** image with the same tag (`:latest`):
   ```bash
   UNIQUE=$(openssl rand -hex 4 | cut -c1-7)
   docker build -f integrity-demo-app/Dockerfile --build-arg UNIQUE_VALUE=$UNIQUE \
     -t danielw.jfrog.io/runtimedemo-integrity-demo-app-docker-dev/integrity-demo-app:latest \
     -t danielw.jfrog.io/runtimedemo-integrity-demo-app-docker-dev/integrity-demo-app:$UNIQUE ./integrity-demo-app
   jf docker push danielw.jfrog.io/runtimedemo-integrity-demo-app-docker-dev/integrity-demo-app:latest
   ```
3. Redeploy (pod will use cached image on the same node):
   ```bash
   kubectl rollout restart deployment/integrity-demo-app -n runtime-demo
   kubectl rollout status deployment/integrity-demo-app -n runtime-demo
   ```
4. JFrog Runtime will report an **integrity violation** because the running digest no longer matches Artifactory’s digest for `:latest`

#### 4. Sync with Artifactory (clear the violation)

Same as step 1. Run the Sync workflow or manually set `imagePullPolicy: Always`, apply, and redeploy. The pod pulls the latest image from Artifactory; the integrity violation clears.

### Why Node Affinity Matters

With multiple nodes, a restarted pod may land on a different node that does not have the image cached. That node would pull the new image, so no violation would occur. Node affinity ensures the pod always schedules on the same node (e.g. `ip-192-168-63-72.us-east-2.compute.internal`), so with `IfNotPresent` it reuses the cached old image after you push a new one to Artifactory.

### GitHub Actions (separate workflows per stage)

| Workflow | Purpose |
|----------|---------|
| `integrity-demo-reset.yml` | Sync with Artifactory / Reset — set `imagePullPolicy: Always`, redeploy. Use at start (optional) or after Trigger to clear violation |
| `integrity-demo-setup.yml` | Set `imagePullPolicy: IfNotPresent` — run after every Sync, before Trigger |
| `integrity-demo-trigger.yml` | Build+push new image, redeploy — triggers violation (requires Setup first) |

**Demo flow:** Sync (optional) → Setup → Trigger → Sync → Setup → Trigger → … (Setup required before each Trigger; Sync resets to `Always`.)

**Required GitHub secrets** (all integrity workflows; SSO temporary credentials):
- `AWS_ACCESS_KEY_ID` — from SSO credential export
- `AWS_SECRET_ACCESS_KEY` — from SSO credential export
- `AWS_SESSION_TOKEN` — from SSO credential export (required for temporary credentials)

**Required Repository variables** — see [Repository Variables](#repository-variables) above. Integrity workflows use: `AWS_REGION`, `EKS_CLUSTER_NAME`, `K8S_NAMESPACE`, `K8S_DEPLOYMENT`; trigger also uses `JF_URL`, `JF_PROJECT`, `JF_DOCKER_REGISTRY`, `DOCKER_REPOSITORY`, `IMAGE_NAME`.

**IAM permissions** for the access key: `eks:DescribeCluster` (and `eks:ListClusters` if needed). The IAM user must be able to authenticate to the EKS cluster.
