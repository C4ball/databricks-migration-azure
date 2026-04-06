#!/bin/bash
###############################################################################
# 03_migrate_data.sh
#
# Migra todos os recursos Databricks da workspace ORIGEM para a DESTINO:
#   - Notebooks (export/import)
#   - Secret Scopes e Secrets (recriar)
#   - Jobs (export, limpar IDs, recriar)
#
# Uso:
#   ./03_migrate_data.sh \
#       --profile-origem <profile> \
#       --profile-destino <profile> \
#       [--export-dir <path>]
#       [--secrets-file <path>]  # arquivo com valores dos secrets
#       [--sync-storage]         # habilita sincronizacao de storage ADLS Gen2
#       [--origem-storage-account <name>]   # storage account de origem
#       [--destino-storage-account <name>]  # storage account de destino
###############################################################################
set -euo pipefail

# ===================== PARAMETROS =====================
PROFILE_ORIGEM=""
PROFILE_DESTINO=""
EXPORT_DIR="./migration-export"
SECRETS_FILE=""
SYNC_STORAGE=false
ORIGEM_STORAGE_ACCOUNT=""
DESTINO_STORAGE_ACCOUNT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-origem)          PROFILE_ORIGEM="$2"; shift 2;;
    --profile-destino)         PROFILE_DESTINO="$2"; shift 2;;
    --export-dir)              EXPORT_DIR="$2"; shift 2;;
    --secrets-file)            SECRETS_FILE="$2"; shift 2;;
    --sync-storage)            SYNC_STORAGE=true; shift;;
    --origem-storage-account)  ORIGEM_STORAGE_ACCOUNT="$2"; shift 2;;
    --destino-storage-account) DESTINO_STORAGE_ACCOUNT="$2"; shift 2;;
    *) echo "Parametro desconhecido: $1"; exit 1;;
  esac
done

if [[ -z "$PROFILE_ORIGEM" || -z "$PROFILE_DESTINO" ]]; then
  echo "Uso: $0 --profile-origem <profile> --profile-destino <profile>"
  exit 1
fi

mkdir -p "$EXPORT_DIR"/{notebooks,jobs,secrets}

echo "============================================"
echo " Migracao de Dados Databricks"
echo " Origem:  $PROFILE_ORIGEM"
echo " Destino: $PROFILE_DESTINO"
echo " Export:  $EXPORT_DIR"
echo "============================================"
echo ""

# ===================== VALIDAR CONECTIVIDADE =====================
echo "[0/8] Validando conectividade..."
ORIGEM_HOST=$(databricks auth env --profile "$PROFILE_ORIGEM" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['env']['DATABRICKS_HOST'])")
DESTINO_HOST=$(databricks auth env --profile "$PROFILE_DESTINO" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['env']['DATABRICKS_HOST'])")
echo "  Origem:  $ORIGEM_HOST"
echo "  Destino: $DESTINO_HOST"

# Testar acesso
databricks workspace list / --profile "$PROFILE_ORIGEM" > /dev/null 2>&1 || { echo "ERRO: Nao foi possivel conectar a ORIGEM"; exit 1; }
databricks workspace list / --profile "$PROFILE_DESTINO" > /dev/null 2>&1 || { echo "ERRO: Nao foi possivel conectar ao DESTINO"; exit 1; }
echo "  Conectividade OK!"
echo ""

###########################################################################
# FASE 1: NOTEBOOKS
###########################################################################
echo "============================================"
echo " FASE 1: Migrar Notebooks"
echo "============================================"

echo "[1/8] Exportando notebooks da ORIGEM..."
databricks workspace export-dir / "$EXPORT_DIR/notebooks" \
  --profile "$PROFILE_ORIGEM" \
  --overwrite 2>&1 | tail -5
NOTEBOOK_COUNT=$(find "$EXPORT_DIR/notebooks" -type f -name "*.py" -o -name "*.sql" -o -name "*.scala" -o -name "*.r" 2>/dev/null | wc -l | tr -d ' ')
echo "  Exportados: $NOTEBOOK_COUNT notebooks"

echo "[2/8] Importando notebooks no DESTINO..."
databricks workspace import-dir "$EXPORT_DIR/notebooks" / \
  --profile "$PROFILE_DESTINO" \
  --overwrite 2>&1 | tail -5
echo "  Notebooks importados!"

# Verificar
echo "  Verificando..."
echo "  ORIGEM:"
databricks workspace list /Shared --profile "$PROFILE_ORIGEM" 2>/dev/null | sed 's/^/    /'
echo "  DESTINO:"
databricks workspace list /Shared --profile "$PROFILE_DESTINO" 2>/dev/null | sed 's/^/    /'
echo ""

###########################################################################
# FASE 2: SECRET SCOPES
###########################################################################
echo "============================================"
echo " FASE 2: Migrar Secret Scopes"
echo "============================================"

echo "[3/8] Exportando secret scopes da ORIGEM..."
databricks secrets list-scopes --profile "$PROFILE_ORIGEM" --output json > "$EXPORT_DIR/secrets/scopes.json" 2>/dev/null

SCOPE_COUNT=$(python3 -c "
import json
with open('$EXPORT_DIR/secrets/scopes.json') as f:
    data = json.load(f)
scopes = data.get('scopes', data) if isinstance(data, dict) else data
print(len(scopes) if isinstance(scopes, list) else 0)
" 2>/dev/null || echo "0")

echo "  Scopes encontrados: $SCOPE_COUNT"

if [[ "$SCOPE_COUNT" -gt 0 ]]; then
  # Extrair nomes dos scopes
  SCOPE_NAMES=$(python3 -c "
import json
with open('$EXPORT_DIR/secrets/scopes.json') as f:
    data = json.load(f)
scopes = data.get('scopes', data) if isinstance(data, dict) else data
if isinstance(scopes, list):
    for s in scopes:
        name = s.get('name', s) if isinstance(s, dict) else s
        print(name)
" 2>/dev/null)

  for scope_name in $SCOPE_NAMES; do
    echo ""
    echo "  Scope: $scope_name"

    # Listar secrets neste scope
    databricks secrets list-secrets "$scope_name" --profile "$PROFILE_ORIGEM" --output json \
      > "$EXPORT_DIR/secrets/keys_${scope_name}.json" 2>/dev/null

    SECRET_KEYS=$(python3 -c "
import json
with open('$EXPORT_DIR/secrets/keys_${scope_name}.json') as f:
    data = json.load(f)
if isinstance(data, list):
    for s in data:
        print(s.get('key', '') if isinstance(s, dict) else s)
elif isinstance(data, dict):
    for s in data.get('secrets', []):
        print(s.get('key', '') if isinstance(s, dict) else s)
" 2>/dev/null)

    # Criar scope no destino
    echo "    Criando scope no DESTINO..."
    databricks secrets create-scope "$scope_name" --profile "$PROFILE_DESTINO" 2>/dev/null || \
      echo "    (Scope ja existe ou erro ao criar)"

    # Recriar secrets
    for key in $SECRET_KEYS; do
      echo "    Secret: $key"

      # Tentar ler valor do arquivo de secrets (se fornecido)
      SECRET_VALUE=""
      if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
        SECRET_VALUE=$(python3 -c "
import json
with open('$SECRETS_FILE') as f:
    data = json.load(f)
print(data.get('$scope_name', {}).get('$key', ''))
" 2>/dev/null || true)
      fi

      if [[ -n "$SECRET_VALUE" ]]; then
        databricks secrets put-secret "$scope_name" "$key" \
          --string-value "$SECRET_VALUE" \
          --profile "$PROFILE_DESTINO" 2>/dev/null
        echo "      -> Migrado com valor do arquivo de secrets"
      else
        # Secret values nao sao exportaveis - usar placeholder
        databricks secrets put-secret "$scope_name" "$key" \
          --string-value "PLACEHOLDER_MIGRATE_ME_$(date +%s)" \
          --profile "$PROFILE_DESTINO" 2>/dev/null
        echo "      -> Criado com PLACEHOLDER (valor original nao exportavel!)"
      fi
    done
  done

  echo ""
  echo "  ATENCAO: Valores de secrets NAO sao exportaveis pela API."
  echo "  Secrets criados com placeholder devem ser atualizados manualmente."
  if [[ -z "$SECRETS_FILE" ]]; then
    echo "  Dica: use --secrets-file com um JSON no formato:"
    echo '  {"scope_name": {"key1": "valor1", "key2": "valor2"}}'
  fi
fi
echo ""

###########################################################################
# FASE 3: JOBS
###########################################################################
echo "============================================"
echo " FASE 3: Migrar Jobs"
echo "============================================"

echo "[4/8] Exportando jobs da ORIGEM..."
databricks jobs list --profile "$PROFILE_ORIGEM" --output json > "$EXPORT_DIR/jobs/jobs_list.json" 2>/dev/null

JOB_COUNT=$(python3 -c "
import json
with open('$EXPORT_DIR/jobs/jobs_list.json') as f:
    data = json.load(f)
jobs = data.get('jobs', data) if isinstance(data, dict) else data
print(len(jobs) if isinstance(jobs, list) else 0)
" 2>/dev/null || echo "0")

echo "  Jobs encontrados: $JOB_COUNT"

if [[ "$JOB_COUNT" -gt 0 ]]; then
  # Extrair IDs dos jobs
  JOB_IDS=$(python3 -c "
import json
with open('$EXPORT_DIR/jobs/jobs_list.json') as f:
    data = json.load(f)
jobs = data.get('jobs', data) if isinstance(data, dict) else data
if isinstance(jobs, list):
    for j in jobs:
        print(j.get('job_id', ''))
" 2>/dev/null)

  echo "[5/8] Exportando definicoes completas dos jobs..."
  for job_id in $JOB_IDS; do
    if [[ -n "$job_id" ]]; then
      databricks jobs get "$job_id" --profile "$PROFILE_ORIGEM" --output json \
        > "$EXPORT_DIR/jobs/job_${job_id}.json" 2>/dev/null
      JOB_NAME=$(python3 -c "
import json
with open('$EXPORT_DIR/jobs/job_${job_id}.json') as f:
    d = json.load(f)
print(d.get('settings',{}).get('name', d.get('name','unknown')))
" 2>/dev/null)
      echo "    Job $job_id: $JOB_NAME"
    fi
  done

  echo "[6/8] Limpando e recriando jobs no DESTINO..."
  for job_id in $JOB_IDS; do
    if [[ -n "$job_id" && -f "$EXPORT_DIR/jobs/job_${job_id}.json" ]]; then
      # Limpar campos read-only e extrair settings
      python3 << PYEOF
import json

with open("$EXPORT_DIR/jobs/job_${job_id}.json") as f:
    job = json.load(f)

# Extrair settings (a parte que pode ser reutilizada)
settings = job.get("settings", job)

# Remover campos que nao podem ser migrados
readonly_fields = [
    "job_id", "created_time", "creator_user_name", "run_as_user_name",
    "run_as", "effective_budget_policy_id", "budget_policy_id",
    "deployment", "edit_mode"
]
for field in readonly_fields:
    settings.pop(field, None)
    job.pop(field, None)

# Remover cluster IDs existentes (serao recriados)
# Manter new_cluster configs mas remover existing_cluster_id
def clean_tasks(tasks):
    if not tasks:
        return tasks
    for task in tasks:
        task.pop("existing_cluster_id", None)
        task.pop("run_if", None)
        # Limpar sub-tasks recursivamente
        if "depends_on" in task:
            for dep in task["depends_on"]:
                dep.pop("outcome", None)
    return tasks

if "tasks" in settings:
    settings["tasks"] = clean_tasks(settings["tasks"])

with open("$EXPORT_DIR/jobs/job_${job_id}_clean.json", "w") as f:
    json.dump(settings, f, indent=2)
PYEOF

      JOB_NAME=$(python3 -c "import json; print(json.load(open('$EXPORT_DIR/jobs/job_${job_id}_clean.json')).get('name','unknown'))" 2>/dev/null)

      # Criar job no destino
      NEW_JOB=$(databricks jobs create --json @"$EXPORT_DIR/jobs/job_${job_id}_clean.json" \
        --profile "$PROFILE_DESTINO" 2>/dev/null)
      NEW_JOB_ID=$(echo "$NEW_JOB" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id','?'))" 2>/dev/null || echo "?")
      echo "    $JOB_NAME: ORIGEM=$job_id -> DESTINO=$NEW_JOB_ID"

      # Salvar mapeamento
      echo "$job_id,$NEW_JOB_ID,$JOB_NAME" >> "$EXPORT_DIR/jobs/job_id_mapping.csv"
    fi
  done
else
  echo "[5/8] Nenhum job para exportar."
  echo "[6/8] Pulando..."
fi

###########################################################################
# FASE 4: STORAGE SYNC (ADLS Gen2)
###########################################################################
STORAGE_SYNC_STATUS="Pulado (--sync-storage nao fornecido)"
STORAGE_SYNC_BYTES=""

if [[ "$SYNC_STORAGE" == "true" ]]; then
  echo "============================================"
  echo " FASE 4: Sincronizar Storage ADLS Gen2"
  echo "============================================"

  if [[ -z "$ORIGEM_STORAGE_ACCOUNT" || -z "$DESTINO_STORAGE_ACCOUNT" ]]; then
    echo "  ERRO: --origem-storage-account e --destino-storage-account sao obrigatorios com --sync-storage"
    echo "  Pulando sincronizacao de storage..."
    STORAGE_SYNC_STATUS="Erro: parametros de storage nao fornecidos"
  else
    echo "[7/8] Listando containers e tamanhos na ORIGEM..."
    mkdir -p "$EXPORT_DIR/storage"

    # List containers in source
    CONTAINERS=$(az storage container list \
      --account-name "$ORIGEM_STORAGE_ACCOUNT" \
      --auth-mode login \
      --query "[].name" -o tsv 2>/dev/null || true)

    if [[ -z "$CONTAINERS" ]]; then
      echo "  Nenhum container encontrado na storage de origem."
      STORAGE_SYNC_STATUS="Nenhum container encontrado"
    else
      echo "  Containers encontrados:"
      TOTAL_SIZE=0
      for container in $CONTAINERS; do
        # Get container size (best effort)
        SIZE=$(az storage blob list \
          --account-name "$ORIGEM_STORAGE_ACCOUNT" \
          --container-name "$container" \
          --auth-mode login \
          --query "[].properties.contentLength" -o tsv 2>/dev/null | \
          awk '{s+=$1} END {print s+0}' || echo "0")
        SIZE_MB=$(( SIZE / 1024 / 1024 ))
        echo "    $container: ${SIZE_MB} MB"
        TOTAL_SIZE=$(( TOTAL_SIZE + SIZE ))
      done
      TOTAL_SIZE_GB=$(( TOTAL_SIZE / 1024 / 1024 / 1024 ))
      echo "  Total estimado: ${TOTAL_SIZE_GB} GB"
      echo ""

      echo "[8/8] Sincronizando dados com azcopy..."
      echo "  Origem:  $ORIGEM_STORAGE_ACCOUNT"
      echo "  Destino: $DESTINO_STORAGE_ACCOUNT"
      echo ""

      # Determine authentication method
      # Try Azure AD auth first (azcopy login), fallback to SAS tokens
      AZCOPY_AUTH="aad"
      if ! azcopy list "https://${ORIGEM_STORAGE_ACCOUNT}.blob.core.windows.net/" > /dev/null 2>&1; then
        echo "  Azure AD auth nao disponivel para azcopy, tentando SAS tokens..."
        AZCOPY_AUTH="sas"

        # Generate SAS tokens for source (read) and destination (write)
        SAS_EXPIRY=$(date -u -d "+24 hours" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -v+24H '+%Y-%m-%dT%H:%MZ')

        ORIGEM_SAS=$(az storage account generate-sas \
          --account-name "$ORIGEM_STORAGE_ACCOUNT" \
          --permissions rl \
          --services b \
          --resource-types co \
          --expiry "$SAS_EXPIRY" \
          -o tsv 2>/dev/null || true)

        DESTINO_SAS=$(az storage account generate-sas \
          --account-name "$DESTINO_STORAGE_ACCOUNT" \
          --permissions rwdlac \
          --services b \
          --resource-types co \
          --expiry "$SAS_EXPIRY" \
          -o tsv 2>/dev/null || true)

        if [[ -z "$ORIGEM_SAS" || -z "$DESTINO_SAS" ]]; then
          echo "  ERRO: Nao foi possivel gerar SAS tokens. Verifique permissoes."
          STORAGE_SYNC_STATUS="Erro: falha ao gerar SAS tokens"
          SYNC_STORAGE=false
        fi
      fi

      if [[ "$SYNC_STORAGE" == "true" ]]; then
        SYNC_ERRORS=0
        SYNC_SUCCESS=0

        for container in $CONTAINERS; do
          echo ""
          echo "  Sincronizando container: $container ..."

          if [[ "$AZCOPY_AUTH" == "aad" ]]; then
            SRC_URL="https://${ORIGEM_STORAGE_ACCOUNT}.blob.core.windows.net/${container}"
            DST_URL="https://${DESTINO_STORAGE_ACCOUNT}.blob.core.windows.net/${container}"
          else
            SRC_URL="https://${ORIGEM_STORAGE_ACCOUNT}.blob.core.windows.net/${container}?${ORIGEM_SAS}"
            DST_URL="https://${DESTINO_STORAGE_ACCOUNT}.blob.core.windows.net/${container}?${DESTINO_SAS}"
          fi

          if azcopy sync "$SRC_URL" "$DST_URL" --recursive=true 2>&1 | tee -a "$EXPORT_DIR/storage/azcopy_${container}.log" | tail -5; then
            SYNC_SUCCESS=$((SYNC_SUCCESS + 1))
            echo "    Container $container: OK"
          else
            SYNC_ERRORS=$((SYNC_ERRORS + 1))
            echo "    Container $container: ERRO (ver log: $EXPORT_DIR/storage/azcopy_${container}.log)"
          fi
        done

        STORAGE_SYNC_STATUS="Completo (sucesso: $SYNC_SUCCESS, erros: $SYNC_ERRORS)"
        STORAGE_SYNC_BYTES="${TOTAL_SIZE_GB} GB transferidos (estimado)"
      fi
    fi
  fi
else
  echo ""
  echo "============================================"
  echo " FASE 4: Sincronizar Storage ADLS Gen2"
  echo "============================================"
  echo "  Pulado (use --sync-storage para habilitar)"
fi

###########################################################################
# RESUMO FINAL
###########################################################################
echo ""
echo "============================================"
echo " Migracao Concluida!"
echo "============================================"
echo ""
echo " NOTEBOOKS:"
echo "   Exportados: $NOTEBOOK_COUNT"
echo "   Importados no DESTINO: OK"
echo ""
echo " SECRET SCOPES:"
echo "   Scopes migrados: $SCOPE_COUNT"
if [[ -z "$SECRETS_FILE" ]]; then
echo "   ATENCAO: Valores com PLACEHOLDER - atualizar manualmente!"
fi
echo ""
echo " JOBS:"
echo "   Jobs migrados: $JOB_COUNT"
if [[ -f "$EXPORT_DIR/jobs/job_id_mapping.csv" ]]; then
echo "   Mapeamento de IDs: $EXPORT_DIR/jobs/job_id_mapping.csv"
echo ""
echo "   ID Mapping (ORIGEM -> DESTINO):"
cat "$EXPORT_DIR/jobs/job_id_mapping.csv" | while IFS=',' read -r old new name; do
  echo "     $name: $old -> $new"
done
fi
echo ""
echo " STORAGE SYNC:"
echo "   Status: $STORAGE_SYNC_STATUS"
if [[ -n "$STORAGE_SYNC_BYTES" ]]; then
echo "   Volume: $STORAGE_SYNC_BYTES"
fi
if [[ "$SYNC_STORAGE" == "true" && -n "$ORIGEM_STORAGE_ACCOUNT" ]]; then
echo "   Origem:  $ORIGEM_STORAGE_ACCOUNT"
echo "   Destino: $DESTINO_STORAGE_ACCOUNT"
echo "   Logs:    $EXPORT_DIR/storage/"
fi
echo ""
echo " Arquivos exportados em: $EXPORT_DIR/"
echo ""
echo " Proximos passos:"
echo "   1. Atualizar valores de secrets com os valores reais"
echo "   2. Validar notebooks importados no DESTINO"
echo "   3. Executar um job de teste no DESTINO"
echo "   4. Verificar conectividade de rede e storage"
if [[ "$SYNC_STORAGE" != "true" ]]; then
echo "   5. Sincronizar storage com --sync-storage (se necessario)"
fi
echo "============================================"
