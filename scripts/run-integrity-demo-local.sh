#!/bin/bash
# Run the entire integrity violation demo locally (no GitHub Actions).
# Flow: Reset → Setup → Trigger → Verify
#
# Prerequisites:
#   - aws sso login (or AWS credentials)
#   - kubectl configured for EKS (aws eks update-kubeconfig)
#   - docker login danielw.jfrog.io (or jf docker login)
#   - JFROG_ACCESS_TOKEN used to create artifactory-registry secret in runtime-demo namespace
#
# Usage: ./scripts/run-integrity-demo-local.sh
#   SKIP_RESET=1     Skip the initial Reset step (if cluster already in sync)
#   SKIP_VERIFY=1    Skip the final validation script
set -e

# Config (override with env)
AWS_PROFILE="${AWS_PROFILE:-$(cat aws-profile 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-2}"
EKS_CLUSTER="${EKS_CLUSTER:-demo-cluster}"
JF_REGISTRY="${JF_REGISTRY:-danielw.jfrog.io}"
DOCKER_REPO="${DOCKER_REPO:-runtimedemo-integrity-demo-app-docker-dev}"
IMAGE_NAME="${IMAGE_NAME:-integrity-demo-app}"
K8S_NAMESPACE="${K8S_NAMESPACE:-runtime-demo}"
K8S_DEPLOYMENT="${K8S_DEPLOYMENT:-integrity-demo-app}"

FULL_IMAGE="${JF_REGISTRY}/${DOCKER_REPO}/${IMAGE_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=============================================="
echo "  Integrity Violation Demo (Local)"
echo "=============================================="
echo "Registry:  $JF_REGISTRY"
echo "Image:    $FULL_IMAGE:latest"
echo "Cluster:  $EKS_CLUSTER ($AWS_REGION)"
echo "Namespace: $K8S_NAMESPACE"
echo ""

# Prereq checks
check_prereqs() {
  echo "--- Checking prerequisites ---"
  command -v kubectl >/dev/null || { echo "Error: kubectl required"; exit 1; }
  command -v docker >/dev/null || { echo "Error: docker required"; exit 1; }
  command -v aws >/dev/null || { echo "Error: aws CLI required"; exit 1; }

  if [ -n "$AWS_PROFILE" ]; then
    export AWS_PROFILE
    echo "Using AWS profile: $AWS_PROFILE"
  fi

  # Refresh kubeconfig
  echo "Updating kubeconfig..."
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER" ${AWS_PROFILE:+--profile "$AWS_PROFILE"} 2>/dev/null || true

  # Verify cluster access
  kubectl get nodes >/dev/null 2>&1 || { echo "Error: Cannot reach cluster. Run: aws sso login; aws eks update-kubeconfig ..."; exit 1; }
  echo "Cluster OK"

  # Ensure namespace and deployment exist
  kubectl apply -f "$PROJECT_ROOT/k8s/namespace.yaml"
  kubectl apply -f "$PROJECT_ROOT/k8s/integrity-demo-app/"

  # Ensure image pull secret exists
  kubectl get secret artifactory-registry -n "$K8S_NAMESPACE" >/dev/null 2>&1 || {
    echo "Error: Secret artifactory-registry not found in $K8S_NAMESPACE."
    echo "  Run: export JFROG_ACCESS_TOKEN=<token>; ./scripts/create-artifactory-secret.sh"
    exit 1
  }
  echo ""
}

step_reset() {
  echo "--- Step 1: Reset (Sync with Artifactory) ---"
  kubectl patch deployment "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE" \
    --type='json' \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}]'
  kubectl rollout restart deployment/"$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE"
  kubectl rollout status deployment/"$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE" --timeout=180s
  echo "Reset complete. Cluster now matches Artifactory."
  echo ""
}

step_setup() {
  echo "--- Step 2: Setup (IfNotPresent) ---"
  kubectl patch deployment "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE" \
    --type='json' \
    -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]'
  echo "Setup complete. Pod will use cached image on next restart."
  echo ""
}

step_trigger() {
  echo "--- Step 3: Trigger (Build + Push + Redeploy) ---"
  UNIQUE=$(openssl rand -hex 4 | cut -c1-7)
  echo "Unique build ID: $UNIQUE"

  echo "Building image..."
  docker build -f "$PROJECT_ROOT/integrity-demo-app/Dockerfile" \
    --build-arg UNIQUE_VALUE="$UNIQUE" \
    -t "$FULL_IMAGE:latest" \
    -t "$FULL_IMAGE:$UNIQUE" \
    "$PROJECT_ROOT/integrity-demo-app"

  echo "Pushing to Artifactory..."
  if command -v jf >/dev/null 2>&1; then
    jf docker push "$FULL_IMAGE:latest" && jf docker push "$FULL_IMAGE:$UNIQUE"
  else
    docker push "$FULL_IMAGE:latest" && docker push "$FULL_IMAGE:$UNIQUE"
  fi

  echo "Redeploying (pod will use cached image)..."
  kubectl rollout restart deployment/"$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE"
  kubectl rollout status deployment/"$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE" --timeout=180s

  echo ""
  echo "--- Verify integrity violation ---"
  K8S=$(kubectl exec -n "$K8S_NAMESPACE" deployment/"$K8S_DEPLOYMENT" -- cat /app/build_id.txt 2>/dev/null | tr -d '\n')
  echo "Running image (cached):  $K8S"
  echo "Hosted image (pushed):   $UNIQUE"
  if [ "$K8S" = "$UNIQUE" ]; then
    echo "MATCH — Pod pulled fresh. No integrity violation. Demo may not work as expected."
    return 1
  else
    echo "MISMATCH — Integrity violation! Pod used cached image. Demo succeeded."
    return 0
  fi
}

step_validate() {
  echo ""
  echo "--- Step 4: Full validation (pod vs Artifactory :latest) ---"
  "$SCRIPT_DIR/validate-integrity-violation.sh" || true
}

# Main
check_prereqs

if [ "${SKIP_RESET:-0}" != "1" ]; then
  step_reset
else
  echo "--- Skipping Reset (SKIP_RESET=1) ---"
  echo ""
fi

step_setup
step_trigger
TRIGGER_EXIT=$?

if [ "${SKIP_VERIFY:-0}" != "1" ]; then
  step_validate
fi

echo ""
echo "=============================================="
if [ $TRIGGER_EXIT -eq 0 ]; then
  echo "  Demo complete. Integrity violation detected."
else
  echo "  Demo complete. No violation (pod may have pulled fresh)."
fi
echo "=============================================="
