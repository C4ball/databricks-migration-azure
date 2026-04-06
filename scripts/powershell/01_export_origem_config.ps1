<#
.SYNOPSIS
    Exports all infrastructure configuration from the source (ORIGEM) Databricks Workspace.

.DESCRIPTION
    Exports Workspace, VNet, Subnets, NSG, Private Endpoint, and DNS configuration
    from the source workspace to a local directory, generating a consolidated JSON
    that will be used by 02_create_destino_infra.ps1 to recreate in the destination account.

.PARAMETER Subscription
    Azure Subscription ID of the source account.

.PARAMETER ResourceGroup
    Resource Group name of the source workspace.

.PARAMETER WorkspaceName
    Name of the source Databricks workspace.

.PARAMETER OutputDir
    Path to the output directory for exported configuration. Defaults to './origem-export'.

.EXAMPLE
    .\01_export_origem_config.ps1 `
        -Subscription "aaaa-bbbb-cccc" `
        -ResourceGroup "rg-prod" `
        -WorkspaceName "dbw-prod" `
        -OutputDir "./origem-export"
#>

param(
    [Parameter(Mandatory)]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [string]$OutputDir = "./origem-export"
)

$ErrorActionPreference = "Stop"

# ===================== CREATE OUTPUT DIR =====================
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "============================================"
Write-Host " Exportando configuracao da ORIGEM"
Write-Host " Subscription: $Subscription"
Write-Host " Resource Group: $ResourceGroup"
Write-Host " Workspace: $WorkspaceName"
Write-Host " Output: $OutputDir"
Write-Host "============================================"

# ===================== SET SUBSCRIPTION =====================
Write-Host "[1/7] Definindo subscription..."
az account set --subscription $Subscription

# ===================== EXPORT WORKSPACE =====================
Write-Host "[2/7] Exportando workspace..."
az databricks workspace show `
    --resource-group $ResourceGroup `
    --name $WorkspaceName `
    --output json | Out-File -FilePath "$OutputDir/workspace.json" -Encoding utf8

# Extrair parametros chave
$wsJson = Get-Content "$OutputDir/workspace.json" -Raw | ConvertFrom-Json

$Location = $wsJson.location
$Sku = $wsJson.sku.name
$PublicNetwork = if ($wsJson.publicNetworkAccess) { $wsJson.publicNetworkAccess } else { "Enabled" }
$NsgRules = if ($wsJson.requiredNsgRules) { $wsJson.requiredNsgRules } else { "AllRules" }
$NoPublicIp = $wsJson.parameters.enableNoPublicIp.value
$VnetId = $wsJson.parameters.customVirtualNetworkId.value
$HostSubnet = $wsJson.parameters.customPublicSubnetName.value
$ContainerSubnet = $wsJson.parameters.customPrivateSubnetName.value

$HasVnetInjection = $false
if ($VnetId -and $VnetId -ne "null") {
    $HasVnetInjection = $true
}

Write-Host "  Location: $Location"
Write-Host "  SKU: $Sku"
Write-Host "  VNet Injection: $HasVnetInjection"

# ===================== EXPORT VNET (se existir) =====================
$VnetName = ""
$VnetAddressSpace = ""
$NsgNames = @()

if ($HasVnetInjection) {
    $VnetName = ($VnetId -split '/')[-1]
    Write-Host "[3/7] Exportando VNet: $VnetName ..."
    az network vnet show `
        --resource-group $ResourceGroup `
        --name $VnetName `
        --output json | Out-File -FilePath "$OutputDir/vnet.json" -Encoding utf8

    $vnetJson = Get-Content "$OutputDir/vnet.json" -Raw | ConvertFrom-Json
    $VnetAddressSpace = $vnetJson.addressSpace.addressPrefixes[0]

    # ===================== EXPORT SUBNETS =====================
    Write-Host "[4/7] Exportando subnets..."
    az network vnet subnet list `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --output json | Out-File -FilePath "$OutputDir/subnets.json" -Encoding utf8

    # ===================== EXPORT NSG =====================
    Write-Host "[5/7] Exportando NSGs..."
    $subnetsJson = Get-Content "$OutputDir/subnets.json" -Raw | ConvertFrom-Json

    # Detectar NSGs associados as subnets
    $nsgIds = @()
    foreach ($subnet in $subnetsJson) {
        if ($subnet.networkSecurityGroup -and $subnet.networkSecurityGroup.id) {
            $nsgIds += $subnet.networkSecurityGroup.id
        }
    }
    $nsgIds = $nsgIds | Sort-Object -Unique | Where-Object { $_ -ne "" }

    $idx = 0
    foreach ($nsgId in $nsgIds) {
        $nsgName = ($nsgId -split '/')[-1]
        $NsgNames += $nsgName
        az network nsg show `
            --resource-group $ResourceGroup `
            --name $nsgName `
            --output json | Out-File -FilePath "$OutputDir/nsg_${idx}.json" -Encoding utf8
        Write-Host "  NSG: $nsgName"
        $idx++
    }
}
else {
    Write-Host "[3/7] Sem VNet injection - pulando VNet..."
    Write-Host "[4/7] Sem VNet injection - pulando subnets..."
    Write-Host "[5/7] Sem VNet injection - pulando NSG..."
}

# ===================== EXPORT PRIVATE ENDPOINTS =====================
Write-Host "[6/7] Exportando Private Endpoints..."
$WsResourceId = $wsJson.id

$HasPrivateEndpoint = $false
$PeSubnet = ""
$PeGroupId = ""

try {
    $peListRaw = az network private-endpoint list `
        --resource-group $ResourceGroup `
        --query "[?privateLinkServiceConnections[0].privateLinkServiceId=='$WsResourceId'].name" `
        --output tsv 2>$null
    $peList = if ($peListRaw) { $peListRaw -split "`n" | Where-Object { $_.Trim() -ne "" } } else { @() }
}
catch {
    $peList = @()
}

if ($peList.Count -gt 0) {
    $HasPrivateEndpoint = $true
    foreach ($peName in $peList) {
        $peName = $peName.Trim()
        az network private-endpoint show `
            --resource-group $ResourceGroup `
            --name $peName `
            --output json | Out-File -FilePath "$OutputDir/private_endpoint.json" -Encoding utf8

        $peJson = Get-Content "$OutputDir/private_endpoint.json" -Raw | ConvertFrom-Json
        $PeSubnet = ($peJson.subnet.id -split '/')[-1]
        $PeGroupId = $peJson.privateLinkServiceConnections[0].groupIds[0]
        Write-Host "  PE: $peName (subnet: $PeSubnet, group: $PeGroupId)"
    }

    # Exportar Private DNS Zone
    Write-Host "  Exportando Private DNS Zone..."
    try {
        az network private-dns zone list `
            --resource-group $ResourceGroup `
            --query "[?name=='privatelink.azuredatabricks.net']" `
            --output json | Out-File -FilePath "$OutputDir/private_dns.json" -Encoding utf8
    }
    catch {
        "[]" | Out-File -FilePath "$OutputDir/private_dns.json" -Encoding utf8
    }
}
else {
    Write-Host "  Nenhum Private Endpoint encontrado"
}

# ===================== GERAR CONFIG CONSOLIDADA =====================
Write-Host "[7/7] Gerando config consolidada..."

# Montar subnets config
$SubnetsArray = @()
if ($HasVnetInjection) {
    $subnetsJson = Get-Content "$OutputDir/subnets.json" -Raw | ConvertFrom-Json
    foreach ($snet in $subnetsJson) {
        $delegations = @()
        if ($snet.delegations) {
            foreach ($d in $snet.delegations) {
                $delegations += $d.serviceName
            }
        }
        $SubnetsArray += @{
            name          = $snet.name
            addressPrefix = $snet.addressPrefix
            delegations   = $delegations
            hasNsg        = [bool]($snet.networkSecurityGroup)
        }
    }
}

$migrationConfig = @{
    source          = @{
        subscription  = $Subscription
        resourceGroup = $ResourceGroup
        workspaceName = $WorkspaceName
    }
    workspace       = @{
        location            = $Location
        sku                 = $Sku
        publicNetworkAccess = $PublicNetwork
        requiredNsgRules    = $NsgRules
        enableNoPublicIp    = $NoPublicIp
    }
    network         = @{
        hasVnetInjection = $HasVnetInjection
        vnetName         = $VnetName
        vnetAddressSpace = $VnetAddressSpace
        hostSubnet       = $HostSubnet
        containerSubnet  = $ContainerSubnet
        subnets          = $SubnetsArray
    }
    privateEndpoint = @{
        enabled = $HasPrivateEndpoint
        subnet  = $PeSubnet
        groupId = if ($PeGroupId) { $PeGroupId } else { "databricks_ui_api" }
    }
    privateDns      = @{
        zoneName = "privatelink.azuredatabricks.net"
    }
}

$migrationConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath "$OutputDir/migration_config.json" -Encoding utf8

Write-Host ""
Write-Host "============================================"
Write-Host " Exportacao concluida!"
Write-Host " Config: $OutputDir/migration_config.json"
Write-Host "============================================"

# Pretty-print the config
Get-Content "$OutputDir/migration_config.json" -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10 | Write-Host
