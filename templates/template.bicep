@description('Publicly accessible raw URL for the updated Purview ADLS deployment PowerShell script.')
param deploymentScriptUri string

var location = resourceGroup().location
var subscriptionId = subscription().subscriptionId
var resourceGroupName = resourceGroup().name
var rdPrefix = '/subscriptions/${subscriptionId}/providers/Microsoft.Authorization/roleDefinitions'
var roles = {
  owner: '${rdPrefix}/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
  storageBlobDataReader: '${rdPrefix}/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  storageBlobDataContributor: '${rdPrefix}/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}
var suffix = substring(uniqueString(resourceGroup().id, deployment().name), 0, 5)

// Microsoft Purview account used for the Epicor governance demo.
resource purviewAccount 'Microsoft.Purview/accounts@2021-07-01' existing = {
  name: 'rsb-purview' 
  scope: resourceGroup(subscription().subscriptionId, 'purview-rg')
}

// User-assigned managed identity used by the post-deployment configuration script.
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: 'configDeployer'
  location: location
}

// The deployment script needs resource-group access to configure Purview and upload sample data.
resource deploymentIdentityOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userAssignedIdentity.id, roles.owner)
  scope: resourceGroup()
  properties: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: roles.owner
    principalType: 'ServicePrincipal'
  }
}

// ADLS Gen2 storage account scanned by Purview.
// Public blob access is disabled. The deployment identity uploads data through RBAC.
resource adls 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'pvdemo${suffix}adls'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource adlsBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: adls
  name: 'default'
}

resource sampleContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: adlsBlobService
  name: 'bing'
  properties: {
    publicAccess: 'None'
  }
}

// Purview's system-assigned identity needs read access to scan ADLS.
resource purviewStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adls.id, purviewAccount.id, roles.storageBlobDataReader)
  scope: adls
  properties: {
    principalId: purviewAccount.identity.principalId
    roleDefinitionId: roles.storageBlobDataReader
    principalType: 'ServicePrincipal'
  }
}

// The configuration identity needs data-plane write access to upload the sample dataset.
resource deploymentStorageContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adls.id, userAssignedIdentity.id, roles.storageBlobDataContributor)
  scope: adls
  properties: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: roles.storageBlobDataContributor
    principalType: 'ServicePrincipal'
  }
}

// Configures collections, sample data, the ADLS source, the managed-identity scan, and glossary.
resource configurationScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'configure-purview-adls-demo'
  location: location
  kind: 'AzurePowerShell'
  properties: {
    azPowerShellVersion: '11.0'
    arguments: '-subscriptionId ${subscriptionId} -resourceGroupName ${resourceGroupName} -purviewResourceGroupName purview-rg -rootCollectionName rsb-collection -accountName ${purviewAccount.name} -objectId ${userAssignedIdentity.properties.principalId} -location ${location} -storageAccountName ${adls.name}'
    primaryScriptUri: deploymentScriptUri
    forceUpdateTag: guid(resourceGroup().id, deployment().name, deploymentScriptUri)
    retentionInterval: 'PT4H'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  dependsOn: [
    deploymentIdentityOwner
    purviewStorageReader
    deploymentStorageContributor
    sampleContainer
  ]
}

output purviewAccountName string = purviewAccount.name
output purviewPortalUrl string = 'https://${purviewAccount.name}.purview.azure.com'
output storageAccountName string = adls.name
output sampleContainerName string = sampleContainer.name
