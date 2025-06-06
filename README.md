# Azure Virtual Desktop (AVD) Automated Deployment Scripts

This repository contains a comprehensive, step-by-step automation suite for deploying and configuring Azure Virtual Desktop (AVD) with FSLogix, private endpoint storage, and all supporting identity, network, and permissions infrastructure. The scripts and templates are designed to be run in sequence to provide a secure, production-ready AVD environment.

---

## 🗂️ Deployment Phases Overview

### **Phase 1: Core Infrastructure**
**Script:** `AVD-Phase1.Bicep`  
- Deploys Storage Account for FSLogix with Azure AD Kerberos
- Sets up necessary Azure roles for profile shares
- Configures Private Endpoint and network settings
- Provisions AVD Host Pool, Application Group, and Workspace

### **Phase 2: Session Hosts Deployment**
**Script:** `AVD-Phase2.Bicep`  
- Deploys Windows 11 session host VMs (configurable count)
- Joins hosts to vNet/subnet and configures DNS
- Runs custom host preparation scripts for FSLogix and Kerberos
- Registers session hosts to the AVD Host Pool using a registration key from Phase 1

### **Phase 3: Session Host Preparation**
**Script:** `AVD-Phase3.ps1`  
- Configures Windows registry for Cloud Kerberos support
- Configures FSLogix registry settings using supplied profile/redirection paths
- Cleans up unwanted pre-installed Windows/UWP apps

### **Phase 4: AVD Permissions, Groups, and Compliance**
**Script:** `AVD-Phase4.ps1`  
- Run from Azure Cloud Shell
- Prompts for resource group, group names, app group, and storage app display name
- Creates or reuses user/admin/device groups
- Assigns RBAC for AVD logins and admin
- Checks and updates Application Group and desktop friendly name
- Grants/reviews admin consent for storage enterprise app
- Excludes storage app from Conditional Access policies
- Enables VM auto-shutdown

### **Phase 5: Internal DNS Configuration**
**Script:** `Add-ADVD-StorageDNS.ps1`  
- Run from a Domain Controller or DNS management server
- Adds or updates the DNS A record for the storage account's private endpoint

### **Phase 6: Mount & Permission Azure Files Shares**
**Script:** `MountAndSetFSLPermissions.ps1`  
- Run from a hybrid-joined Windows device with network and AD permissions
- Mounts FSLogix shares and sets strict NTFS permissions for AVD admin/user groups

---

## 🚀 Usage Instructions

### 1. **Clone this repository**
```sh
git clone https://github.com/YOUR-ORG/YOUR-REPO.git
cd YOUR-REPO
```

### 2. **Run Each Phase in Order**

#### **Phase 1:**  
Deploy with Azure CLI, PowerShell, or the Azure Portal (Bicep support required).

#### **Phase 2:**  
Use the Host Pool registration key output from Phase 1 as an input parameter when deploying.

#### **Phase 3:**  
This script is referenced in Phase 2 and runs automatically as a VM custom script extension.

#### **Phase 4:**  
Run interactively from Azure Cloud Shell. Follow prompts for all required values.

#### **Phase 5:**  
Run on your DNS server with rights to create A records in your internal DNS zone.

#### **Phase 6:**  
Run on a hybrid-joined Windows device with access to the Azure Files share and AD.

---

## ⚠️ Prerequisites

- Azure subscription and permissions to deploy resources
- Azure CLI, PowerShell, or portal access
- Admin access to AD/DNS for steps 5 and 6
- [FSLogix](https://docs.microsoft.com/en-us/fslogix/) licensing and compliance
- Hybrid identity (Azure AD + Active Directory) for full enterprise integration

---

## 📋 Notes and Best Practices

- **Parameterization:** Most scripts prompt for or accept parameters to fit your environment.
- **Security:** Storage is provisioned with private endpoints and strict network ACLs; permissions use Entra ID groups.
- **Manual Steps:** Some steps (e.g., DNS or app admin consent) require manual or interactive approval.
- **Idempotency:** Bicep and PowerShell scripts are designed to be safe to re-run where possible.

---

## 📝 Credits & Maintenance

Maintained by [andrew-kemp](https://github.com/andrew-kemp).

Feel free to open issues or pull requests for improvements, bug fixes, or additional features.

---

## 📄 License

MIT License – see [LICENSE](LICENSE) for details.