#!/usr/bin/env bash
# Run once in Cloud Shell AFTER `terraform apply`, from the repo root.
#   export LABEL=storesales-aj      # unique DNS label -> <label>.northcentralus.cloudapp.azure.com
#   export LE_EMAIL=you@example.com # Let's Encrypt contact
#   bash scripts/bootstrap.sh
set -euo pipefail
: "${LABEL:?set LABEL}"; : "${LE_EMAIL:?set LE_EMAIL}"
T="terraform -chdir=terraform output -raw"
RG=$($T resource_group); AKS=$($T aks_name); ACR=$($T acr_name)
export ACR_LOGIN_SERVER=$($T acr_login_server) KEY_VAULT_URL=$($T key_vault_url)
export STORAGE_ACCOUNT=$($T storage_account) APP_CLIENT_ID=$($T app_identity_client_id)
export APP_HOST="$LABEL.northcentralus.cloudapp.azure.com" IMAGE_TAG="${IMAGE_TAG:-v7}"
NS=storesales-m5

az aks get-credentials -g "$RG" -n "$AKS" --admin --overwrite-existing

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set-string controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$LABEL" \
  --set-string controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true --wait

cat <<YAML | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: letsencrypt-production }
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $LE_EMAIL
    privateKeySecretRef: { name: letsencrypt-production-key }
    solvers:
      - http01: { ingress: { ingressClassName: nginx } }
YAML

echo "Building image $IMAGE_TAG in ACR (takes a few minutes)..."
az acr build -r "$ACR" -t "store-sales-forecasting-api:$IMAGE_TAG" .

VARS='${ACR_LOGIN_SERVER} ${IMAGE_TAG} ${KEY_VAULT_URL} ${STORAGE_ACCOUNT} ${APP_CLIENT_ID} ${APP_HOST}'
for f in k8s/*.yaml; do envsubst "$VARS" < "$f" | kubectl apply -f -; done
kubectl -n $NS rollout status deployment/api --timeout=300s
kubectl -n $NS rollout status deployment/dashboard --timeout=300s

echo "Applying database migration inside the cluster (database is private)..."
kubectl -n $NS exec deploy/api -- python -c "from state import run_migrations; run_migrations()"

echo
echo "URL: https://$APP_HOST   (certificate can take 2-5 minutes: kubectl -n $NS get certificate)"
echo
echo "GitHub repository variables to set (Settings > Secrets and variables > Actions > Variables):"
cat <<VARS_OUT
AZURE_CLIENT_ID=$($T github_client_id)
AZURE_TENANT_ID=$($T tenant_id)
AZURE_SUBSCRIPTION_ID=$($T subscription_id)
RESOURCE_GROUP=$RG
AKS_NAME=$AKS
ACR_NAME=$ACR
ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER
KEY_VAULT_URL=$KEY_VAULT_URL
STORAGE_ACCOUNT=$STORAGE_ACCOUNT
APP_CLIENT_ID=$APP_CLIENT_ID
APP_HOST=$APP_HOST
VARS_OUT
