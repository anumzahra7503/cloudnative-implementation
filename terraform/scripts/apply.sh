#!/usr/bin/env bash
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-todo-minikube}"
DRIVER="${MINIKUBE_DRIVER:-docker}"
CPUS="${MINIKUBE_CPUS:-2}"
MEMORY="${MINIKUBE_MEMORY:-4096}"
OWNER="${DOCKERHUB_USERNAME:-anumzahra}"
TAG="${IMAGE_TAG:-v1}"
NS="${NAMESPACE:-todo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${K8S_DIR:-$(cd "${SCRIPT_DIR}/../../k8s" && pwd)}"

for cmd in minikube kubectl; do
  command -v "$cmd" >/dev/null || { echo "Required command not found: $cmd" >&2; exit 1; }
done

echo "Starting Minikube profile '${PROFILE}' (single node, Calico CNI)..."
minikube start \
  -p "${PROFILE}" \
  --nodes=1 \
  --driver="${DRIVER}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --cni=calico

minikube update-context -p "${PROFILE}" >/dev/null
kubectl config use-context "${PROFILE}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
kubectl rollout status ds/calico-node -n kube-system --timeout=180s >/dev/null 2>&1 || true

IP="$(minikube ip -p "${PROFILE}" | tr -d '[:space:]')"
if [[ -z "${IP}" ]]; then
  echo "Could not read Minikube IP" >&2
  exit 1
fi

API_URL="http://${IP}:30080"
echo "Minikube IP: ${IP}"
echo "Frontend API endpoint: ${API_URL}"

echo "Applying Kubernetes manifests from ${K8S_DIR} ..."
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Active "namespace/${NS}" --timeout=60s
kubectl apply -f "${K8S_DIR}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: todo-frontend-env
  namespace: ${NS}
type: Opaque
stringData:
  REACT_APP_API_ENDPOINT: ${API_URL}
EOF

kubectl -n "${NS}" set image deployment/todo-api "todo-api=${OWNER}/go-to-do-api:${TAG}" >/dev/null
kubectl -n "${NS}" set image deployment/todo-frontend "todo-frontend=${OWNER}/go-to-do-frontend:${TAG}" >/dev/null
kubectl -n "${NS}" rollout restart deployment/todo-frontend >/dev/null

echo "Waiting for workloads..."
kubectl -n "${NS}" rollout status deployment/mongodb --timeout=300s
kubectl -n "${NS}" rollout status deployment/todo-api --timeout=300s
kubectl -n "${NS}" rollout status deployment/todo-frontend --timeout=300s

echo
echo "Application is deployed."
echo "  UI:  http://${IP}:30081"
echo "  API: http://${IP}:30080/healthz"
echo "  kubectl --context=${PROFILE} get pods -n ${NS}"
