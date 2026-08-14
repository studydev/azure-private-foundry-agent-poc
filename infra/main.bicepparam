using './main.bicep'

param location = 'koreacentral'
param resourceGroupName = 'rg-aca-foundry-private-agent-poc'
param baseName = 'afapoc'
param containerImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param modelDeploymentName = 'gpt-4o-mini'
param tags = {
  scenario: 'aca-foundry-private-agent-poc'
  purpose: 'public-proof-of-concept'
}
