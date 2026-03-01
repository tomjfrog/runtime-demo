#!/bin/bash
# Test: Does the patch step cause the pod to pull fresh (breaking the integrity violation)?
# Simulates the full GitHub Actions Trigger workflow locally.
# Run after: aws sso login --profile $(cat aws-profile)
set -e

echo "=== Step 0: Reset (sync cluster with Artifactory) ==="
kubectl patch deployment integrity-demo-app -n runtime-demo \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}]'
kubectl rollout restart deployment/integrity-demo-app -n runtime-demo
kubectl rollout status deployment/integrity-demo-app -n runtime-demo
BEFORE=$(kubectl exec -n runtime-demo deployment/integrity-demo-app -- cat /app/build_id.txt 2>/dev/null | tr -d '\n')
echo "Cluster UNIQUE_VALUE after reset: $BEFORE"

echo ""
echo "=== Step 1: Patch to IfNotPresent (simulates Trigger workflow) ==="
kubectl patch deployment integrity-demo-app -n runtime-demo \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]'
kubectl rollout status deployment/integrity-demo-app -n runtime-demo
echo "Patch applied, rollout complete."

echo ""
echo "=== Step 2: Build and push NEW image ==="
UNIQUE=$(openssl rand -hex 4 | cut -c1-7)
echo "Building with UNIQUE_VALUE=$UNIQUE"
docker build -f integrity-demo-app/Dockerfile --build-arg UNIQUE_VALUE=$UNIQUE \
  -t danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:latest \
  -t danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:$UNIQUE ./integrity-demo-app
docker push danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:latest
docker push danielw.jfrog.io/runtimedemo-docker-dev/integrity-demo-app:$UNIQUE
echo "Pushed UNIQUE_VALUE: $UNIQUE"

echo ""
echo "=== Step 3: Rollout restart ==="
kubectl rollout restart deployment/integrity-demo-app -n runtime-demo
kubectl rollout status deployment/integrity-demo-app -n runtime-demo

echo ""
echo "=== Step 4: Compare ==="
K8S=$(kubectl exec -n runtime-demo deployment/integrity-demo-app -- cat /app/build_id.txt 2>/dev/null | tr -d '\n')
echo "K8s:        $K8S"
echo "Artifactory: $UNIQUE"
echo ""

if [ "$K8S" = "$UNIQUE" ]; then
  echo "MATCH — patch is the culprit. Pod pulled fresh instead of using cache."
  echo "Hypothesis CONFIRMED: Remove patch from Trigger workflow."
else
  echo "MISMATCH — integrity violation. Patch did not cause the issue."
  echo "Hypothesis NOT confirmed."
fi
