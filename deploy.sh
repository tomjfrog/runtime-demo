#!/usr/bin/env bash
set -e

# Deploy Runtime Demo app to EKS
# Prerequisites:
#   - kubectl configured for demo-cluster
#   - namespace runtime-demo exists (kubectl apply -f k8s/namespace.yaml)
#   - artifactory-registry secret exists in runtime-demo (see DEPLOY.md step 2)
#   - Image pushed to Artifactory, deployment.yaml updated with registry URL

echo "Deploying Runtime Demo app to EKS..."
kubectl apply -f k8s/
echo "Done. Check status with: kubectl get pods -n runtime-demo"
