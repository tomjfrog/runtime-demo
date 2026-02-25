#!/usr/bin/env bash
set -e

# Deploy Runtime Demo app to EKS
# Prerequisites: kubectl configured for demo-cluster, image pushed to registry, deployment.yaml updated with image path

echo "Deploying Runtime Demo app to EKS..."
kubectl apply -f k8s/
echo "Done. Check status with: kubectl get pods -n runtime-demo"
