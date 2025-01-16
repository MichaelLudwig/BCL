@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des App Service Plans')
param appServicePlanName string = 'asp-bcl-reviewer'

@description('Der Name der Web App')
param webAppName string = 'app-bcl-reviewer'

@description('Der Name des AI Services Account')
param aiServiceName string = 'ai-service-bcl-reviewer'


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

// Web App
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
    }
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
    publicNetworkAccess: 'Enabled'
    apiProperties: {
      statisticsEnabled: false
    }
  }
}

// Bereitstellung des GPT-4o Mini Modells
resource openAIModel 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
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

// Ausgabe Principal
output managedIdentityPrincipalId string = webApp.identity.principalId
// Ausgabe des Endpunkts und des Schlüssels
//output aiServiceEndpoint string = aiService.properties.endpoint
//output aiServiceKey string = listKeys(aiService.id, '2023-10-01-preview').key1


