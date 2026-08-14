targetScope = 'resourceGroup'

param location string
param appIdentityName string
param foundryName string
param projectName string
param acrName string
param cosmosName string
param storageName string
param searchName string

var acrId = resourceId('Microsoft.ContainerRegistry/registries', acrName)
var foundryId = resourceId('Microsoft.CognitiveServices/accounts', foundryName)
var projectId = '${foundryId}/projects/${projectName}'
var cosmosId = resourceId('Microsoft.DocumentDB/databaseAccounts', cosmosName)
var storageId = resourceId('Microsoft.Storage/storageAccounts', storageName)
var searchId = resourceId('Microsoft.Search/searchServices', searchName)

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var cosmosDbOperatorRoleId = '230815da-be43-4aae-9cb4-875f7bd000aa'
var storageAccountContributorRoleId = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var searchIndexDataContributorRoleId = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributorRoleId = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
// Foundry User was formerly named Azure AI User; use the stable role definition ID during the rename rollout.
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource appUamiRef 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: appIdentityName
}

resource acrRef 'Microsoft.ContainerRegistry/registries@2025-06-01-preview' existing = {
  name: acrName
}

resource foundryRef 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource cosmosRef 'Microsoft.DocumentDB/databaseAccounts@2026-04-01-preview' existing = {
  name: cosmosName
}

resource storageRef 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageName
}

resource searchRef 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchName
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrId, appIdentityName, acrPullRoleId)
  scope: acrRef
  properties: {
    principalId: appUamiRef.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

resource appFoundryUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryId, appIdentityName, foundryUserRoleId)
  scope: foundryRef
  properties: {
    principalId: appUamiRef.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
  }
}

resource appCognitiveServicesUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryId, appIdentityName, cognitiveServicesUserRoleId)
  scope: foundryRef
  properties: {
    principalId: appUamiRef.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-12-01' = {
  name: '${foundryName}/${projectName}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Private network injected Foundry Agent Service project for the Container Apps PoC.'
  }
}

resource projectCosmosOperatorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmosId, projectName, cosmosDbOperatorRoleId)
  scope: cosmosRef
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosDbOperatorRoleId)
  }
}

resource projectStorageContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageId, projectName, storageAccountContributorRoleId)
  scope: storageRef
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
  }
}

resource projectSearchIndexDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchId, projectName, searchIndexDataContributorRoleId)
  scope: searchRef
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributorRoleId)
  }
}

resource projectSearchServiceContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchId, projectName, searchServiceContributorRoleId)
  scope: searchRef
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributorRoleId)
  }
}

var cosmosConnectionName = 'conn-cosmos'
var storageConnectionName = 'conn-storage'
var searchConnectionName = 'conn-search'

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-12-01' = {
  name: '${foundryName}/${projectName}/${cosmosConnectionName}'
  properties: {
    authType: 'AAD'
    category: 'CosmosDb'
    target: 'https://${cosmosName}.documents.azure.com:443/'
    metadata: {
      ResourceId: cosmosId
      location: location
    }
  }
  dependsOn: [
    aiProject
  ]
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-12-01' = {
  name: '${foundryName}/${projectName}/${storageConnectionName}'
  properties: {
    authType: 'AAD'
    category: 'AzureStorageAccount'
    target: 'https://${storageName}.blob.core.windows.net/'
    metadata: {
      ResourceId: storageId
      location: location
    }
  }
  dependsOn: [
    aiProject
  ]
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-12-01' = {
  name: '${foundryName}/${projectName}/${searchConnectionName}'
  properties: {
    authType: 'AAD'
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    metadata: {
      ResourceId: searchId
      location: location
    }
  }
  dependsOn: [
    aiProject
  ]
}

// Do not declare an account-level capability host: when networkInjections is set, the platform auto-provisions it and a user declaration can race the platform.
resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-12-01' = {
  name: '${foundryName}/${projectName}/agents'
  properties: {
    capabilityHostKind: 'Agents'
    storageConnections: [
      storageConnectionName
    ]
    threadStorageConnections: [
      cosmosConnectionName
    ]
    vectorStoreConnections: [
      searchConnectionName
    ]
  }
  dependsOn: [
    cosmosConnection
    storageConnection
    searchConnection
    projectCosmosOperatorAssignment
    projectStorageContributorAssignment
    projectSearchIndexDataContributorAssignment
    projectSearchServiceContributorAssignment
    acrPullAssignment
    appFoundryUserAssignment
    appCognitiveServicesUserAssignment
  ]
}

output capabilityHostResourceId string = '${projectId}/capabilityHosts/agents'
