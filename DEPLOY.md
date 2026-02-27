# Deploying the Runtime Demo App to EKS

## Prerequisites

- AWS CLI v2, `eksctl`, and `kubectl` installed
- AWS SSO session active (run `aws sso login --profile AdministratorAccess-YOUR_ACCOUNT_ID`)

## 1. Configure kubectl for EKS

Ensure kubectl can authenticate to your `demo-cluster`:

```bash
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile AdministratorAccess-YOUR_ACCOUNT_ID
```

Verify connectivity:

```bash
export AWS_PROFILE=AdministratorAccess-YOUR_ACCOUNT_ID
kubectl get nodes
```

## 2. Artifactory Setup (for CI-built images)

The manifests are configured to pull from Artifactory at `danielw.jfrog.io`.

Create the image pull secret using a **JFrog Access Token** (long-lived). Create the token in Artifactory: **Administration → Identity and Access → Access Tokens** — use a token with appropriate scope (e.g. "Read" for pulling images).

**Order matters:** Create the namespace first (the secret must be created in an existing namespace), then create the secret:

```bash
kubectl apply -f k8s/namespace.yaml

export JFROG_ACCESS_TOKEN="<your-jfrog-access-token>"

kubectl create secret docker-registry artifactory-registry \
  --docker-server=danielw.jfrog.io \
  --docker-username=tomj@jfrog.com \
  --docker-password="$JFROG_ACCESS_TOKEN" \
  -n runtime-demo
```

The secret name `artifactory-registry` must match `imagePullSecrets` in the deployment.

## 3. Build and Push (manual alternative)

If not using the GitHub Actions workflow, build and push manually:

```bash
# Unique tag (7-char hex) - use same value for UNIQUE_VALUE and tag so you know which build 'latest' points to
UNIQUE=$(openssl rand -hex 4 | cut -c1-7)
docker build --build-arg UNIQUE_VALUE=$UNIQUE \
  -t danielw.jfrog.io/runtimedemo-docker-dev/runtime-demo-app:latest \
  -t danielw.jfrog.io/runtimedemo-docker-dev/runtime-demo-app:$UNIQUE .
docker push danielw.jfrog.io/runtimedemo-docker-dev/runtime-demo-app:latest
docker push danielw.jfrog.io/runtimedemo-docker-dev/runtime-demo-app:$UNIQUE
```

## 4. Deploy to the Cluster

**Required order:** namespace → secret → deployment + service. The namespace and `artifactory-registry` secret must exist before applying the deployment.

```bash
# 1. Namespace (if not already created in step 2)
kubectl apply -f k8s/namespace.yaml

# 2. Secret (see step 2; must run after namespace exists)

# 3. Deployment and service
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

Or apply all manifests at once (namespace + deployment + service; secret must already exist):

```bash
kubectl apply -f k8s/
```

## 5. Verify the Deployment

```bash
kubectl get pods -n runtime-demo
kubectl get svc -n runtime-demo
```

Check pod logs:

```bash
kubectl logs -n runtime-demo -l app=runtime-demo-app -f
```

Test from inside the cluster (e.g., from another pod):

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- curl http://runtime-demo-app.runtime-demo.svc.cluster.local/health
```
