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
Write-Host "[1/9] Definindo subscription..."
az account set --subscription $Subscription

# ===================== EXPORT WORKSPACE =====================
Write-Host "[2/9] Exportando workspace..."
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
    Write-Host "[3/9] Exportando VNet: $VnetName ..."
    az network vnet show `
        --resource-group $ResourceGroup `
        --name $VnetName `
        --output json | Out-File -FilePath "$OutputDir/vnet.json" -Encoding utf8

    $vnetJson = Get-Content "$OutputDir/vnet.json" -Raw | ConvertFrom-Json
    $VnetAddressSpace = $vnetJson.addressSpace.addressPrefixes[0]

    # ===================== EXPORT SUBNETS =====================
    Write-Host "[4/9] Exportando subnets..."
    az network vnet subnet list `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --output json | Out-File -FilePath "$OutputDir/subnets.json" -Encoding utf8

    # ===================== EXPORT NSG =====================
    Write-Host "[5/9] Exportando NSGs..."
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
    Write-Host "[3/9] Sem VNet injection - pulando VNet..."
    Write-Host "[4/9] Sem VNet injection - pulando subnets..."
    Write-Host "[5/9] Sem VNet injection - pulando NSG..."
}

# ===================== EXPORT ADLS GEN2 STORAGE ACCOUNTS =====================
Write-Host "[6/9] Exportando ADLS Gen2 Storage Accounts..."

# Find storage accounts with HNS enabled (ADLS Gen2) in the resource group
$HasAdlsStorage = $false
$StorageConfigs = @()

try {
    $storageAccountsRaw = az storage account list `
        --resource-group $ResourceGroup `
        --query "[?isHnsEnabled==``true``]" `
        --output json 2>$null
    $storageAccounts = $storageAccountsRaw | ConvertFrom-Json
}
catch {
    $storageAccounts = @()
}

if ($storageAccounts -and $storageAccounts.Count -gt 0) {
    $HasAdlsStorage = $true
    Write-Host "  Encontradas $($storageAccounts.Count) storage account(s) ADLS Gen2"

    $storageAccountsRaw | Out-File -FilePath "$OutputDir/storage_accounts.json" -Encoding utf8

    foreach ($sa in $storageAccounts) {
        $saName = $sa.name
        $saSku = $sa.sku.name
        $saKind = $sa.kind
        $saAccessTier = if ($sa.accessTier) { $sa.accessTier } else { "Hot" }
        $saHns = $sa.isHnsEnabled

        Write-Host "  Storage Account: $saName (SKU: $saSku, Kind: $saKind, Tier: $saAccessTier)"

        # Export containers
        $containerNames = @()
        try {
            $containersRaw = az storage container list `
                --account-name $saName `
                --auth-mode login `
                --output json 2>$null
            $containers = $containersRaw | ConvertFrom-Json
            $containerNames = @($containers | ForEach-Object { $_.name })
            Write-Host "    Containers: $($containerNames.Count)"
        }
        catch {
            Write-Host "    Containers: erro ao listar"
        }

        # Export CORS rules
        $corsRules = @()
        try {
            $corsRaw = az storage cors list `
                --account-name $saName `
                --services b `
                --auth-mode login `
                --output json 2>$null
            $corsRules = $corsRaw | ConvertFrom-Json
        }
        catch { }

        # Export network rules
        $networkRules = @{}
        $defaultAction = "Allow"
        try {
            $networkRulesRaw = az storage account network-rule list `
                --account-name $saName `
                --resource-group $ResourceGroup `
                --output json 2>$null
            $networkRules = $networkRulesRaw | ConvertFrom-Json
            $defaultAction = if ($sa.networkRuleSet -and $sa.networkRuleSet.defaultAction) { $sa.networkRuleSet.defaultAction } else { "Allow" }
        }
        catch { }

        Write-Host "    Network default action: $defaultAction"

        $StorageConfigs += @{
            name                 = $saName
            sku                  = $saSku
            kind                 = $saKind
            accessTier           = $saAccessTier
            isHnsEnabled         = $saHns
            containers           = $containerNames
            cors                 = $corsRules
            networkDefaultAction = $defaultAction
            networkRules         = $networkRules
        }
    }
}
else {
    Write-Host "  Nenhuma storage account ADLS Gen2 encontrada no Resource Group"
}

# ===================== EXPORT ACCESS CONNECTORS =====================
Write-Host "[7/9] Exportando Access Connectors para Databricks..."

$HasAccessConnector = $false
$AcConfigs = @()

try {
    $acRaw = az resource list `
        --resource-group $ResourceGroup `
        --resource-type "Microsoft.Databricks/accessConnectors" `
        --output json 2>$null
    $accessConnectors = $acRaw | ConvertFrom-Json
}
catch {
    $accessConnectors = @()
}

if ($accessConnectors -and $accessConnectors.Count -gt 0) {
    $HasAccessConnector = $true
    Write-Host "  Encontrados $($accessConnectors.Count) Access Connector(s)"
    $acRaw | Out-File -FilePath "$OutputDir/access_connectors.json" -Encoding utf8

    foreach ($ac in $accessConnectors) {
        $AcConfigs += @{
            name     = $ac.name
            location = $ac.location
            identity = $ac.identity
        }
    }
}
else {
    Write-Host "  Nenhum Access Connector encontrado"
}

# Mount points note
Write-Host "  (Mount points devem ser verificados manualmente via dbutils.fs.mounts())"

# ===================== EXPORT PRIVATE ENDPOINTS =====================
Write-Host "[8/9] Exportando Private Endpoints..."
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
Write-Host "[9/9] Gerando config consolidada..."

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
    storage         = @{
        hasAdlsGen2        = $HasAdlsStorage
        storageAccounts    = $StorageConfigs
        hasAccessConnector = $HasAccessConnector
        accessConnectors   = $AcConfigs
        mountPoints        = @()
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
