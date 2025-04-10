---
sidebar_position: 2
---
# Deploying the Tracebloc Client Locally (Minikube + Tilt)

This guide walks you through deploying the Tracebloc client on a **local Kubernetes cluster** using **Minikube** and **Tilt** — ideal for development, testing, and debugging Tracebloc components locally.

---

## 🔧 Prerequisites

Install the following tools:

| Tool       | Purpose                     | Install Guide |
|------------|-----------------------------|---------------|
| Docker     | Container runtime           | [Install Docker](https://docs.docker.com/get-docker/) |
| Minikube   | Lightweight local K8s       | [Install Minikube](https://minikube.sigs.k8s.io/docs/start/) |
| Tilt       | Dev tool for Kubernetes     | [Install Tilt](https://docs.tilt.dev/install.html) |
| kubectl    | Kubernetes CLI              | [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |
| Helm 3.x   | Package manager for K8s     | [Install Helm](https://helm.sh/docs/intro/install/) |

You'll also need:
- Tracebloc client credentials (username and password)
- At least **4 GB RAM** and **2 CPU cores** for smooth local execution

---

## 🚀 Deployment Steps

### 1. Start a Local Cluster 
- Minikube

   ```bash
   minikube start --driver=docker
   kubectl get nodes
   ```
- Tilt
   ```bash
   tilt up
   kubectl get nodes
   ```

---

### 2. Add the Tracebloc Helm Chart

```bash
helm repo add tracebloc https://tracebloc.github.io/client/
helm repo update
```

---

### 3. Configure Your Deployment

#### 1. Download Helm values:

```bash
helm show values tracebloc/local > values.yaml
```

#### 2. Edit `values.yaml`:

```yaml
# Authentication
jobsManager:
  env:
    CLIENT_USERNAME: "your-username"

# Enable development mode
development:
  enabled: true
  useLocalImages: true  # Required for Tilt to use locally built images

# Resource Requests & Limits
resources:
  requests:
    cpu: "200m"
    memory: "512Mi"
  limits:
    cpu: "1000m"
    memory: "1Gi"

# Persistent Volumes
sharedData:
  name: shared-data
  storage: 10Gi

logsPvc:
  name: logs-pvc
  storage: 1Gi

mysqlPvc:
  name: mysql-pvc
  storage: 1Gi
```

---

### 4. Create Client Secret

```bash
kubectl create secret generic tracebloc-secrets \
  --from-literal=CLIENT_PASSWORD='your-client-password'
```

---

### 5. Deploy the Helm Chart

```bash
kubectl create namespace tracebloc

helm install tracebloc tracebloc/local \
  --namespace tracebloc \
  --values values.yaml
```

---

### 6. Configure and Run Tilt

#### 1. Create a `Tiltfile` in your repo:

```python
k8s_yaml('kubernetes.yaml')
k8s_resource('tracebloc', port_forwards=8080)

docker_build('tracebloc/client', '.')
```

#### 2. Start Tilt:

```bash
tilt up
```

Tilt will watch your local code and auto-redeploy changes.

---

### 7. Access the Application

```bash
minikube service tracebloc -n tracebloc --url
```

Tilt may also expose a web UI at `http://localhost:10350` to view service status and logs.

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
<summary><strong>Insufficient Resources</strong></summary>

```bash
kubectl top nodes
kubectl top pods -n tracebloc
```
</details>

<details>
<summary><strong>Local Image Not Detected</strong></summary>

Make sure `useLocalImages: true` is set and `docker_build()` is used in `Tiltfile`.

</details>

<details>
<summary><strong>Persistent Volume Errors</strong></summary>

```bash
kubectl get pvc -n tracebloc
kubectl get pv
```
</details>

---

## 🔄 Maintenance

### Upgrade Deployment

```bash
helm show values tracebloc/local > new-values.yaml
# Update file, then:
helm upgrade tracebloc tracebloc/local \
  --namespace tracebloc \
  --values new-values.yaml
```

---

### Cleanup

```bash
helm uninstall tracebloc -n tracebloc
kubectl delete pvc --all -n tracebloc
kubectl delete namespace tracebloc

# Optional: Stop and delete Minikube cluster
minikube delete
```

---

## 📬 Need Help?

- 📧 Email: [support@tracebloc.io](mailto:support@tracebloc.io)
- 📚 Docs: [https://docs.tracebloc.io](https://docs.tracebloc.io)

---

> ⚠️ **Note**: Replace placeholders (`your-username`, etc.) before executing commands. Local clusters are best for dev and testing — not production.