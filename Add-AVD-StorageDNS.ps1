# PowerShell script to add the storage account file share DNS record to AD-integrated DNS
Import-Module DNSServer

# Prompt for DNS zone (e.g., contoso.com)
$zoneName = Read-Host "Enter the DNS zone name (e.g. contoso.com)"

# Prompt for storage account prefix or full FQDN
$inputName = Read-Host "Enter the storage account prefix (e.g. mystorageaccount) or FQDN (e.g. mystorageaccount.file.core.windows.net)"

# Normalize: extract prefix if FQDN provided
if ($inputName -match "^([^.]+)\.file\.core\.windows\.net$") {
    $storagePrefix = $matches[1]
} elseif ($inputName -notmatch "\.") {
    $storagePrefix = $inputName
} else {
    Write-Host "Input not recognized. Please enter either the prefix (e.g. mystorageaccount) or full FQDN (e.g. mystorageaccount.file.core.windows.net)." -ForegroundColor Red
    exit 1
}

# Build the full record name for file.core.windows.net
$recordName = "$storagePrefix.file.core.windows.net"

# Prompt for Private Endpoint IP
$ipAddress = Read-Host "Enter the Private Endpoint IP address (e.g. 10.1.2.4)"

# Add the DNS A record (record name must be absolute or relative to zone)
# If your zone is file.core.windows.net, record label is just the prefix
if ($zoneName -eq "file.core.windows.net") {
    $recordLabel = $storagePrefix
} else {
    # For other zones, just add the full record as a label
    $recordLabel = $recordName
}

Add-DnsServerResourceRecordA -Name $recordLabel -ZoneName $zoneName -IPv4Address $ipAddress

Write-Host "DNS record $recordLabel.$zoneName -> $ipAddress added."