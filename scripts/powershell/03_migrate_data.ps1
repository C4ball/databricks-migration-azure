<#
.SYNOPSIS
    Migrates all Databricks resources from the source workspace to the destination.

.DESCRIPTION
    Migrates the following Databricks resources from ORIGEM to DESTINO:
      - Notebooks (export/import)
      - Secret Scopes and Secrets (recreate)
      - Jobs (export, clean IDs, recreate)

.PARAMETER ProfileOrigem
    Databricks CLI profile for the source workspace.

.PARAMETER ProfileDestino
    Databricks CLI profile for the destination workspace.

.PARAMETER ExportDir
    Directory for export files. Defaults to './migration-export'.

.PARAMETER SecretsFile
    Optional JSON file with secret values for migration.
    Format: {"scope_name": {"key1": "valor1", "key2": "valor2"}}

.EXAMPLE
    .\03_migrate_data.ps1 `
        -ProfileOrigem "prod-origem" `
        -ProfileDestino "prod-destino" `
        -ExportDir "./migration-export" `
        -SecretsFile "./secrets.json"
#>

param(
    [Parameter(Mandatory)]
    [string]$ProfileOrigem,

    [Parameter(Mandatory)]
    [string]$ProfileDestino,

    [string]$ExportDir = "./migration-export",

    [string]$SecretsFile = ""
)

$ErrorActionPreference = "Stop"

# ===================== CREATE EXPORT DIRS =====================
foreach ($subDir in @("notebooks", "jobs", "secrets")) {
    $path = Join-Path $ExportDir $subDir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

Write-Host "============================================"
Write-Host " Migracao de Dados Databricks"
Write-Host " Origem:  $ProfileOrigem"
Write-Host " Destino: $ProfileDestino"
Write-Host " Export:  $ExportDir"
Write-Host "============================================"
Write-Host ""

# ===================== VALIDAR CONECTIVIDADE =====================
Write-Host "[0/6] Validando conectividade..."

$origemEnvRaw = databricks auth env --profile $ProfileOrigem 2>$null
$origemEnv = $origemEnvRaw | ConvertFrom-Json
$OrigemHost = $origemEnv.env.DATABRICKS_HOST

$destinoEnvRaw = databricks auth env --profile $ProfileDestino 2>$null
$destinoEnv = $destinoEnvRaw | ConvertFrom-Json
$DestinoHost = $destinoEnv.env.DATABRICKS_HOST

Write-Host "  Origem:  $OrigemHost"
Write-Host "  Destino: $DestinoHost"

# Testar acesso
try {
    databricks workspace list / --profile $ProfileOrigem 2>$null | Out-Null
}
catch {
    Write-Host "ERRO: Nao foi possivel conectar a ORIGEM" -ForegroundColor Red
    exit 1
}

try {
    databricks workspace list / --profile $ProfileDestino 2>$null | Out-Null
}
catch {
    Write-Host "ERRO: Nao foi possivel conectar ao DESTINO" -ForegroundColor Red
    exit 1
}

Write-Host "  Conectividade OK!"
Write-Host ""

###########################################################################
# FASE 1: NOTEBOOKS
###########################################################################
Write-Host "============================================"
Write-Host " FASE 1: Migrar Notebooks"
Write-Host "============================================"

Write-Host "[1/6] Exportando notebooks da ORIGEM..."
$exportOutput = databricks workspace export-dir / "$ExportDir/notebooks" `
    --profile $ProfileOrigem `
    --overwrite 2>&1
# Show last 5 lines of output
$exportLines = ($exportOutput -split "`n")
$exportLines | Select-Object -Last 5 | ForEach-Object { Write-Host $_ }

$notebookFiles = Get-ChildItem -Path "$ExportDir/notebooks" -Recurse -File -Include "*.py", "*.sql", "*.scala", "*.r" -ErrorAction SilentlyContinue
$NotebookCount = if ($notebookFiles) { $notebookFiles.Count } else { 0 }
Write-Host "  Exportados: $NotebookCount notebooks"

Write-Host "[2/6] Importando notebooks no DESTINO..."
$importOutput = databricks workspace import-dir "$ExportDir/notebooks" / `
    --profile $ProfileDestino `
    --overwrite 2>&1
$importLines = ($importOutput -split "`n")
$importLines | Select-Object -Last 5 | ForEach-Object { Write-Host $_ }
Write-Host "  Notebooks importados!"

# Verificar
Write-Host "  Verificando..."
Write-Host "  ORIGEM:"
try {
    $origemList = databricks workspace list /Shared --profile $ProfileOrigem 2>$null
    $origemList -split "`n" | ForEach-Object { Write-Host "    $_" }
}
catch { }

Write-Host "  DESTINO:"
try {
    $destinoList = databricks workspace list /Shared --profile $ProfileDestino 2>$null
    $destinoList -split "`n" | ForEach-Object { Write-Host "    $_" }
}
catch { }
Write-Host ""

###########################################################################
# FASE 2: SECRET SCOPES
###########################################################################
Write-Host "============================================"
Write-Host " FASE 2: Migrar Secret Scopes"
Write-Host "============================================"

Write-Host "[3/6] Exportando secret scopes da ORIGEM..."
try {
    databricks secrets list-scopes --profile $ProfileOrigem --output json | Out-File -FilePath "$ExportDir/secrets/scopes.json" -Encoding utf8 2>$null
}
catch {
    "[]" | Out-File -FilePath "$ExportDir/secrets/scopes.json" -Encoding utf8
}

$scopesData = Get-Content "$ExportDir/secrets/scopes.json" -Raw | ConvertFrom-Json

# Handle both formats: {scopes: [...]} or [...]
$scopes = if ($scopesData -is [System.Collections.IEnumerable] -and $scopesData -isnot [string]) {
    if ($scopesData.scopes) { $scopesData.scopes } else { $scopesData }
}
else {
    @()
}

# Ensure it is an array
if ($scopes -isnot [array]) { $scopes = @($scopes) }
$ScopeCount = $scopes.Count

Write-Host "  Scopes encontrados: $ScopeCount"

if ($ScopeCount -gt 0) {
    foreach ($scope in $scopes) {
        $scopeName = if ($scope -is [string]) { $scope } else { $scope.name }

        Write-Host ""
        Write-Host "  Scope: $scopeName"

        # Listar secrets neste scope
        try {
            databricks secrets list-secrets $scopeName --profile $ProfileOrigem --output json | Out-File -FilePath "$ExportDir/secrets/keys_${scopeName}.json" -Encoding utf8 2>$null
        }
        catch {
            "[]" | Out-File -FilePath "$ExportDir/secrets/keys_${scopeName}.json" -Encoding utf8
        }

        $keysData = Get-Content "$ExportDir/secrets/keys_${scopeName}.json" -Raw | ConvertFrom-Json

        # Handle both formats: {secrets: [...]} or [...]
        $secretKeys = if ($keysData -is [System.Collections.IEnumerable] -and $keysData -isnot [string]) {
            if ($keysData.secrets) { $keysData.secrets } else { $keysData }
        }
        else {
            @()
        }
        if ($secretKeys -isnot [array]) { $secretKeys = @($secretKeys) }

        # Criar scope no destino
        Write-Host "    Criando scope no DESTINO..."
        try {
            databricks secrets create-scope $scopeName --profile $ProfileDestino 2>$null
        }
        catch {
            Write-Host "    (Scope ja existe ou erro ao criar)"
        }

        # Recriar secrets
        foreach ($secretItem in $secretKeys) {
            $key = if ($secretItem -is [string]) { $secretItem } else { $secretItem.key }
            Write-Host "    Secret: $key"

            # Tentar ler valor do arquivo de secrets (se fornecido)
            $secretValue = ""
            if ($SecretsFile -and (Test-Path $SecretsFile)) {
                try {
                    $secretsData = Get-Content $SecretsFile -Raw | ConvertFrom-Json
                    $scopeSecrets = $secretsData.$scopeName
                    if ($scopeSecrets -and $scopeSecrets.$key) {
                        $secretValue = $scopeSecrets.$key
                    }
                }
                catch { }
            }

            if ($secretValue) {
                databricks secrets put-secret $scopeName $key `
                    --string-value $secretValue `
                    --profile $ProfileDestino 2>$null
                Write-Host "      -> Migrado com valor do arquivo de secrets"
            }
            else {
                # Secret values nao sao exportaveis - usar placeholder
                $timestamp = [int][double]::Parse((Get-Date -UFormat %s))
                databricks secrets put-secret $scopeName $key `
                    --string-value "PLACEHOLDER_MIGRATE_ME_$timestamp" `
                    --profile $ProfileDestino 2>$null
                Write-Host "      -> Criado com PLACEHOLDER (valor original nao exportavel!)"
            }
        }
    }

    Write-Host ""
    Write-Host "  ATENCAO: Valores de secrets NAO sao exportaveis pela API." -ForegroundColor Yellow
    Write-Host "  Secrets criados com placeholder devem ser atualizados manualmente." -ForegroundColor Yellow
    if (-not $SecretsFile) {
        Write-Host '  Dica: use -SecretsFile com um JSON no formato:'
        Write-Host '  {"scope_name": {"key1": "valor1", "key2": "valor2"}}'
    }
}
Write-Host ""

###########################################################################
# FASE 3: JOBS
###########################################################################
Write-Host "============================================"
Write-Host " FASE 3: Migrar Jobs"
Write-Host "============================================"

Write-Host "[4/6] Exportando jobs da ORIGEM..."
try {
    databricks jobs list --profile $ProfileOrigem --output json | Out-File -FilePath "$ExportDir/jobs/jobs_list.json" -Encoding utf8 2>$null
}
catch {
    "[]" | Out-File -FilePath "$ExportDir/jobs/jobs_list.json" -Encoding utf8
}

$jobsData = Get-Content "$ExportDir/jobs/jobs_list.json" -Raw | ConvertFrom-Json

# Handle both formats: {jobs: [...]} or [...]
$jobs = if ($jobsData -is [System.Collections.IEnumerable] -and $jobsData -isnot [string]) {
    if ($jobsData.jobs) { $jobsData.jobs } else { $jobsData }
}
else {
    @()
}
if ($jobs -isnot [array]) { $jobs = @($jobs) }
$JobCount = $jobs.Count

Write-Host "  Jobs encontrados: $JobCount"

if ($JobCount -gt 0) {
    # Extrair IDs dos jobs
    $jobIds = @()
    foreach ($job in $jobs) {
        if ($job.job_id) { $jobIds += $job.job_id }
    }

    Write-Host "[5/6] Exportando definicoes completas dos jobs..."
    foreach ($jobId in $jobIds) {
        if ($jobId) {
            databricks jobs get $jobId --profile $ProfileOrigem --output json | Out-File -FilePath "$ExportDir/jobs/job_${jobId}.json" -Encoding utf8 2>$null
            $jobDetail = Get-Content "$ExportDir/jobs/job_${jobId}.json" -Raw | ConvertFrom-Json
            $jobName = if ($jobDetail.settings -and $jobDetail.settings.name) { $jobDetail.settings.name } elseif ($jobDetail.name) { $jobDetail.name } else { "unknown" }
            Write-Host "    Job ${jobId}: $jobName"
        }
    }

    Write-Host "[6/6] Limpando e recriando jobs no DESTINO..."
    foreach ($jobId in $jobIds) {
        $jobFilePath = "$ExportDir/jobs/job_${jobId}.json"
        if ($jobId -and (Test-Path $jobFilePath)) {
            # Limpar campos read-only e extrair settings
            $jobData = Get-Content $jobFilePath -Raw | ConvertFrom-Json
            $settings = if ($jobData.settings) { $jobData.settings } else { $jobData }

            # Remover campos que nao podem ser migrados
            $readonlyFields = @(
                "job_id", "created_time", "creator_user_name", "run_as_user_name",
                "run_as", "effective_budget_policy_id", "budget_policy_id",
                "deployment", "edit_mode"
            )

            # Convert to hashtable for easier manipulation
            $settingsHash = @{}
            $settings.PSObject.Properties | ForEach-Object {
                $settingsHash[$_.Name] = $_.Value
            }

            foreach ($field in $readonlyFields) {
                $settingsHash.Remove($field)
            }

            # Remover cluster IDs existentes e limpar tasks
            if ($settingsHash.ContainsKey("tasks") -and $settingsHash["tasks"]) {
                foreach ($task in $settingsHash["tasks"]) {
                    # Remove existing_cluster_id
                    if ($task.PSObject.Properties["existing_cluster_id"]) {
                        $task.PSObject.Properties.Remove("existing_cluster_id")
                    }
                    # Remove run_if
                    if ($task.PSObject.Properties["run_if"]) {
                        $task.PSObject.Properties.Remove("run_if")
                    }
                    # Limpar depends_on
                    if ($task.depends_on) {
                        foreach ($dep in $task.depends_on) {
                            if ($dep.PSObject.Properties["outcome"]) {
                                $dep.PSObject.Properties.Remove("outcome")
                            }
                        }
                    }
                }
            }

            $cleanFilePath = "$ExportDir/jobs/job_${jobId}_clean.json"
            $settingsHash | ConvertTo-Json -Depth 20 | Out-File -FilePath $cleanFilePath -Encoding utf8

            $cleanData = Get-Content $cleanFilePath -Raw | ConvertFrom-Json
            $jobName = if ($cleanData.name) { $cleanData.name } else { "unknown" }

            # Criar job no destino
            try {
                $newJobRaw = databricks jobs create --json "@$cleanFilePath" --profile $ProfileDestino 2>$null
                $newJob = $newJobRaw | ConvertFrom-Json
                $newJobId = if ($newJob.job_id) { $newJob.job_id } else { "?" }
            }
            catch {
                $newJobId = "?"
            }

            Write-Host "    ${jobName}: ORIGEM=$jobId -> DESTINO=$newJobId"

            # Salvar mapeamento
            "$jobId,$newJobId,$jobName" | Out-File -FilePath "$ExportDir/jobs/job_id_mapping.csv" -Append -Encoding utf8
        }
    }
}
else {
    Write-Host "[5/6] Nenhum job para exportar."
    Write-Host "[6/6] Pulando..."
}

###########################################################################
# RESUMO FINAL
###########################################################################
Write-Host ""
Write-Host "============================================"
Write-Host " Migracao Concluida!" -ForegroundColor Green
Write-Host "============================================"
Write-Host ""
Write-Host " NOTEBOOKS:"
Write-Host "   Exportados: $NotebookCount"
Write-Host "   Importados no DESTINO: OK"
Write-Host ""
Write-Host " SECRET SCOPES:"
Write-Host "   Scopes migrados: $ScopeCount"
if (-not $SecretsFile) {
    Write-Host "   ATENCAO: Valores com PLACEHOLDER - atualizar manualmente!" -ForegroundColor Yellow
}
Write-Host ""
Write-Host " JOBS:"
Write-Host "   Jobs migrados: $JobCount"
$mappingFile = "$ExportDir/jobs/job_id_mapping.csv"
if (Test-Path $mappingFile) {
    Write-Host "   Mapeamento de IDs: $mappingFile"
    Write-Host ""
    Write-Host "   ID Mapping (ORIGEM -> DESTINO):"
    Get-Content $mappingFile | ForEach-Object {
        $parts = $_ -split ","
        if ($parts.Count -ge 3) {
            $old = $parts[0]
            $new = $parts[1]
            $name = $parts[2]
            Write-Host "     ${name}: $old -> $new"
        }
    }
}
Write-Host ""
Write-Host " Arquivos exportados em: $ExportDir/"
Write-Host ""
Write-Host " Proximos passos:"
Write-Host "   1. Atualizar valores de secrets com os valores reais"
Write-Host "   2. Validar notebooks importados no DESTINO"
Write-Host "   3. Executar um job de teste no DESTINO"
Write-Host "   4. Verificar conectividade de rede e storage"
Write-Host "============================================"
