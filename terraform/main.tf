terraform {
  required_version = ">= 1.3.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "minikube_profile" {
  description = "Single-node Minikube profile name."
  type        = string
  default     = "todo-minikube"
}

variable "minikube_driver" {
  description = "Minikube driver (docker is recommended)."
  type        = string
  default     = "docker"
}

variable "dockerhub_username" {
  description = "Docker Hub namespace that hosts the API and frontend images."
  type        = string
  default     = "anumzahra"
}

variable "image_tag" {
  description = "Image tag built by GitHub Actions."
  type        = string
  default     = "v1"
}

variable "namespace" {
  description = "Kubernetes namespace for the to-do app."
  type        = string
  default     = "todo"
}

variable "api_node_port" {
  description = "NodePort for the todo-api Service. The apply scripts patch this onto the cluster after kubectl apply."
  type        = number
  default     = 30080
}

variable "frontend_node_port" {
  description = "NodePort for the todo-frontend Service. The apply scripts patch this onto the cluster after kubectl apply."
  type        = number
  default     = 30081
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  description = "Minikube memory in MB."
  type        = number
  default     = 4096
}

variable "delete_cluster_on_destroy" {
  description = "If true, terraform destroy deletes the Minikube profile."
  type        = bool
  default     = false
}

locals {
  is_windows        = substr(pathexpand("~"), 1, 1) == ":"
  apply_script      = local.is_windows ? "${path.module}/scripts/apply.ps1" : "${path.module}/scripts/apply.sh"
  apply_interpreter = local.is_windows ? ["PowerShell", "-NoProfile", "-File"] : ["/bin/bash"]
  destroy_script    = local.is_windows ? "${path.module}/scripts/destroy.ps1" : "${path.module}/scripts/destroy.sh"
  manifests_hash = sha256(join("", [
    for f in fileset("${path.module}/../k8s", "*.yaml") :
    filesha256("${path.module}/../k8s/${f}")
  ]))
}

resource "null_resource" "minikube_and_app" {
  triggers = {
    profile           = var.minikube_profile
    driver            = var.minikube_driver
    dockerhub         = var.dockerhub_username
    image_tag         = var.image_tag
    namespace         = var.namespace
    api_port          = tostring(var.api_node_port)
    frontend_port     = tostring(var.frontend_node_port)
    manifests_hash    = local.manifests_hash
    delete_on_destroy = tostring(var.delete_cluster_on_destroy)
  }

  provisioner "local-exec" {
    interpreter = local.apply_interpreter
    command     = local.apply_script
    environment = {
      MINIKUBE_PROFILE   = var.minikube_profile
      MINIKUBE_DRIVER    = var.minikube_driver
      MINIKUBE_CPUS      = tostring(var.cpus)
      MINIKUBE_MEMORY    = tostring(var.memory)
      DOCKERHUB_USERNAME = var.dockerhub_username
      IMAGE_TAG          = var.image_tag
      NAMESPACE          = var.namespace
      API_NODE_PORT      = tostring(var.api_node_port)
      FRONTEND_NODE_PORT = tostring(var.frontend_node_port)
      K8S_DIR            = abspath("${path.module}/../k8s")
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = substr(pathexpand("~"), 1, 1) == ":" ? ["PowerShell", "-NoProfile", "-File"] : ["/bin/bash"]
    command     = substr(pathexpand("~"), 1, 1) == ":" ? "${path.module}/scripts/destroy.ps1" : "${path.module}/scripts/destroy.sh"
    environment = {
      MINIKUBE_PROFILE          = self.triggers.profile
      DELETE_CLUSTER_ON_DESTROY = self.triggers.delete_on_destroy
    }
  }
}

output "minikube_profile" {
  value = var.minikube_profile
}

output "namespace" {
  value = var.namespace
}

output "images" {
  value = {
    api      = "${var.dockerhub_username}/go-to-do-api:${var.image_tag}"
    frontend = "${var.dockerhub_username}/go-to-do-frontend:${var.image_tag}"
    db       = "bitnamilegacy/mongodb:4.4.15"
  }
}

output "next_steps" {
  value = <<-EOT
    After apply succeeds:
      minikube -p ${var.minikube_profile} ip
      kubectl --context=${var.minikube_profile} get pods -n ${var.namespace}
      Open frontend: http://$(minikube -p ${var.minikube_profile} ip):${var.frontend_node_port}
      API health:    http://$(minikube -p ${var.minikube_profile} ip):${var.api_node_port}/healthz
  EOT
}
