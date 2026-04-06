<#
.SYNOPSIS
    Creates all destination (DESTINO) infrastructure based on the exported source configuration.

.DESCRIPTION
    Reads the migration_config.json exported from the source and recreates all
    infrastructure in the destination subscription/account:
      - Resource Group
      - VNet + Subnets (with delegations and NSG)
      - Databricks Workspace (with VNet injection)
      - Private Endpoint + Private DNS Zone
      - Configures Databricks CLI profile

.PARAMETER ConfigFile
    Path to the migration_config.json file exported from the source.

.PARAMETER Subscription
    Azure Subscription ID of the destination account.

.PARAMETER ResourceGroup
    Resource Group name for the destination workspace.

.PARAMETER WorkspaceName
    Name of the destination Databricks workspace.

.PARAMETER VnetName
    Name of the VNet in the destination. Defaults to 'vnet-<WorkspaceName>'.

.PARAMETER CliProfile
    Databricks CLI profile name for the destination. Defaults to 'migration-destino'.

.PARAMETER Location
    Azure region. Optional; inherits from source if omitted.

.PARAMETER VnetAddressSpace
    CIDR of the VNet. Optional; inherits from source if omitted.

.EXAMPLE
    .\02_create_destino_infra.ps1 `
        -ConfigFile "./origem-export/migration_config.json" `
        -Subscription "dddd-eeee-ffff" `
        -ResourceGroup "rg-prod-new" `
        -WorkspaceName "dbw-prod-new" `
        -VnetName "vnet-dbw-prod-new" `
        -CliProfile "prod-destino"
#>

param(
    [Parameter(Mandatory)]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [string]$VnetName = "",

    [string]$CliProfile = "migration-destino",

    [string]$Location = "",

    [string]$VnetAddressSpace = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERRO: Arquivo de config nao encontrado: $ConfigFile" -ForegroundColor Red
    exit 1
}

# ===================== LER CONFIG DA ORIGEM =====================
Write-Host "============================================"
Write-Host " Lendo configuracao da ORIGEM..."
Write-Host "============================================"

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# Workspace params
$SrcLocation = $config.workspace.location
$Sku = $config.workspace.sku
$PublicNetwork = $config.workspace.publicNetworkAccess
$NsgRules = $config.workspace.requiredNsgRules
$NoPublicIp = $config.workspace.enableNoPublicIp

# Network params
$HasVnet = $config.network.hasVnetInjection
$SrcVnetCidr = $config.network.vnetAddressSpace
$HostSubnetName = $config.network.hostSubnet
$ContainerSubnetName = $config.network.containerSubnet

# Private Endpoint params
$HasPe = $config.privateEndpoint.enabled
$PeSubnetName = $config.privateEndpoint.subnet
$PeGroupId = $config.privateEndpoint.groupId

# Defaults
if (-not $Location) { $Location = $SrcLocation }
if (-not $VnetAddressSpace) { $VnetAddressSpace = $SrcVnetCidr }

if ($HasVnet -and (-not $VnetName)) {
    $VnetName = "vnet-$WorkspaceName"
}

Write-Host "  Destino Subscription: $Subscription"
Write-Host "  Destino RG: $ResourceGroup"
Write-Host "  Destino Workspace: $WorkspaceName"
Write-Host "  Location: $Location"
Write-Host "  SKU: $Sku"
Write-Host "  VNet Injection: $HasVnet"
Write-Host "  Private Endpoint: $HasPe"
Write-Host ""

# ===================== SET SUBSCRIPTION =====================
Write-Host "[1/8] Definindo subscription destino..."
az account set --subscription $Subscription

# ===================== RESOURCE GROUP =====================
Write-Host "[2/8] Criando Resource Group: $ResourceGroup ..."
az group create `
    --name $ResourceGroup `
    --location $Location `
    --tags purpose=migration-destino created-by=migration-script `
    --output none
Write-Host "  Resource Group criado."

# ===================== VNET + SUBNETS =====================
$NsgName = ""
if ($HasVnet) {
    Write-Host "[3/8] Criando VNet: $VnetName ($VnetAddressSpace) ..."
    az network vnet create `
        --resource-group $ResourceGroup `
        --name $VnetName `
        --location $Location `
        --address-prefix $VnetAddressSpace `
        --output none
    Write-Host "  VNet criada."

    # Recriar subnets com as mesmas configs
    $SubnetCount = $config.network.subnets.Count
    Write-Host "[4/8] Criando $SubnetCount subnets..."

    for ($i = 0; $i -lt $SubnetCount; $i++) {
        $snet = $config.network.subnets[$i]
        $snetName = $snet.name
        $snetPrefix = $snet.addressPrefix
        $snetDelegation = if ($snet.delegations -and $snet.delegations.Count -gt 0) { $snet.delegations[0] } else { $null }

        $delegationArgs = @()
        if ($snetDelegation -and $snetDelegation -ne "null") {
            $delegationArgs = @("--delegations", $snetDelegation)
        }

        $subnetArgs = @(
            "network", "vnet", "subnet", "create",
            "--resource-group", $ResourceGroup,
            "--vnet-name", $VnetName,
            "--name", $snetName,
            "--address-prefix", $snetPrefix
        )
        $subnetArgs += $delegationArgs
        $subnetArgs += @("--output", "none")

        & az @subnetArgs
        Write-Host "  Subnet: $snetName ($snetPrefix) delegation=$snetDelegation"
    }

    # ===================== NSG =====================
    Write-Host "[5/8] Criando NSG..."
    $NsgName = "nsg-$WorkspaceName"
    az network nsg create `
        --resource-group $ResourceGroup `
        --name $NsgName `
        --location $Location `
        --output none
    Write-Host "  NSG criado: $NsgName"

    # Associar NSG as subnets com delegation (host e container)
    for ($i = 0; $i -lt $SubnetCount; $i++) {
        $snet = $config.network.subnets[$i]
        $snetName = $snet.name
        $hasNsg = $snet.hasNsg
        if ($hasNsg) {
            az network vnet subnet update `
                --resource-group $ResourceGroup `
                --vnet-name $VnetName `
                --name $snetName `
                --network-security-group $NsgName `
                --output none
            Write-Host "  NSG associado a subnet: $snetName"
        }
    }
}
else {
    Write-Host "[3/8] Sem VNet injection na origem - pulando VNet..."
    Write-Host "[4/8] Pulando subnets..."
    Write-Host "[5/8] Pulando NSG..."
}

# ===================== WORKSPACE =====================
Write-Host "[6/8] Criando Workspace Databricks: $WorkspaceName ..."
Write-Host "  (Isso pode levar 5-10 minutos...)"

$wsArgs = @(
    "databricks", "workspace", "create",
    "--resource-group", $ResourceGroup,
    "--name", $WorkspaceName,
    "--location", $Location,
    "--sku", $Sku
)

if ($HasVnet) {
    $DestVnetId = "/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.Network/virtualNetworks/${VnetName}"
    $wsArgs += @(
        "--vnet", $DestVnetId,
        "--public-subnet", $HostSubnetName,
        "--private-subnet", $ContainerSubnetName,
        "--public-network-access", $PublicNetwork,
        "--required-nsg-rules", $NsgRules
    )

    if ($NoPublicIp -eq $true) {
        $wsArgs += "--enable-no-public-ip"
    }
}

$wsArgs += @("--output", "none")
& az @wsArgs
Write-Host "  Workspace criado!"

# Obter URL
$WsUrl = az databricks workspace show `
    --resource-group $ResourceGroup `
    --name $WorkspaceName `
    --query workspaceUrl -o tsv

$WsId = az databricks workspace show `
    --resource-group $ResourceGroup `
    --name $WorkspaceName `
    --query id -o tsv

Write-Host "  URL: https://$WsUrl"

# ===================== PRIVATE ENDPOINT =====================
$PeName = ""
$DnsZone = ""
if ($HasPe -and $HasVnet) {
    Write-Host "[7/8] Criando Private Endpoint..."

    $PeName = "pe-$WorkspaceName"
    $PeConnName = "pe-conn-$WorkspaceName"

    az network private-endpoint create `
        --name $PeName `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --subnet $PeSubnetName `
        --private-connection-resource-id $WsId `
        --group-id $PeGroupId `
        --connection-name $PeConnName `
        --location $Location `
        --output none
    Write-Host "  Private Endpoint criado: $PeName"

    # Private DNS Zone
    $DnsZone = "privatelink.azuredatabricks.net"
    Write-Host "  Criando Private DNS Zone: $DnsZone ..."
    az network private-dns zone create `
        --resource-group $ResourceGroup `
        --name $DnsZone `
        --output none

    # Link DNS Zone to VNet
    az network private-dns link vnet create `
        --resource-group $ResourceGroup `
        --zone-name $DnsZone `
        --name "link-$VnetName" `
        --virtual-network $VnetName `
        --registration-enabled false `
        --output none
    Write-Host "  DNS Zone vinculada a VNet."

    # DNS Zone Group for auto-registration
    az network private-endpoint dns-zone-group create `
        --resource-group $ResourceGroup `
        --endpoint-name $PeName `
        --name default `
        --private-dns-zone $DnsZone `
        --zone-name databricks `
        --output none
    Write-Host "  DNS Zone Group criada."
}
else {
    Write-Host "[7/8] Sem Private Endpoint na origem - pulando..."
}

# ===================== DATABRICKS CLI =====================
Write-Host "[8/8] Configurando Databricks CLI (profile: $CliProfile) ..."
try {
    databricks auth login --host "https://$WsUrl" --profile $CliProfile 2>$null
}
catch {
    # Ignore errors in auth login (same as bash || true)
}

# ===================== RESUMO FINAL =====================
Write-Host ""
Write-Host "============================================"
Write-Host " Infraestrutura DESTINO criada com sucesso!" -ForegroundColor Green
Write-Host "============================================"
Write-Host ""
Write-Host " Subscription:       $Subscription"
Write-Host " Resource Group:     $ResourceGroup"
Write-Host " Workspace:          $WorkspaceName"
Write-Host " URL:                https://$WsUrl"
Write-Host " Location:           $Location"
Write-Host " SKU:                $Sku"
if ($HasVnet) {
    Write-Host " VNet:               $VnetName ($VnetAddressSpace)"
    Write-Host " Host Subnet:        $HostSubnetName"
    Write-Host " Container Subnet:   $ContainerSubnetName"
    Write-Host " No Public IP:       $NoPublicIp"
    Write-Host " NSG:                $NsgName"
}
if ($HasPe) {
    Write-Host " Private Endpoint:   $PeName"
    Write-Host " Private DNS:        $DnsZone"
}
Write-Host " CLI Profile:        $CliProfile"
Write-Host ""
Write-Host " Proximo passo: execute o script de migracao de dados"
Write-Host "   .\03_migrate_data.ps1 -ProfileOrigem migration-origem -ProfileDestino $CliProfile"
Write-Host "============================================"
