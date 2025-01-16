@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des App Service Plans')
param appServicePlanName string = 'asp-bcl-reviewer'

@description('Der Name der Web App')
param webAppName string = 'app-bcl-reviewer'

@description('Der Name des AI Services Account')
param aiServiceName string = 'ai-service-bcl-reviewer'

@description('Der Name des VNets')
param vnetName string = 'vnet-bcl-reviewer'

@description('Das Subnetz für den Private Endpoint')
param privateEndpointSubnetName string = 'subnet-private-endpoint'

@description('Das Subnetz für App Service VNet-Integration')
param appServiceSubnetName string = 'subnet-appservice'

// VNet mit Subnetzen erstellen
resource vnet 'Microsoft.Network/virtualNetworks@2023-02-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: appServiceSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'
          delegations: [
            {
              name: 'delegation-appservice'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  properties: {
    reserved: true
  }
  sku: {
    name: 'B2'
    tier: 'Basic'
  }
}

// Web App mit VNet-Integration
resource webApp 'Microsoft.Web/sites@2021-02-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: '/bin/bash startup.sh'
      alwaysOn: true
      scmType: 'None'
      appSettings: [
        {
          name: 'AZURE_OPENAI_API_KEY'
          value: listKeys(aiService.id, aiService.apiVersion).key1
        }
      ]
    }
    virtualNetworkSubnetId: vnet.properties.subnets[1].id // Verknüpft mit Subnetz für App Service
  }
}

// Azure AI Services Multi-Service Account erstellen
resource aiService 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aiServiceName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: aiServiceName
    publicNetworkAccess: 'Disabled' // Verhindert öffentlichen Zugriff
    apiProperties: {
      statisticsEnabled: false
    }
  }
}

// Private Endpoint für OpenAI Service
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-02-01' = {
  name: '${aiServiceName}-pe'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: '${aiServiceName}-connection'
        properties: {
          privateLinkServiceId: aiService.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2023-02-01' = {
  name: 'privatelink.openai.azure.com'
  location: location
  properties: {}
}

// Link DNS Zone mit VNet
resource dnsZoneLink 'Microsoft.Network/virtualNetworks@2023-02-01' = {
  name: '${vnetName}-link'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// DNS-Eintrag für Private Endpoint
resource privateDnsZoneGroup 'Microsoft.Network/privateDnsZoneGroups@2023-02-01' = {
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'zoneConfig'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    privateEndpoint
  ]
}

// RBAC-Zuweisung für Web App zur OpenAI-Nutzung
resource openAIRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(webApp.id, aiService.id, 'Cognitive Services User')
  scope: aiService
  properties: {
    principalId: webApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd') // Cognitive Services User
    principalType: 'ServicePrincipal'
  }
}

