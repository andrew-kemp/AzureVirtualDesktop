Import-Module DNSServer

# Prompt for DNS server (default: localhost)
$dnsServer = Read-Host "Enter the DNS server name (default: localhost)"
if ([string]::IsNullOrWhiteSpace($dnsServer)) {
    $dnsServer = "localhost"
}

# Prompt for DNS zone (default: file.core.windows.net)
$zoneName = Read-Host "Enter the DNS zone name (default: file.core.windows.net)"
if ([string]::IsNullOrWhiteSpace($zoneName)) {
    $zoneName = "file.core.windows.net"
}

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

# Check for zone existence, create if missing
$zone = Get-DnsServerZone -Name $zoneName -ComputerName $dnsServer -ErrorAction SilentlyContinue
if (-not $zone) {
    Write-Host "Zone '$zoneName' does not exist on '$dnsServer'. Creating zone..."
    Add-DnsServerPrimaryZone -Name $zoneName -ZoneFile "$zoneName.dns" -ComputerName $dnsServer
    Write-Host "Zone '$zoneName' created on '$dnsServer'."
} else {
    Write-Host "Zone '$zoneName' already exists on '$dnsServer'."
}

# Determine record label based on zone type
if ($zoneName -eq "file.core.windows.net") {
    $recordLabel = $storagePrefix
} else {
    $recordLabel = $recordName
}

# Check if record already exists
$existing = Get-DnsServerResourceRecord -ZoneName $zoneName -Name $recordLabel -ComputerName $dnsServer -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "A DNS record for $recordLabel.$zoneName already exists on $dnsServer. No action taken." -ForegroundColor Yellow
} else {
    # Add the DNS A record
    Add-DnsServerResourceRecordA -Name $recordLabel -ZoneName $zoneName -IPv4Address $ipAddress -ComputerName $dnsServer
    Write-Host "DNS record $recordLabel.$zoneName -> $ipAddress added on $dnsServer."
}