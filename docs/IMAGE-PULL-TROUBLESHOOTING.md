# Image Pull Troubleshooting

## 1. Get the exact error

```bash
kubectl describe pod -n runtime-demo -l app=integrity-demo-app | grep -A 20 "Events:"
```

Common errors:
- **`not found`** — Image doesn't exist at that path/tag in the registry
- **`401` / `unauthorized`** — Auth failure; check `imagePullSecrets`
- **`403` / `forbidden`** — No permission to pull; check token scope
- **`no basic auth credentials`** — Secret missing or wrong `docker-server`

## 2. Verify the image exists in the registry

```bash
# Try pulling locally (requires docker login first)
docker login danielw.jfrog.io
docker pull danielw.jfrog.io/runtimedemo-integrity-demo-app-docker-dev/integrity-demo-app:latest
```

If local pull fails, the image isn't in the registry or the path/tag is wrong.

## 3. Check imagePullSecrets

```bash
kubectl get secret artifactory-registry -n runtime-demo
kubectl describe secret artifactory-registry -n runtime-demo
```

- Secret must exist in the same namespace as the pod
- `--docker-server` must match the registry host exactly (e.g. `danielw.jfrog.io`)

## 4. Verify deployment image matches registry

```bash
kubectl get deployment integrity-demo-app -n runtime-demo -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Compare with what's in `k8s/integrity-demo-app/deployment.yaml`. Ensure:
- Registry host is correct
- Repository path matches (e.g. `runtimedemo-integrity-demo-app-docker-dev`)
- Tag exists (e.g. `:latest`, `:2`)

## 5. Recreate the secret (if auth is suspect)

```bash
kubectl delete secret artifactory-registry -n runtime-demo
export JFROG_ACCESS_TOKEN="<your-token>"
kubectl create secret docker-registry artifactory-registry \
  --docker-server=danielw.jfrog.io \
  --docker-username=tomj@jfrog.com \
  --docker-password="$JFROG_ACCESS_TOKEN" \
  -n runtime-demo
kubectl rollout restart deployment integrity-demo-app -n runtime-demo
```

## 6. Check for repo path mismatch

Confirm the correct repo name in Artifactory (Administration → Repositories). This project uses `runtimedemo-integrity-demo-app-docker-dev` for integrity-demo-app and `runtimedemo-insecure-demo-app-docker-dev` for insecure-demo-app.
