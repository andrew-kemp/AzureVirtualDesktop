<#
.SYNOPSIS
    Deploys Azure Virtual Desktop (AVD) pooled infrastructure and session hosts using Bicep templates, with logging and parameter persistence.

.DESCRIPTION
    - Interactive CLI for deploying Core Infra and Session Hosts.
    - Logs all actions.
    - Saves and loads deployment parameters from AVDConf.inf for easy repeat deployments.
    - Supports pooled scenario (user/group assignments can be tailored).
#>

# ================ UTILITY FUNCTIONS ================

function Write-Banner {
    param([string]$Heading)
    $bannerWidth = 51
    $innerWidth = $bannerWidth - 2
    $bannerLine = ('#' * $bannerWidth)
    $emptyLine = ('#' + (' ' * ($bannerWidth - 2)) + '#')
    $centered = $Heading.Trim()
    $centered = $centered.PadLeft(([math]::Floor(($centered.Length + $innerWidth) / 2))).PadRight($innerWidth)
    Write-Host ""
    Write-Host $bannerLine -ForegroundColor Cyan
    Write-Host $emptyLine -ForegroundColor Cyan
    Write-Host ("#"+$centered+"#") -ForegroundColor Cyan
    Write-Host $emptyLine -ForegroundColor Cyan
    Write-Host $bannerLine -ForegroundColor Cyan
    Write-Host ""
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logPath = Join-Path $PSScriptRoot "AVDDeploy.log"
    $entry = "$timestamp [$Level] $Message"
    Add-Content -Path $logPath -Value $entry
}

function Ensure-Module {
    param([string]$ModuleName)
    $isInstalled = Get-Module -ListAvailable -Name $ModuleName
    if (-not $isInstalled) {
        Write-Host "Installing module $ModuleName..." -ForegroundColor Yellow
        Write-Log "Installing module $ModuleName..." "WARN"
        Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $ModuleName safely." -ForegroundColor Cyan
        Write-Log "Installed $ModuleName. Please restart PowerShell session." "ERROR"
        exit 0
    }
}

function Ensure-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Azure CLI (az) is not installed." -ForegroundColor Red
        Write-Log "Azure CLI not installed." "ERROR"
        exit 1
    }
}

function Ensure-AzAccountModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "ERROR: Az.Accounts module is not installed." -ForegroundColor Red
        Write-Log "Az.Accounts module not installed." "ERROR"
        exit 1
    }
}

function Ensure-AzConnection {
    try { $null = Get-AzContext -ErrorAction Stop }
    catch { 
        Write-Host "Re-authenticating to Azure..." -ForegroundColor Yellow
        Write-Log "Re-authenticating to Azure..." "WARN"
        Connect-AzAccount | Out-Null 
    }
}

# ================ INF FILE HANDLING ================
$AVDConfPath = Join-Path $PSScriptRoot "AVDConf.inf"
$AVDConf = @{}
function Save-AVDConf {
    $AVDConf | ConvertTo-Json | Out-File -Encoding UTF8 -FilePath $AVDConfPath
    Write-Log "Deployment parameters saved to $AVDConfPath"
}
function Load-AVDConf {
    if (Test-Path $AVDConfPath) {
        try {
            $AVDConf = Get-Content $AVDConfPath -Raw | ConvertFrom-Json
            Write-Log "Loaded deployment parameters from $AVDConfPath"
            return $AVDConf
        } catch {
            Write-Log "Failed to load $AVDConfPath" "ERROR"
        }
    }
    return @{}
}

# ================ CORE INFRA DEPLOYMENT ================
function Deploy-CoreInfra {

    #############################
    #                           #
    #   Environment Preparation #
    #                           #
    #############################
    Clear-Host
    Write-Banner "Environment Preparation"
    # Ensure required modules are present
    $modules = @("Microsoft.Graph", "Az.Accounts")
    foreach ($mod in $modules) {
        $isInstalled = Get-Module -ListAvailable -Name $mod
        if (-not $isInstalled) {
            Write-Host "Installing module $mod..." -ForegroundColor Yellow
            Write-Log "Installing module $mod..." "WARN"
            Install-Module $mod -Scope CurrentUser -Force -AllowClobber
            Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
            Write-Log "Installed $mod. Please restart PowerShell session." "ERROR"
            exit 0
        }
    }
    
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Azure CLI (az) is not installed. Please install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and log in using 'az login'." -ForegroundColor Red
        Write-Log "Azure CLI not installed." "ERROR"
        exit 1
    }
    
    Import-Module Az.Accounts -ErrorAction SilentlyContinue
    
    # Authenticate to Azure CLI
    $azLoggedIn = $false
    try {
        $azAccount = az account show 2>$null | ConvertFrom-Json
        if ($azAccount) {
            $azLoggedIn = $true
            Write-Host "Already logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
            Write-Log "Already logged in to Azure CLI as $($azAccount.user.name)"
        }
    } catch {}
    if (-not $azLoggedIn) {
        Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
        Write-Log "Logging in to Azure CLI..." "WARN"
        az login | Out-Null
        $azAccount = az account show | ConvertFrom-Json
        Write-Host "Logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
        Write-Log "Logged in to Azure CLI as $($azAccount.user.name)"
    }
    
    # Authenticate to Az PowerShell
    $azPSLoggedIn = $false
    try {
        $azContext = Get-AzContext
        if ($azContext) {
            $azPSLoggedIn = $true
            Write-Host "Already connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
            Write-Log "Already connected to Az PowerShell as $($azContext.Account)"
        }
    } catch {}
    if (-not $azPSLoggedIn) {
        Write-Host "Connecting to Az PowerShell..." -ForegroundColor Yellow
        Write-Log "Connecting to Az PowerShell..." "WARN"
        Connect-AzAccount | Out-Null
        $azContext = Get-AzContext
        Write-Host "Connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
        Write-Log "Connected to Az PowerShell as $($azContext.Account)"
    }
    
    # Authenticate to Microsoft Graph
    $graphLoggedIn = $false
    try {
        $mgContext = Get-MgContext
        if ($mgContext) {
            $graphLoggedIn = $true
            Write-Host "Already connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
            Write-Log "Already connected to Microsoft Graph as $($mgContext.Account)"
        }
    } catch {}
    if (-not $graphLoggedIn) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
        Write-Log "Connecting to Microsoft Graph..." "WARN"
        Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All"
        $mgContext = Get-MgContext
        Write-Host "Connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
        Write-Log "Connected to Microsoft Graph as $($mgContext.Account)"
    }
    Write-Log "Environment preparation complete."
    Start-Sleep 1
    
    #############################
    #    Subscription Selection #
    #############################
    Clear-Host
    Write-Banner "Subscription Selection"
    Write-Host "Fetching your Azure subscriptions..." -ForegroundColor Yellow
    Write-Log "Fetching Azure subscriptions..."
    $subs = az account list --output json | ConvertFrom-Json
    if (-not $subs) { Write-Host "No subscriptions found for this account." -ForegroundColor Red; Write-Log "No subscriptions found for this account." "ERROR"; exit 1 }
    for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host "$($i+1)) $($subs[$i].name)  ($($subs[$i].id))" -ForegroundColor Cyan }
    Write-Host "`nEnter the number of the subscription to use:" -ForegroundColor Green
    $subChoice = Read-Host
    $chosenSub = $subs[$subChoice - 1]
    Write-Host "Using subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
    Write-Log "Using subscription: $($chosenSub.name) ($($chosenSub.id))"
    az account set --subscription $chosenSub.id
    Select-AzSubscription -SubscriptionId $chosenSub.id
    Write-Log "Subscription selection complete."
    Start-Sleep 1
    
    try {
        $tenantId = (Get-AzContext).Tenant.Id
    } catch {
        $tenantId = (az account show --query tenantId -o tsv)
    }
    
    #############################
    #   Resource Group Setup    #
    #############################
    Clear-Host
    Write-Banner "Resource Group Setup"
    while ($true) {
        Write-Host "Would you like to use an existing resource group, or create a new one?" -ForegroundColor Green
        Write-Host "1) Existing" -ForegroundColor Yellow
        Write-Host "2) New" -ForegroundColor Yellow
        $rgChoice = Read-Host
        if ($rgChoice -eq "1") {
            $rgs = az group list --output json | ConvertFrom-Json
            if (-not $rgs) {
                Write-Host "No resource groups found. You must create a new one." -ForegroundColor Red
                $rgChoice = "2"
            } else {
                for ($i = 0; $i -lt $rgs.Count; $i++) { Write-Host "$($i+1)) $($rgs[$i].name)  ($($rgs[$i].location))" -ForegroundColor Cyan }
                $rgSelect = Read-Host "Enter the number of the resource group to use"
                $resourceGroup = $rgs[$rgSelect - 1].name
                $resourceGroupLocation = $rgs[$rgSelect - 1].location
                break
            }
        }
        if ($rgChoice -eq "2") {
            $resourceGroup = Read-Host "Enter a name for the new resource group"
            $resourceGroupLocation = Read-Host "Enter the Azure region for the new resource group (e.g., uksouth, eastus)"
            az group create --name $resourceGroup --location $resourceGroupLocation | Out-Null
            Write-Host "Resource group $resourceGroup created." -ForegroundColor Green
            break
        }
        if (-not ($rgChoice -eq "1" -or $rgChoice -eq "2")) {
            Write-Host "Invalid selection. Please enter 1 or 2." -ForegroundColor Red
        }
    }
    Write-Log "Resource group setup complete."
    Start-Sleep 1
    
    #############################
    # Entra Group Selection/Creation
    #############################
    Clear-Host
    Write-Banner "Entra Group Selection/Creation"
    
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
        $allGroups = Get-MgGroup -All
        $filteredGroups = $allGroups | Where-Object { $_.DisplayName -match $searchSubstring }
        if (-not $filteredGroups) {
            Write-Host "No groups found containing '$searchSubstring' in the display name." -ForegroundColor Red
            return $null
        }
        Write-Host "Select the $role group from the list below:" -ForegroundColor Cyan
        $i = 1
        foreach ($group in $filteredGroups) {
            Write-Host "$i) $($group.DisplayName) (ObjectId: $($group.Id))" -ForegroundColor Cyan
            $i++
        }
        $selection = Read-Host "Enter the number of the $role group to use"
        $selectedGroup = $filteredGroups[$selection - 1]
        Write-Host "Selected group: $($selectedGroup.DisplayName)" -ForegroundColor Cyan
        return $selectedGroup
    }
    
    Write-Host "1) Use existing Entra groups" -ForegroundColor Yellow
    Write-Host "2) Create new Entra groups" -ForegroundColor Yellow
    $groupsChoice = Read-Host "Select an option (Default: 1)"
    if ([string]::IsNullOrEmpty($groupsChoice)) { $groupsChoice = "1" }
    if ($groupsChoice -eq "1") {
        $groupSearch = Read-Host "Enter search substring for group names (e.g. 'AVD')"
        $userGroup = $null
        while (-not $userGroup) {
            $userGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Users (Contributors)"
            if (-not $userGroup) { $groupSearch = Read-Host "Try a different substring for Users group" }
        }
        $adminGroup = $null
        while (-not $adminGroup) {
            $adminGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Admins (Elevated Contributors)"
            if (-not $adminGroup) { $groupSearch = Read-Host "Try a different substring for Admins group" }
        }
    } else {
        $userGroupName = Read-Host "Enter a name for the new Users (Contributors) group"
        $userGroup = Create-AADGroup $userGroupName
        $adminGroupName = Read-Host "Enter a name for the new Admins (Elevated Contributors) group"
        $adminGroup = Create-AADGroup $adminGroupName
    }
    Write-Log "Entra group setup complete."
    Start-Sleep 1
    
    #############################
    # Deployment Parameter Input#
    #############################
    Clear-Host
    Write-Banner "Deployment Parameter Input"
    
    function Deploy-CoreInfra {

        #############################
        #   Environment Preparation #
        #############################
        Clear-Host
        Write-Banner "Environment Preparation"
        $modules = @("Microsoft.Graph", "Az.Accounts")
        foreach ($mod in $modules) {
            $isInstalled = Get-Module -ListAvailable -Name $mod
            if (-not $isInstalled) {
                Write-Host "Installing module $mod..." -ForegroundColor Yellow
                Write-Log "Installing module $mod..." "WARN"
                Install-Module $mod -Scope CurrentUser -Force -AllowClobber
                Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
                Write-Log "Installed $mod. Please restart PowerShell session." "ERROR"
                exit 0
            }
        }
    
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            Write-Host "ERROR: Azure CLI (az) is not installed. Please install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and log in using 'az login'." -ForegroundColor Red
            Write-Log "Azure CLI not installed." "ERROR"
            exit 1
        }
    
        Import-Module Az.Accounts -ErrorAction SilentlyContinue
    
        # Authenticate to Azure CLI
        $azLoggedIn = $false
        try {
            $azAccount = az account show 2>$null | ConvertFrom-Json
            if ($azAccount) {
                $azLoggedIn = $true
                Write-Host "Already logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
                Write-Log "Already logged in to Azure CLI as $($azAccount.user.name)"
            }
        } catch {}
        if (-not $azLoggedIn) {
            Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
            Write-Log "Logging in to Azure CLI..." "WARN"
            az login | Out-Null
            $azAccount = az account show | ConvertFrom-Json
            Write-Host "Logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
            Write-Log "Logged in to Azure CLI as $($azAccount.user.name)"
        }
    
        # Authenticate to Az PowerShell
        $azPSLoggedIn = $false
        try {
            $azContext = Get-AzContext
            if ($azContext) {
                $azPSLoggedIn = $true
                Write-Host "Already connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
                Write-Log "Already connected to Az PowerShell as $($azContext.Account)"
            }
        } catch {}
        if (-not $azPSLoggedIn) {
            Write-Host "Connecting to Az PowerShell..." -ForegroundColor Yellow
            Write-Log "Connecting to Az PowerShell..." "WARN"
            Connect-AzAccount | Out-Null
            $azContext = Get-AzContext
            Write-Host "Connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
            Write-Log "Connected to Az PowerShell as $($azContext.Account)"
        }
    
        # Authenticate to Microsoft Graph
        $graphLoggedIn = $false
        try {
            $mgContext = Get-MgContext
            if ($mgContext) {
                $graphLoggedIn = $true
                Write-Host "Already connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
                Write-Log "Already connected to Microsoft Graph as $($mgContext.Account)"
            }
        } catch {}
        if (-not $graphLoggedIn) {
            Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
            Write-Log "Connecting to Microsoft Graph..." "WARN"
            Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All"
            $mgContext = Get-MgContext
            Write-Host "Connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
            Write-Log "Connected to Microsoft Graph as $($mgContext.Account)"
        }
        Write-Log "Environment preparation complete."
        Start-Sleep 1
    
        #############################
        #    Subscription Selection #
        #############################
        Clear-Host
        Write-Banner "Subscription Selection"
        Write-Host "Fetching your Azure subscriptions..." -ForegroundColor Yellow
        Write-Log "Fetching Azure subscriptions..."
        $subs = az account list --output json | ConvertFrom-Json
        if (-not $subs) { Write-Host "No subscriptions found for this account." -ForegroundColor Red; Write-Log "No subscriptions found for this account." "ERROR"; exit 1 }
        for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host "$($i+1)) $($subs[$i].name)  ($($subs[$i].id))" -ForegroundColor Cyan }
        Write-Host "`nEnter the number of the subscription to use:" -ForegroundColor Green
        $subChoice = Read-Host
        $chosenSub = $subs[$subChoice - 1]
        Write-Host "Using subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
        Write-Log "Using subscription: $($chosenSub.name) ($($chosenSub.id))"
        az account set --subscription $chosenSub.id
        Select-AzSubscription -SubscriptionId $chosenSub.id
        Write-Log "Subscription selection complete."
        Start-Sleep 1
    
        try {
            $tenantId = (Get-AzContext).Tenant.Id
        } catch {
            $tenantId = (az account show --query tenantId -o tsv)
        }
    
        #############################
        #   Resource Group Setup    #
        #############################
        Clear-Host
        Write-Banner "Resource Group Setup"
        while ($true) {
            Write-Host "Would you like to use an existing resource group, or create a new one?" -ForegroundColor Green
            Write-Host "1) Existing" -ForegroundColor Yellow
            Write-Host "2) New" -ForegroundColor Yellow
            $rgChoice = Read-Host
            if ($rgChoice -eq "1") {
                $rgs = az group list --output json | ConvertFrom-Json
                if (-not $rgs) {
                    Write-Host "No resource groups found. You must create a new one." -ForegroundColor Red
                    $rgChoice = "2"
                } else {
                    for ($i = 0; $i -lt $rgs.Count; $i++) { Write-Host "$($i+1)) $($rgs[$i].name)  ($($rgs[$i].location))" -ForegroundColor Cyan }
                    $rgSelect = Read-Host "Enter the number of the resource group to use"
                    $resourceGroup = $rgs[$rgSelect - 1].name
                    $resourceGroupLocation = $rgs[$rgSelect - 1].location
                    break
                }
            }
            if ($rgChoice -eq "2") {
                $resourceGroup = Read-Host "Enter a name for the new resource group"
                $resourceGroupLocation = Read-Host "Enter the Azure region for the new resource group (e.g., uksouth, eastus)"
                az group create --name $resourceGroup --location $resourceGroupLocation | Out-Null
                Write-Host "Resource group $resourceGroup created." -ForegroundColor Green
                break
            }
            if (-not ($rgChoice -eq "1" -or $rgChoice -eq "2")) {
                Write-Host "Invalid selection. Please enter 1 or 2." -ForegroundColor Red
            }
        }
        Write-Log "Resource group setup complete."
        Start-Sleep 1
    
        #############################
        # Entra Group Selection/Creation
        #############################
        Clear-Host
        Write-Banner "Entra Group Selection/Creation"
    
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
            $allGroups = Get-MgGroup -All
            $filteredGroups = $allGroups | Where-Object { $_.DisplayName -match $searchSubstring }
            if (-not $filteredGroups) {
                Write-Host "No groups found containing '$searchSubstring' in the display name." -ForegroundColor Red
                return $null
            }
            Write-Host "Select the $role group from the list below:" -ForegroundColor Cyan
            $i = 1
            foreach ($group in $filteredGroups) {
                Write-Host "$i) $($group.DisplayName) (ObjectId: $($group.Id))" -ForegroundColor Cyan
                $i++
            }
            $selection = Read-Host "Enter the number of the $role group to use"
            $selectedGroup = $filteredGroups[$selection - 1]
            Write-Host "Selected group: $($selectedGroup.DisplayName)" -ForegroundColor Cyan
            return $selectedGroup
        }
    
        Write-Host "1) Use existing Entra groups" -ForegroundColor Yellow
        Write-Host "2) Create new Entra groups" -ForegroundColor Yellow
        $groupsChoice = Read-Host "Select an option (Default: 1)"
        if ([string]::IsNullOrEmpty($groupsChoice)) { $groupsChoice = "1" }
        if ($groupsChoice -eq "1") {
            $groupSearch = Read-Host "Enter search substring for group names (e.g. 'AVD')"
            $userGroup = $null
            while (-not $userGroup) {
                $userGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Users (Contributors)"
                if (-not $userGroup) { $groupSearch = Read-Host "Try a different substring for Users group" }
            }
            $adminGroup = $null
            while (-not $adminGroup) {
                $adminGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Admins (Elevated Contributors)"
                if (-not $adminGroup) { $groupSearch = Read-Host "Try a different substring for Admins group" }
            }
        } else {
            $userGroupName = Read-Host "Enter a name for the new Users (Contributors) group"
            $userGroup = Create-AADGroup $userGroupName
            $adminGroupName = Read-Host "Enter a name for the new Admins (Elevated Contributors) group"
            $adminGroup = Create-AADGroup $adminGroupName
        }
        Write-Log "Entra group setup complete."
        Start-Sleep 1
    
        #############################
        # Deployment Parameter Input#
        #############################
        Clear-Host
        Write-Banner "Deployment Parameter Input"
    
        function Get-ValidatedStorageAccountName {
            while ($true) {
                Write-Host "Enter the storage account name (3-24 chars, lowercase letters and numbers only)" -ForegroundColor Green
                $storageAccountName = Read-Host
                $storageAccountName = $storageAccountName.Trim()
                if ([string]::IsNullOrEmpty($storageAccountName)) { Write-Host "Cannot be blank." -ForegroundColor Red; Start-Sleep 2; continue }
                if ($storageAccountName.Length -lt 3 -or $storageAccountName.Length -gt 24) { Write-Host "Invalid length." -ForegroundColor Red; Start-Sleep 2; continue }
                if ($storageAccountName -notmatch '^[a-z0-9]{3,24}$') { Write-Host "Invalid characters." -ForegroundColor Red; Start-Sleep 2; continue }
                Write-Host "Checking availability of the storage account name..." -ForegroundColor Cyan
                try {
                    $azResult = az storage account check-name --name $storageAccountName | ConvertFrom-Json
                } catch {
                    Write-Host "Validation failed, continuing..." -ForegroundColor Yellow
                    return $storageAccountName
                }
                if (-not $azResult.nameAvailable) {
                    Write-Host "Name already in use." -ForegroundColor Red
                    $randomNumber = Get-Random -Minimum 100 -Maximum 999
                    $newName = $storageAccountName
                    if ($newName.Length -gt 21) { $newName = $newName.Substring(0, 21) }
                    $newName += $randomNumber
                    Write-Host "Trying '$newName'..." -ForegroundColor Cyan
                    $azResult = az storage account check-name --name $newName | ConvertFrom-Json
                    if ($azResult.nameAvailable) { Write-Host "'$newName' is available." -ForegroundColor Green; Start-Sleep 1; return $newName } else { continue }
                }
                Write-Host "Storage account name is available." -ForegroundColor Green
                Start-Sleep 1
                return $storageAccountName
            }
        }
    
        $DefaultPrefix = Read-Host "Enter the resource prefix (Default: AVD)"
        if ([string]::IsNullOrEmpty($DefaultPrefix)) { $DefaultPrefix = "AVD" }
    
        $storageAccountName = Get-ValidatedStorageAccountName
        $kerberosDomainName = Read-Host "Enter the Active Directory domain name for Azure AD Kerberos authentication (e.g., corp.contoso.com)"
        $kerberosDomainGuid = Read-Host "Enter the GUID of the Active Directory domain"
    
        $vnetResourceGroup = Read-Host "Enter the resource group of the vNet for the Private Endpoint and Session Hosts (default is 'Core-Services')"
        if ([string]::IsNullOrEmpty($vnetResourceGroup)) { $vnetResourceGroup = "Core-Services" }
    
        $vnetName = Read-Host "Enter the name of the vNet for the Private Endpoint and Session Hosts (default is 'Master-vNet')"
        if ([string]::IsNullOrEmpty($vnetName)) { $vnetName = "Master-vNet" }
    
        Write-Host "Do you want to use the same subnet for both the Private Endpoint (Storage) and Session Hosts? (y/n) [Default: n]" -ForegroundColor Green
        $sameSubnet = Read-Host
        if ([string]::IsNullOrWhiteSpace($sameSubnet)) { $sameSubnet = "n" }
    
        if ($sameSubnet -eq "y") {
            $subnetName = Read-Host "Enter the subnet name for both Private Endpoint and Session Hosts (default is 'AzureVirtualDesktop')"
            if ([string]::IsNullOrEmpty($subnetName)) { $subnetName = "AzureVirtualDesktop" }
            $storageSubnetName = $subnetName
            $sessionHostSubnetName = $subnetName
        } else {
            $storageSubnetName = Read-Host "Enter the subnet name for the Private Endpoint (default is 'Storage')"
            if ([string]::IsNullOrEmpty($storageSubnetName)) { $storageSubnetName = "Storage" }
            $sessionHostSubnetName = Read-Host "Enter the subnet name for the Session Hosts (default is 'AzureVirtualDesktop')"
            if ([string]::IsNullOrEmpty($sessionHostSubnetName)) { $sessionHostSubnetName = "AzureVirtualDesktop" }
        }
    
        $bicepTemplateFile = "01-Deploy-CoreAVDInfra.bicep"
    
        Write-Host "`nAll parameters collected." -ForegroundColor Green
        Write-Log "All parameters collected for deployment."
        Write-Log "Deployment parameter input complete."
        Start-Sleep 1
    
        #############################
        # Bicep Template Deployment #
        #############################
        Clear-Host
        Write-Banner "Bicep Template Deployment"
        Write-Host ""
        Write-Host "-----------------------------" -ForegroundColor Magenta
        Write-Host "Deployment Parameter Summary:" -ForegroundColor Magenta
        Write-Host "TenantId: $tenantId" -ForegroundColor Yellow
        Write-Host "Subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
        Write-Host "Resource Group: $resourceGroup" -ForegroundColor Yellow
        Write-Host "Resource Group Location: $resourceGroupLocation" -ForegroundColor Yellow
        Write-Host "DefaultPrefix: $DefaultPrefix" -ForegroundColor Yellow
        Write-Host "storageAccountName: $storageAccountName" -ForegroundColor Yellow
        Write-Host "kerberosDomainName: $kerberosDomainName" -ForegroundColor Yellow
        Write-Host "kerberosDomainGuid: $kerberosDomainGuid" -ForegroundColor Yellow
        Write-Host "smbShareContributorGroupOid: $($userGroup.Id)" -ForegroundColor Yellow
        Write-Host "smbShareElevatedContributorGroupOid: $($adminGroup.Id)" -ForegroundColor Yellow
        Write-Host "vnetResourceGroup: $vnetResourceGroup" -ForegroundColor Yellow
        Write-Host "vnetName: $vnetName" -ForegroundColor Yellow
        Write-Host "Storage Subnet Name: $storageSubnetName" -ForegroundColor Yellow
        Write-Host "Session Host Subnet Name: $sessionHostSubnetName" -ForegroundColor Yellow
        Write-Host "bicepTemplateFile: $bicepTemplateFile" -ForegroundColor Yellow
        Write-Host "-----------------------------" -ForegroundColor Magenta
    
        Write-Log "Deployment parameter summary displayed."
        Write-Host ""
        Write-Host "Would you like to deploy the selected Bicep template now? (y/n) [Default: y]" -ForegroundColor Green
        $deployNow = Read-Host
        if ([string]::IsNullOrWhiteSpace($deployNow)) { $deployNow = "y" }
        if ($deployNow -eq "y") {
            Write-Host "Starting deployment..." -ForegroundColor Yellow
            Write-Log "Starting deployment..."
            $paramArgs = @(
                "--resource-group", $resourceGroup,
                "--template-file", $bicepTemplateFile,
                "--parameters",
                "storageAccountName=$storageAccountName",
                "kerberosDomainName=$kerberosDomainName",
                "kerberosDomainGuid=$kerberosDomainGuid",
                "smbShareContributorGroupOid=$($userGroup.Id)",
                "smbShareElevatedContributorGroupOid=$($adminGroup.Id)",
                "vnetResourceGroup=$vnetResourceGroup",
                "vnetName=$vnetName",
                "subnetName=$storageSubnetName",
                "sessionHostSubnetName=$sessionHostSubnetName",
                "DefaultPrefix=$DefaultPrefix"
            )
            Write-Host "az deployment group create $($paramArgs -join ' ')" -ForegroundColor Gray
            Write-Log "az deployment group create $($paramArgs -join ' ')"
            az deployment group create @paramArgs
            Write-Host "`nDeployment command executed." -ForegroundColor Green
            Write-Log "Deployment command executed."
        } else {
            Write-Host "Deployment skipped. You can deploy later using the collected parameters." -ForegroundColor Yellow
            Write-Log "Deployment skipped by user."
            exit 0
        }
        Write-Log "Deployment section complete."
        Start-Sleep 1
    
        # ... Post-deployment RBAC and CA logic continues here ...
    
    }
        
        ##############################
        #     Post-Deployment:       #
        #   RBAC & AVD Config        #
        ##############################
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
        Select-AzSubscription -SubscriptionId $chosenSub.id
        
        $resourceGroupScope = "/subscriptions/$($chosenSub.id)/resourceGroups/$resourceGroup"
        
        # Assign RBAC for VM and AVD access
        Ensure-RoleAssignment -ObjectId $userGroup.Id -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceGroupScope
        Ensure-RoleAssignment -ObjectId $adminGroup.Id -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceGroupScope
        Ensure-RoleAssignment -ObjectId $adminGroup.Id -RoleDefinitionName "Virtual Machine Administrator Login" -Scope $resourceGroupScope
        
        $avdServicePrincipal = Get-AzADServicePrincipal -DisplayName "Azure Virtual Desktop" -ErrorAction SilentlyContinue
        if ($avdServicePrincipal) {
            Ensure-RoleAssignment -ObjectId $avdServicePrincipal.Id -RoleDefinitionName "Desktop Virtualization Power On Contributor" -Scope $resourceGroupScope
        }
        
        # Find the application group created by the Bicep
        $appGroupName = "$DefaultPrefix-AppGroup"
        $appGroup = Get-AzWvdApplicationGroup -Name $appGroupName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
        if (-not $appGroup) {
            Write-Host "Application Group '$appGroupName' does not exist in resource group '$resourceGroup'." -ForegroundColor Red
            Write-Log "Application Group '$appGroupName' does not exist in resource group '$resourceGroup'." "ERROR"
            Write-Host "Please create it in the Azure Portal or with PowerShell before running the rest of this script."
            exit 1
        }
        $appGroupPath = $appGroup.Id
        
        Ensure-RoleAssignment -ObjectId $userGroup.Id -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
        Ensure-RoleAssignment -ObjectId $adminGroup.Id -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
        
        Write-Host "Session Desktop friendly name configuration..." -ForegroundColor Cyan
        Write-Log "Session Desktop friendly name configuration..."
        $sessionDesktop = Get-AzWvdDesktop -ResourceGroupName $resourceGroup -ApplicationGroupName $appGroupName -Name "SessionDesktop" -ErrorAction SilentlyContinue
        $defaultDesktopName = "$DefaultPrefix Desktop"
        if ($sessionDesktop) {
            Write-Host "Enter the friendly name for the Session Desktop (Default: $defaultDesktopName):" -ForegroundColor Green
            $sessionDesktopFriendlyName = Read-Host
            if ([string]::IsNullOrEmpty($sessionDesktopFriendlyName)) {
                $sessionDesktopFriendlyName = $defaultDesktopName
            }
            Write-Host "Updating SessionDesktop friendly name to '$sessionDesktopFriendlyName'..." -ForegroundColor Cyan
            Write-Log "Updating SessionDesktop friendly name to '$sessionDesktopFriendlyName'..."
            Update-AzWvdDesktop -ResourceGroupName $resourceGroup -ApplicationGroupName $appGroupName -Name "SessionDesktop" -FriendlyName $sessionDesktopFriendlyName
        } else {
            Write-Host "SessionDesktop not found in $appGroupName. Skipping friendly name update." -ForegroundColor Yellow
            Write-Log "SessionDesktop not found in $appGroupName. Skipping friendly name update." "WARN"
        }
        Write-Log "RBAC and AVD configuration complete."
        Start-Sleep 1
        
        ##############################
        # Conditional Access Bypass  #
        ##############################
        Clear-Host
        Write-Banner "Conditional Access Policy Exclusion"
        Ensure-MgGraphConnection
        
        Write-Host "--------------------------------------" -ForegroundColor Magenta
        Write-Host "Storage App Conditional Access Exclusion" -ForegroundColor Magenta
        Write-Host "--------------------------------------" -ForegroundColor Magenta
        
        $expectedPrefix = "[Storage Account] $storageAccountName.file.core.windows.net"
        $applications = @(Get-MgApplication -Filter "startswith(displayName, '[Storage Account]')" | Select-Object DisplayName, AppId, Id)
        $selectedApp = $null
        
        if ($applications.Count -eq 0) {
            Write-Host "No applications found starting with '[Storage Account]'." -ForegroundColor Red
            Write-Log "No applications found starting with '[Storage Account]'." "ERROR"
            exit
        }
        
        # Find exact match
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
        
        Write-Host "`n=== Azure Virtual Desktop Core Infrastructure Deployment Complete ===" -ForegroundColor Green
        Write-Host "Please verify all actions in Azure Portal as instructed." -ForegroundColor Yellow
        Write-Log "Script execution complete."
        }

    
# ================ MAIN MENU ================
Clear-Host
Write-Banner "AVD Deployment Menu"
Write-Host "1) Deploy Core Infra"
Write-Host "2) Deploy Session Host(s)"
Write-Host "0) Exit"
$menuChoice = Read-Host "Select an option"
switch ($menuChoice) {
    "1" { Deploy-CoreInfra }
    "2" { Deploy-SessionHost }
    default { Write-Host "Exiting..." -ForegroundColor Yellow }
}