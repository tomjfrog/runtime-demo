#!/bin/bash
# Test: Without the patch step, does the pod use cached image? (integrity violation)
# Simulates the proposed Trigger workflow (no patch).
# Prerequisite: deployment must already have imagePullPolicy: IfNotPresent
# Run after: aws sso login --profile $(cat aws-profile)
set -e

echo "=== Prerequisite: Ensure IfNotPresent is set ==="
CURRENT=$(kubectl get deployment integrity-demo-app -n runtime-demo -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || echo "unknown")
if [ "$CURRENT" != "IfNotPresent" ]; then
  echo "Setting imagePullPolicy to IfNotPresent..."
  kubectl patch deployment integrity-demo-app -n runtime-demo \
    --type='json' \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]'
  kubectl rollout status deployment/integrity-demo-app -n runtime-demo
fi
BEFORE=$(kubectl exec -n runtime-demo deployment/integrity-demo-app -- cat /app/build_id.txt 2>/dev/null | tr -d '\n')
echo "Cluster UNIQUE_VALUE before: $BEFORE"

echo ""
echo "=== Step 1: Build and push NEW image (no patch) ==="
UNIQUE=$(openssl rand -hex 4 | cut -c1-7)
echo "Building with UNIQUE_VALUE=$UNIQUE"
docker build -f integrity-demo-app/Dockerfile --build-arg UNIQUE_VALUE=$UNIQUE \
  -t danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:latest \
  -t danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:$UNIQUE ./integrity-demo-app
docker push danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:latest
docker push danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:$UNIQUE
echo "Pushed UNIQUE_VALUE: $UNIQUE"

echo ""
echo "=== Step 2: Rollout restart ==="
kubectl rollout restart deployment/integrity-demo-app -n runtime-demo
kubectl rollout status deployment/integrity-demo-app -n runtime-demo

echo ""
echo "=== Step 3: Compare ==="
K8S=$(kubectl exec -n runtime-demo deployment/integrity-demo-app -- cat /app/build_id.txt 2>/dev/null | tr -d '\n')
echo "K8s:         $K8S"
echo "Artifactory: $UNIQUE"
echo ""

if [ "$K8S" = "$UNIQUE" ]; then
  echo "MATCH — pod pulled fresh. No integrity violation."
else
  echo "MISMATCH — integrity violation! Pod used cached image."
  echo "Proposed flow works as expected."
fi
