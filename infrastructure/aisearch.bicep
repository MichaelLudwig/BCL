@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des existierenden VNets')
param vnetName string = 'vnet-${resourceGroup().name}'

@description('Der Name des bereits existierenden Subnetzes für den Private Endpoint')
param privateEndpointSubnetName string = 'subnet-private-endpoint'

@description('Der Name des Azure Cognitive Search Services')
param searchServiceName string = 'search-${resourceGroup().name}'

@description('Der Name des Storage Accounts für Dokumente alles klein und ohne Sonderzeichen')
param storageAccountName string = 'docsa${substring(toLower(replace(resourceGroup().name, '-', '')), 0, 10)}'

@description('Die Principal ID der Web App (Managed Identity), die Zugriff auf den Search Service erhalten soll')
param webAppPrincipalId string

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
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_RAGRS'
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

// -----------------------------------
// 2) Azure Cognitive Search Service
// -----------------------------------
resource searchService 'Microsoft.Search/searchServices@2023-10-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: 'standard'
  }
  properties: {
    publicNetworkAccess: 'Disabled' // Nur privat erreichbar
    hostingMode: 'default'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'standard'
    vectorSearch: {
      mode: 'enabled'
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

resource searchDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.search.windows.net'
  location: 'global'
  properties: {}
}

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
  dependsOn: [
    searchDnsZoneLink
  ]
}

// -----------------------------------
// 4) RBAC für Web App -> Search Service
// -----------------------------------
resource searchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(webAppPrincipalId, searchService.id, 'Search Index Contributor')
  scope: searchService
  properties: {
    principalId: webAppPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '275602e7-8741-4c13-9a44-2428efcf1f0e') // "Search Index Contributor"
    principalType: 'ServicePrincipal'
  }
}
