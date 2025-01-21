@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des App Service Plans')
param appServicePlanName string = 'asp-${resourceGroup().name}'

@description('Der Name der Web App')
param webAppName string = 'app-${resourceGroup().name}'

@description('Der Name des Azure OpenAI Services')
param aiServiceName string = 'ai-service-${resourceGroup().name}'

@description('Der Name des VNets')
param vnetName string = 'vnet-${resourceGroup().name}'

@description('Das Subnetz für den Private Endpoint')
param privateEndpointSubnetName string = 'subnet-private-endpoint'

@description('Das Subnetz für die App Service VNet-Integration')
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
          privateEndpointNetworkPolicies: 'Disabled' // Erforderlich für Private Endpoint
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

// App Service Plan erstellen
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

// Web App mit VNet-Integration erstellen
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
      alwaysOn: true
      appSettings: [
        {
          name: 'USE_MANAGED_IDENTITY'
          value: 'true'
        }
      ]
    }
    virtualNetworkSubnetId: vnet.properties.subnets[1].id // Subnetz für App Service
  }
}

// Azure OpenAI Service erstellen
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
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

// GPT-4 Modell Deployment
resource gpt4Deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiService
  name: 'gpt-4o-mini'
  sku: {
    name: 'Standard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
    raiPolicyName: 'Microsoft.Default'
  }
}

// Ada-002 Embeddings Modell Deployment
resource embeddingsDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiService
  name: 'text-embedding-ada-002'
  sku: {
    name: 'Standard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-ada-002'
      version: '2'
    }
    raiPolicyName: 'Microsoft.Default'
  }
}

// Private Endpoint für Azure OpenAI Service erstellen
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

// Private DNS Zone erstellen
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
  properties: {}
}

// DNS-Zonenlink mit VNet verbinden
resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-dns-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// DNS-Zonengruppe für den Private Endpoint erstellen
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-02-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    dnsZoneLink
  ]
}

// RBAC-Zuweisung für Web App zur Azure OpenAI-Nutzung
resource openAIRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(webApp.id, aiService.id, 'Cognitive Services User')
  scope: aiService
  properties: {
    principalId: webApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd') // Cognitive Services User
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output webAppManagedIdentityPrincipalId string = webApp.identity.principalId

