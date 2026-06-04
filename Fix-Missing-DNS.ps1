param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName
)

Write-Host "Starting DNS Zone Group reconciliation for RG: $ResourceGroupName"

# 🔹 CONFIG: groupId → Private DNS Zone ID
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

# 🔹 Fetch all Private Endpoints
$privateEndpoints = az network private-endpoint list `
    --resource-group $ResourceGroupName `
    | ConvertFrom-Json

if (-not $privateEndpoints) {
    Write-Host "No private endpoints found."
    return
}

# 🔹 Process each Private Endpoint (Sequential - stable)
foreach ($pe in $privateEndpoints) {

    $peName = $pe.name
    $peId   = $pe.id

    Write-Host "`nProcessing PE: $peName"

    # 🔹 Get existing DNS zone groups for this PE
    $existingZones = @()

    try {
        $zoneGroups = az network private-endpoint dns-zone-group list `
            --resource-group $ResourceGroupName `
            --endpoint-name $peName `
            | ConvertFrom-Json

        foreach ($zg in $zoneGroups) {
            foreach ($config in $zg.privateDnsZoneConfigs) {
                $existingZones += ($config.privateDnsZoneId.Split("/")[-1])
            }
        }
    }
    catch {
        Write-Host "No existing DNS zone groups found for $peName"
    }

    # 🔹 Process groupIds
    foreach ($conn in $pe.privateLinkServiceConnections) {

        foreach ($groupId in $conn.groupIds) {

            if (-not $dnsZoneMap.ContainsKey($groupId)) {
                Write-Warning "[$peName] Unknown groupId: $groupId"
                continue
            }

            $zoneId   = $dnsZoneMap[$groupId]
            $zoneName = $zoneId.Split("/")[-1]

            # 🔹 Skip if already configured
            if ($existingZones -contains $zoneName) {
                Write-Host "[$peName] Already has $zoneName"
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
}

Write-Host "`nCompleted DNS reconciliation."
