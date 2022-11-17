param systemName string

@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string
param location string = resourceGroup().location
param locationAbbreviation string
param webPubSubSku object
param developersGroup string
param redisCacheSku object

var defaultResourceName = toLower('${systemName}-${environmentName}-${locationAbbreviation}')
var webPubSubHubname = 'pollstar'

var networkingResourceGroup = 'blckjck-net-prod-neu'
var virtualNetworkResourceName = '${networkingResourceGroup}-vnet'

resource vnet 'Microsoft.Network/virtualNetworks@2022-05-01' existing = {
  name: virtualNetworkResourceName
  scope: resourceGroup(networkingResourceGroup)
}

resource configurationDataReaderRole 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: resourceGroup()
  name: '516239f1-63e1-4d78-a4de-a74fb236a071'
}
resource accessSecretsRole 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: resourceGroup()
  name: '4633458b-17de-408a-b874-0445c86b69e6'
}

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2022-05-01' = {
  name: '${defaultResourceName}-cfg'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Standard'
  }
}

resource allowContributorForDevelopmentTeam 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${systemName}-${developersGroup}-${configurationDataReaderRole.name}')
  properties: {
    principalId: developersGroup
    principalType: 'Group'
    roleDefinitionId: configurationDataReaderRole.id
  }
}
resource allowSecretsForDevelopmentTeam 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${systemName}-${developersGroup}-${accessSecretsRole.name}')
  properties: {
    principalId: developersGroup
    principalType: 'Group'
    roleDefinitionId: accessSecretsRole.id
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: '${defaultResourceName}-kv'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    accessPolicies: []
  }
}
module developerAccessPoliciesModule 'accessPolicies.bicep' = {
  name: 'developerAccessPoliciesModule'
  params: {
    keyVaultName: keyVault.name
    principalId: developersGroup
  }
}

// Logging & Instrumentation
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-12-01-preview' = {
  name: '${defaultResourceName}-log'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${defaultResourceName}-ai'
  location: location
  kind: 'web'
  properties: {
    WorkspaceResourceId: logAnalyticsWorkspace.id
    Application_Type: 'web'
  }
}
resource applicationInsightsConfigurationValue 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
  parent: appConfig
  properties: {
    value: applicationInsights.properties.ConnectionString
    contentType: 'text/plain'
  }
}

resource containerAppEnvironments 'Microsoft.App/managedEnvironments@2022-03-01' = {
  name: '${defaultResourceName}-env'
  location: location
  properties: {
    daprAIInstrumentationKey: applicationInsights.properties.InstrumentationKey
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
    vnetConfiguration: {
      infrastructureSubnetId: '${vnet.id}/subnets/containerapps'
      runtimeSubnetId: '${vnet.id}/subnets/containerappsruntime'
      internal: true
    }
  }
}

// Web pubsub
resource webPubSub 'Microsoft.SignalRService/webPubSub@2021-10-01' = {
  name: '${defaultResourceName}-pubsub'
  location: location
  sku: webPubSubSku
  properties: {
    publicNetworkAccess: 'Enabled'
  }
  resource hub 'hubs' = {
    name: webPubSubHubname
    properties: {
      anonymousConnectPolicy: 'allow'
    }
  }
}
resource webPubSubSecret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  name: 'WebPubSub'
  parent: keyVault
  properties: {
    contentType: 'text/plain'
    value: webPubSub.listKeys().primaryConnectionString
  }
}
resource webPubSubConfigurationValue 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'Azure:WebPubSub'
  parent: appConfig
  properties: {
    contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
    value: '{"uri":"${webPubSubSecret.properties.secretUri}"}'
  }
}
resource webPubSubHubNameConfigurationValue 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'Azure:PollStarHub'
  parent: appConfig
  properties: {
    contentType: 'text/plain'
    value: webPubSubHubname
  }
}

resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-01-01-preview' = {
  name: '${defaultResourceName}-bus'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
}
resource serviceBusName 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'Azure:ServiceBus'
  parent: appConfig
  properties: {
    contentType: 'text/plain'
    value: '${serviceBus.name}.servicebus.windows.net'
  }
}
resource serviceBusFqdn 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'ServiceBusConnection:fullyQualifiedNamespace'
  parent: appConfig
  properties: {
    contentType: 'text/plain'
    value: '${serviceBus.name}.servicebus.windows.net'
  }
}

resource redisCache 'Microsoft.Cache/Redis@2019-07-01' = {
  name: '${defaultResourceName}-redis'
  location: location
  properties: {
    sku: redisCacheSku
  }
}
resource redisCacheSecret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
  name: 'RedisCacheKey'
  parent: keyVault
  properties: {
    value: redisCache.listKeys().primaryKey
  }
}
resource redisCacheKeyConfigValue 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'Cache:Secret'
  parent: appConfig
  properties: {
    contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
    value: '{"uri": "${redisCacheSecret.properties.secretUri}"}'
  }
}
resource redisCacheEndpointConfigValue 'Microsoft.AppConfiguration/configurationStores/keyValues@2022-05-01' = {
  name: 'Cache:Endpoint'
  parent: appConfig
  properties: {
    contentType: 'plain/text'
    value: redisCache.properties.hostName
  }
}

output containerAppEnvironmentName string = containerAppEnvironments.name
output applicationInsightsResourceName string = applicationInsights.name
