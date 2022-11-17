targetScope = 'subscription'

param systemName string

@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string
param location string = deployment().location
param locationAbbreviation string
param developersGroup string
param webPubSubSku object = {
  capacity: 1
  tier: 'Free'
  name: 'Free_F1'
}
param redisCacheSku object = {
  name: 'Standard'
  family: 'C'
  capacity: 1
}

var integrationResourceGroupName = toLower('${systemName}-${environmentName}-${locationAbbreviation}')

resource integrationResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: integrationResourceGroupName
  location: location
}

module integrationModule 'integration.bicep' = {
  name: 'IntegrationModule'
  scope: integrationResourceGroup
  params: {
    environmentName: environmentName
    locationAbbreviation: locationAbbreviation
    systemName: systemName
    location: location
    webPubSubSku: webPubSubSku
    developersGroup: developersGroup
    redisCacheSku: redisCacheSku
  }
}
