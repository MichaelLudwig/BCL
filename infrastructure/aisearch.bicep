@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des existierenden VNets')
param vnetName string = 'vnet-${resourceGroup().name}'

@description('Der Name des bereits existierenden Subnetzes für den Private Endpoint')
param privateEndpointSubnetName string = 'subnet-private-endpoint'

@description('Der Name des Azure Cognitive Search Services')
param searchServiceName string = 'search${replace(toLower(resourceGroup().name), '-', '')}'

@description('Der Name des Storage Accounts für Dokumente alles klein und ohne Sonderzeichen')
param storageAccountName string = 'store${uniqueString(resourceGroup().id)}'

@description('Der Name der existierenden Web App')
param webAppName string = 'app-${resourceGroup().name}'

@description('Die Private DNS Zone URL für Blob Storage')
param blobDnsZoneUrl string = 'privatelink.blob.${environment().suffixes.storage}'

// Referenz auf die existierende Web App
resource existingWebApp 'Microsoft.Web/sites@2021-02-01' existing = {
  name: webAppName
}

// -----------------------------------
// EXISTING VNet einbinden
// -----------------------------------
resource existingVnet 'Microsoft.Network/virtualNetworks@2023-02-01' existing = {
  name: vnetName
}

var privateEndpointSubnetId = '${existingVnet.id}/subnets/${privateEndpointSubnetName}'

// -----------------------------------
// 1) Storage Account
// -----------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
      defaultAction: 'Allow'
    }
  }
}

// Blob Services
resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

// Container für Dokumente
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobServices
  name: 'documents'
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------
// 2) Azure Cognitive Search Service
// -----------------------------------
resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'basic'
  }
  properties: {
    publicNetworkAccess: 'disabled'
    hostingMode: 'default'
    replicaCount: 1
    partitionCount: 1
    authOptions: {
      aadOrApiKey: {}  // Aktiviert RBAC-basierte Authentifizierung
    }
  }
}

// -----------------------------------
// 3) Private Endpoint + DNS für Cognitive Search
// -----------------------------------
resource searchPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-02-01' = {
  name: '${searchServiceName}-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${searchServiceName}-connection'
        properties: {
          privateLinkServiceId: searchService.id
          groupIds: [
            'searchService'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone für Search Service
resource searchDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.search.windows.net'
  location: 'global'
  properties: {}
}

// DNS-Zonenlink mit VNet verbinden
resource searchDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: searchDnsZone
  name: '${vnetName}-search-dns-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: existingVnet.id
    }
    registrationEnabled: false
  }
}

// DNS Zone Group für Search Service
resource searchDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-02-01' = {
  parent: searchPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'searchconfig'
        properties: {
          privateDnsZoneId: searchDnsZone.id
        }
      }
    ]
  }
}

// -----------------------------------
// 4) RBAC für Web App -> Search Service
// -----------------------------------


// RBAC für Web App -> Search Service
resource searchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingWebApp.id, searchService.id, 'Search Service Contributor')
  scope: searchService
  properties: {
    principalId: existingWebApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    principalType: 'ServicePrincipal'
  }
}

// RBAC für Web App -> Storage
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, existingWebApp.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    principalId: existingWebApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalType: 'ServicePrincipal'
  }
}

// Referenz auf den existierenden AI Service
resource existingAiService 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: 'ai-service-${resourceGroup().name}'
}

// RBAC für Search Service -> AI Service
resource searchToAiServiceRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, existingAiService.id, 'Cognitive Services OpenAI User')
  scope: existingAiService
  properties: {
    principalId: searchService.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a001fd3d-188f-4b5d-821b-7da978bf7442') // Cognitive Services OpenAI User
    principalType: 'ServicePrincipal'
  }
}

// RBAC für AI Service -> Storage Account
resource aiServiceToStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingAiService.id, storageAccount.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    principalId: existingAiService.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
  }
}

// RBAC für Search Service -> Storage Account (ändern von Reader zu Contributor)
resource searchToStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, storageAccount.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    principalId: searchService.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
  }
}

// Private Endpoint für Storage Account
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-02-01' = {
  name: '${storageAccountName}-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone für Blob Storage
resource storageDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: blobDnsZoneUrl
  location: 'global'
  properties: {}
}

// DNS-Zonenlink für Storage
resource storageDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storageDnsZone
  name: '${vnetName}-storage-dns-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: existingVnet.id
    }
    registrationEnabled: false
  }
}

// DNS Zone Group für Storage
resource storageDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-02-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'storageconfig'
        properties: {
          privateDnsZoneId: storageDnsZone.id
        }
      }
    ]
  }
}

// RBAC für OpenAI Service -> Search Service
resource openaiToSearchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingAiService.id, searchService.id, 'Search Service Contributor')
  scope: searchService
  properties: {
    principalId: existingAiService.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0') // Search Service Contributor
    principalType: 'ServicePrincipal'
  }
}

// Referenz auf den OpenAI Private Endpoint
resource existingOpenAiPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-02-01' existing = {
  name: '${existingAiService.name}-pe'
}

// Outputs
output searchServiceEndpoint string = 'https://${searchService.name}.search.windows.net'
output storageAccountName string = storageAccount.name

// Route Table für den Search Service -> OpenAI Traffic
resource searchServiceRoute 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${searchServiceName}-routes'
  location: location
  properties: {
    routes: [
      {
        name: 'to-openai'
        properties: {
          addressPrefix: 'privatelink.openai.azure.com'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: existingOpenAiPrivateEndpoint.properties.networkInterfaces[0].properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

// Existierendes Private Endpoint Subnet aktualisieren
resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-02-01' = {
  parent: existingVnet
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: '10.0.1.0/24'  // Bestehendes Prefix beibehalten
    privateEndpointNetworkPolicies: 'Disabled'
    routeTable: {
      id: searchServiceRoute.id
    }
  }
}
