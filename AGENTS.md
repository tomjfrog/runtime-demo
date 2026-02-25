# Runtime Demo — Agent Guide

## Overview
This project contains the configuration and tooling for a demo environment running on AWS EKS.

## AWS Account & Authentication
- **Account ID:** 925310216015
- **Auth method:** AWS IAM Identity Center (SSO)
- **SSO start URL:** https://jfrog-sandbox.awsapps.com/start/#
- **SSO region:** us-east-1
- **CLI profile:** `AdministratorAccess-925310216015`
- **SSO session name:** `Runtime Demo`

### Logging In
```
aws sso login --profile AdministratorAccess-925310216015
```

> **Note:** The SSO session section in `~/.aws/config` must be `[sso-session Runtime Demo]` (no quotes around the name) to match the `sso_session = Runtime Demo` reference in the profile.

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
  --profile AdministratorAccess-925310216015 \
  --nodegroup-name demo-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --managed
```

### Known Issues
- CloudWatch logging is not enabled. Enable with:
  ```
  eksctl utils update-cluster-logging --enable-types=all --region=us-east-2 --cluster=demo-cluster --profile AdministratorAccess-925310216015
  ```
- OIDC is not enabled on the cluster, so vpc-cni addon IAM permissions are using the node role rather than pod identity. If fine-grained pod IAM is needed later, enable OIDC or configure pod identity associations.

## CLI Prerequisites
- `aws` CLI v2
- `eksctl`
- `kubectl`

## Interacting with the Cluster

### Kubectl Setup

After logging in via SSO, configure kubectl to use the EKS cluster:

```
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile AdministratorAccess-925310216015
```

This adds the context `arn:aws:eks:us-east-2:925310216015:cluster/demo-cluster` to `~/.kube/config`. Run this after a new SSO session or on a new machine.

Set the AWS profile for kubectl (required for EKS auth):

```
export AWS_PROFILE=AdministratorAccess-925310216015
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
- **`deploy.sh`** — Script to apply manifests (`kubectl apply -f k8s/`)

### Configuring kubectl for EKS
```
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile AdministratorAccess-925310216015
```

### Artifactory Integration

The deployment pulls images from Artifactory. Before deploying:

1. **Update the image path** in `k8s/deployment.yaml`: replace `your-artifactory` with your `JF_DOCKER_REGISTRY` value (e.g. `company.jfrog.io`).
2. **Create the cluster secret** using a long-lived JFrog Access Token (create in Artifactory: Administration → Identity and Access → Access Tokens):

   ```bash
   kubectl apply -f k8s/namespace.yaml
   echo -n "<jfrog-access-token>" | kubectl create secret docker-registry artifactory-registry \
     --docker-server=<your-registry>.jfrog.io \
     --docker-username=<artifactory-username> \
     --docker-password-stdin \
     -n runtime-demo
   ```

3. **Apply manifests:** `kubectl apply -f k8s/` or `./deploy.sh`

See `DEPLOY.md` for full step-by-step instructions.

### Deploying (manual build)

If not using GitHub Actions: build locally, push to Artifactory, then apply manifests as above.

### GitHub Actions

**`.github/workflows/build-deploy-artifactory.yml`** — Builds the Docker image and pushes to Artifactory.

- **Triggers:** `workflow_dispatch` (manual), `push` to `main`
- **Required GitHub vars:** `JF_URL`, `JF_PROJECT`, `JF_DOCKER_REGISTRY`
- **Auth:** JFrog OIDC (`oidc-provider-name: github-oidc-integration`, `oidc-audience: jfrog-github`)
- **Image tags:** `docker-local/runtime-demo-app:<run_number>` and `:latest`
- **Build info:** Published to JFrog via `jf rt build-docker-create` and `jf rt build-publish`

### Planned

- Add deploy-to-EKS job to the workflow
