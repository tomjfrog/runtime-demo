# Deploying the Runtime Demo App to EKS

## Prerequisites

- AWS CLI v2, `eksctl`, and `kubectl` installed
- AWS SSO session active (run `aws sso login --profile AdministratorAccess-925310216015`)

## 1. Configure kubectl for EKS

Ensure kubectl can authenticate to your `demo-cluster`:

```bash
aws eks update-kubeconfig \
  --region us-east-2 \
  --name demo-cluster \
  --profile AdministratorAccess-925310216015
```

Verify connectivity:

```bash
export AWS_PROFILE=AdministratorAccess-925310216015
kubectl get nodes
```

## 2. Artifactory Setup (for CI-built images)

The manifests are configured to pull from Artifactory at `your-artifactory.jfrog.io/docker-local/runtime-demo-app:latest`. Update `k8s/deployment.yaml` and replace `your-artifactory` with your `JF_DOCKER_REGISTRY` value (e.g. `company.jfrog.io`).

Create the image pull secret using a **JFrog Access Token** (long-lived). Create the token in Artifactory: **Administration → Identity and Access → Access Tokens** — use a token with appropriate scope (e.g. "Read" for pulling images).

```bash
kubectl create secret docker-registry artifactory-registry \
  --docker-server=<your-registry>.jfrog.io \
  --docker-username=<artifactory-username> \
  --docker-password=<jfrog-access-token> \
  -n runtime-demo
```

To avoid exposing the token in shell history, use `--docker-password-stdin`:

```bash
echo -n "<jfrog-access-token>" | kubectl create secret docker-registry artifactory-registry \
  --docker-server=<your-registry>.jfrog.io \
  --docker-username=<artifactory-username> \
  --docker-password-stdin \
  -n runtime-demo
```

The secret name `artifactory-registry` must match `imagePullSecrets` in the deployment.

## 3. Build and Push (manual alternative)

If not using the GitHub Actions workflow, build and push manually:

```bash
docker build -t runtime-demo-app:1.0.0 .
docker tag runtime-demo-app:1.0.0 <your-registry>.jfrog.io/docker-local/runtime-demo-app:latest
docker push <your-registry>.jfrog.io/docker-local/runtime-demo-app:latest
```

## 4. Deploy to the Cluster

Apply in order: namespace first (required for the secret), then create the secret (step 2), then deployment and service:

```bash
kubectl apply -f k8s/namespace.yaml
# Create artifactory-registry secret (see step 2), then:
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

Or apply manifests only (secret must exist):

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
