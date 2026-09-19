#!/usr/bin/env bash
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-todo-minikube}"
DELETE="${DELETE_CLUSTER_ON_DESTROY:-false}"

if [[ "${DELETE}" == "true" ]]; then
  echo "Deleting Minikube profile '${PROFILE}'..."
  minikube delete -p "${PROFILE}"
else
  echo "Leaving Minikube profile '${PROFILE}' running. Set delete_cluster_on_destroy=true to remove it."
fi
