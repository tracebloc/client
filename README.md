**Overview:**   

This guide explains how to deploy the tracebloc application to your Kubernetes cluster using a **Helm Chart**. The app includes the tracebloc runtime, which runs experiments and sends results to the tracebloc backend. 


  
**Prerequisites:** 

- You need `kubectl` installed and connected to your Kubernetes cluster. 

- `Helm 3.x` must be installed on your machine. 

  

**Network Requirements:** 

- Communication with the tracebloc backend is one-way (client requests data only). 

- Port 443 must be open to send experiment data through Azure Service Bus (AmqpOverWebsocket). 

- The client only communicates with the tracebloc backend, sharing experiment metrics and weight files. 

  

**Cluster Requirements:** 

- We recommend that each node in the cluster has at least 50 GB of RAM and 20 CPU cores. 

  

**Data Storage:** 

- Training data, models, and weight files will be stored on persistent volumes. 

  

**Required Configuration:** 

- Docker credentials (username, password) 

- Client credentials (client ID, username, password) 

- Service Bus connection string 

- Azure Storage connection string 

  

For these configurations, email us at info@tracebloc.io. 

  

**Deployment Options:** 

<Link_for_client_setup>

  
