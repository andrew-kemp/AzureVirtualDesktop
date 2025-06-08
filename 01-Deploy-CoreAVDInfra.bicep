// This Bicep template deploys core Azure Virtual Desktop (AVD) infrastructure components
// including a storage account with Azure AD Kerberos authentication, private endpoints,
// and AVD resources such as host pools, application groups, and workspaces.
// It also configures role assignments for file share contributors and elevated contributors.
// The template is designed to be reusable and parameterized for flexibility.
// Version: 1.0.0
// Created by:Andrew Kemp
// Date: 2025-06-08
// Created with the assistance of Copilot for GitHub
//Run this script in the Azure Cloud Shell or Azure CLI with Bicep installed
// Script 1 of 5

// This will as you for the followin:
// Create or use an existing resource group
// Provide a name for the storage account (must be globally unique)
// Provide the Active Directory domain name for Azure AD Kerberos authentication
// Provide the GUID of the Active Directory domain
// Provide the Object ID of the group to assign Storage File Data SMB Share Contributor
// Provide the Object ID of the group to assign Storage File Data SMB Share Elevated Contributor
// Provide the resource group of the vNet for the Private Endpoint (default is 'Core-Services')
// Provide the name of the vNet for the Private Endpoint (default is 'Master-vNet')
// Provide the subnet name for the Private Endpoint (default is 'Storage')
// Provide a prefix for the AVD resources (default is 'Kemponline')


//// Parameters:

@description('The name of the storage account.')
param storageAccountName string

@description('The Active Directory domain name for Azure AD Kerberos authentication (e.g., corp.contoso.com).')
param kerberosDomainName string

@description('The GUID of the Active Directory domain (e.g., 12345678-90ab-cdef-1234-567890abcdef).')
param kerberosDomainGuid string

@description('The Object ID of the group to assign Storage File Data SMB Share Contributor.')
param smbShareContributorGroupOid string

@description('The Object ID of the group to assign Storage File Data SMB Share Elevated Contributor.')
param smbShareElevatedContributorGroupOid string

@description('Resource group of the vNet for the Private Endpoint')
param vnetResourceGroup string = 'Core-Services'

@description('Name of the vNet for the Private Endpoint')
param vnetName string = 'Master-vNet'

@description('Subnet name for the Private Endpoint')
param subnetName string = 'Storage'

@description('Prefix for the AVD resources')
param DefaultPrefix string = 'Kemponline'

// STORAGE RESOURCES

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
      activeDirectoryProperties: {
        domainName: kerberosDomainName
        domainGuid: kerberosDomainGuid
      }
      sharePermissions: 'Share'
    }
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
  }
}

// Disable Azure Files soft delete (backup) by default
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource fileShareProfiles 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: 'profiles'
  parent: fileService
}

resource fileShareRedirection 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: 'redirections'
  parent: fileService
}

// Role assignment for Storage File Data SMB Share Contributor
resource smbShareContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, smbShareContributorGroupOid, 'FileShareContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
    principalId: smbShareContributorGroupOid
    principalType: 'Group'
  }
}

// Role assignment for Storage File Data SMB Share Elevated Contributor
resource smbShareElevatedContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, smbShareElevatedContributorGroupOid, 'FileShareElevatedContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a7264617-510b-434b-a828-9731dc254ea7')
    principalId: smbShareElevatedContributorGroupOid
    principalType: 'Group'
  }
}

// Reference the vNet and subnet in another resource group
resource vnet 'Microsoft.Network/virtualNetworks@2023-06-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-06-01' existing = {
  parent: vnet
  name: subnetName
}

// Private Endpoint for Storage Account File Service only (target subresource is 'file')
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${storageAccountName}-file-pe'
  location: resourceGroup().location
  properties: {
    subnet: {
      id: subnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'storageAccountFileConnection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

// AVD RESOURCES

// Hostpool
resource HostPool 'Microsoft.DesktopVirtualization/hostPools@2021-07-12' = {
  name: '${DefaultPrefix}-HostPool'
  location: resourceGroup().location
  properties: {
    friendlyName: '${DefaultPrefix} Host Pool'
    description: '${DefaultPrefix} AVD Host Pool for users to securely access resources from'
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: 5
    personalDesktopAssignmentType: 'Automatic'
    startVMOnConnect: true
    preferredAppGroupType: 'Desktop'
    customRdpProperty: 'enablecredsspsupport:i:1;authentication level:i:2;enablerdsaadauth:i:1;redirectwebauthn:i:1;'
  }
}

// Desktop Application Group
resource AppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2021-07-12' = {
  name: '${DefaultPrefix}-AppGroup'
  location: resourceGroup().location
  properties: {
    description: '${DefaultPrefix} Application Group'
    friendlyName: '${DefaultPrefix} Desktop Application Group'
    hostPoolArmPath: HostPool.id
    applicationGroupType: 'Desktop'
  }
}

// AVD Workspace 
resource Workspace 'Microsoft.DesktopVirtualization/workspaces@2021-07-12' = {
  name: '${DefaultPrefix}-Workspace'
  location: resourceGroup().location
  properties: {
    description: '${DefaultPrefix} Workspace'
    friendlyName: '${DefaultPrefix} Workspace'
    applicationGroupReferences: [
      AppGroup.id
    ]
  }
}

// OUTPUTS

output storageAccountId string = storageAccount.id
output profilesShareName string = fileShareProfiles.name
output redirectionShareName string = fileShareRedirection.name
output privateEndpointId string = privateEndpoint.id
output hostPoolId string = HostPool.id
output appGroupId string = AppGroup.id
output workspaceId string = Workspace.id
