targetScope = 'subscription'

@description('Azure region for all resources. Keep koreacentral unless you have validated Foundry private networking support in another region.')
param location string = 'koreacentral'

@description('Resource group to create for this PoC.')
param resourceGroupName string = 'rg-aca-foundry-private-agent-poc'

@description('Short lowercase prefix used in globally unique resource names. Use lowercase letters, numbers, and hyphens only.')
param baseName string = 'afapoc'

@description('Container image to run. The first deployment uses a public placeholder; the pipeline builds to ACR and redeploys with the private image tag.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Model deployment name used by the sample app.')
param modelDeploymentName string = 'gpt-4o-mini'

@description('Optional tags applied to supported resources.')
param tags object = {
  scenario: 'aca-foundry-private-agent-poc'
  purpose: 'public-proof-of-concept'
}

var uniqueSuffix = uniqueString(subscription().id, resourceGroupName, baseName)
var cleanBaseName = toLower(replace(baseName, '-', ''))

var vnetName = 'vnet-${baseName}'
var nsgName = 'nsg-${baseName}'
var acaEnvName = 'cae-${baseName}'
var acaInfraRgName = 'rg-${baseName}-aca-infra'
var containerAppName = 'app-${baseName}'
var verifyJobName = 'job-${baseName}-verify'
var appIdentityName = 'uami-${baseName}-app'
var logAnalyticsName = 'law-${baseName}'
var acrName = take('acr${cleanBaseName}${uniqueSuffix}', 50)
var foundryName = take('ai-${baseName}-${uniqueSuffix}', 64)
var projectName = 'proj-${baseName}'
var cosmosName = take('cosmos-${baseName}-${uniqueSuffix}', 44)
var cosmosDatabaseName = 'agents'
var storageName = take('st${cleanBaseName}${uniqueSuffix}', 24)
var searchName = take('srch-${baseName}-${uniqueSuffix}', 60)
var keyVaultName = take('kv-${baseName}-${uniqueSuffix}', 24)

var vnetId = resourceId(resourceGroupName, 'Microsoft.Network/virtualNetworks', vnetName)
var subnetAcaId = '${vnetId}/subnets/snet-aca'
var subnetAgentId = '${vnetId}/subnets/snet-agent'
var subnetPeId = '${vnetId}/subnets/snet-pe'
var nsgId = resourceId(resourceGroupName, 'Microsoft.Network/networkSecurityGroups', nsgName)
var logAnalyticsResourceId = resourceId(resourceGroupName, 'Microsoft.OperationalInsights/workspaces', logAnalyticsName)
var appIdentityId = resourceId(resourceGroupName, 'Microsoft.ManagedIdentity/userAssignedIdentities', appIdentityName)
var foundryId = resourceId(resourceGroupName, 'Microsoft.CognitiveServices/accounts', foundryName)
var projectId = '${foundryId}/projects/${projectName}'
var cosmosId = resourceId(resourceGroupName, 'Microsoft.DocumentDB/databaseAccounts', cosmosName)
var storageId = resourceId(resourceGroupName, 'Microsoft.Storage/storageAccounts', storageName)
var searchId = resourceId(resourceGroupName, 'Microsoft.Search/searchServices', searchName)
var keyVaultId = resourceId(resourceGroupName, 'Microsoft.KeyVault/vaults', keyVaultName)
var acaEnvId = resourceId(resourceGroupName, 'Microsoft.App/managedEnvironments', acaEnvName)
var foundryProjectEndpoint = 'https://${foundryName}.services.ai.azure.com/api/projects/${projectName}'

var privateDnsZoneNames = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.documents.azure.com'
  'privatelink.search.windows.net'
  'privatelink.blob.core.windows.net'
  'privatelink.vaultcore.azure.net'
]

var serviceAiDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
var openAiDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
var cognitiveDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
var cosmosDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
var searchDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
var blobDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.core.windows.net')
var vaultDnsZoneId = resourceId(resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net')

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module nsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-${uniqueSuffix}'
  scope: rg
  params: {
    name: nsgName
    location: location
    tags: tags
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.10.1' = {
  name: 'vnet-${uniqueSuffix}'
  scope: rg
  params: {
    name: vnetName
    location: location
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    subnets: [
      {
        name: 'snet-aca'
        addressPrefix: '10.0.0.0/23'
        delegation: 'Microsoft.App/environments'
        networkSecurityGroupResourceId: nsgId
      }
      {
        name: 'snet-agent'
        addressPrefix: '10.0.4.0/24'
        delegation: 'Microsoft.App/environments'
        networkSecurityGroupResourceId: nsgId
      }
      {
        name: 'snet-pe'
        addressPrefix: '10.0.8.0/26'
        networkSecurityGroupResourceId: nsgId
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
    tags: tags
  }
  dependsOn: [
    nsg
  ]
}

module dnsZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for zoneName in privateDnsZoneNames: {
  name: 'pdz-${uniqueString(zoneName, uniqueSuffix)}'
  scope: rg
  params: {
    name: zoneName
    location: 'global'
    virtualNetworkLinks: [
      {
        name: 'link-${vnetName}'
        registrationEnabled: false
        virtualNetworkResourceId: vnetId
      }
    ]
    tags: tags
  }
  dependsOn: [
    vnet
  ]
}]

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'law-${uniqueSuffix}'
  scope: rg
  params: {
    name: logAnalyticsName
    location: location
    dataRetention: 30
    skuName: 'PerGB2018'
    tags: tags
  }
}

module appIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'uami-${uniqueSuffix}'
  scope: rg
  params: {
    name: appIdentityName
    location: location
    tags: tags
  }
}

module acr 'br/public:avm/res/container-registry/registry:0.12.1' = {
  name: 'acr-${uniqueSuffix}'
  scope: rg
  params: {
    name: acrName
    location: location
    acrSku: 'Basic'
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    tags: tags
  }
}

module keyVault 'br/public:avm/res/key-vault/vault:0.14.0' = {
  name: 'kv-${uniqueSuffix}'
  scope: rg
  params: {
    name: keyVaultName
    location: location
    enablePurgeProtection: false
    enableRbacAuthorization: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    publicNetworkAccess: 'Disabled'
    softDeleteRetentionInDays: 7
    tags: tags
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'st-${uniqueSuffix}'
  scope: rg
  params: {
    name: storageName
    location: location
    allowBlobPublicAccess: false
    kind: 'StorageV2'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    publicNetworkAccess: 'Disabled'
    skuName: 'Standard_LRS'
    tags: tags
  }
}

module cosmos 'br/public:avm/res/document-db/database-account:0.21.1' = {
  name: 'cosmos-${uniqueSuffix}'
  scope: rg
  params: {
    name: cosmosName
    location: location
    capacityMode: 'Serverless'
    defaultConsistencyLevel: 'Session'
    disableLocalAuthentication: true
    failoverLocations: [
      {
        failoverPriority: 0
        isZoneRedundant: false
        locationName: location
      }
    ]
    networkRestrictions: {
      networkAclBypass: 'AzureServices'
      publicNetworkAccess: 'Disabled'
    }
    sqlDatabases: [
      {
        name: cosmosDatabaseName
      }
    ]
    tags: tags
    zoneRedundant: false
  }
}

module search 'br/public:avm/res/search/search-service:0.13.0' = {
  name: 'search-${uniqueSuffix}'
  scope: rg
  params: {
    name: searchName
    location: location
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    disableLocalAuth: true
    partitionCount: 1
    publicNetworkAccess: 'Disabled'
    replicaCount: 1
    sku: 'basic'
    tags: tags
  }
}

module foundry 'br/public:avm/res/cognitive-services/account:0.19.0' = {
  name: 'foundry-${uniqueSuffix}'
  scope: rg
  params: {
    name: foundryName
    location: location
    kind: 'AIServices'
    sku: 'S0'
    allowProjectManagement: true
    customSubDomainName: foundryName
    deployments: [
      {
        name: modelDeploymentName
        model: {
          format: 'OpenAI'
          name: 'gpt-4o-mini'
          version: '2024-07-18'
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 10
        }
      }
    ]
    disableLocalAuth: true
    // networkInjections is ahead of some published schemas and is required at creation time for private Foundry Agent Service network injection.
    #disable-next-line BCP036
    networkInjections: {
      scenario: 'agent'
      subnetResourceId: subnetAgentId
      useMicrosoftManagedNetwork: false
    }
    publicNetworkAccess: 'Disabled'
    tags: tags
  }
  dependsOn: [
    vnet
  ]
}

module foundryPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-foundry-${uniqueSuffix}'
  scope: rg
  params: {
    name: 'pe-${foundryName}'
    location: location
    subnetResourceId: subnetPeId
    privateLinkServiceConnections: [
      {
        name: 'pe-${foundryName}'
        properties: {
          groupIds: [
            'account'
          ]
          privateLinkServiceId: foundryId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'services-ai'
          privateDnsZoneResourceId: serviceAiDnsZoneId
        }
        {
          name: 'openai'
          privateDnsZoneResourceId: openAiDnsZoneId
        }
        {
          name: 'cognitive'
          privateDnsZoneResourceId: cognitiveDnsZoneId
        }
      ]
    }
    tags: tags
  }
  dependsOn: [
    foundry
    dnsZones
  ]
}

module cosmosPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-cosmos-${uniqueSuffix}'
  scope: rg
  params: {
    name: 'pe-${cosmosName}'
    location: location
    subnetResourceId: subnetPeId
    privateLinkServiceConnections: [
      {
        name: 'pe-${cosmosName}'
        properties: {
          groupIds: [
            'Sql'
          ]
          privateLinkServiceId: cosmosId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'documents'
          privateDnsZoneResourceId: cosmosDnsZoneId
        }
      ]
    }
    tags: tags
  }
  dependsOn: [
    cosmos
    dnsZones
  ]
}

module searchPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-search-${uniqueSuffix}'
  scope: rg
  params: {
    name: 'pe-${searchName}'
    location: location
    subnetResourceId: subnetPeId
    privateLinkServiceConnections: [
      {
        name: 'pe-${searchName}'
        properties: {
          groupIds: [
            'searchService'
          ]
          privateLinkServiceId: searchId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'search'
          privateDnsZoneResourceId: searchDnsZoneId
        }
      ]
    }
    tags: tags
  }
  dependsOn: [
    search
    dnsZones
  ]
}

module storagePrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-storage-${uniqueSuffix}'
  scope: rg
  params: {
    name: 'pe-${storageName}-blob'
    location: location
    subnetResourceId: subnetPeId
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageName}-blob'
        properties: {
          groupIds: [
            'blob'
          ]
          privateLinkServiceId: storageId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'blob'
          privateDnsZoneResourceId: blobDnsZoneId
        }
      ]
    }
    tags: tags
  }
  dependsOn: [
    storage
    dnsZones
  ]
}

module keyVaultPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-kv-${uniqueSuffix}'
  scope: rg
  params: {
    name: 'pe-${keyVaultName}'
    location: location
    subnetResourceId: subnetPeId
    privateLinkServiceConnections: [
      {
        name: 'pe-${keyVaultName}'
        properties: {
          groupIds: [
            'vault'
          ]
          privateLinkServiceId: keyVaultId
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'vault'
          privateDnsZoneResourceId: vaultDnsZoneId
        }
      ]
    }
    tags: tags
  }
  dependsOn: [
    keyVault
    dnsZones
  ]
}

module acaEnv 'br/public:avm/res/app/managed-environment:0.15.0' = {
  name: 'cae-${uniqueSuffix}'
  scope: rg
  params: {
    name: acaEnvName
    location: location
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalyticsResourceId
    }
    infrastructureResourceGroupName: acaInfraRgName
    infrastructureSubnetResourceId: subnetAcaId
    internal: true
    platformReservedCidr: '10.0.2.0/24'
    platformReservedDnsIP: '10.0.2.10'
    publicNetworkAccess: 'Disabled'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
    tags: tags
  }
  dependsOn: [
    logAnalytics
    vnet
  ]
}

resource acaEnvRef 'Microsoft.App/managedEnvironments@2025-10-02-preview' existing = {
  name: acaEnvName
  scope: rg
}

module acaPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'pdz-aca-${uniqueSuffix}'
  scope: rg
  params: {
    name: acaEnvRef.properties.defaultDomain
    location: 'global'
    a: [
      {
        name: '@'
        ttl: 300
        aRecords: [
          {
            ipv4Address: acaEnvRef.properties.staticIp
          }
        ]
      }
      {
        name: '*'
        ttl: 300
        aRecords: [
          {
            ipv4Address: acaEnvRef.properties.staticIp
          }
        ]
      }
    ]
    virtualNetworkLinks: [
      {
        name: 'link-${vnetName}'
        registrationEnabled: false
        virtualNetworkResourceId: vnetId
      }
    ]
    tags: tags
  }
  dependsOn: [
    acaEnv
    vnet
  ]
}

module foundryProject './foundry-project.bicep' = {
  name: 'foundry-project-${uniqueSuffix}'
  scope: rg
  params: {
    location: location
    appIdentityName: appIdentityName
    foundryName: foundryName
    projectName: projectName
    acrName: acrName
    cosmosName: cosmosName
    storageName: storageName
    searchName: searchName
  }
  dependsOn: [
    appIdentity
    acr
    foundry
    foundryPrivateEndpoint
    cosmos
    cosmosPrivateEndpoint
    storage
    storagePrivateEndpoint
    search
    searchPrivateEndpoint
  ]
}
var appEnv = [
  {
    name: 'PROJECT_ENDPOINT'
    value: foundryProjectEndpoint
  }
  {
    name: 'MODEL_DEPLOYMENT_NAME'
    value: modelDeploymentName
  }
  {
    name: 'FOUNDRY_FQDN'
    value: '${foundryName}.services.ai.azure.com'
  }
  {
    name: 'COSMOS_FQDN'
    value: '${cosmosName}.documents.azure.com'
  }
  {
    name: 'SEARCH_FQDN'
    value: '${searchName}.search.windows.net'
  }
  {
    name: 'STORAGE_FQDN'
    value: '${storageName}.blob.core.windows.net'
  }
]

module containerApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'app-${uniqueSuffix}'
  scope: rg
  params: {
    name: containerAppName
    location: location
    environmentResourceId: acaEnvId
    activeRevisionsMode: 'Single'
    containers: [
      {
        name: 'api'
        image: containerImage
        env: appEnv
        resources: {
          cpu: '0.5'
          memory: '1.0Gi'
        }
      }
    ]
    ingressAllowInsecure: false
    ingressExternal: false
    ingressTargetPort: 8000
    ingressTransport: 'auto'
    managedIdentities: {
      userAssignedResourceIds: [
        appIdentityId
      ]
    }
    registries: [
      {
        server: '${acrName}.azurecr.io'
        identity: appIdentityId
      }
    ]
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 2
    }
    workloadProfileName: 'Consumption'
    tags: tags
  }
  dependsOn: [
    acaEnv
    acaPrivateDnsZone
    foundryProject
  ]
}

module verifyJob 'br/public:avm/res/app/job:0.7.2' = {
  name: 'job-${uniqueSuffix}'
  scope: rg
  params: {
    name: verifyJobName
    location: location
    environmentResourceId: acaEnvId
    triggerType: 'Manual'
    manualTriggerConfig: {
      parallelism: 1
      replicaCompletionCount: 1
    }
    replicaRetryLimit: 0
    replicaTimeout: 1200
    managedIdentities: {
      userAssignedResourceIds: [
        appIdentityId
      ]
    }
    registries: [
      {
        server: '${acrName}.azurecr.io'
        identity: appIdentityId
      }
    ]
    containers: [
      {
        name: 'smoketest'
        image: containerImage
        command: [
          'python'
          '-m'
          'app.smoketest'
        ]
        env: union(appEnv, [
          {
            name: 'BACKEND_URL'
            value: 'https://${containerAppName}.${acaEnvRef.properties.defaultDomain}'
          }
        ])
        resources: {
          cpu: '0.5'
          memory: '1.0Gi'
        }
      }
    ]
    workloadProfileName: 'Consumption'
    tags: tags
  }
  dependsOn: [
    containerApp
  ]
}

output resourceGroupName string = resourceGroupName
output location string = location
output acrName string = acrName
output acrLoginServer string = '${acrName}.azurecr.io'
output containerImage string = containerImage
output containerAppName string = containerAppName
output containerAppFqdn string = '${containerAppName}.${acaEnvRef.properties.defaultDomain}'
output containerAppUrl string = 'https://${containerAppName}.${acaEnvRef.properties.defaultDomain}'
output verifyJobName string = verifyJobName
output logAnalyticsWorkspaceResourceId string = logAnalyticsResourceId
output foundryAccountName string = foundryName
output foundryProjectName string = projectName
output foundryProjectEndpoint string = foundryProjectEndpoint
output foundryCapabilityHostResourceId string = '${projectId}/capabilityHosts/agents'
output cosmosFqdn string = '${cosmosName}.documents.azure.com'
output searchFqdn string = '${searchName}.search.windows.net'
output storageBlobFqdn string = '${storageName}.blob.core.windows.net'



