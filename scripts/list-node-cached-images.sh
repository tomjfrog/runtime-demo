#!/bin/bash
# List container images cached on a specific EKS node.
# Uses kubectl debug to run ctr (containerd CLI) on the node.
# Run after: aws sso login, kubectl configured for cluster.
set -e

NODE="${NODE:-ip-192-168-63-72.us-east-2.compute.internal}"

echo "=== Cached images on node $NODE ==="
echo "Creating debug pod (this may take ~15s)..."
echo ""

# Create a debug pod that stays running so we can exec into it.
# We use a subshell to run kubectl debug in the background.
(
  kubectl debug "node/$NODE" --image=busybox -- sleep 90
) &
DEBUG_PID=$!

# Wait for pod to be created and running
DEBUG_POD=""
for i in $(seq 1 45); do
  sleep 2
  # Find the debug pod (scheduled on our target node by kubectl debug)
  DEBUG_POD=$(kubectl get pods -n default -o name 2>/dev/null | grep node-debugger | head -1 | sed 's|pod/||')
  if [ -n "$DEBUG_POD" ]; then
    PHASE=$(kubectl get pod "$DEBUG_POD" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$PHASE" = "Running" ]; then
      sleep 3
      break
    fi
  fi
done

if [ -z "$DEBUG_POD" ]; then
  echo "Error: Debug pod did not become ready in time."
  kill $DEBUG_PID 2>/dev/null || true
  exit 1
fi

# Run ctr on the host via chroot (EKS nodes have ctr from containerd package)
echo "Listing images..."
kubectl exec -n default "$DEBUG_POD" -c debugger -- chroot /host sh -c \
  'ctr -n k8s.io images ls 2>/dev/null || (CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock crictl images 2>/dev/null) || echo "Neither ctr nor crictl found on node"'

# Clean up
kubectl delete pod "$DEBUG_POD" -n default --ignore-not-found --wait=false 2>/dev/null || true
kill $DEBUG_PID 2>/dev/null || true
