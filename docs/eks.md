
# Step 1
clusterName = "tracebloc-clients"
regionCode = "eu-central-1"
cluster = (aws eks describe-cluster --name $clusterName --region $regionCode)

$cluster = ($cluster | ConvertFrom-JSON)

# Step 2
$oidc_id = ($cluster.cluster.identity.oidc.issuer.split("/"))[4]

# Step 3
eksctl utils associate-iam-oidc-provider --cluster $clusterName --region $regionCode --approve


eksctl utils associate-iam-oidc-provider --region=eu-central-1 --cluster=tracebloc-clients --approve

eksctl create iamserviceaccount \
  --region eu-central-1 \
  --name efs-csi-controller-sa \
  --namespace kube-system \
  --cluster tracebloc-clients \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EFS_CSI_DriverRole



export cluster_name=my-cluster
export role_name=AmazonEKS_EFS_CSI_DriverRole
eksctl create iamserviceaccount \
    --name efs-csi-controller-sa \
    --namespace kube-system \
    --cluster $cluster_name \
    --role-name $role_name \
    --role-only \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
    --approve
TRUST_POLICY=$(aws iam get-role --role-name $role_name --query 'Role.AssumeRolePolicyDocument' | \
    sed -e 's/efs-csi-controller-sa/efs-csi-*/' -e 's/StringEquals/StringLike/')
aws iam update-assume-role-policy --role-name $role_name --policy-document "$TRUST_POLICY"