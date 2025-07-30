#!/bin/bash

namespace=${1:-default}

# Create the RBAC manifest file dynamically
echo "
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: trivy-scanner
  namespace: $namespace
---
apiVersion: v1
kind: Secret
metadata:
  name: trivy-scanner-token
  namespace: $namespace
  annotations:
    kubernetes.io/service-account.name: trivy-scanner
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: trivy-scanner-role
rules:
- apiGroups: [\"\"]
  resources: [\"pods\", \"pods/log\", \"services\", \"serviceaccounts\", \"configmaps\", 
              \"replicationcontrollers\", \"resourcequotas\", \"limitranges\", \"nodes\",
              \"nodes/proxy\", \"nodes/stats\", \"nodes/spec\", \"nodes/status\", \"events\",
              \"namespaces\"]
  verbs: [\"get\", \"list\", \"watch\"]
- apiGroups: [\"apps\"]
  resources: [\"deployments\", \"statefulsets\", \"daemonsets\", \"replicasets\"]
  verbs: [\"get\", \"list\"]
- apiGroups: [\"batch\"]
  resources: [\"cronjobs\", \"jobs\"]
  verbs: [\"get\", \"list\", \"create\", \"delete\", \"watch\"]
- apiGroups: [\"rbac.authorization.k8s.io\"]
  resources: [\"roles\", \"rolebindings\", \"clusterroles\", \"clusterrolebindings\"]
  verbs: [\"get\", \"list\"]
- apiGroups: [\"networking.k8s.io\"]
  resources: [\"networkpolicies\", \"ingresses\"]
  verbs: [\"get\", \"list\"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: trivy-scanner-rolebinding
subjects:
- kind: ServiceAccount
  name: trivy-scanner
  namespace: $namespace
roleRef:
  kind: ClusterRole
  name: trivy-scanner-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Namespace
metadata:
  name: trivy-temp
---
" > raider_manifest.yml

# Apply the manifest using kubectl
kubectl apply -f raider_manifest.yml

# Retrieve configuration details
cluster_name=$(kubectl config view --minify -o jsonpath="{.clusters[0].name}")
server=$(kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}")
ca=$(kubectl config view --flatten -o jsonpath="{.clusters[0].cluster.certificate-authority-data}")
token=$(kubectl get secret trivy-scanner-token -o jsonpath='{.data.token}' | base64 --decode)

# Generate JSON output
jq -n \
    --arg cluster_name "$cluster_name" \
    --arg server "$server" \
    --arg ca "$ca" \
    --arg token "$token" \
    --arg namespace "$namespace" \
    '{
        cluster_name: $cluster_name, 
        server: $server, 
        namespace: $namespace, 
        certificate_authority_data: $ca, 
        token: $token
    }' > k8s_cluster_config.json

echo
# Print redacted details
echo "Kubernetes Cluster Configuration:"
echo "--------------------------------"
echo "Cluster Name    : $cluster_name"
echo "Server          : $(echo "$server" | cut -c1-50)..."
echo "Namespace       : $namespace"
echo "Token           : ${token:0:20}..."
echo
echo "Configuration JSON generated: k8s_cluster_config.json"