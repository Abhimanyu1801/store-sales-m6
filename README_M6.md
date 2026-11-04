# Milestone 6 kit: run order

## A. Put the files in your fork (on `main`)
Copy from this kit into the repo root of your fork:
- `app.py` (replaces the old one: JSON logs, /debug/error, /version)
- `k8s/` (replaces the old folder: templated values)
- `terraform/`, `scripts/`, `.github/workflows/deploy.yml`
Delete the two old workflows: `git rm .github/workflows/ci-cd.yaml .github/workflows/build-push.yml`
Do NOT create the `deploy` branch yet (every push to it triggers the pipeline).

## B. Terraform state storage (once, Cloud Shell)
    az group create -n tfstate-rg -l northcentralus
    az storage account create -n tfstateaj4417 -g tfstate-rg -l northcentralus --sku Standard_LRS --allow-shared-key-access false --min-tls-version TLS1_2
    az role assignment create --assignee $(az ad signed-in-user show --query id -o tsv) --role "Storage Blob Data Contributor" --scope $(az storage account show -n tfstateaj4417 -g tfstate-rg --query id -o tsv)
    az storage container create --account-name tfstateaj4417 -n tfstate --auth-mode login
Then in `terraform/`: `cp backend.tf.example backend.tf` and put your account name in it
(commit backend.tf; it holds no secret). `cp terraform.tfvars.example terraform.tfvars` and fill it
in (do NOT commit terraform.tfvars).

## C. Build the infrastructure
    git clone <your fork> && cd <repo>
    cd terraform && terraform init && terraform validate && terraform plan -out tf.plan && terraform apply tf.plan && cd ..

## D. Bring the app up (about 15 minutes)
    export LABEL=storesales-<yourname>   # must be unique in the region
    export LE_EMAIL=<your email>
    bash scripts/bootstrap.sh
It prints the HTTPS URL and the GitHub variables to add. Check: `kubectl -n storesales-m5 get certificate`.

## E. Turn on the pipeline
Add the printed variables in GitHub (Settings > Secrets and variables > Actions > Variables),
then `git checkout -b deploy && git push -u origin deploy`. Green run = build + deploy + health check.

## F. Demo moves
- Controlled 5xx:
  `kubectl -n storesales-m5 exec deploy/api -- curl -s "http://localhost:8000/debug/error?token=m6-demo"`
- Failed deploy: change `BREAK_READY` to "true" in k8s/10-api-deployment.yaml, push to `deploy`.
  New pods never become ready, old pods keep serving, the workflow rolls back and verifies /version.
