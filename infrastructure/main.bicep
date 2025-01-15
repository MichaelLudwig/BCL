@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des App Service Plans')
param appServicePlanName string = 'asp-bcl-reviewer'

@description('Der Name der Web App')
param webAppName string = 'app-bcl-reviewer'

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
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'PYTHON_ENABLE_GUNICORN'
          value: 'true'
        }
        {
          name: 'WEBSITES_PORT'
          value: '8000'
        }
      ]
      alwaysOn: true
    }
  }
}

// Outputs für die Managed Identity Principal ID
output managedIdentityPrincipalId string = webApp.identity.principalId 
