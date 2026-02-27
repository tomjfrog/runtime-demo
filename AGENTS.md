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

**Registry source of truth:** `danielw.jfrog.io` — CI pushes to `runtimedemo-docker-dev-local/runtime-demo-app`; deployment pulls from there.

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

**End-to-end flow:** GitHub Actions builds the image → pushes to Artifactory (`docker-local/runtime-demo-app`) → cluster pulls via `imagePullSecrets` (JFrog Access Token) → deployment runs the image.

### Project Structure
- **`app/`** — Node.js application
  - `server.js` — HTTP server on port 3000; `/` returns greeting, `/health` and `/healthz` return JSON health status
  - `package.json` — Minimal config, no external dependencies
- **`k8s/`** — Kubernetes manifests
  - `namespace.yaml` — `runtime-demo` namespace
  - `deployment.yaml` — Deployment pulling from Artifactory (`<registry>/docker-local/runtime-demo-app:latest`); uses `imagePullSecrets: artifactory-registry` (authenticated via JFrog Access Token)
  - `service.yaml` — ClusterIP service (port 80 → 3000)
- **`Dockerfile`** — Uses `node:20-alpine`; copies app and exposes port 3000
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

1. **Update the image path** in `k8s/deployment.yaml` if needed (registry: `danielw.jfrog.io`).
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

**`.github/workflows/build-deploy-artifactory.yml`** — Builds the Docker image and pushes to Artifactory.

- **Triggers:** `workflow_dispatch` (manual), `push` to `main`
- **Auth:** JFrog OIDC (`oidc-provider-name: github-oidc-integration`, `oidc-audience: jfrog-github`)
- **Image tags:** `docker-local/runtime-demo-app:<run_number>` and `:latest`
- **Build info:** Published to JFrog via `jf rt build-docker-create` and `jf rt build-publish`

### Repository Variables

Configure these in **Settings → Secrets and variables → Actions → Variables**:

| Variable | Used by | Purpose |
|----------|---------|---------|
| `AWS_REGION` | integrity-demo-* | AWS region for EKS (e.g. `us-east-2`) |
| `DOCKER_REPOSITORY` | build-deploy-artifactory, integrity-demo-trigger | Artifactory repository path (e.g. `runtimedemo-docker-dev-local`) |
| `EKS_CLUSTER_NAME` | integrity-demo-* | EKS cluster name (e.g. `demo-cluster`) |
| `IMAGE_NAME` | build-deploy-artifactory, integrity-demo-trigger | Docker image name (e.g. `runtime-demo-app`) |
| `JF_DOCKER_REGISTRY` | build-deploy-artifactory, integrity-demo-trigger | JFrog registry host (e.g. `danielw.jfrog.io`) |
| `JF_PROJECT` | build-deploy-artifactory, integrity-demo-trigger | JFrog project key for OIDC |
| `JF_URL` | build-deploy-artifactory, integrity-demo-trigger | JFrog Platform URL (e.g. `https://danielw.jfrog.io`) |
| `K8S_DEPLOYMENT` | integrity-demo-* | Kubernetes deployment name (e.g. `runtime-demo-app`) |
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

[`docs/integrity-violation-workflow.mmd`](docs/integrity-violation-workflow.mmd) — Mermaid flowchart for Setup → Trigger Violation → Clear Violation.

### Step-by-Step Instructions

#### 1. Reset environment (optional — start from clean state)

Ensure the cluster runs the same image as Artifactory:

1. In `k8s/deployment.yaml`, set `imagePullPolicy: Always`
2. Apply and redeploy:
   ```bash
   kubectl apply -f k8s/deployment.yaml
   kubectl rollout restart deployment/runtime-demo-app -n runtime-demo
   ```
3. Wait for rollout: `kubectl rollout status deployment/runtime-demo-app -n runtime-demo`

#### 2. Trigger the integrity violation

1. In `k8s/deployment.yaml`, set `imagePullPolicy: IfNotPresent`
2. Apply the deployment:
   ```bash
   kubectl apply -f k8s/deployment.yaml
   ```
3. Verify the pod is running and has pulled the image (it will be cached on the pinned node)
4. Build and push a **new** image with the same tag (`:latest`):
   ```bash
   BUILD_TAG=$(openssl rand -hex 4 | cut -c1-7)
   docker build --build-arg BUILD_ID=$BUILD_TAG \
     -t danielw.jfrog.io/runtimedemo-docker-dev-local/runtime-demo-app:latest \
     -t danielw.jfrog.io/runtimedemo-docker-dev-local/runtime-demo-app:$BUILD_TAG .
   jf docker push danielw.jfrog.io/runtimedemo-docker-dev-local/runtime-demo-app:latest
   ```
5. Redeploy (pod will use cached image on the same node):
   ```bash
   kubectl rollout restart deployment/runtime-demo-app -n runtime-demo
   ```
6. JFrog Runtime will report an **integrity violation** because the running digest no longer matches Artifactory’s digest for `:latest`

#### 3. Clear the violation (reset)

1. In `k8s/deployment.yaml`, set `imagePullPolicy: Always`
2. Apply and redeploy:
   ```bash
   kubectl apply -f k8s/deployment.yaml
   kubectl rollout restart deployment/runtime-demo-app -n runtime-demo
   ```
3. The pod pulls the latest image from Artifactory; the integrity violation clears

### Why Node Affinity Matters

With multiple nodes, a restarted pod may land on a different node that does not have the image cached. That node would pull the new image, so no violation would occur. Node affinity ensures the pod always schedules on the same node (e.g. `ip-192-168-63-72.us-east-2.compute.internal`), so with `IfNotPresent` it reuses the cached old image after you push a new one to Artifactory.

### GitHub Actions (separate workflows per stage)

| Workflow | Purpose |
|----------|---------|
| `integrity-demo-reset.yml` | Set `imagePullPolicy: Always`, redeploy — cluster in sync with Artifactory |
| `integrity-demo-trigger.yml` | Set `IfNotPresent`, build+push new image, redeploy — triggers violation |
| `integrity-demo-clear.yml` | Set `imagePullPolicy: Always`, redeploy — clears violation |

**Required GitHub secrets** (all integrity workflows; SSO temporary credentials):
- `AWS_ACCESS_KEY_ID` — from SSO credential export
- `AWS_SECRET_ACCESS_KEY` — from SSO credential export
- `AWS_SESSION_TOKEN` — from SSO credential export (required for temporary credentials)

**Required Repository variables** — see [Repository Variables](#repository-variables) above. Integrity workflows use: `AWS_REGION`, `EKS_CLUSTER_NAME`, `K8S_NAMESPACE`, `K8S_DEPLOYMENT`; trigger also uses `JF_URL`, `JF_PROJECT`, `JF_DOCKER_REGISTRY`, `DOCKER_REPOSITORY`, `IMAGE_NAME`.

**IAM permissions** for the access key: `eks:DescribeCluster` (and `eks:ListClusters` if needed). The IAM user must be able to authenticate to the EKS cluster.
