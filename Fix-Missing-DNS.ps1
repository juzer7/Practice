param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName
)

Write-Host "Starting DNS Zone Group reconciliation for RG: $ResourceGroupName"

# 🔹 CONFIG: groupId → Private DNS Zone ID (PASS THESE)
$dnsZoneMap = @{
    "blob"      = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    "file"      = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
    "queue"     = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net"
    "table"     = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
    "dfs"       = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net"

    "vault"     = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"

    "sqlServer" = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"

    "Sql"       = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com"
    "MongoDB"   = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.mongo.cosmos.azure.com"
    "Cassandra" = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cassandra.cosmos.azure.com"
    "Gremlin"   = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.gremlin.cosmos.azure.com"
    "Table"     = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.table.cosmos.azure.com"

    "namespace" = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"

    "eventHub"  = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"

    "topic"     = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.eventgrid.azure.net"

    "registry"  = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"

    "sites"     = "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
}

# 🔹 Retry Wrapper
function Invoke-WithRetry {
    param (
        [scriptblock]$ScriptBlock,
        [int]$Retries = 3
    )

    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            return & $ScriptBlock
        }
        catch {
            Write-Warning "Retry $($i+1) failed. Retrying..."
            Start-Sleep -Seconds (2 * ($i + 1))
        }
    }

    throw "Operation failed after $Retries retries"
}

# 🔹 Fetch all Private Endpoints (single call)
$privateEndpoints = az network private-endpoint list `
    --resource-group $ResourceGroupName `
    | ConvertFrom-Json

if (-not $privateEndpoints) {
    Write-Host "No private endpoints found."
    return
}

# 🔹 Fetch all DNS Zone Groups via Resource Graph (bulk)
$zoneGroups = az graph query -q "
Resources
| where type == 'microsoft.network/privateendpoints/privateDnsZoneGroups'
| where resourceGroup == '$ResourceGroupName'
| project peId = tostring(split(id, '/privateDnsZoneGroups')[0]),
         zones = properties.privateDnsZoneConfigs
" | ConvertFrom-Json

# 🔹 Build lookup
$zoneGroupLookup = @{}

foreach ($zg in $zoneGroups.data) {
    $zones = @()
    foreach ($z in $zg.zones) {
        $zones += ($z.privateDnsZoneId.Split("/")[-1])
    }
    $zoneGroupLookup[$zg.peId] = $zones
}

# 🔹 Parallel Processing
$throttleLimit = 10

$privateEndpoints | ForEach-Object -Parallel {

    param($dnsZoneMap, $zoneGroupLookup, $ResourceGroupName)

    function Invoke-WithRetry {
        param ([scriptblock]$ScriptBlock, [int]$Retries = 3)
        for ($i = 0; $i -lt $Retries; $i++) {
            try { return & $ScriptBlock }
            catch { Start-Sleep -Seconds (2 * ($i + 1)) }
        }
        throw "Retry failed"
    }

    $pe = $_
    $peId = $pe.id
    $peName = $pe.name

    $existingZones = @()
    if ($zoneGroupLookup.ContainsKey($peId)) {
        $existingZones = $zoneGroupLookup[$peId]
    }

    foreach ($conn in $pe.privateLinkServiceConnections) {

        foreach ($groupId in $conn.groupIds) {

            if (-not $dnsZoneMap.ContainsKey($groupId)) {
                Write-Host "[$peName] Unknown groupId: $groupId"
                continue
            }

            $zoneId = $dnsZoneMap[$groupId]
            $zoneName = $zoneId.Split("/")[-1]

            if ($existingZones -contains $zoneName) {
                continue
            }

            Write-Host "[$peName] Attaching $zoneName"

            Invoke-WithRetry {
                az network private-endpoint dns-zone-group create `
                    --resource-group $ResourceGroupName `
                    --endpoint-name $peName `
                    --name "default" `
                    --private-dns-zone $zoneId `
                    --zone-name $zoneName | Out-Null
            }
        }
    }

} -ThrottleLimit $throttleLimit -ArgumentList $dnsZoneMap, $zoneGroupLookup, $ResourceGroupName

Write-Host "Completed DNS reconciliation."
