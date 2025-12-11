# 🌐 Tracebloc Client
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


## 📄 Description
Tracebloc Client is a Kubernetes-based application that runs experiments and communicates results to the Tracebloc backend. It's designed to handle distributed machine learning workloads efficiently and securely.

## 🛠️ Tech Stack
- Kubernetes
- Helm 3.x
- Azure Service Bus (AmqpOverWebsocket)
- Docker
- Persistent Volume Storage

## 🚀 Installation & Setup

### Prerequisites
- `kubectl` installed and configured
- `Helm 3.x` installed
- Access to a Kubernetes cluster

### System Requirements

#### Network Requirements
- One-way communication with Tracebloc backend
- Port 443 open for Azure Service Bus (AmqpOverWebsocket)
- Secure metric and weight file transmission

#### Cluster Specifications
- **RAM:** 50 GB (minimum)
- **CPU:** 20 cores (minimum)

#### Storage
- Persistent volumes for:
  - Training data
  - Models
  - Weight files

### Required Credentials
1. Docker Registry Access:
   - Username
   - Password

2. Client Authentication:
   - Client ID
   - Username
   - Password

## 📦 Deployment Guide

1. Ensure all prerequisites are met
2. Configure your credentials
3. Follow our detailed deployment guide at:
   [Create Your Client](https://traceblocdocsdev.azureedge.net/environment-setup/create-your-client)




# Helm Chart Verification Guide

## Manual Verification Steps

### 1. Lint the Chart
Checks for common issues, best practices, and potential problems:
```bash
helm lint eks/
```

**What it checks:**
- Chart structure and metadata
- Template syntax
- Values file structure
- Best practices compliance

### 2. Render Templates (Dry Run)
Renders all templates with your values to check for syntax errors:
```bash
helm template eks eks/ --namespace test-namespace
```

**With debug output:**
```bash
helm template eks eks/ --namespace test-namespace --debug
```

**What it checks:**
- Template syntax errors
- Missing required values
- Incorrect template functions
- YAML formatting issues

### 3. Validate Kubernetes Manifests
Validates that the rendered YAML is valid Kubernetes:
```bash
helm template eks eks/ --namespace test-namespace | kubectl apply --dry-run=client -f -
```

**What it checks:**
- Valid Kubernetes API versions
- Correct resource definitions
- Required fields are present

### 4. Test Installation (Dry Run)
Simulates an installation without actually deploying:
```bash
helm install test-release eks/ --namespace test-namespace --dry-run --debug
```

**What it checks:**
- All resources would be created correctly
- Dependencies are resolved
- Values are properly substituted

### 5. Package the Chart
Creates a chart package to verify it can be packaged:
```bash
helm package eks/
```

**What it checks:**
- Chart can be packaged for distribution
- All required files are included
- Chart metadata is correct

### 6. Check for Placeholder Values
Search for placeholder values that need to be replaced:
```bash
helm template eks eks/ --namespace test-namespace | grep -E "<.*>"
```

Or check values.yaml directly:
```bash
grep -E "<.*>" eks/values.yaml
```

## Common Issues to Check

### ✅ Before Submitting, Verify:

1. **No placeholder values** - Replace all `<PLACEHOLDER>`, `<NAMESPACE>`, etc.
2. **All required values are set** - Check values.yaml for any empty required fields
3. **Template syntax is correct** - All `{{ }}` blocks are properly closed
4. **Resource names are unique** - No conflicts with existing resources
5. **RBAC permissions are correct** - Service accounts have necessary permissions
6. **Image tags are specified** - No `latest` tags in production
7. **Resource limits are set** - Containers have appropriate resource requests/limits
8. **Secrets are handled properly** - No hardcoded secrets in templates
9. **Namespace is configurable** - Uses `.Release.Namespace` or `.Values.namespace`
10. **Labels and selectors match** - All resources have consistent labeling

## Pre-Submission Checklist

- [ ] `helm lint eks/` passes without errors
- [ ] `helm template eks eks/` renders without errors
- [ ] All placeholder values in values.yaml are replaced or documented
- [ ] Kubernetes manifest validation passes
- [ ] Chart packages successfully
- [ ] All template files are properly formatted
- [ ] RBAC resources are correctly configured
- [ ] Service accounts reference correct ClusterRoles
- [ ] Image pull secrets are configured
- [ ] Resource requests/limits are set appropriately
- [ ] Documentation is updated (if applicable)

## Testing with Different Values

Test your chart with different value files:
```bash
# Test with custom values
helm template eks eks/ -f values-16-dev.yaml --namespace dev

# Test with multiple value files
helm template eks eks/ -f values.yaml -f values-16-dev.yaml --namespace dev
```

## Advanced Validation

### Validate against Kubernetes schema:
```bash
helm template eks eks/ --namespace test-namespace | \
  kubectl apply --dry-run=server -f -
```

### Check for deprecated APIs:
```bash
helm template eks eks/ --namespace test-namespace | \
  kubectl convert --local -f - 2>&1 | grep -i deprecated
```

### View all rendered resources:
```bash
helm template eks eks/ --namespace test-namespace | \
  kubectl get -f - --dry-run=client -o name
```

## Troubleshooting

### Template rendering errors:
- Check for unclosed `{{ }}` blocks
- Verify all referenced values exist in values.yaml
- Ensure proper indentation in templates

### Lint warnings:
- Review warnings and fix critical issues
- Some warnings may be acceptable (document why)

### Kubernetes validation errors:
- Check API versions are correct for your cluster
- Verify required fields are present
- Ensure resource names follow Kubernetes naming conventions







## 📜 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.


## 📞 Support
For additional support or questions, please refer to our documentation or contact the Tracebloc support team.