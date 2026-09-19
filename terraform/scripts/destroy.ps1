$ErrorActionPreference = "Stop"

$profile = if ($env:MINIKUBE_PROFILE) { $env:MINIKUBE_PROFILE } else { "todo-minikube" }
$delete = $env:DELETE_CLUSTER_ON_DESTROY

if ($delete -eq "true") {
  Write-Host "Deleting Minikube profile '$profile'..."
  minikube delete -p $profile
} else {
  Write-Host "Leaving Minikube profile '$profile' running. Set delete_cluster_on_destroy=true to remove it."
}
