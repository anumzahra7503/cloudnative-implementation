$ErrorActionPreference = "Stop"

$profile = if ($env:MINIKUBE_PROFILE) { $env:MINIKUBE_PROFILE } else { "todo-minikube" }
$driver = if ($env:MINIKUBE_DRIVER) { $env:MINIKUBE_DRIVER } else { "docker" }
$cpus = if ($env:MINIKUBE_CPUS) { $env:MINIKUBE_CPUS } else { "2" }
$memory = if ($env:MINIKUBE_MEMORY) { $env:MINIKUBE_MEMORY } else { "4096" }
$owner = if ($env:DOCKERHUB_USERNAME) { $env:DOCKERHUB_USERNAME } else { "anumzahra" }
$tag = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "v1" }
$ns = if ($env:NAMESPACE) { $env:NAMESPACE } else { "todo" }
$apiPort = if ($env:API_NODE_PORT) { [int]$env:API_NODE_PORT } else { 30080 }
$frontendPort = if ($env:FRONTEND_NODE_PORT) { [int]$env:FRONTEND_NODE_PORT } else { 30081 }
$k8sDir = if ($env:K8S_DIR) { $env:K8S_DIR } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..\k8s")).Path }

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $name"
  }
}

function Invoke-Kubectl {
  & kubectl @args
  if ($LASTEXITCODE -ne 0) {
    throw "kubectl failed: kubectl $($args -join ' ')"
  }
}

function Set-ServiceNodePort([string]$service, [int]$port) {
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "todo-$service-nodeport.json"
  $json = "[{`"op`":`"replace`",`"path`":`"/spec/ports/0/nodePort`",`"value`":$port}]"
  [System.IO.File]::WriteAllText($tmp, $json)
  Invoke-Kubectl -n $ns patch svc $service --type=json --patch-file $tmp
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

# Docker Desktop on Windows does not publish Minikube NodePorts on the Minikube IP.
$apiUrl = "http://${ip}:${apiPort}"
$usePortForward = $false
if ($env:OS -eq "Windows_NT") {
  $usePortForward = $true
  $apiUrl = "http://127.0.0.1:18080"
}

Write-Host "Minikube IP: $ip"
Write-Host "NodePorts: api=$apiPort frontend=$frontendPort"
Write-Host "Frontend API endpoint: $apiUrl"

Write-Host "Applying Kubernetes manifests from $k8sDir ..."
Invoke-Kubectl apply -f (Join-Path $k8sDir "namespace.yaml")
Invoke-Kubectl wait --for=jsonpath="{.status.phase}"=Active "namespace/$ns" --timeout=60s
Invoke-Kubectl apply -f $k8sDir

Set-ServiceNodePort -service todo-api -port $apiPort
Set-ServiceNodePort -service todo-frontend -port $frontendPort

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
if ($LASTEXITCODE -ne 0) {
  throw "kubectl failed while patching todo-frontend-env"
}

Invoke-Kubectl -n $ns set image deployment/todo-api "todo-api=${owner}/go-to-do-api:${tag}"
Invoke-Kubectl -n $ns set image deployment/todo-frontend "todo-frontend=${owner}/go-to-do-frontend:${tag}"
Invoke-Kubectl -n $ns rollout restart deployment/todo-frontend

Write-Host "Waiting for workloads..."
Invoke-Kubectl -n $ns rollout status deployment/mongodb --timeout=300s
Invoke-Kubectl -n $ns rollout status deployment/todo-api --timeout=300s
Invoke-Kubectl -n $ns rollout status deployment/todo-frontend --timeout=300s

Write-Host ""
Write-Host "Application is deployed."
if ($usePortForward) {
  Write-Host "Docker Desktop on Windows: keep these port-forwards running, then open the UI."
  Write-Host "  kubectl --context=$profile -n $ns port-forward svc/todo-api 18080:8080"
  Write-Host "  kubectl --context=$profile -n $ns port-forward svc/todo-frontend 18081:8080"
  Write-Host "  UI:  http://127.0.0.1:18081"
  Write-Host "  API: http://127.0.0.1:18080/healthz"
} else {
  Write-Host "  UI:  http://${ip}:${frontendPort}"
  Write-Host "  API: http://${ip}:${apiPort}/healthz"
}
Write-Host "  kubectl --context=$profile get pods -n $ns"
