---
sidebar_position: 2
---
# Deploying the Tracebloc Client on Amazon EKS

This guide walks you through deploying the Tracebloc client on **Amazon Elastic Kubernetes Service (EKS)** using Helm.

---

## 🔧 Prerequisites

Ensure the following tools are installed:

| Tool      | Purpose                    | Install Guide |
|-----------|----------------------------|---------------|
| AWS CLI   | Manage AWS services        | [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| kubectl   | Manage Kubernetes clusters | [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |
| Helm 3.x  | Kubernetes package manager | [Install Helm](https://helm.sh/docs/intro/install/) |

You’ll also need:

- An active AWS account
- Access to the Tracebloc Helm chart
- Your Tracebloc client credentials

---

## 🚀 Deployment Steps

### 1. Connect to Your EKS Cluster

```bash
aws eks --region <your-region> update-kubeconfig --name <your-eks-cluster-name>
kubectl get nodes
```

---

### 2. Add the Tracebloc Helm Repository

```bash
helm repo add tracebloc https://tracebloc.github.io/client/
helm repo update
```

---

### 3. Configure Your Deployment

1. Download the default values:

```bash
helm show values tracebloc/eks > values.yaml
```

2. Edit the `values.yaml` file and update the following sections:

#### 🔐 Authentication

```yaml
jobsManager:
  env:
    CLIENT_USERNAME: "your-username"
```

#### 🐳 Docker Registry

```yaml
dockerRegistry:
  create: true
  secretName: regcred
  server: https://index.docker.io/v1/
  username: "your-docker-username"
  password: "your-docker-password"
  email: "your-email"
```

#### 💾 Storage Configuration (EBS-backed PVCs)

```yaml
sharedData:
  name: shared-data
  storage: 50Gi
  storageClass: gp2

logsPvc:
  name: logs-pvc
  storage: 10Gi
  storageClass: gp2

mysqlPvc:
  name: mysql-pvc
  storage: 2Gi
  storageClass: gp2
```

#### ⚙️ Resource Limits

```yaml
resources:
  requests:
    cpu: "50m"
    memory: "207084Ki"
  limits:
    cpu: "100m"
    memory: "414168Ki"

gpu:
  requests: "nvidia.com/gpu=1"
  limits: "nvidia.com/gpu=1"
```

---

### 4. Create Required Kubernetes Secrets

```bash
kubectl create secret generic tracebloc-secrets \
  --from-literal=CLIENT_PASSWORD='your-client-password'
```

---

### 5. Deploy the Client

```bash
kubectl create namespace tracebloc

helm install tracebloc tracebloc/eks \
  --namespace tracebloc \
  --values values.yaml
```

---

### 6. Verify the Deployment

```bash
kubectl get pods -n tracebloc
kubectl get services -n tracebloc
kubectl get pvc -n tracebloc
```

All pods should be in a `Running` state within a few minutes.

---

## 🛠 Troubleshooting

<details>
<summary><strong>Pods Not Starting</strong></summary>

```bash
kubectl get pods -n tracebloc
kubectl logs <pod-name> -n tracebloc
kubectl describe pod <pod-name> -n tracebloc
```

</details>

<details>
<summary><strong>Storage Issues</strong></summary>

```bash
kubectl get pvc -n tracebloc
kubectl get pv
```

</details>

<details>
<summary><strong>Image Pull Errors</strong></summary>

```bash
kubectl get secret regcred -n tracebloc
```

</details>

---

## 🔄 Maintenance

### Upgrade the Deployment

```bash
helm show values tracebloc/eks > new-values.yaml
# Edit as needed
helm upgrade tracebloc tracebloc/eks \
  --namespace tracebloc \
  --values new-values.yaml
```

---

### Uninstall the Client

```bash
helm uninstall tracebloc -n tracebloc
kubectl delete pvc --all -n tracebloc
kubectl delete namespace tracebloc
```

---

## 📬 Need Help?

- 📧 Email: [support@tracebloc.io](mailto:support@tracebloc.io)  
- 📚 Docs: [Tracebloc Documentation Portal](https://docs.tracebloc.io)

---

> ⚠️ **Note**: Replace all placeholders (`your-username`, `your-password`, `your-region`) with actual values before running commands.