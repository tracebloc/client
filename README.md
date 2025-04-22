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

## 📜 License
This project is licensed under the MIT License - see the [LICENSE.txt](LICENSE.txt) file for details.


## 📞 Support
For additional support or questions, please refer to our documentation or contact the Tracebloc support team.