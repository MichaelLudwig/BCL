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
  name: guid(searchService.id, existingAiService.id, 'Cognitive Services User')
  scope: existingAiService
  properties: {
    principalId: searchService.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd') // Cognitive Services User
    principalType: 'ServicePrincipal'
  }
}

// RBAC für Search Service -> Storage Account
resource searchToStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, storageAccount.id, 'Storage Blob Data Reader')
  scope: storageAccount
  properties: {
    principalId: searchService.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1') // Storage Blob Data Reader
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
  name: 'privatelink.blob.core.windows.net'
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

// Outputs
output searchServiceEndpoint string = 'https://${searchService.name}.search.windows.net'
output storageAccountName string = storageAccount.name
