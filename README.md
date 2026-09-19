# Cloud-native To-Do app on Minikube

This repository packages a three-tier to-do application (React frontend, Go API, MongoDB) for a **single-node Minikube** cluster.

Upstream application: [abdennour/cloudnative-implementation](https://github.com/abdennour/cloudnative-implementation) (fork of Shubham Chadokar’s Go to-do app). This fork adds GitHub Actions, plain Kubernetes manifests, NetworkPolicies, and Terraform so that **one `terraform apply`** starts Minikube and deploys the app.

## Components

| Component | Source | Runtime |
| --- | --- | --- |
| **Frontend** | `client/` (React 16, nginx) | Deployment `todo-frontend`, NodePort **30081** |
| **API** | `server/` (Go + Gorilla Mux) | Deployment `todo-api`, NodePort **30080** |
| **Database** | Bitnami MongoDB `4.4.1` | Deployment `mongodb`, ClusterIP **27017** only |
| **CI** | `.github/workflows/` | Builds and pushes images to Docker Hub |
| **Cluster + deploy** | `terraform/` | Starts Minikube (Calico) and applies `k8s/` |

Request flow:

1. Browser opens the UI on NodePort 30081.
2. An init container writes `config/env.js` from `REACT_APP_API_ENDPOINT` (the Minikube IP + API NodePort).
3. The UI calls the Go API (`/api/task`, …).
4. The API reads and writes MongoDB. Frontend pods are **not** allowed to reach MongoDB (NetworkPolicy).

Namespace: `todo`. Minikube profile: `todo-minikube`.

## Prerequisites

- Docker Desktop (or another Minikube driver you set with `minikube_driver`)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- kubectl
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3
- GitHub account (private fork) and a [Docker Hub](https://hub.docker.com/) account
- GitHub CLI (`gh`) if you want to fork from the command line

## 1. Fork to a private repository

```bash
gh repo fork abdennour/cloudnative-implementation --fork-name cloudnative-implementation --clone=false
gh repo edit <your-github-user>/cloudnative-implementation --visibility private
git clone https://github.com/<your-github-user>/cloudnative-implementation.git
cd cloudnative-implementation
```

## 2. Docker Hub + GitHub Actions secrets

Create a Docker Hub access token, then add repository secrets:

| Secret | Value |
| --- | --- |
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |

Workflows:

- Changes under `client/` → `.github/workflows/frontend.yml` → `<user>/go-to-do-frontend:v1` (also `latest` and the git SHA)
- Changes under `server/` → `.github/workflows/api.yml` → `<user>/go-to-do-api:v1` (also `latest` and the git SHA)

Push the workflows (or use **Actions → workflow_dispatch**) so images exist on Docker Hub before the first cluster deploy.

If you are using this clone as-is, default image names are `anumzahra/go-to-do-api:v1` and `anumzahra/go-to-do-frontend:v1`. Override with Terraform:

```hcl
dockerhub_username = "your-dockerhub-user"
```

### Optional: build images locally instead of waiting for CI

```bash
docker build -t <dockerhub-user>/go-to-do-api:v1 --target release ./server
docker build -t <dockerhub-user>/go-to-do-frontend:v1 --target release ./client
docker push <dockerhub-user>/go-to-do-api:v1
docker push <dockerhub-user>/go-to-do-frontend:v1
```

## 3. Deploy with Terraform (cluster + app)

From the repo root:

```bash
cd terraform
terraform init
terraform apply
```

Confirm the plan. One apply will:

1. Start a **single-node** Minikube cluster (`--cni=calico` so NetworkPolicies work)
2. `kubectl apply -f ../k8s/`
3. Set `REACT_APP_API_ENDPOINT` to `http://<minikube-ip>:30080`
4. Point Deployments at `<dockerhub_username>/go-to-do-*:v1`
5. Wait until `mongodb`, `todo-api`, and `todo-frontend` roll out

Useful variables (`-var` or a `terraform.tfvars` file you do not commit):

| Variable | Default | Meaning |
| --- | --- | --- |
| `dockerhub_username` | `anumzahra` | Docker Hub namespace |
| `image_tag` | `v1` | Image tag |
| `minikube_profile` | `todo-minikube` | Cluster profile |
| `minikube_driver` | `docker` | Minikube driver |
| `delete_cluster_on_destroy` | `false` | If `true`, `terraform destroy` deletes Minikube |

## 4. Open the app

```bash
minikube ip -p todo-minikube
kubectl --context=todo-minikube get pods,svc -n todo
```

- UI: `http://<minikube-ip>:30081`
- API health: `http://<minikube-ip>:30080/healthz`
- List tasks: `http://<minikube-ip>:30080/api/task`

On Docker Desktop / some Windows setups, if the NodePort is not reachable at the Minikube IP, run:

```bash
minikube -p todo-minikube service todo-frontend -n todo
```

## 5. Apply manifests without Terraform (optional)

If Minikube is already running with Calico:

```bash
minikube start -p todo-minikube --nodes=1 --cni=calico --driver=docker
kubectl apply -f k8s/
```

Then patch the frontend API URL:

```bash
kubectl -n todo create secret generic todo-frontend-env \
  --from-literal=REACT_APP_API_ENDPOINT=http://$(minikube ip -p todo-minikube):30080 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n todo rollout restart deployment/todo-frontend
```

## Bonus: frontend cannot talk to the database

`k8s/network-policy.yaml` installs:

- Default deny ingress/egress in `todo`
- DNS to `kube-system` (so names still resolve)
- MongoDB **ingress only from** `app=todo-api`
- Frontend **egress only to** `todo-api:8080` (plus DNS)

Calico is required. The default Minikube CNI does not enforce NetworkPolicy.

Quick check from a frontend pod (should fail to connect):

```bash
kubectl --context=todo-minikube -n todo exec deploy/todo-frontend -- \
  wget -qO- --timeout=3 http://mongodb:27017 || echo "blocked (expected)"
```

The frontend image is distroless/nginx, so `wget` may be missing. Use a debug pod labeled as frontend, or `kubectl run` with the frontend labels.

## Kubernetes objects (`k8s/`)

| File | What it creates |
| --- | --- |
| `namespace.yaml` | Namespace `todo` |
| `secret.yaml` | Mongo credentials and frontend `REACT_APP_API_ENDPOINT` |
| `db.yaml` | MongoDB Deployment + ClusterIP Service |
| `api.yaml` | API Deployment (waits for Mongo on 27017) + NodePort 30080 |
| `frontend.yaml` | Frontend Deployment (generates `env.js`) + NodePort 30081 |
| `network-policy.yaml` | Isolation described above |

Demo credentials match `.env.example` (`appuser` / `apppass`). Change the Secret before any non-demo use.

## Original Compose / Helm path

The upstream Docker Compose and Helmfile flow is unchanged:

```bash
cp .env.example .env
docker-compose up -d
# UI http://localhost:8081  API http://localhost:8080
```

Helmfile still lives in `helmfile.yaml` and `.helm-charts/`. The assignment deliverable is the **Minikube + manifests + Terraform** path above, not Helm.

## Authors

- Shubham Kumar Chadokar — original application
- Abdennour Toumi — Docker / Helm packaging
- This fork — GitHub Actions, Kubernetes manifests, NetworkPolicy, Terraform for Minikube
