<#
.SYNOPSIS
    Deploys the Azure Virtual Desktop (AVD) solution in Azure, including core infrastructure and/or additional session hosts.

.DESCRIPTION
    This script provides an interactive menu to deploy the full AVD solution or just additional session hosts.
    It automates the setup of Azure resources, Azure Virtual Desktop (AVD) host pools, Entra ID (Azure AD) groups,
    RBAC assignments, and more. The script connects to and manages resources in Azure via both Azure CLI and Az PowerShell,
    and interacts with Microsoft Graph for Entra ID (Azure AD) operations.

    Key features:
    - Interactive menu for full or session host-only deployment
    - Automated environment and module checks
    - Azure subscription and resource group selection/creation
    - Entra ID group selection or creation
    - Bicep/ARM template selection and deployment
    - RBAC assignment for AVD and VM access
    - Optional session host deployment with user assignment and group membership
    - Device tagging and VM auto-shutdown configuration

.REQUIREMENTS
    - PowerShell 7.x (latest recommended)
    - Azure CLI (az) installed and authenticated
    - Az PowerShell modules: Az.Accounts, Az.DesktopVirtualization
    - Microsoft Graph PowerShell modules: Microsoft.Graph, Microsoft.Graph.Groups, Microsoft.Graph.Authentication
    - Sufficient Azure and Entra ID (Azure AD) permissions to create resources, assign roles, and manage groups

.NOTES
    - Run this script in a PowerShell 7 terminal for best compatibility and performance.
    - You must be authenticated to Azure and Microsoft Graph; the script will prompt for login if needed.
    - All actions are logged to AVDDeploy.log in the script directory.

.AUTHOR
    [Your Name or Organization]
#>
# ==========================
# Shared Utility Functions
# ==========================

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "########################################" -ForegroundColor Cyan
    Write-Host ("#  {0,-36} #" -f $Text) -ForegroundColor Cyan
    Write-Host "########################################" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $entry = "$timestamp [$Level] $Message"
    Add-Content -Path "deploy-coreinfra.log" -Value $entry
}

function Ensure-Module {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Host "Installing module $ModuleName..." -ForegroundColor Yellow
        Install-Module -Name $ModuleName -Force -Scope CurrentUser
    }
}

function Ensure-AzCli {
    if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
        Write-Host "Azure CLI not found. Please install Azure CLI." -ForegroundColor Red
        exit 1
    }
}

function Ensure-AzAccountModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "Az.Accounts module not found. Installing..." -ForegroundColor Yellow
        Install-Module -Name Az.Accounts -Force -Scope CurrentUser
    }
}

function Ensure-AzConnection {
    if (-not (Get-AzContext)) {
        Write-Host "Connecting to Azure..." -ForegroundColor Yellow
        Connect-AzAccount
    }
}

function Ensure-MgGraphConnection {
    if (-not (Get-MgContext)) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph -Scopes "Group.ReadWrite.All"
    }
}

function Select-FromList {
    param (
        [Parameter(Mandatory)]
        [array]$Options,
        [Parameter(Mandatory)]
        [string]$Prompt
    )
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "$($i + 1)) $($Options[$i])"
    }
    do {
        $selection = Read-Host "$Prompt [1-$($Options.Count)]"
        $valid = ($selection -as [int]) -and $selection -ge 1 -and $selection -le $Options.Count
        if (-not $valid) { Write-Host "Invalid selection. Please choose a valid number." -ForegroundColor Red }
    } until ($valid)
    return $Options[$selection - 1]
}

function Setup-ResourceGroup {
    while ($true) {
        Clear-Host
        Write-Banner "Resource Group Setup"

        Write-Host "Would you like to use an existing resource group, or create a new one?" -ForegroundColor Green
        Write-Host "1) Existing" -ForegroundColor Yellow
        Write-Host "2) New" -ForegroundColor Yellow
        Write-Host "0) Go Back" -ForegroundColor Yellow
        $rgChoice = Read-Host "Enter selection (Default 1)"
        if ([string]::IsNullOrEmpty($rgChoice)) { $rgChoice = "1" }

        # Handle Go Back
        if ($rgChoice -eq "0") {
            Write-Host "Returning to previous menu..." -ForegroundColor Cyan
            Write-Log "User chose to go back from resource group setup." "INFO"
            return $null
        }

        if ($rgChoice -eq "1") {
            Clear-Host
            Write-Banner "Select Existing Resource Group"
            $rgs = az group list --output json | ConvertFrom-Json
            if (-not $rgs) {
                Write-Host "No resource groups found. You must create a new one." -ForegroundColor Red
                Write-Log "No resource groups found. Creating new one." "WARN"
                $rgChoice = "2"
            } else {
                for ($i = 0; $i -lt $rgs.Count; $i++) { Write-Host "$($i+1)) $($rgs[$i].name)  ($($rgs[$i].location))" -ForegroundColor Cyan }
                Write-Host "0) Go Back" -ForegroundColor Yellow
                $rgSelect = Read-Host "Enter the number of the resource group to use"
                if ($rgSelect -eq "0") { continue }
                if (($rgSelect -as [int]) -and $rgSelect -ge 1 -and $rgSelect -le $rgs.Count) {
                    $resourceGroup = $rgs[$rgSelect - 1].name
                    $resourceGroupLocation = $rgs[$rgSelect - 1].location
                    Write-Host "Using resource group: $resourceGroup" -ForegroundColor Yellow
                    Write-Log "Using resource group: $resourceGroup ($resourceGroupLocation)"
                    break
                } else {
                    Write-Host "Invalid selection. Please enter a valid number." -ForegroundColor Red
                    continue
                }
            }
        }
        if ($rgChoice -eq "2") {
            Clear-Host
            Write-Banner "Create New Resource Group"
            Write-Host "Enter a name for the new resource group (or 0 to go back):" -ForegroundColor Green
            $resourceGroup = Read-Host
            if ($resourceGroup -eq "0") { continue }
            Write-Host "Enter the Azure region for the new resource group (e.g., uksouth, eastus or 0 to go back):" -ForegroundColor Green
            $resourceGroupLocation = Read-Host
            if ($resourceGroupLocation -eq "0") { continue }
            Write-Host "Creating resource group $resourceGroup in $resourceGroupLocation..." -ForegroundColor Yellow
            Write-Log "Creating resource group $resourceGroup in $resourceGroupLocation..."
            az group create --name $resourceGroup --location $resourceGroupLocation | Out-Null
            Write-Host "Resource group $resourceGroup created." -ForegroundColor Green
            Write-Log "Resource group $resourceGroup created."
            break
        }

        if (($rgChoice -ne "1") -and ($rgChoice -ne "2")) {
            Write-Host "Invalid selection. Please enter a valid option." -ForegroundColor Red
        }
    }
    Write-Log "Resource group setup complete."
    Start-Sleep 1

    return @{
        Name = $resourceGroup
        Location = $resourceGroupLocation
    }
}


function Create-AADGroup([string]$groupName) {
    $mailNickname = $groupName -replace '\s',''
    $groupParams = @{
        DisplayName     = $groupName
        MailEnabled     = $false
        MailNickname    = $mailNickname
        SecurityEnabled = $true
    }
    $newGroup = New-MgGroup @groupParams
    Write-Host "Created group '$($newGroup.DisplayName)' with Object ID: $($newGroup.Id)" -ForegroundColor Cyan
    Write-Log "Created AAD group: $($newGroup.DisplayName) ObjectId: $($newGroup.Id)"
    return $newGroup
}

function Select-AADGroupBySubstring([string]$searchSubstring, [string]$role) {
    Write-Host "Searching for Azure AD groups containing '$searchSubstring' for $role..." -ForegroundColor Green
    Write-Log "Searching for Azure AD groups containing '$searchSubstring' for $role..."
    $allGroups = Get-MgGroup -All
    $filteredGroups = $allGroups | Where-Object { $_.DisplayName -match $searchSubstring }
    if (-not $filteredGroups) {
        Write-Host "No groups found containing '$searchSubstring' in the display name." -ForegroundColor Red
        Write-Log "No groups found containing '$searchSubstring' in the display name." "WARN"
        return $null
    }
    Write-Host "Select the $role group from the list below:" -ForegroundColor Cyan
    $i = 1
    foreach ($group in $filteredGroups) {
        Write-Host "$i) $($group.DisplayName) (ObjectId: $($group.Id))" -ForegroundColor Cyan
        $i++
    }
    Write-Host "Enter the number of the $role group to use" -ForegroundColor Green
    $selection = Read-Host
    $selectedGroup = $filteredGroups[$selection - 1]
    Write-Host "Selected group: $($selectedGroup.DisplayName)" -ForegroundColor Cyan
    Write-Log "Selected AAD group for: $($selectedGroup.DisplayName) ObjectId: $($selectedGroup.Id)"
    return $selectedGroup
}

function Get-ValidatedStorageAccountName {
    while ($true) {
        Write-Host "Enter the storage account name (3-24 chars, lowercase letters and numbers only)" -ForegroundColor Green
        $storageAccountName = Read-Host
        $storageAccountName = $storageAccountName.Trim()
        if ([string]::IsNullOrEmpty($storageAccountName)) { Write-Host "Cannot be blank." -ForegroundColor Red; Write-Log "Storage account name blank" "WARN"; Start-Sleep 2; continue }
        if ($storageAccountName.Length -lt 3 -or $storageAccountName.Length -gt 24) { Write-Host "Invalid length." -ForegroundColor Red; Write-Log "Storage account name invalid length: $storageAccountName" "WARN"; Start-Sleep 2; continue }
        if ($storageAccountName -notmatch '^[a-z0-9]{3,24}$') { Write-Host "Invalid characters." -ForegroundColor Red; Write-Log "Storage account name invalid characters: $storageAccountName" "WARN"; Start-Sleep 2; continue }
        Write-Host "Checking availability of the storage account name..." -ForegroundColor Cyan
        Write-Log "Checking storage account name availability: $storageAccountName"
        try {
            $azResult = az storage account check-name --name $storageAccountName | ConvertFrom-Json
        } catch {
            Write-Host "@Validation of Storage account name has failed, please continue with caution. If the name exists the deployment will fail." -ForegroundColor Yellow
            Write-Log "Storage account validation failed for $storageAccountName. Exception: $($_.Exception.Message)" "ERROR"
            return $storageAccountName
        }
        if (-not $azResult.nameAvailable) {
            Write-Host "Name already in use." -ForegroundColor Red
            Write-Log "Storage account name already in use: $storageAccountName" "WARN"
            Start-Sleep 2
            $randomNumber = Get-Random -Minimum 100 -Maximum 999
            $newName = $storageAccountName
            if ($newName.Length -gt 21) { $newName = $newName.Substring(0, 21) }
            $newName += $randomNumber
            Write-Host "Trying '$newName'..." -ForegroundColor Cyan
            Write-Log "Trying alternate storage account name: $newName"
            $azResult = az storage account check-name --name $newName | ConvertFrom-Json
            if ($azResult.nameAvailable) { Write-Host "'$newName' is available." -ForegroundColor Green; Write-Log "Storage account name '$newName' is available." ; Start-Sleep 1; return $newName } else { continue }
        }
        Write-Host "Storage account name is available." -ForegroundColor Green
        Write-Log "Storage account name '$storageAccountName' is available."
        Start-Sleep 1
        return $storageAccountName
    }
}

function Select-VNetAndSubnet {
    param(
        [string]$ContextLabel = ""
    )

    while ($true) {
        Clear-Host
        Write-Banner "VNet/Subnet Selection $ContextLabel"
        Write-Host "1) Enter details manually"
        Write-Host "2) Search and select"
        $choice = Read-Host "Choose an option [Default: 2]"
        if ([string]::IsNullOrEmpty($choice)) { $choice = "2" }

        if ($choice -eq "1") {
            Clear-Host
            Write-Banner "Manual VNet/Subnet Entry $ContextLabel"
            $vnetResourceGroup = Read-Host "Enter the resource group of the vNet $ContextLabel (default: Core-Services)"
            if (-not $vnetResourceGroup) { $vnetResourceGroup = "Core-Services" }
            $vnetName = Read-Host "Enter the vNet name $ContextLabel (default: Master-vNet)"
            if (-not $vnetName) { $vnetName = "Master-vNet" }
            $subnetName = Read-Host "Enter the subnet name $ContextLabel (default: Storage)"
            if (-not $subnetName) { $subnetName = "Storage" }
            return @{
                VNetResourceGroup = $vnetResourceGroup
                VNetName = $vnetName
                SubnetName = $subnetName
            }
        } else {
            Clear-Host
            Write-Banner "Select VNet Resource Group $ContextLabel"
            $vnetRgs = az group list --output json | ConvertFrom-Json
            for ($i = 0; $i -lt $vnetRgs.Count; $i++) {
                Write-Host "$($i+1)) $($vnetRgs[$i].name)" -ForegroundColor Cyan
            }
            $rgChoice = Read-Host "Select the resource group containing the vNet $ContextLabel"
            $vnetResourceGroup = $vnetRgs[$rgChoice - 1].name

            Clear-Host
            Write-Banner "Select VNet $ContextLabel"
            $vnets = az network vnet list --resource-group $vnetResourceGroup --output json | ConvertFrom-Json
            if (-not $vnets) { Write-Host "No VNets found in this resource group." -ForegroundColor Red; return $null }
            for ($i = 0; $i -lt $vnets.Count; $i++) {
                Write-Host "$($i+1)) $($vnets[$i].name)" -ForegroundColor Cyan
            }
            $vnetChoice = Read-Host "Select the vNet $ContextLabel"
            $vnetName = $vnets[$vnetChoice - 1].name

            Clear-Host
            Write-Banner "Select Subnet $ContextLabel"
            $subnets = $vnets[$vnetChoice - 1].subnets
            if (-not $subnets) {
                $subnets = az network vnet subnet list --resource-group $vnetResourceGroup --vnet-name $vnetName --output json | ConvertFrom-Json
            }
            for ($i = 0; $i -lt $subnets.Count; $i++) {
                Write-Host "$($i+1)) $($subnets[$i].name)" -ForegroundColor Cyan
            }
            $subnetChoice = Read-Host "Select the subnet $ContextLabel"
            $subnetName = $subnets[$subnetChoice - 1].name

            return @{
                VNetResourceGroup = $vnetResourceGroup
                VNetName = $vnetName
                SubnetName = $subnetName
            }
        }
    }
}

function Select-BicepFile {
    param(
        [string]$PreferredKeyword = "",
        [string]$Prompt = "Would you like to use this file? [Y/n]"
    )
    $bicepFiles = Get-ChildItem -Path . -Filter '*.bicep' | Select-Object -ExpandProperty Name

    $autoFile = $null
    if ($PreferredKeyword) {
        $autoFile = $bicepFiles | Where-Object { $_ -like "*$PreferredKeyword*.bicep" } | Select-Object -First 1
    }

    if ($autoFile) {
        Write-Host "Bicep file found: $autoFile"
        $useAuto = Read-Host $Prompt
        if ([string]::IsNullOrEmpty($useAuto) -or $useAuto -match '^(y|Y)$') {
            return $autoFile
        }
    }
    # If not using auto or no match, present all .bicep files
    Write-Host "Select a Bicep file to use:"
    for ($i = 0; $i -lt $bicepFiles.Count; $i++) {
        Write-Host "$($i+1)) $($bicepFiles[$i])"
    }
    do {
        $choice = Read-Host "Enter number [1-$($bicepFiles.Count)]"
        $valid = ($choice -as [int]) -and $choice -ge 1 -and $choice -le $bicepFiles.Count
        if (-not $valid) { Write-Host "Invalid selection." -ForegroundColor Red }
    } until ($valid)
    return $bicepFiles[$choice - 1]
}

function Write-DeploymentInfo {
    param(
        [Parameter(Mandatory)] [hashtable]$Info,
        [string]$FileName = "deployment-info.inf"
    )
    $json = $Info | ConvertTo-Json -Depth 5
    $json | Set-Content -Path $FileName
    Write-Host "Deployment information written to $FileName" -ForegroundColor Green
}

# ==========================
# Main Core Infra Function
# ==========================

function Deploy-CoreInfra {
    Clear-Host
    Write-Banner "Deploying Core Infrastructure"

    # Ensure required modules and authentication
    Ensure-Module -ModuleName Az.DesktopVirtualization
    Ensure-Module -ModuleName Microsoft.Graph.Groups
    Ensure-AzCli
    Ensure-AzAccountModule
    Ensure-AzConnection
    Ensure-MgGraphConnection

    Clear-Host
    Write-Banner "Select Azure Subscription"
    # --- Subscription selection ---
    $subs = Get-AzSubscription | Select-Object -Property Name, Id
    $subOptions = $subs | ForEach-Object { "$($_.Name) [$($_.Id)]" }
    $selectedSub = Select-FromList -Options $subOptions -Prompt "Select a subscription"
    $subIndex = $subOptions.IndexOf($selectedSub)
    $subId = $subs[$subIndex].Id
    Set-AzContext -SubscriptionId $subId
    Write-Log "Set Azure context to subscription $subId" "INFO"

    Clear-Host
    # --- Resource group selection/creation ---
    Write-Banner "Resource Group Setup/Selection"
    $rgInfo = Setup-ResourceGroup
    if (-not $rgInfo) {
        Write-Log "Resource group setup cancelled. Exiting Core Infra deployment." "WARN"
        return
    }
    $resourceGroup = $rgInfo.Name
    $resourceGroupLocation = $rgInfo.Location

    Clear-Host
    #############################
    # Entra Group Selection/Creation
    #############################
    Write-Banner "Entra Group Selection/Creation"
    Write-Host "vPAW User and Admin Entra groups" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "1) Use existing Entra groups" -ForegroundColor Yellow
    Write-Host "2) Create new Entra groups" -ForegroundColor Yellow
    Write-Host ""
    $groupsChoice = Read-Host "Select an option (Default: 1)"
    if ([string]::IsNullOrEmpty($groupsChoice)) { $groupsChoice = "1" }

    Clear-Host
    if ($groupsChoice -eq "1") {
        Write-Host "Enter search substring for group names (e.g. 'PAW')" -ForegroundColor Green
        $groupSearch = Read-Host
        $userGroup = $null
        while (-not $userGroup) {
            $userGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Users (Contributors)"
            if (-not $userGroup) {
                Write-Host "Please try a different search or ensure the group exists." -ForegroundColor Red
                Write-Host "Enter search substring for Users group" -ForegroundColor Green
                $groupSearch = Read-Host
            }
        }
        Clear-Host
        $adminGroup = $null
        while (-not $adminGroup) {
            $adminGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Admins (Elevated Contributors)"
            if (-not $adminGroup) {
                Write-Host "Please try a different search or ensure the group exists." -ForegroundColor Red
                Write-Host "Enter search substring for Admins group" -ForegroundColor Green
                $groupSearch = Read-Host
            }
        }
    } else {
        Write-Host "Enter a name for the new Users (Contributors) group" -ForegroundColor Green
        $userGroupName = Read-Host
        $userGroup = Create-AADGroup $userGroupName
        Clear-Host
        Write-Host "Enter a name for the new Admins (Elevated Contributors) group" -ForegroundColor Green
        $adminGroupName = Read-Host
        $adminGroup = Create-AADGroup $adminGroupName
    }
    Write-Log "Entra group setup complete."
    Start-Sleep 1

    Clear-Host
    #############################
    # Deployment Parameter Input
    #############################
    Write-Banner "Deployment Parameter Input"

    $storageAccountName = Get-ValidatedStorageAccountName
    $kerberosDomainName = Read-Host "Enter the Active Directory domain name (e.g., corp.contoso.com)"
    $kerberosDomainGuid = Read-Host "Enter the GUID of the Active Directory domain"

    Clear-Host
    #############################
    # VNet/Subnet Enhanced Selection Section
    #############################
    Write-Banner "VNet/Subnet Enhanced Selection"
    $vnetSelection = Select-VNetAndSubnet -ContextLabel "for the private endpoint"
    $vnetResourceGroup = $vnetSelection.VNetResourceGroup
    $vnetName = $vnetSelection.VNetName
    $privateEndpointSubnet = $vnetSelection.SubnetName
    Clear-Host

    $defaultPrefix = Read-Host "Enter the prefix for AVD resources (default: Kemponline)"
    if (-not $defaultPrefix) { $defaultPrefix = "Kemponline" }

    Clear-Host
    #############################
    # Bicep File Selection
    #############################
    Write-Banner "Bicep File Selection"
    $coreBicepFile = Select-BicepFile -PreferredKeyword "CoreAVDInfra"

    # Robust check for bicep file selection
    if (-not $coreBicepFile) {
        Write-Host "No Bicep template selected. Deployment cannot continue." -ForegroundColor Red
        Pause
        return
    }

    Clear-Host
    #############################
    # Write Deployment Info to INF (JSON)
    #############################
    Write-Banner "Writing Deployment Info"
    $deploymentInfo = @{
        SubscriptionId                = $subId
        ResourceGroup                 = $resourceGroup
        ResourceGroupLocation         = $resourceGroupLocation
        StorageAccountName            = $storageAccountName
        KerberosDomainName            = $kerberosDomainName
        KerberosDomainGuid            = $kerberosDomainGuid
        AVDUsersGroupOid              = $userGroup.Id
        AVDAdminsGroupOid             = $adminGroup.Id
        VNetResourceGroup             = $vnetResourceGroup
        VNetName                      = $vnetName
        CoreInfraPrivateEndpointSubnet = $privateEndpointSubnet   # <-- Custom key for clarity
        DefaultPrefix                 = $defaultPrefix
        CoreInfraBicep                = $coreBicepFile
        TimestampUTC                  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    Write-DeploymentInfo -Info $deploymentInfo

    Clear-Host
##############################
# Deploy the Bicep template
##############################
Write-Banner "Deploying Bicep Template"

# BUILD THE COMMAND HERE
$deployCommand = "az deployment group create --resource-group $resourceGroup --template-file $coreBicepFile --parameters " +
    "storageAccountName=$storageAccountName kerberosDomainName=$kerberosDomainName kerberosDomainGuid=$kerberosDomainGuid " +
    "avdUsersGroupOid=$($userGroup.Id) avdAdminsGroupOid=$($adminGroup.Id) vnetResourceGroup=$vnetResourceGroup " +
    "vnetName=$vnetName subnetName=$privateEndpointSubnet defaultPrefix=$defaultPrefix"
    
    Write-Host "Running deployment command..."
    Write-Host $deployCommand -ForegroundColor Yellow
    
    try {
        $deployResult = Invoke-Expression $deployCommand 2>&1
        Write-Host $deployResult
    
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Core infrastructure deployed successfully." -ForegroundColor Green
            Write-Log "Core infrastructure deployment succeeded." "INFO"
            Write-Host "Press Enter to continue..." -ForegroundColor Yellow
            [void][System.Console]::ReadLine()
    
            # Call the post-deployment step
            Post-Deploy-CoreInfra `
                -SubscriptionId $subId `
                -ResourceGroup $resourceGroup `
                -AppGroupName $appGroupName `
                -UserGroup $userGroup `
                -AdminGroup $adminGroup `
                -StorageAccountName $storageAccountName
        } else {
            Write-Host "Core infrastructure deployment failed with exit code $LASTEXITCODE." -ForegroundColor Red
            Write-Host "See details above or check the logs for more information." -ForegroundColor Red
            Write-Log "Core infrastructure deployment failed: $deployResult" "ERROR"
            Write-Host "Press Enter to continue..." -ForegroundColor Yellow
            [void][System.Console]::ReadLine()
        }
    } catch {
        Write-Host "Deployment command threw an exception: $_" -ForegroundColor Red
        Write-Log "Deployment command exception: $_" "ERROR"
        Write-Host "Press Enter to continue..." -ForegroundColor Yellow
        [void][System.Console]::ReadLine()
    }
}
########################################################################################################################

function Post-Deploy-CoreInfra {
    param(
        [Parameter(Mandatory=$true)] [string]$SubscriptionId,
        [Parameter(Mandatory=$true)] [string]$ResourceGroup,
        [Parameter(Mandatory=$true)] [string]$AppGroupName,
        [Parameter(Mandatory=$true)] $UserGroup,   # expects object with .Id
        [Parameter(Mandatory=$true)] $AdminGroup,  # expects object with .Id
        [Parameter(Mandatory=$true)] [string]$StorageAccountName
    )

    #############################
    #     Post-Deployment:      #
    #   RBAC & AVD Config       #
    #############################
    Clear-Host
    Write-Banner "Post-Deployment: RBAC & AVD Config"

    function Ensure-RoleAssignment {
        param (
            [Parameter(Mandatory=$true)][string]$ObjectId,
            [Parameter(Mandatory=$true)][string]$RoleDefinitionName,
            [Parameter(Mandatory=$true)][string]$Scope
        )
        $ra = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope -ErrorAction SilentlyContinue
        if (-not $ra) {
            Write-Host "Assigning '$RoleDefinitionName' to object $ObjectId at scope $Scope..." -ForegroundColor Cyan
            Write-Log "Assigning '$RoleDefinitionName' to object $ObjectId at scope $Scope..."
            New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope | Out-Null
        } else {
            Write-Host "'$RoleDefinitionName' already assigned to object $ObjectId at scope $Scope." -ForegroundColor Green
            Write-Log "'$RoleDefinitionName' already assigned to object $ObjectId at scope $Scope."
        }
    }

    Ensure-AzConnection
    Set-AzContext -SubscriptionId $SubscriptionId

    # --- Start: Resource Group RBAC Assignments ---
    $resourceGroupScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

    # 1. Virtual Machine User Login for vPAW/AVD users group
    Ensure-RoleAssignment -ObjectId $UserGroup.Id -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceGroupScope

    # 2. Virtual Machine User Login for vPAW/AVD admins group
    Ensure-RoleAssignment -ObjectId $AdminGroup.Id -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceGroupScope

    # 3. Virtual Machine Administrator Login for vPAW/AVD admins group
    Ensure-RoleAssignment -ObjectId $AdminGroup.Id -RoleDefinitionName "Virtual Machine Administrator Login" -Scope $resourceGroupScope

    # 4. Desktop Virtualization Power On Contributor for AVD Service Principal
    $avdServicePrincipal = Get-AzADServicePrincipal -DisplayName "Azure Virtual Desktop"
    if ($avdServicePrincipal) {
        Ensure-RoleAssignment -ObjectId $avdServicePrincipal.Id -RoleDefinitionName "Desktop Virtualization Power On Contributor" -Scope $resourceGroupScope
    }
    # --- End: Resource Group RBAC Assignments ---

    # --- Application Group RBAC ---
    Write-Host "Checking for WVD Application Group: $AppGroupName in resource group: $ResourceGroup" -ForegroundColor Yellow
    Write-Log "Checking for WVD Application Group: $AppGroupName in resource group: $ResourceGroup"
    $appGroup = Get-AzWvdApplicationGroup -Name $AppGroupName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $appGroup) {
        Write-Host "Application Group '$AppGroupName' does not exist in resource group '$ResourceGroup'." -ForegroundColor Red
        Write-Log "Application Group '$AppGroupName' does not exist in resource group '$ResourceGroup'." "ERROR"
        Write-Host "Please create it in the Azure Portal or with PowerShell before running the rest of this script."
        exit 1
    }
    $appGroupPath = $appGroup.Id

    # Assign Desktop Virtualization User at App Group scope
    Ensure-RoleAssignment -ObjectId $UserGroup.Id -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
    Ensure-RoleAssignment -ObjectId $AdminGroup.Id -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath

    # --- Session Desktop Friendly Name ---
    Write-Host "Session Desktop friendly name configuration..." -ForegroundColor Cyan
    Write-Log "Session Desktop friendly name configuration..."
    $sessionDesktop = Get-AzWvdDesktop -ResourceGroupName $ResourceGroup -ApplicationGroupName $AppGroupName -Name "SessionDesktop" -ErrorAction SilentlyContinue
    if ($sessionDesktop) {
        $defaultDesktopName = "vPAW Desktop"
        Write-Host "Enter the friendly name for the Session Desktop (Default: $defaultDesktopName):" -ForegroundColor Green
        $sessionDesktopFriendlyName = Read-Host
        if ([string]::IsNullOrEmpty($sessionDesktopFriendlyName)) {
            $sessionDesktopFriendlyName = $defaultDesktopName
        }
        Write-Host "Updating SessionDesktop friendly name to '$sessionDesktopFriendlyName'..." -ForegroundColor Cyan
        Write-Log "Updating SessionDesktop friendly name to '$sessionDesktopFriendlyName'..."
        Update-AzWvdDesktop -ResourceGroupName $ResourceGroup -ApplicationGroupName $AppGroupName -Name "SessionDesktop" -FriendlyName $sessionDesktopFriendlyName
    } else {
        Write-Host "SessionDesktop not found in $AppGroupName. Skipping friendly name update." -ForegroundColor Yellow
        Write-Log "SessionDesktop not found in $AppGroupName. Skipping friendly name update." "WARN"
    }
    Write-Log "RBAC and AVD configuration complete."
    Start-Sleep 1

    #############################
    # Conditional Access Policy Exclusion
    #############################
    Clear-Host
    Write-Banner "Conditional Access Policy Exclusion"
    Ensure-MgGraphConnection

    Write-Host "--------------------------------------" -ForegroundColor Magenta
    Write-Host "Storage App Conditional Access Exclusion" -ForegroundColor Magenta
    Write-Host "--------------------------------------" -ForegroundColor Magenta

    $expectedPrefix = "[Storage Account] $StorageAccountName.file.core.windows.net"
    $applications = @(Get-MgApplication -Filter "startswith(displayName, '[Storage Account]')" | Select-Object DisplayName, AppId, Id)
    $selectedApp = $null

    if ($applications.Count -eq 0) {
        Write-Host "No applications found starting with '[Storage Account]'." -ForegroundColor Red
        Write-Log "No applications found starting with '[Storage Account]'." "ERROR"
        exit
    }

    $matchingApps = $applications | Where-Object {
        $_.DisplayName.Trim().ToLower() -eq $expectedPrefix.ToLower()
    }

    if ($matchingApps.Count -eq 1) {
        $selectedApp = $matchingApps[0]
        Write-Host "Automatically selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))" -ForegroundColor Green
        Write-Log "Automatically selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
    } elseif ($matchingApps.Count -gt 1) {
        Write-Host "Multiple storage apps found for '$expectedPrefix'. Please select:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $matchingApps.Count; $i++) {
            Write-Host "$($i+1): $($matchingApps[$i].DisplayName) | AppId: $($matchingApps[$i].AppId) | ObjectId: $($matchingApps[$i].Id)" -ForegroundColor Yellow
        }
        $selection = Read-Host "`nEnter the number of the application you want to select"
        if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $matchingApps.Count) {
            $selectedApp = $matchingApps[$selection - 1]
            Write-Log "User selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
        }
    } else {
        Write-Host "No app found starting with '$expectedPrefix'. Please select from all '[Storage Account]' apps:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $applications.Count; $i++) {
            Write-Host "$($i+1): $($applications[$i].DisplayName) | AppId: $($applications[$i].AppId) | ObjectId: $($applications[$i].Id)" -ForegroundColor Yellow
        }
        $selection = Read-Host "`nEnter the number of the application you want to select"
        if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $applications.Count) {
            $selectedApp = $applications[$selection - 1]
            Write-Log "User selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
        }
    }

    if (-not $selectedApp) {
        Write-Host "No storage app selected." -ForegroundColor Red
        Write-Log "No storage app selected." "ERROR"
        exit
    }
    $CAExclude = $selectedApp.AppId
    $ObjectId = $selectedApp.Id
    Write-Host "`nYou selected: $($selectedApp.DisplayName)" -ForegroundColor Cyan
    Write-Host "AppId stored in `$CAExclude: $CAExclude" -ForegroundColor Cyan
    Write-Host "ObjectId: $ObjectId" -ForegroundColor Cyan
    Write-Log "Storage App selected: $($selectedApp.DisplayName) AppId: $CAExclude ObjectId: $ObjectId"

    $policies = Get-MgIdentityConditionalAccessPolicy
    $filteredPolicies = $policies | Where-Object {
        $_.Conditions.Applications.IncludeApplications -contains "All" -and
        $_.DisplayName -notlike "*Microsoft Managed*"
    }
    Write-Host "`nConditional Access policies targeting ALL apps (excluding 'Microsoft Managed'):" -ForegroundColor Yellow
    $filteredPolicies | Select-Object DisplayName, Id, State | Format-Table -AutoSize
    Write-Log "Conditional Access policies targeting ALL apps (excluding Microsoft Managed) enumerated."

    foreach ($policy in $filteredPolicies) {
        if ($policy.DisplayName -like "Microsoft-managed*") {
            Write-Host "`nSkipping Microsoft-managed policy '$($policy.DisplayName)' (cannot update excluded apps)." -ForegroundColor Yellow
            Write-Log "Skipping Microsoft-managed policy '$($policy.DisplayName)'; cannot update excluded apps." "WARN"
            continue
        }
        $excludedApps = @($policy.Conditions.Applications.ExcludeApplications)
        if (-not $excludedApps.Contains($CAExclude)) {
            $newExcludedApps = $excludedApps + $CAExclude
            $updateBody = @{
                Conditions = @{
                    Applications = @{
                        IncludeApplications = $policy.Conditions.Applications.IncludeApplications
                        ExcludeApplications = $newExcludedApps
                    }
                }
            }
            Write-Host "`nUpdating policy '$($policy.DisplayName)' (Id: $($policy.Id)) to exclude AppId $CAExclude..." -ForegroundColor Cyan
            Write-Log "Updating policy '$($policy.DisplayName)' (Id: $($policy.Id)) to exclude AppId $CAExclude..."
            try {
                Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter $updateBody
                Write-Host "Policy '$($policy.DisplayName)' updated." -ForegroundColor Green
                Write-Log "Policy '$($policy.DisplayName)' updated to exclude AppId $CAExclude."
            } catch {
                Write-Host "Failed to update policy '$($policy.DisplayName)': $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "Failed to update policy '$($policy.DisplayName)': $($_.Exception.Message)" "ERROR"
            }
        } else {
            Write-Host "`nPolicy '$($policy.DisplayName)' already excludes AppId $CAExclude." -ForegroundColor Green
            Write-Log "Policy '$($policy.DisplayName)' already excludes AppId $CAExclude."
        }
    }

    Write-Host "---------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
    Write-Host "Please verify the CA exclusions and permissions in the Entra Portal." -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT: Grant Admin Consent in Azure Portal" -ForegroundColor Green
    Write-Host "Go to: Azure Portal > App registrations > $($selectedApp.DisplayName) > API permissions > Grant admin consent" -ForegroundColor Green
    Write-Host "This is required for openid, profile, and User.Read delegated permissions to be effective." -ForegroundColor Green
    Write-Host "---------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
    Write-Log "Script completed. Please verify CA exclusions and grant admin consent for $($selectedApp.DisplayName) in Azure Portal."
    Write-Log "Conditional Access exclusion complete."
    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
}
#################################################################################################################

function Deploy-SessionHosts {
    
 Write-Banner "Deploying Additional Session Hosts Only"
    # Ensure required modules are loaded
    Ensure-Module -ModuleName Az.DesktopVirtualization
    Ensure-Module -ModuleName Microsoft.Graph.Groups
    Ensure-AzCli
    Ensure-AzAccountModule
    Ensure-AzConnection
    Ensure-MgGraphConnection

    # Check if the user is authenticated to Azure and Microsoft Graph
    if (-not (Get-AzContext)) {
        Write-Host "You must be authenticated to Azure. Please run Connect-AzAccount." -ForegroundColor Red
        Write-Log "User not authenticated to Azure." "ERROR"
        return
    }
    
    if (-not (Get-MgContext)) {
        Write-Host "You must be authenticated to Microsoft Graph. Please run Connect-MgGraph." -ForegroundColor Red
        Write-Log "User not authenticated to Microsoft Graph." "ERROR"
        return
    }

    # Placeholder for session host deployment logic   
}



# === MAIN MENU ===
while ($true) {
    Clear-Host
    Write-Banner "Azure Virtual Desktop Deployment Menu"
    Write-Host "1) Core Infrastructure Deployment (with session host option)"
    Write-Host "2) Deploy Additional Session Host(s) Only"
    Write-Host "3) Exit"
    $choice = Read-Host "Select an option (1-3)"
    switch ($choice) {
        "1" { Deploy-CoreInfra }
        "2" { Deploy-SessionHosts }
        "3" { Write-Host "Exiting..."; break }
        default { Write-Host "Invalid selection. Please choose 1, 2, or 3." -ForegroundColor Red }
    }
}