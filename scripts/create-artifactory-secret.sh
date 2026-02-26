#!/usr/bin/env bash
set -e

# Create imagePullSecrets for danielw.jfrog.io
# Requires: JFROG_ACCESS_TOKEN set in environment

if [ -z "$JFROG_ACCESS_TOKEN" ]; then
  echo "Error: JFROG_ACCESS_TOKEN must be set"
  echo "  export JFROG_ACCESS_TOKEN=\"<your-token>\""
  exit 1
fi

kubectl apply -f k8s/namespace.yaml

kubectl create secret docker-registry artifactory-registry \
  --docker-server=danielw.jfrog.io \
  --docker-username=tomj@jfrog.com \
  --docker-password="$JFROG_ACCESS_TOKEN" \
  -n runtime-demo

echo "Secret created. Restarting deployment..."
kubectl rollout restart deployment runtime-demo-app -n runtime-demo
