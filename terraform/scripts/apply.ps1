$ErrorActionPreference = "Stop"

$profile = if ($env:MINIKUBE_PROFILE) { $env:MINIKUBE_PROFILE } else { "todo-minikube" }
$driver = if ($env:MINIKUBE_DRIVER) { $env:MINIKUBE_DRIVER } else { "docker" }
$cpus = if ($env:MINIKUBE_CPUS) { $env:MINIKUBE_CPUS } else { "2" }
$memory = if ($env:MINIKUBE_MEMORY) { $env:MINIKUBE_MEMORY } else { "4096" }
$owner = if ($env:DOCKERHUB_USERNAME) { $env:DOCKERHUB_USERNAME } else { "anumzahra" }
$tag = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "v1" }
$ns = if ($env:NAMESPACE) { $env:NAMESPACE } else { "todo" }
$k8sDir = if ($env:K8S_DIR) { $env:K8S_DIR } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..\k8s")).Path }

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $name"
  }
}

Assert-Command minikube
Assert-Command kubectl

Write-Host "Starting Minikube profile '$profile' (single node, Calico CNI)..."
minikube start `
  -p $profile `
  --nodes=1 `
  --driver=$driver `
  --cpus=$cpus `
  --memory=$memory `
  --cni=calico

minikube update-context -p $profile | Out-Null
kubectl config use-context $profile | Out-Null
kubectl wait --for=condition=Ready nodes --all --timeout=180s | Out-Null
kubectl rollout status ds/calico-node -n kube-system --timeout=180s 2>$null | Out-Null

$ip = (minikube ip -p $profile).Trim()
if (-not $ip) {
  throw "Could not read Minikube IP"
}

$apiUrl = "http://${ip}:30080"
Write-Host "Minikube IP: $ip"
Write-Host "Frontend API endpoint: $apiUrl"

Write-Host "Applying Kubernetes manifests from $k8sDir ..."
kubectl apply -f $k8sDir

$secretPatch = @"
apiVersion: v1
kind: Secret
metadata:
  name: todo-frontend-env
  namespace: $ns
type: Opaque
stringData:
  REACT_APP_API_ENDPOINT: $apiUrl
"@
$secretPatch | kubectl apply -f -

kubectl -n $ns set image deployment/todo-api todo-api="${owner}/go-to-do-api:${tag}" | Out-Null
kubectl -n $ns set image deployment/todo-frontend todo-frontend="${owner}/go-to-do-frontend:${tag}" | Out-Null
kubectl -n $ns rollout restart deployment/todo-frontend | Out-Null

Write-Host "Waiting for workloads..."
kubectl -n $ns rollout status deployment/mongodb --timeout=180s
kubectl -n $ns rollout status deployment/todo-api --timeout=180s
kubectl -n $ns rollout status deployment/todo-frontend --timeout=180s

Write-Host ""
Write-Host "Application is deployed."
Write-Host "  UI:  http://${ip}:30081"
Write-Host "  API: http://${ip}:30080/healthz"
Write-Host "  kubectl --context=$profile get pods -n $ns"
