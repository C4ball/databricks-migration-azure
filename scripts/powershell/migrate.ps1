<#
.SYNOPSIS
    Main orchestration script for Databricks Workspace migration between Azure accounts.

.DESCRIPTION
    Orchestrates the 3 migration scripts in sequence:
      1. Exports infrastructure configuration from ORIGEM (source)
      2. Recreates infrastructure in DESTINO (destination) - VNet, PE, DNS, Workspace
      3. Migrates data - notebooks, secrets, jobs

    All source and destination parameters are passed via command line.

.PARAMETER OrigemSubscription
    Azure Subscription ID of the source account.

.PARAMETER OrigemResourceGroup
    Resource Group of the source workspace.

.PARAMETER OrigemWorkspace
    Name of the source Databricks workspace.

.PARAMETER OrigemCliProfile
    Databricks CLI profile for the source.

.PARAMETER DestinoSubscription
    Azure Subscription ID of the destination account.

.PARAMETER DestinoResourceGroup
    Resource Group for the destination workspace.

.PARAMETER DestinoWorkspace
    Name of the destination Databricks workspace.

.PARAMETER DestinoCliProfile
    Databricks CLI profile for the destination.

.PARAMETER DestinoVnetName
    Name of the VNet in the destination. Optional; defaults to 'vnet-<workspace>'.

.PARAMETER DestinoLocation
    Azure region for the destination. Optional; inherits from source.

.PARAMETER DestinoVnetAddressSpace
    CIDR of the VNet in the destination. Optional; inherits from source.

.PARAMETER DestinoStorageName
    Custom name for the destination ADLS Gen2 storage account. Optional.

.PARAMETER SyncStorage
    Switch to enable ADLS Gen2 storage data synchronization.

.PARAMETER SecretsFile
    JSON file with secret values for migration.

.PARAMETER ExportDir
    Directory for export files. Defaults to auto-generated with timestamp.

.PARAMETER SkipInfra
    Skip infrastructure creation (if already created).

.PARAMETER SkipData
    Skip data migration (infrastructure only).

.PARAMETER DryRun
    Show the execution plan without running anything.

.EXAMPLE
    # Full migration (infra + data)
    .\migrate.ps1 `
        -OrigemSubscription "aaaa-bbbb-cccc" `
        -OrigemResourceGroup "rg-prod" `
        -OrigemWorkspace "dbw-prod" `
        -OrigemCliProfile "prod-origem" `
        -DestinoSubscription "dddd-eeee-ffff" `
        -DestinoResourceGroup "rg-prod-new" `
        -DestinoWorkspace "dbw-prod-new" `
        -DestinoCliProfile "prod-destino" `
        -SecretsFile "./secrets.json"

.EXAMPLE
    # Data migration only (infra already exists)
    .\migrate.ps1 `
        -OrigemSubscription "aaaa-bbbb-cccc" `
        -OrigemResourceGroup "rg-prod" `
        -OrigemWorkspace "dbw-prod" `
        -OrigemCliProfile "prod-origem" `
        -DestinoSubscription "dddd-eeee-ffff" `
        -DestinoResourceGroup "rg-prod-new" `
        -DestinoWorkspace "dbw-prod-new" `
        -DestinoCliProfile "prod-destino" `
        -SkipInfra
#>

param(
    [Parameter(Mandatory)]
    [string]$OrigemSubscription,

    [Parameter(Mandatory)]
    [string]$OrigemResourceGroup,

    [Parameter(Mandatory)]
    [string]$OrigemWorkspace,

    [Parameter(Mandatory)]
    [string]$OrigemCliProfile,

    [Parameter(Mandatory)]
    [string]$DestinoSubscription,

    [Parameter(Mandatory)]
    [string]$DestinoResourceGroup,

    [Parameter(Mandatory)]
    [string]$DestinoWorkspace,

    [Parameter(Mandatory)]
    [string]$DestinoCliProfile,

    [string]$DestinoVnetName = "",

    [string]$DestinoLocation = "",

    [string]$DestinoVnetAddressSpace = "",

    [string]$DestinoStorageName = "",

    [switch]$SyncStorage,

    [string]$SecretsFile = "",

    [string]$ExportDir = "",

    [switch]$SkipInfra,

    [switch]$SkipData,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ===================== DEFAULTS =====================
if (-not $ExportDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ExportDir = Join-Path $PSScriptRoot "export-$timestamp"
}

# ===================== VALIDATION =====================
$Errors = @()
# (Mandatory params are enforced by [Parameter(Mandatory)], but validate secrets file)
if ($SecretsFile -and -not (Test-Path $SecretsFile)) {
    Write-Host "ERRO: Arquivo de secrets nao encontrado: $SecretsFile" -ForegroundColor Red
    exit 1
}

# ===================== SETUP DIRS =====================
$InfraDir = Join-Path $ExportDir "infra"
$DataDir = Join-Path $ExportDir "data"
New-Item -ItemType Directory -Path $InfraDir -Force | Out-Null
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

# ===================== PLANO =====================
Write-Host ""
Write-Host "################################################################"
Write-Host "#  MIGRACAO DATABRICKS WORKSPACE - AZURE                      #"
Write-Host "################################################################"
Write-Host ""
Write-Host "  ORIGEM:"
Write-Host "    Subscription:   $OrigemSubscription"
Write-Host "    Resource Group: $OrigemResourceGroup"
Write-Host "    Workspace:      $OrigemWorkspace"
Write-Host "    CLI Profile:    $OrigemCliProfile"
Write-Host ""
Write-Host "  DESTINO:"
Write-Host "    Subscription:   $DestinoSubscription"
Write-Host "    Resource Group: $DestinoResourceGroup"
Write-Host "    Workspace:      $DestinoWorkspace"
Write-Host "    CLI Profile:    $DestinoCliProfile"
if ($DestinoVnetName) {
    Write-Host "    VNet Name:      $DestinoVnetName"
}
if ($DestinoLocation) {
    Write-Host "    Location:       $DestinoLocation"
}
Write-Host ""
Write-Host "  OPCOES:"
Write-Host "    Export Dir:     $ExportDir"
Write-Host "    Secrets File:   $(if ($SecretsFile) { $SecretsFile } else { 'nao fornecido' })"
Write-Host "    Storage Name:   $(if ($DestinoStorageName) { $DestinoStorageName } else { 'auto' })"
Write-Host "    Sync Storage:   $SyncStorage"
Write-Host "    Skip Infra:     $SkipInfra"
Write-Host "    Skip Data:      $SkipData"
Write-Host "    Dry Run:        $DryRun"
Write-Host ""

# ===================== DRY RUN =====================
if ($DryRun) {
    Write-Host "  [DRY RUN] Plano de execucao:" -ForegroundColor Cyan
    Write-Host ""
    if (-not $SkipInfra) {
        Write-Host "  Passo 1: Exportar configuracao da ORIGEM"
        Write-Host "    -> $PSScriptRoot\01_export_origem_config.ps1"
        Write-Host "       -Subscription $OrigemSubscription"
        Write-Host "       -ResourceGroup $OrigemResourceGroup"
        Write-Host "       -WorkspaceName $OrigemWorkspace"
        Write-Host "       -OutputDir $InfraDir"
        Write-Host ""
        Write-Host "  Passo 2: Criar infraestrutura no DESTINO"
        Write-Host "    -> $PSScriptRoot\02_create_destino_infra.ps1"
        Write-Host "       -ConfigFile $InfraDir\migration_config.json"
        Write-Host "       -Subscription $DestinoSubscription"
        Write-Host "       -ResourceGroup $DestinoResourceGroup"
        Write-Host "       -WorkspaceName $DestinoWorkspace"
        Write-Host "       -CliProfile $DestinoCliProfile"
        if ($DestinoVnetName) { Write-Host "       -VnetName $DestinoVnetName" }
        if ($DestinoLocation) { Write-Host "       -Location $DestinoLocation" }
        if ($DestinoVnetAddressSpace) { Write-Host "       -VnetAddressSpace $DestinoVnetAddressSpace" }
        if ($DestinoStorageName) { Write-Host "       -StorageName $DestinoStorageName" }
        Write-Host ""
    }
    if (-not $SkipData) {
        Write-Host "  Passo 3: Migrar dados (notebooks, secrets, jobs)"
        Write-Host "    -> $PSScriptRoot\03_migrate_data.ps1"
        Write-Host "       -ProfileOrigem $OrigemCliProfile"
        Write-Host "       -ProfileDestino $DestinoCliProfile"
        Write-Host "       -ExportDir $DataDir"
        if ($SecretsFile) { Write-Host "       -SecretsFile $SecretsFile" }
        if ($SyncStorage) { Write-Host "       -SyncStorage" }
    }
    Write-Host ""
    Write-Host "  [DRY RUN] Nenhuma acao executada." -ForegroundColor Cyan
    exit 0
}

# ===================== CONFIRMACAO =====================
Write-Host "  Deseja continuar com a migracao? (y/N)"
$Confirm = Read-Host
if ($Confirm -ne "y" -and $Confirm -ne "Y") {
    Write-Host "  Migracao cancelada."
    exit 0
}

$StartTime = Get-Date

# ===================== PASSO 1: EXPORTAR INFRA ORIGEM =====================
if (-not $SkipInfra) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "  PASSO 1/3: Exportando configuracao da ORIGEM"
    Write-Host "================================================================"
    & "$PSScriptRoot\01_export_origem_config.ps1" `
        -Subscription $OrigemSubscription `
        -ResourceGroup $OrigemResourceGroup `
        -WorkspaceName $OrigemWorkspace `
        -OutputDir $InfraDir

    # ===================== PASSO 2: CRIAR INFRA DESTINO =====================
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "  PASSO 2/3: Criando infraestrutura no DESTINO"
    Write-Host "================================================================"

    $createArgs = @{
        ConfigFile    = "$InfraDir\migration_config.json"
        Subscription  = $DestinoSubscription
        ResourceGroup = $DestinoResourceGroup
        WorkspaceName = $DestinoWorkspace
        CliProfile    = $DestinoCliProfile
    }
    if ($DestinoVnetName) { $createArgs["VnetName"] = $DestinoVnetName }
    if ($DestinoLocation) { $createArgs["Location"] = $DestinoLocation }
    if ($DestinoVnetAddressSpace) { $createArgs["VnetAddressSpace"] = $DestinoVnetAddressSpace }
    if ($DestinoStorageName) { $createArgs["StorageName"] = $DestinoStorageName }

    & "$PSScriptRoot\02_create_destino_infra.ps1" @createArgs
}
else {
    Write-Host ""
    Write-Host "  [SKIP] Criacao de infra pulada (-SkipInfra)" -ForegroundColor Yellow
}

# ===================== PASSO 3: MIGRAR DADOS =====================
if (-not $SkipData) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "  PASSO 3/3: Migrando dados (notebooks, secrets, jobs)"
    Write-Host "================================================================"

    $migrateArgs = @{
        ProfileOrigem  = $OrigemCliProfile
        ProfileDestino = $DestinoCliProfile
        ExportDir      = $DataDir
    }
    if ($SecretsFile) { $migrateArgs["SecretsFile"] = $SecretsFile }
    if ($SyncStorage) { $migrateArgs["SyncStorage"] = $true }

    & "$PSScriptRoot\03_migrate_data.ps1" @migrateArgs
}
else {
    Write-Host ""
    Write-Host "  [SKIP] Migracao de dados pulada (-SkipData)" -ForegroundColor Yellow
}

# ===================== RESUMO FINAL =====================
$EndTime = Get-Date
$Elapsed = $EndTime - $StartTime
$Minutes = [math]::Floor($Elapsed.TotalMinutes)
$Seconds = $Elapsed.Seconds

Write-Host ""
Write-Host "################################################################" -ForegroundColor Green
Write-Host "#  MIGRACAO CONCLUIDA!                                        #" -ForegroundColor Green
Write-Host "################################################################" -ForegroundColor Green
Write-Host ""
Write-Host "  Tempo total: ${Minutes}m ${Seconds}s"
Write-Host "  Export dir:  $ExportDir"
Write-Host ""
Write-Host "  ORIGEM:  $OrigemWorkspace ($OrigemResourceGroup)"
Write-Host "  DESTINO: $DestinoWorkspace ($DestinoResourceGroup)"
Write-Host ""
Write-Host "  Proximos passos:"
Write-Host "    1. Verificar secrets (se migrados com placeholder)"
Write-Host "    2. Validar notebooks importados no DESTINO"
Write-Host "    3. Executar um job de teste no DESTINO"
Write-Host "    4. Configurar scheduling dos jobs"
Write-Host "    5. Atualizar DNS/bookmarks para nova workspace"
Write-Host "    6. Pausar jobs na ORIGEM apos validacao"
Write-Host "    7. Validar dados no storage destino (se sincronizado)"
Write-Host "    8. Atualizar mount points/external locations no DESTINO"
Write-Host "################################################################"
