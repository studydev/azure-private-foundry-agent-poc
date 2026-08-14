using './main.bicep'

param location = 'koreacentral'
param resourceGroupName = 'rg-aca-foundry-private-agent-poc'
param baseName = 'afapoc'
param enableAgentStandardSetup = false
param containerImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param modelDeploymentName = 'gpt-4.1-mini'
param tags = {
  scenario: 'aca-foundry-private-agent-poc'
  purpose: 'public-proof-of-concept'
}
