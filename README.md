# tracebloc AKS Chart Deployment Guide for Azure AKS

This guide will walk you through the process of deploying the tracebloc application to your Azure Kubernetes Service (AKS) cluster using the **tracebloc AKS Chart**.

## Prerequisites

1. An active Azure subscription.
2. Azure CLI installed and configured.
3. kubectl installed and configured to connect to your AKS cluster.
4. Helm 3.x installed on your local machine.
5. Access to the tracebloc AKS chart repository.

## Step 1: Connect to Your AKS Cluster

Ensure you're connected to your AKS cluster:

```bash
az aks get-credentials --resource-group <your-resource-group> --name <your-aks-cluster-name>
```

Verify the connection:

```bash
kubectl get nodes
```

## Step 2: Add the tracebloc Helm Repository

Add the tracebloc Helm repository to your local Helm installation:

```bash
helm repo add tracebloc https://tracebloc.github.io/tracebloc-helm-charts/
helm repo update
```

## Step 3: Configure Values

Create a `values.yaml` file to customize the tracebloc deployment. You can start with the default values and modify as needed:

```bash
helm show values tracebloc/tracebloc-aks-chart > values.yaml
```

Edit `values.yaml` to set your specific configuration. Pay special attention to:

- `env`: Set to your desired environment (e.g., "dev", "stg", "prod").
- `jobsManager.tag`: Set the correct image tag.
- `jobsManager.env`: Configure environment-specific variables.
- `storageClass`: Verify this matches your AKS storage class.
- `mysql`: set the name for the mysql hostname.
- `dockerRegistry`: Ensure this matches your docker Container Registry credentials.




## Step 4: Create Necessary Secrets

Create secrets for sensitive information (replace with your actual values):

```bash
kubectl create secret generic tracebloc-secrets \
  --from-literal=EDGE_PASSWORD=<your-edge-password> \
  --from-literal=CONNECTION_STRING=<your-connection-string> \
  --from-literal=AZURE_STORAGE_CONNECTION_STRING=<your-storage-connection-string>
```


## Step 5: Install the Helm Chart

Install the tracebloc AKS chart using your custom values:

```bash
helm install tracebloc tracebloc/tracebloc-aks-chart -f values.yaml
```

## Step 6: Verify the Deployment

Check the status of your pods:

```bash
kubectl get pods
```
You should see the mysql and jobs manager pods.


Verify services are running:

```bash
kubectl get services
```

## Step 7: Access the Application

Depending on your ingress configuration, you may need to set up an ingress controller or use a LoadBalancer service to access the application externally.

## Troubleshooting

- If pods are not starting, check the logs:
  ```bash
  kubectl logs <pod-name>
  ```
- For persistent volume issues, check the PVC status:
  ```bash
  kubectl get pvc
  ```
- For general Helm issues, use:
  ```bash
  helm list
  helm status tracebloc
  ```

## Upgrading

To upgrade your tracebloc deployment:

1. Update your `values.yaml` file with any new configurations.
2. Run the upgrade command:
   ```bash
   helm upgrade tracebloc tracebloc/tracebloc-aks-chart -f values.yaml
   ```

## Uninstalling

To remove the tracebloc deployment:

```bash
helm uninstall tracebloc
```

Note: This will not delete PVCs or secrets. Delete them manually if needed.

For more information or support, please contact tracebloc support or refer to the official documentation.

