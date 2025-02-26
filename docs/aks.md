# tracebloc AKS Chart Deployment Guide for Azure AKS

This guide will walk you through the process of deploying the tracebloc application to your Azure Kubernetes Service (AKS) cluster using the **tracebloc AKS Chart**.

## Prerequisites

1. An active Azure subscription
2. Azure CLI installed and configured
3. kubectl installed and configured
4. Helm 3.x installed on your local machine
5. Access to the tracebloc AKS chart repository
6. Docker registry credentials (for pulling tracebloc images)

## Step 1: Set Up Azure Resources

1. First, log in to Azure CLI:
```bash
az login
```

2. Create a resource group if you don't have one:
```bash
az group create --name <your-resource-group> --location <region>
```

3. Create an AKS cluster:
```bash
az aks create \
    --resource-group <your-resource-group> \
    --name <your-aks-cluster-name> \
    --node-count 2 \
    --enable-addons monitoring \
    --generate-ssh-keys
```

4. Connect to your AKS cluster:
```bash
az aks get-credentials --resource-group <your-resource-group> --name <your-aks-cluster-name>
```

5. Verify the connection:
```bash
kubectl get nodes
```

## Step 2: Add the tracebloc Helm Repository

```bash
helm repo add tracebloc https://tracebloc.github.io/client/
helm repo update
```

## Step 3: Configure Values

1. Download the default values file:
```bash
helm show values tracebloc/aks > values.yaml
```

2. Edit `values.yaml` to configure your deployment. Key configurations include:

### Required Settings:
- `jobsManager.tag`: Set your desired image version (e.g., "latest, dev, staging, prod")
- `jobsManager.env.EDGE_ENV`: Set environment ("dev", "staging", "prod")
- `jobsManager.env.EDGE_USERNAME`: Set your edge authentication username
- `dockerRegistry`: Configure your registry access:
  ```yaml
  dockerRegistry:
    create: true
    secretName: regcred
    server: https://index.docker.io/v1/
    username: <your-username>
    password: <your-password>
    email: <your-email>
  ```

### Optional Settings:
- `HTTP_PROXY_*`: Configure if you're behind a proxy
- Resource Settings:
  ```yaml
  RESOURCE_REQUESTS: "cpu=50m,memory=207084Ki"
  RESOURCE_LIMITS: "cpu=100m,memory=414168Ki"
  GPU_REQUESTS: "nvidia.com/gpu=1"
  GPU_LIMITS: "nvidia.com/gpu=1"
  ```

### Storage Configuration:
- Review and adjust PVC sizes based on your needs:
  ```yaml
  sharedData:
    name: shared-data
    storage: 50Gi
  logsPvc:
    name: logs-pvc
    storage: 10Gi
  mysqlPvc:
    name: mysql-pvc
    storage: 2Gi
  ```

## Step 4: Install the Helm Chart

1. Create a dedicated namespace:
```bash
kubectl create namespace tracebloc
```

2. Install the chart:
```bash
helm install tracebloc tracebloc/aks \
    --namespace tracebloc \
    --values values.yaml
```

## Step 5: Verify the Deployment

1. Check pod status:
```bash
kubectl get pods -n tracebloc
```

2. Check services:
```bash
kubectl get services -n tracebloc
```

3. Check persistent volumes:
```bash
kubectl get pvc -n tracebloc
```


## Troubleshooting Guide

### Common Issues and Solutions:

1. Pods not starting:
```bash
# Check pod status
kubectl get pods -n tracebloc
# Check pod logs
kubectl logs <pod-name> -n tracebloc
# Check pod details
kubectl describe pod <pod-name> -n tracebloc
```

2. Storage issues:
```bash
# Check PVC status
kubectl get pvc -n tracebloc
# Check PV status
kubectl get pv
```

3. Image pull errors:
```bash
# Verify registry secret
kubectl get secret regcred -n tracebloc
# Check pod events
kubectl describe pod <pod-name> -n tracebloc
```

## Upgrading

1. Update your values:
```bash
helm show values tracebloc/aks > new-values.yaml
# Edit new-values.yaml with your changes
```

2. Upgrade the deployment:
```bash
helm upgrade tracebloc tracebloc/aks \
    --namespace tracebloc \
    --values new-values.yaml
```

## Uninstalling

1. Remove the Helm release:
```bash
helm uninstall tracebloc -n tracebloc
```

2. Clean up persistent resources (optional):
```bash
kubectl delete pvc --all -n tracebloc
kubectl delete namespace tracebloc
```

For additional support or questions, please contact tracebloc support at support@tracebloc.io or visit our documentation portal.



