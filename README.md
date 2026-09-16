# Voting App — Azure DevOps CI/CD & Argo CD GitOps

A containerized microservices voting application deployed to Azure Kubernetes Service (AKS) using Azure DevOps Pipelines, Azure Container Registry (ACR), Kubernetes, and Argo CD.

This repository documents an end-to-end CI/CD and GitOps workflow: application changes are built into container images, pushed to ACR, wired into Kubernetes manifests stored in Git, and automatically synchronized to AKS by Argo CD.

---

## Application Overview

| Service        | Role                                                   |
| -------------- | ------------------------------------------------------ |
| **Vote**       | Python web app where users submit a vote               |
| **Redis**      | In-memory store that receives new votes                |
| **Worker**     | Reads votes from Redis and persists them to PostgreSQL |
| **PostgreSQL** | Durable storage for vote data                          |
| **Result**     | Node.js web app that displays live results             |

```text
Vote (Python) → Redis → Worker → PostgreSQL → Result (Node.js)
```

Runs locally with Docker Compose, or in Kubernetes for the full CI/CD + GitOps setup described below.

---

## How the Pipeline Works

At a high level, a code change moves through four stages before it's live on the cluster:

1. **Trigger** — A commit to the application code triggers the Azure Pipeline for that service.
2. **Build & Publish** — The pipeline builds a Docker image, tags it with the unique Azure Pipelines Build ID, and pushes it to ACR.
3. **Update Desired State** — The pipeline updates the image tag in the relevant Kubernetes manifest and commits that change back to Git. Git — not the pipeline — is the source of truth for what should be running.
4. **Sync** — Argo CD watches the Git repository, detects the manifest change, and reconciles the cluster to match it.

This is the core GitOps principle behind the setup: **the CI pipeline never talks to the cluster directly.** It only ever changes Git. Argo CD is solely responsible for applying changes to AKS. This separation keeps deployments auditable (every change is a Git commit) and keeps the pipeline's permissions limited to "can write to Git" rather than "can modify the cluster."

```text
Code Change → Azure Pipelines CI → Build Image → Push to ACR
     → Update K8s Manifest → Git Commit → Argo CD Detects Change
     → Argo CD Syncs → AKS
```

### Architecture diagram

> 📌 **Placeholder:** the visual architecture diagram will be added here once generated, at `docs/azure-devops-gitops-architecture.png`. The reference below is already wired up — it will render automatically as soon as that file is added to the repo.

![Azure DevOps CI/CD and GitOps Architecture](docs/azure-devops-gitops-architecture.png)

---

## Continuous Integration (Azure Pipelines)

For each triggered build, the pipeline:

1. Detects changes in the relevant application directory.
2. Builds the Docker image.
3. Tags the image with the Azure Pipelines **Build ID** — this gives every build a unique, traceable version instead of relying on `latest`.
4. Pushes the image to ACR.
5. Updates the corresponding Kubernetes deployment manifest with the new image tag.
6. Commits the updated manifest back to Git.

```text
rahulazurecicd.azurecr.io/votingapp:15
```

---

## Continuous Delivery (Argo CD / GitOps)

Argo CD handles delivery, separately from CI. The Kubernetes manifests in Git are the **desired state**; Argo CD's only job is to make the cluster match them.

```yaml
image: rahulazurecicd.azurecr.io/votingapp:15
```

```text
Git Manifest (desired state) → Argo CD (reconciliation) → AKS (actual state)
```

Why it's split this way: if the pipeline applied changes to AKS directly, there would be no single record of what's actually deployed, and no easy way to roll back other than re-running a pipeline. With GitOps, rolling back is just reverting a Git commit — Argo CD picks it up and reconciles the cluster automatically.

---

## Kubernetes Layout

Manifests live in:

```text
k8s-specifications/
```

Service exposure:

- **ClusterIP** — internal-only services (Redis, PostgreSQL)
- **NodePort** — externally reachable services (Vote, Result)

| Service | NodePort |
| ------- | -------- |
| Vote    | 31000    |
| Result  | 31001    |

---

## Azure Container Registry

ACR stores every image the pipelines build, tagged by Build ID for traceability:

```text
rahulazurecicd.azurecr.io
├── votingapp:15
├── workerservice:15
└── ...
```

### Granting AKS Access to ACR (Image Pull Secret)

Pushing an image to ACR doesn't automatically give the AKS cluster permission to pull it — Kubernetes has no built-in awareness of the registry or how to authenticate against it. Without a credential, pods fail to start with an `ImagePullBackOff` error.

To fix this, create a Docker registry secret in the **same namespace the workloads are deployed to**, and reference it in the deployment's `imagePullSecrets`.

**Get credentials:** In the Azure Portal, open the Container Registry → **Access keys** → enable **Admin user**. This exposes a username and password you can use for authentication.

**Create the secret:**

```bash
kubectl create secret docker-registry <secret-name> \
    --namespace <namespace> \
    --docker-server=<container-registry-name>.azurecr.io \
    --docker-username=<service-principal-ID> \
    --docker-password=<service-principal-password>
```

**Why the namespace matters:** secrets in Kubernetes are namespace-scoped. A secret created in `default` is invisible to pods running in `voting` — it has to be created in the exact namespace the Vote/Worker/Result deployments run in, or the pull will still fail.

---

## Automated Manifest Updates

`scripts/updateK8sManifests.sh` is what closes the loop between "image pushed to ACR" and "Git reflects the new desired state." It:

1. Clones the repository.
2. Updates the image reference in the manifest.
3. Stages the change.
4. Configures Git commit identity.
5. Commits.
6. Pushes back to the repository.

```bash
scripts/updateK8sManifests.sh vote \
    rahulazurecicd.azurecr.io \
    votingapp \
    15
```

Result:

```yaml
image: rahulazurecicd.azurecr.io/votingapp:15
```

---

## Authentication & Permissions

Two separate concerns are involved here, and mixing them up is the source of most pipeline failures in this setup:

| Concern                                                | Mechanism                                                           | Purpose                                                                                   |
| ------------------------------------------------------ | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| **Authentication** — proving who the pipeline is       | `System.AccessToken`                                                | Lets Git operations (clone/push) authenticate without a Personal Access Token in the repo |
| **Authorization** — what the pipeline is allowed to do | Repository **Contribute** permission for the Build Service identity | Required specifically for `git push` to succeed                                           |
| **Commit metadata** — who shows up as the author       | `git config user.name` / `user.email`                               | Cosmetic only — has no effect on auth                                                     |

```bash
git config --global http.extraheader \
  "AUTHORIZATION: bearer ${SYSTEM_ACCESSTOKEN}"

git config user.name "Azure Pipelines"
git config user.email "azure-pipelines@local"
```

Passing the token to the script:

```yaml
env:
  SYSTEM_ACCESSTOKEN: $(System.AccessToken)
```

**Why this matters:** cloning can succeed with authentication alone. Pushing needs authorization too. If the Build Service identity lacks Contribute permission, the clone step works fine and the push fails — which is a common point of confusion (see Troubleshooting below).

---

## Pipeline Agent vs. AKS Node Pool

These two are easy to conflate, so it's worth stating the distinction plainly:

|                | Azure Pipelines Agent                             | AKS Node Pool                                                |
| -------------- | ------------------------------------------------- | ------------------------------------------------------------ |
| **What it is** | The machine that _runs the CI/CD job itself_      | The machines that _run the deployed application_             |
| **Lifetime**   | Spun up per job, then discarded                   | Persistent, long-running cluster nodes                       |
| **Example**    | `pool: vmImage: ubuntu-latest` (Microsoft-hosted) | A node pool with 3 nodes running the Vote/Result/Worker pods |

**Microsoft-hosted vs. self-hosted agents:** this project uses a Microsoft-hosted agent (`ubuntu-latest`), a fresh, temporary VM provided by Azure for each run — no maintenance required, but it also means no state (like Git identity) persists between runs. The alternative, a self-hosted agent, is a VM or machine you register and maintain yourself; it's persistent and configurable, but you're responsible for keeping it updated and secure. Neither one is the same as an AKS node — the agent builds and pushes the image; AKS nodes are where the resulting containers actually run.

---

## Argo CD Reconciliation Interval

By default, Argo CD polls Git on a fixed schedule. For faster feedback during development, the interval can be shortened in the `argocd-cm` ConfigMap:

```yaml
data:
  timeout.reconciliation: 10s
  timeout.reconciliation.jitter: 0s
```

After editing, restart the affected components for the change to take effect:

```bash
kubectl -n argocd rollout restart deployment argocd-repo-server
kubectl -n argocd rollout restart statefulset argocd-application-controller
```

**Why not leave it this low permanently:** a 10s poll is convenient while iterating, but it adds continuous API and reconciliation load. Production setups should use a longer interval (or rely on Argo CD's webhook-based instant sync instead of polling).

---

## Troubleshooting

Issues actually hit while building this pipeline, and how they were resolved.

### 1. Script fails with `$'\r': command not found`

- **Symptom:** `$'\r': command not found`, or `git: 'push\r' is not a git command`
- **Cause:** The shell script had Windows-style CRLF line endings, but it runs on a Linux pipeline agent, which interprets the trailing `\r` as part of the command.
- **Fix:** Strip the carriage returns before execution:
  ```yaml
  - script: sed -i 's/\r$//' scripts/updateK8sManifests.sh
    displayName: Convert script to LF
  ```
- **Why this is the right fix:** it lets the script keep whatever line endings it has in source control (e.g. if edited on Windows) without needing every contributor to change their editor settings — the pipeline normalizes it at run time.

### 2. Git commit fails with "Author identity unknown"

- **Symptom:** `Author identity unknown`
- **Cause:** Microsoft-hosted agents are fresh VMs for every run — there's no persisted Git identity to fall back on.
- **Fix:** Set identity explicitly before committing:
  ```bash
  git config user.name "Azure Pipelines"
  git config user.email "azure-pipelines@local"
  ```
- **Why:** this is commit _metadata_, unrelated to authentication — it has to be set every run because the agent doesn't persist state between runs.

## Local Development

```bash
docker compose up
```

- Vote: [http://localhost:8080](http://localhost:8080)
- Result: [http://localhost:8081](http://localhost:8081)

```bash
docker compose down
```

---

## Kubernetes Deployment

```bash
kubectl create -f k8s-specifications/
kubectl get pods -n voting
kubectl get svc -n voting
```

- Vote → NodePort `31000`
- Result → NodePort `31001`

To tear down:

```bash
kubectl delete -f k8s-specifications/
```

### Opening Network Access (VM Scale Set Inbound Rules)

AKS nodes run inside a Virtual Machine Scale Set (VMSS). By default, the network security group attached to that VMSS blocks inbound traffic on arbitrary ports — so even though a NodePort service exposes the app on the node, external traffic can't reach it until an inbound rule explicitly allows it.

Add inbound security rules on the VMSS networking for the following ports:

| Port    | Purpose                       |
| ------- | ----------------------------- |
| `31000` | Vote application (NodePort)   |
| `31001` | Result application (NodePort) |
| `31585` | Argo CD access                |

Without these rules, the services are running correctly inside the cluster but are unreachable from outside it — a common source of "it's deployed but I can't open it in the browser."

---

## Summary

The core principle behind this setup, in one line each:

1. **CI builds the artifact.**
2. **Git stores the desired deployment state.**
3. **Argo CD synchronizes that state to Kubernetes.**

## Technologies

Git · GitHub · Azure Repos · Azure DevOps Pipelines · Docker · Azure Container Registry (ACR) · Kubernetes · Azure Kubernetes Service (AKS) · Argo CD · Python · Node.js · Redis · PostgreSQL · Bash · Azure CLI · kubectl

---

## About This Project

This project implements CI/CD and GitOps around a distributed voting application (Vote/Redis/Worker/PostgreSQL/Result) — a common reference architecture for demonstrating multi-service deployments. The application layer is the vehicle; the DevOps implementation — pipeline design, image versioning, GitOps sync, authentication/authorization setup, and the troubleshooting above — is the focus of this repository.
