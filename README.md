# Azure private Foundry Agent PoC

This proof of concept deploys an Azure Container Apps backend and Azure AI Foundry Agent Service into the same isolated Azure Virtual Network. It demonstrates private connectivity only: the Container Apps environment is internal, Foundry uses standard setup with private networking and network injection, and verification runs from inside the VNet.

## Contents

- [Architecture](#architecture)
- [How the isolation works](#how-the-isolation-works)
- [Prerequisites](#prerequisites)
- [Run in GitHub Codespaces](#run-in-github-codespaces)
- [Deploy from the command line](#deploy-from-the-command-line)
- [Set up the CI/CD pipeline](#set-up-the-cicd-pipeline)
- [Verify](#verify)
- [Cost](#cost)
- [Teardown](#teardown)
- [Known issues and gotchas](#known-issues-and-gotchas)
- [License](#license)

## Architecture

**▶ [Open the interactive architecture diagram](https://studydev.github.io/azure-private-foundry-agent-poc/diagram/architecture.svg)**

[![Architecture](diagram/architecture.png)](https://studydev.github.io/azure-private-foundry-agent-poc/diagram/architecture.svg)

> The PNG is a static preview. The source diagram is [`diagram/architecture.drawio`](diagram/architecture.drawio), which can be opened in any draw.io client.

## How the isolation works

The deployment creates a single VNet (`10.0.0.0/16`) with three subnets:

| Subnet | CIDR | Purpose | Delegation |
| --- | --- | --- | --- |
| `snet-aca` | `10.0.0.0/23` | Internal Azure Container Apps environment | `Microsoft.App/environments` |
| `snet-agent` | `10.0.4.0/24` | Foundry Agent Service network injection | `Microsoft.App/environments` |
| `snet-pe` | `10.0.8.0/26` | Private endpoints | none |

The Foundry account is created with `publicNetworkAccess: Disabled`, `disableLocalAuth: true`, and `networkInjections` pointing at `snet-agent`. Network injection must be present when the Foundry account is created; it is effectively a creation-time choice for this PoC. The Bicep keeps the `networkInjections` property in the Foundry account module call and documents why the schema warning is suppressed.

Private endpoints are created for Foundry, Cosmos DB, AI Search, Storage Blob, and Key Vault. The VNet links to these private DNS zones:

- `privatelink.services.ai.azure.com`
- `privatelink.openai.azure.com`
- `privatelink.cognitiveservices.azure.com`
- `privatelink.documents.azure.com`
- `privatelink.search.windows.net`
- `privatelink.blob.core.windows.net`
- `privatelink.vaultcore.azure.net`

Container Apps internal ingress also needs DNS. Azure does not automatically create a private zone for the managed environment default domain, so the template creates a zone named after that default domain and adds apex (`@`) and wildcard (`*`) A records to the environment static IP.

AI Search, Cosmos DB, and Storage are mandatory in this design because the project capability host declares `vectorStoreConnections`, `threadStorageConnections`, and `storageConnections` unconditionally. The template creates project connections for all three before creating the project-level `Agents` capability host.

## Prerequisites

- Azure subscription with access to Azure Container Apps, Azure AI Foundry, Azure AI Search, Azure Cosmos DB, Azure Container Registry, Storage, Key Vault, and private endpoints in the target region.
- Azure CLI with the Bicep extension.
- GitHub CLI.
- Docker is not required locally when you use `az acr build`.
- Permissions to create resource groups, assign Azure roles, and create GitHub repository secrets and environments.

## Run in GitHub Codespaces

1. Open this repository in GitHub Codespaces.
2. Sign in to Azure:

   ```bash
   az login
   az account set --subscription "<your-subscription-id>"
   ```

3. Deploy the infrastructure with the placeholder image:

   ```bash
   az deployment sub create \
     --name aca-foundry-private-poc \
     --location koreacentral \
     --template-file infra/main.bicep \
     --parameters infra/main.bicepparam
   ```

4. Build the app into ACR and redeploy with the real image, as shown in the next section.

## Deploy from the command line

The image has a chicken-and-egg sequence: the first deployment creates ACR and Container Apps with a public MCR placeholder image, then ACR builds the real app image, then the deployment runs again with the real tag.

```bash
az deployment sub create \
  --name aca-foundry-private-placeholder \
  --location koreacentral \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam

RG=$(az deployment sub show \
  --name aca-foundry-private-placeholder \
  --query properties.outputs.resourceGroupName.value \
  -o tsv)
ACR=$(az deployment sub show \
  --name aca-foundry-private-placeholder \
  --query properties.outputs.acrName.value \
  -o tsv)
IMAGE="$ACR.azurecr.io/private-agent:$(git rev-parse --short HEAD)"

az acr build \
  --registry "$ACR" \
  --image "private-agent:$(git rev-parse --short HEAD)" \
  --file src/Dockerfile \
  src

az deployment sub create \
  --name aca-foundry-private-final \
  --location koreacentral \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --parameters containerImage="$IMAGE"
```

Wait about 10 minutes after the final deployment before testing. ARM can return `Succeeded` before private DNS, RBAC propagation, Container Apps revisions, and Foundry capability hosts are fully ready.

## Set up the CI/CD pipeline

The workflows use GitHub OIDC with no Azure credentials stored in code. Because this is a public repository, the Azure identifiers are stored as GitHub **Secrets**, not Variables. Secrets are masked in logs; Variables are not designed to protect values printed by workflows in public logs.

```bash
OWNER=studydev
REPO=azure-private-foundry-agent-poc
SUBSCRIPTION_ID=<your-subscription-id>
TENANT_ID=<your-tenant-id>
LOCATION=koreacentral
BOOTSTRAP_RG=rg-foundry-agent-poc-oidc
IDENTITY_NAME=uami-github-oidc-foundry-poc

az account set --subscription "$SUBSCRIPTION_ID"
az group create \
  --name "$BOOTSTRAP_RG" \
  --location "$LOCATION"

az identity create \
  --resource-group "$BOOTSTRAP_RG" \
  --name "$IDENTITY_NAME" \
  --location "$LOCATION"

CLIENT_ID=$(az identity show \
  --resource-group "$BOOTSTRAP_RG" \
  --name "$IDENTITY_NAME" \
  --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show \
  --resource-group "$BOOTSTRAP_RG" \
  --name "$IDENTITY_NAME" \
  --query principalId -o tsv)

az identity federated-credential create \
  --resource-group "$BOOTSTRAP_RG" \
  --identity-name "$IDENTITY_NAME" \
  --name main \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:$OWNER/$REPO:ref:refs/heads/main" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --resource-group "$BOOTSTRAP_RG" \
  --identity-name "$IDENTITY_NAME" \
  --name pull-request \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:$OWNER/$REPO:pull_request" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --resource-group "$BOOTSTRAP_RG" \
  --identity-name "$IDENTITY_NAME" \
  --name production \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:$OWNER/$REPO:environment:production" \
  --audiences "api://AzureADTokenExchange"
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

gh secret set AZURE_CLIENT_ID --repo "$OWNER/$REPO" --body "$CLIENT_ID"
gh secret set AZURE_TENANT_ID --repo "$OWNER/$REPO" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$OWNER/$REPO" --body "$SUBSCRIPTION_ID"

gh api --method PUT "repos/$OWNER/$REPO/environments/production" \
  --field wait_timer=0
```

Then add a required reviewer to the `production` environment in the GitHub repository settings. The deploy workflow is intentionally gated by that environment.

## Verify

The positive verification runs as a Container Apps Job inside the VNet. A GitHub-hosted runner cannot reach the private app or private Foundry endpoint, so the workflow starts the job through the ARM control plane, polls its execution status, and reads the PASS/FAIL block from Log Analytics.

The deploy workflow also includes a negative control: it runs `curl` to the Foundry project endpoint and the Container App URL from the public runner and expects both to fail. If either public request succeeds, the workflow fails.

Wait about 10 minutes after deployment before manual testing. `az deployment sub create` returning `Succeeded` means ARM accepted and created resources; it does not guarantee RBAC, private DNS, Foundry capability hosts, and Container Apps cold start are ready.

## Cost

Approximate monthly cost while the lab is running:

| Component | Estimate |
| --- | ---: |
| AI Search Basic | ~$75 |
| Private endpoints | ~$44 |
| Container Apps | ~$10 |
| Cosmos DB serverless | ~$10 |
| ACR Basic | ~$5 |
| Log Analytics | ~$5 |
| Miscellaneous | ~$5 |
| **Total** | **~$135–160/month while running** |

Tear down the lab when idle.

## Teardown

Use the teardown workflow and type the resource group name when prompted. It deletes the project capability host first because that resource can block resource-group deletion, then deletes the resource group, then purges the soft-deleted Foundry account and Key Vault.

Manual equivalent:

```bash
RG=rg-aca-foundry-private-agent-poc

for id in $(az resource list \
  --resource-group "$RG" \
  --resource-type "Microsoft.CognitiveServices/accounts/projects/capabilityHosts" \
  --query "[].id" -o tsv); do
  az resource delete \
    --ids "$id" \
    --api-version 2025-12-01
done

az cognitiveservices account list \
  --resource-group "$RG" \
  --query "[?kind=='AIServices'].[name,location]" \
  -o tsv > foundry-to-purge.tsv
az keyvault list \
  --resource-group "$RG" \
  --query "[].[name,location]" \
  -o tsv > keyvaults-to-purge.tsv

az group delete \
  --name "$RG" \
  --yes

while IFS=$'\t' read -r name location; do
  az cognitiveservices account purge \
    --name "$name" \
    --location "$location"
done < foundry-to-purge.tsv

while IFS=$'\t' read -r name location; do
  az keyvault purge \
    --name "$name" \
    --location "$location"
done < keyvaults-to-purge.tsv
```

## Known issues and gotchas

- Deployment ordering matters: VNet and DNS, private endpoints, Foundry account, Foundry project, dependency connections, RBAC, capability host, Container Apps, then the smoke-test job.
- Foundry capability hosts are immutable for several settings. Delete and recreate the project capability host when those settings change.
- RBAC propagation can take several minutes. The deploy workflow uses bounded retry rather than assuming ARM completion means data-plane readiness.
- `networkInjections` is creation-time-only for this PoC. Create the Foundry account with it from the start.
- Subnet sizing matters. The Container Apps environment uses `/23`, the injected agent runtime uses `/24`, and private endpoints use `/26`.
- Class A private ranges and Foundry private networking can have regional constraints. Validate region support before changing `koreacentral`.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
