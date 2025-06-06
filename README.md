# Azure Virtual Desktop (AVD) – Automated Enterprise Deployment

This repository provides a modular, step-by-step automation suite for deploying Azure Virtual Desktop (AVD) in a secure, enterprise-ready configuration. The workflow leverages Bicep for infrastructure and PowerShell for post-deployment and hybrid tasks, including FSLogix integration, private endpoint storage, RBAC, and hybrid identity.

---

## 📋 Workflow Overview

| Step | Script Name                           | Purpose                                                                      | Run Location          |
|------|---------------------------------------|------------------------------------------------------------------------------|-----------------------|
| 1    | `01-Deploy-CoreAVDInfra.bicep`        | Deploys storage, networking, host pool, app group, and workspace for AVD.     | Azure CLI/Portal      |
| 2    | `02-Deploy-SessionHosts.bicep`        | Deploys session host VMs and registers them to the host pool.                 | Azure CLI/Portal      |
| 2a   | `02a-SessionHostPrep.ps1`             | Prepares session host OS (FSLogix, Kerberos, cleanup) as VM custom script.    | VM extension (auto)   |
| 3    | `03-Configure-AVDRolesAndGroups.ps1`  | Sets up RBAC, AAD groups, application/desktop permissions, and auto-shutdown. | Azure Cloud Shell     |
| 4    | `04-Add-StorageDNSRecord.ps1`         | Adds internal DNS A record for storage private endpoint.                      | DNS/Admin Server      |
| 5    | `05-MountAndSetSharePermissions.ps1`  | Mounts Azure Files shares, sets NTFS permissions for FSLogix.                 | Hybrid-joined Device  |

---

## 🚀 Quick Start

1. **Clone this repository**
   ```sh
   git clone https://github.com/YOUR-ORG/YOUR-REPO.git
   cd YOUR-REPO
   ```

2. **Deploy in Order:**
   - **01-Deploy-CoreAVDInfra.bicep**  
     Deploy using Azure CLI, PowerShell, or Portal.
   - **02-Deploy-SessionHosts.bicep**  
     Use the registration key output from Step 1 as an input parameter.
   - **02a-SessionHostPrep.ps1**  
     Runs automatically as part of Step 2 (do not run manually).
   - **03-Configure-AVDRolesAndGroups.ps1**  
     Run interactively from [Azure Cloud Shell](https://shell.azure.com/).
   - **04-Add-StorageDNSRecord.ps1**  
     Run on your internal DNS server (requires DNS admin permissions).
   - **05-MountAndSetSharePermissions.ps1**  
     Run on a hybrid-joined Windows device with AD and share access.

---

## 📝 Script Descriptions

### 1. `01-Deploy-CoreAVDInfra.bicep`
- Deploys the storage account (with Azure AD Kerberos and private endpoint), networking, FSLogix shares, AVD host pool, app group, and workspace.
- Sets initial RBAC for Azure Files access.

### 2. `02-Deploy-SessionHosts.bicep`
- Deploys Windows 11 AVD session hosts, joins them to vNet/subnet, configures DNS.
- Registers hosts to the host pool (requires registration key output from Step 1).
- Configures VM extensions to run session host preparation.

### 2a. `02a-SessionHostPrep.ps1`
- Referenced as a VM custom script extension in Step 2 (runs automatically).
- Configures FSLogix registry settings, enables Cloud Kerberos, removes unnecessary UWP apps.

### 3. `03-Configure-AVDRolesAndGroups.ps1`
- Run interactively in Azure Cloud Shell.
- Prompts for resource group, group names, and storage app.
- Creates or reuses AAD groups for users/admins/devices.
- Assigns RBAC for VM login, AVD, and application group access.
- Grants/reviews admin consent for storage enterprise app and adjusts Conditional Access.
- Enables VM auto-shutdown for cost savings.

### 4. `04-Add-StorageDNSRecord.ps1`
- Run on your DNS management server.
- Adds an A record for the storage account’s private endpoint in your internal DNS zone.

### 5. `05-MountAndSetSharePermissions.ps1`
- Run on a hybrid-joined Windows device with appropriate network and AD access.
- Mounts FSLogix profile and redirection shares.
- Applies strict NTFS permissions for AVD user and admin groups.

---

## ⚠️ Prerequisites

- Azure subscription and permissions to deploy resources.
- Azure CLI, PowerShell, and (optionally) Azure Portal access.
- Admin rights on AD/DNS servers for steps 4 and 5.
- [FSLogix](https://docs.microsoft.com/en-us/fslogix/) licensing.
- Hybrid identity (Azure AD + Active Directory) for full enterprise integration.

---

## 🔒 Security & Best Practices

- Storage and AVD resources are deployed with private endpoints and strict network ACLs.
- All permissions are group-based for least privilege.
- Manual steps (e.g., DNS, app consent) are clearly indicated in script output.
- Scripts are designed to be idempotent and safely re-runnable.

---

## 📝 Credits & Maintenance

Maintained by [andrew-kemp](https://github.com/andrew-kemp).

Feel free to open [issues](https://github.com/YOUR-ORG/YOUR-REPO/issues) or pull requests for improvements or bug fixes.

---

## 📄 License

MIT License – see [LICENSE](LICENSE) for details.