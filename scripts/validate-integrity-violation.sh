#!/bin/bash
# Validate integrity violation: compare running image (cached) vs hosted image (Artifactory :latest).
# Run after: aws sso login, kubectl configured for cluster, docker logged into Artifactory.
# Exit 0 = mismatch (integrity violation, demo succeeded). Exit 1 = match (no violation).
set -e

IMAGE="${IMAGE:-danielw.jfrog.io/runtimedemo-integrity-demo-app-docker-dev/integrity-demo-app:latest}"
DEPLOYMENT="${DEPLOYMENT:-integrity-demo-app}"
NAMESPACE="${NAMESPACE:-runtime-demo}"

# Remove locally-cached integrity-demo-app images so we pull fresh from Artifactory
IMAGE_REPO="${IMAGE%:*}"
echo "=== Integrity Violation Validation ==="
echo "Removing locally-cached $IMAGE_REPO images..."
for img in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^${IMAGE_REPO}" 2>/dev/null); do
  docker rmi -f "$img" 2>/dev/null || true
done
echo ""

K8S=$(kubectl exec -n "$NAMESPACE" deployment/"$DEPLOYMENT" -- cat /app/build_id.txt 2>/dev/null | tr -d '\n') || {
  echo "Error: Could not get build_id from running pod. Is the deployment running?"
  exit 2
}

ARTIFACTORY=$(docker run --rm "$IMAGE" cat /app/build_id.txt 2>/dev/null | tr -d '\n') || {
  echo "Error: Could not get build_id from hosted image. Run: docker login danielw.jfrog.io"
  exit 2
}

echo "Running image (cached):  $K8S"
echo "Hosted image (latest):   $ARTIFACTORY"
echo ""

if [ "$K8S" = "$ARTIFACTORY" ]; then
  echo "MATCH — No integrity violation. Pod pulled fresh from Artifactory."
  exit 1
else
  echo "MISMATCH — Integrity violation! Pod uses cached image, Artifactory has newer."
  exit 0
fi
