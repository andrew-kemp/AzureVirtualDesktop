@description('Prefix for all session hosts')
param sessionHostPrefix string = 'AVD'

@description('Number of session hosts to deploy')
param numberOfHosts int = 2

@secure()
@description('Admin password for session hosts')
param adminPassword string

@description('Admin username for session hosts')
param adminUsername string = 'AVD-Admin'

@description('Registration key for the AVD host pool')
param hostPoolRegistrationInfoToken string = 'Enter HostPool Registration Key here'

// These values are for the existing vNet/subnet
@description('Resource group containing the vNet')
param vNetResourceGroup string = 'Core-Services'
@description('Name of the vNet')
param vNetName string = 'Master-vNet'
@description('Name of the subnet')
param subnetName string = 'AzureVirtualDesktop'

// Storage account name for FSLogix profiles/redirections
@description('Name of the Storage Account (e.g. "kempystorage")')
param storageAccountName string

// Improved DNS server parameters
@description('Primary DNS server for session hosts (leave blank for default)')
param dns1 string = ''

@description('Secondary DNS server for session hosts (leave blank for default or only use one)')
param dns2 string = ''

// Session host preparation script
@description('URL of the SessionHostPrep.ps1 script')
param sessionHostPrepScriptUrl string = 'https://raw.githubusercontent.com/andrew-kemp/AzureVirtualDesktop/refs/heads/main/02a-SessionHostPrep.ps1'

var fsProfilesPath = '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\profiles'
var fsRedirectionPath = '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\redirections'
var modulesURL = 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02797.442.zip'
var sessionHostPrepScriptName = substring(sessionHostPrepScriptUrl, lastIndexOf(sessionHostPrepScriptUrl, '/') + 1)

// Compose the DNS servers array, omitting blanks (fully compatible Bicep syntax)
var dnsServers = concat(empty(dns1) ? [] : [dns1], empty(dns2) ? [] : [dns2])

// Reference the HostPool
resource HostPool 'Microsoft.DesktopVirtualization/hostpools@2021-07-12' existing = {
  name: '${sessionHostPrefix}-HostPool'
}

// Reference the existing subnet
resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' existing = {
  name: '${vNetName}/${subnetName}'
  scope: resourceGroup(vNetResourceGroup)
}

// Create the NICs for the VMs, with conditional DNS settings
resource nic 'Microsoft.Network/networkInterfaces@2020-11-01' = [for i in range(0, numberOfHosts): {
  name: '${sessionHostPrefix}-${i}-nic'
  location: resourceGroup().location
  properties: union({
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: existingSubnet.id
          }
        }
      }
    ]
  }, empty(dnsServers) ? {} : {
    dnsSettings: {
      dnsServers: dnsServers
    }
  })
}]

// Create the VMs
resource VM 'Microsoft.Compute/virtualMachines@2020-12-01' = [for i in range(0, numberOfHosts): {
  name: '${sessionHostPrefix}-${i}'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_d2as_v5'
    }
    osProfile: {
      computerName: '${sessionHostPrefix}-${i}'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'Windows-11'
        sku: 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 256
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 256
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic[i].id
        }
      ]
    }
  }
}]

// Join the VMs to Entra and Enroll in Intune
resource entraIdJoin 'Microsoft.Compute/virtualMachines/extensions@2021-11-01' = [for i in range(0, numberOfHosts): {
  parent: VM[i]
  name: '${sessionHostPrefix}-${i}-EntraJoinEntrollIntune'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
    settings: {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    } 
  }
}]

// Install the Guest Attestation Extension
resource guestAttestationExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [for i in range(0, numberOfHosts): {
  parent: VM[i]
  name: '${sessionHostPrefix}-${i}-guestAttestationExtension'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn:[
    entraIdJoin
  ]
}]

// Run session host prep script (FSLogix, Cloud Kerberos, etc)
resource SessionPrep 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [for i in range(0, numberOfHosts): {
  parent: VM[i]
  name: '${sessionHostPrefix}-${i}-SessionPrep'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        sessionHostPrepScriptUrl
      ]
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File .\\${sessionHostPrepScriptName} -ProfilesPath "${fsProfilesPath}" -RedirectionPath "${fsRedirectionPath}"'
    }
  }
  dependsOn: [
    guestAttestationExtension
  ]
}]

// Join the SessionHosts to the HostPool
resource dcs 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for i in range(0, numberOfHosts): {
  parent: VM[i]
  name: '${sessionHostPrefix}-${i}-JointoHostPool'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.76'
    settings: {
      modulesUrl: modulesURL
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: HostPool.name
        aadJoin: true
      }
    }
    protectedSettings: {
      properties: {
        registrationInfoToken: hostPoolRegistrationInfoToken
      }
    }
  }
  dependsOn: [
    SessionPrep
  ]
}]

output postDeploymentInstructions string = '''
MANUAL STEPS REQUIRED:
1. Update the AVD enterprise app and grant it permission.
2. Exclude the storage app from Conditional Access policies.
3. Add the folder permissions via a hybrid-joined client.
4. Assign AAD/Entra groups to AVD Application Groups using PowerShell or Portal.
5. Update the Session Desktop friendly name via PowerShell if needed.
6. Please update internal DNS to point ${storageAccountName}.file.${environment().suffixes.storage} to the IP address it has been assigned to.
   (Note: If you are using a Private Endpoint, you can retrieve the assigned IP from the Private Endpoint NIC in the Azure portal.)
'''
