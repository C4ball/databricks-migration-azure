#!/bin/bash
###############################################################################
# migrate.sh
#
# Script principal de migracao de Databricks Workspace entre Contas Azure.
# Orquestra os 3 scripts de migracao em sequencia:
#   1. Exporta configuracao de infra da ORIGEM
#   2. Recria infra na DESTINO (VNet, PE, DNS, Workspace)
#   3. Migra dados (notebooks, secrets, jobs)
#
# Todos os parametros de ORIGEM e DESTINO sao passados por linha de comando.
#
# Uso:
#   ./migrate.sh \
#       --origem-subscription <sub-id> \
#       --origem-resource-group <rg> \
#       --origem-workspace <ws-name> \
#       --origem-cli-profile <profile> \
#       --destino-subscription <sub-id> \
#       --destino-resource-group <rg> \
#       --destino-workspace <ws-name> \
#       --destino-cli-profile <profile> \
#       [--destino-vnet-name <vnet>] \
#       [--destino-location <region>] \
#       [--destino-vnet-address-space <cidr>] \
#       [--secrets-file <path>] \
#       [--export-dir <path>] \
#       [--destino-storage-name <name>]  # nome custom para storage account destino
#       [--sync-storage]      # habilita sincronizacao de storage ADLS Gen2
#       [--skip-infra]        # Pula criacao de infra (se ja foi criada)
#       [--skip-data]         # Pula migracao de dados
#       [--dry-run]           # Apenas mostra o que seria feito
#
# Exemplos:
#
#   # Migracao completa (infra + dados)
#   ./migrate.sh \
#       --origem-subscription "aaaa-bbbb-cccc" \
#       --origem-resource-group "rg-prod" \
#       --origem-workspace "dbw-prod" \
#       --origem-cli-profile "prod-origem" \
#       --destino-subscription "dddd-eeee-ffff" \
#       --destino-resource-group "rg-prod-new" \
#       --destino-workspace "dbw-prod-new" \
#       --destino-cli-profile "prod-destino" \
#       --secrets-file ./secrets.json
#
#   # Apenas migrar dados (infra ja existe)
#   ./migrate.sh \
#       --origem-subscription "aaaa-bbbb-cccc" \
#       --origem-resource-group "rg-prod" \
#       --origem-workspace "dbw-prod" \
#       --origem-cli-profile "prod-origem" \
#       --destino-subscription "dddd-eeee-ffff" \
#       --destino-resource-group "rg-prod-new" \
#       --destino-workspace "dbw-prod-new" \
#       --destino-cli-profile "prod-destino" \
#       --skip-infra
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================== PARAMETROS =====================
ORIGEM_SUBSCRIPTION=""
ORIGEM_RG=""
ORIGEM_WS=""
ORIGEM_PROFILE=""

DESTINO_SUBSCRIPTION=""
DESTINO_RG=""
DESTINO_WS=""
DESTINO_PROFILE=""
DESTINO_VNET=""
DESTINO_LOCATION=""
DESTINO_VNET_CIDR=""

SECRETS_FILE=""
EXPORT_DIR="${SCRIPT_DIR}/export-$(date +%Y%m%d-%H%M%S)"
DESTINO_STORAGE_NAME=""
SYNC_STORAGE=false
SKIP_INFRA=false
SKIP_DATA=false
DRY_RUN=false

show_help() {
  cat << 'HELPEOF'
Uso: ./migrate.sh [opcoes]

PARAMETROS OBRIGATORIOS - ORIGEM:
  --origem-subscription <id>       Azure Subscription ID da conta origem
  --origem-resource-group <name>   Resource Group da workspace origem
  --origem-workspace <name>        Nome da workspace Databricks origem
  --origem-cli-profile <profile>   Profile do Databricks CLI para a origem

PARAMETROS OBRIGATORIOS - DESTINO:
  --destino-subscription <id>      Azure Subscription ID da conta destino
  --destino-resource-group <name>  Resource Group para a workspace destino
  --destino-workspace <name>       Nome da workspace Databricks destino
  --destino-cli-profile <profile>  Profile do Databricks CLI para o destino

PARAMETROS OPCIONAIS - DESTINO:
  --destino-vnet-name <name>       Nome da VNet no destino (default: vnet-<workspace>)
  --destino-location <region>      Regiao Azure (default: herda da origem)
  --destino-vnet-address-space <c> CIDR da VNet (default: herda da origem)

PARAMETROS OPCIONAIS - STORAGE:
  --destino-storage-name <name>    Nome custom para storage account destino
  --sync-storage                   Habilita sincronizacao de dados ADLS Gen2

PARAMETROS OPCIONAIS - GERAL:
  --secrets-file <path>            JSON com valores dos secrets para migrar
  --export-dir <path>              Diretorio para exportacao (default: auto-gerado)
  --skip-infra                     Pula criacao de infra (workspace ja existe)
  --skip-data                      Pula migracao de dados (apenas infra)
  --dry-run                        Mostra o plano sem executar
  --help                           Mostra esta ajuda

FORMATO DO SECRETS FILE:
  {
    "scope_name": {
      "key1": "valor1",
      "key2": "valor2"
    }
  }
HELPEOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --origem-subscription)      ORIGEM_SUBSCRIPTION="$2"; shift 2;;
    --origem-resource-group)    ORIGEM_RG="$2"; shift 2;;
    --origem-workspace)         ORIGEM_WS="$2"; shift 2;;
    --origem-cli-profile)       ORIGEM_PROFILE="$2"; shift 2;;
    --destino-subscription)     DESTINO_SUBSCRIPTION="$2"; shift 2;;
    --destino-resource-group)   DESTINO_RG="$2"; shift 2;;
    --destino-workspace)        DESTINO_WS="$2"; shift 2;;
    --destino-cli-profile)      DESTINO_PROFILE="$2"; shift 2;;
    --destino-vnet-name)        DESTINO_VNET="$2"; shift 2;;
    --destino-location)         DESTINO_LOCATION="$2"; shift 2;;
    --destino-vnet-address-space) DESTINO_VNET_CIDR="$2"; shift 2;;
    --secrets-file)             SECRETS_FILE="$2"; shift 2;;
    --export-dir)               EXPORT_DIR="$2"; shift 2;;
    --destino-storage-name)     DESTINO_STORAGE_NAME="$2"; shift 2;;
    --sync-storage)             SYNC_STORAGE=true; shift;;
    --skip-infra)               SKIP_INFRA=true; shift;;
    --skip-data)                SKIP_DATA=true; shift;;
    --dry-run)                  DRY_RUN=true; shift;;
    --help|-h)                  show_help; exit 0;;
    *) echo "ERRO: Parametro desconhecido: $1"; echo "Use --help para ver opcoes."; exit 1;;
  esac
done

# ===================== VALIDACAO =====================
ERRORS=()
[[ -z "$ORIGEM_SUBSCRIPTION" ]] && ERRORS+=("--origem-subscription e obrigatorio")
[[ -z "$ORIGEM_RG" ]]           && ERRORS+=("--origem-resource-group e obrigatorio")
[[ -z "$ORIGEM_WS" ]]           && ERRORS+=("--origem-workspace e obrigatorio")
[[ -z "$ORIGEM_PROFILE" ]]      && ERRORS+=("--origem-cli-profile e obrigatorio")
[[ -z "$DESTINO_SUBSCRIPTION" ]] && ERRORS+=("--destino-subscription e obrigatorio")
[[ -z "$DESTINO_RG" ]]          && ERRORS+=("--destino-resource-group e obrigatorio")
[[ -z "$DESTINO_WS" ]]          && ERRORS+=("--destino-workspace e obrigatorio")
[[ -z "$DESTINO_PROFILE" ]]     && ERRORS+=("--destino-cli-profile e obrigatorio")

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "ERRO: Parametros faltando:"
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  echo ""
  echo "Use --help para ver todos os parametros."
  exit 1
fi

if [[ -n "$SECRETS_FILE" && ! -f "$SECRETS_FILE" ]]; then
  echo "ERRO: Arquivo de secrets nao encontrado: $SECRETS_FILE"
  exit 1
fi

# ===================== PLANO =====================
INFRA_DIR="${EXPORT_DIR}/infra"
DATA_DIR="${EXPORT_DIR}/data"
mkdir -p "$INFRA_DIR" "$DATA_DIR"

echo ""
echo "################################################################"
echo "#  MIGRACAO DATABRICKS WORKSPACE - AZURE                      #"
echo "################################################################"
echo ""
echo "  ORIGEM:"
echo "    Subscription:   $ORIGEM_SUBSCRIPTION"
echo "    Resource Group: $ORIGEM_RG"
echo "    Workspace:      $ORIGEM_WS"
echo "    CLI Profile:    $ORIGEM_PROFILE"
echo ""
echo "  DESTINO:"
echo "    Subscription:   $DESTINO_SUBSCRIPTION"
echo "    Resource Group: $DESTINO_RG"
echo "    Workspace:      $DESTINO_WS"
echo "    CLI Profile:    $DESTINO_PROFILE"
if [[ -n "$DESTINO_VNET" ]]; then
echo "    VNet Name:      $DESTINO_VNET"
fi
if [[ -n "$DESTINO_LOCATION" ]]; then
echo "    Location:       $DESTINO_LOCATION"
fi
echo ""
echo "  OPCOES:"
echo "    Export Dir:     $EXPORT_DIR"
echo "    Secrets File:   ${SECRETS_FILE:-nao fornecido}"
echo "    Storage Name:   ${DESTINO_STORAGE_NAME:-auto}"
echo "    Sync Storage:   $SYNC_STORAGE"
echo "    Skip Infra:     $SKIP_INFRA"
echo "    Skip Data:      $SKIP_DATA"
echo "    Dry Run:        $DRY_RUN"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [DRY RUN] Plano de execucao:"
  echo ""
  if [[ "$SKIP_INFRA" != "true" ]]; then
    echo "  Passo 1: Exportar configuracao da ORIGEM"
    echo "    -> $SCRIPT_DIR/01_export_origem_config.sh"
    echo "       --subscription $ORIGEM_SUBSCRIPTION"
    echo "       --resource-group $ORIGEM_RG"
    echo "       --workspace-name $ORIGEM_WS"
    echo "       --output-dir $INFRA_DIR"
    echo ""
    echo "  Passo 2: Criar infraestrutura no DESTINO"
    echo "    -> $SCRIPT_DIR/02_create_destino_infra.sh"
    echo "       --config $INFRA_DIR/migration_config.json"
    echo "       --subscription $DESTINO_SUBSCRIPTION"
    echo "       --resource-group $DESTINO_RG"
    echo "       --workspace-name $DESTINO_WS"
    echo "       --cli-profile $DESTINO_PROFILE"
    [[ -n "$DESTINO_VNET" ]] && echo "       --vnet-name $DESTINO_VNET"
    [[ -n "$DESTINO_LOCATION" ]] && echo "       --location $DESTINO_LOCATION"
    [[ -n "$DESTINO_VNET_CIDR" ]] && echo "       --vnet-address-space $DESTINO_VNET_CIDR"
    [[ -n "$DESTINO_STORAGE_NAME" ]] && echo "       --storage-name $DESTINO_STORAGE_NAME"
    echo ""
  fi
  if [[ "$SKIP_DATA" != "true" ]]; then
    echo "  Passo 3: Migrar dados (notebooks, secrets, jobs)"
    echo "    -> $SCRIPT_DIR/03_migrate_data.sh"
    echo "       --profile-origem $ORIGEM_PROFILE"
    echo "       --profile-destino $DESTINO_PROFILE"
    echo "       --export-dir $DATA_DIR"
    [[ -n "$SECRETS_FILE" ]] && echo "       --secrets-file $SECRETS_FILE"
    [[ "$SYNC_STORAGE" == "true" ]] && echo "       --sync-storage"
  fi
  echo ""
  echo "  [DRY RUN] Nenhuma acao executada."
  exit 0
fi

# ===================== CONFIRMACAO =====================
echo "  Deseja continuar com a migracao? (y/N)"
read -r CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "  Migracao cancelada."
  exit 0
fi

START_TIME=$(date +%s)

# ===================== PASSO 1: EXPORTAR INFRA ORIGEM =====================
if [[ "$SKIP_INFRA" != "true" ]]; then
  echo ""
  echo "================================================================"
  echo "  PASSO 1/3: Exportando configuracao da ORIGEM"
  echo "================================================================"
  "$SCRIPT_DIR/01_export_origem_config.sh" \
    --subscription "$ORIGEM_SUBSCRIPTION" \
    --resource-group "$ORIGEM_RG" \
    --workspace-name "$ORIGEM_WS" \
    --output-dir "$INFRA_DIR"

  # ===================== PASSO 2: CRIAR INFRA DESTINO =====================
  echo ""
  echo "================================================================"
  echo "  PASSO 2/3: Criando infraestrutura no DESTINO"
  echo "================================================================"

  CREATE_CMD=("$SCRIPT_DIR/02_create_destino_infra.sh"
    --config "$INFRA_DIR/migration_config.json"
    --subscription "$DESTINO_SUBSCRIPTION"
    --resource-group "$DESTINO_RG"
    --workspace-name "$DESTINO_WS"
    --cli-profile "$DESTINO_PROFILE"
  )
  [[ -n "$DESTINO_VNET" ]]          && CREATE_CMD+=(--vnet-name "$DESTINO_VNET")
  [[ -n "$DESTINO_LOCATION" ]]      && CREATE_CMD+=(--location "$DESTINO_LOCATION")
  [[ -n "$DESTINO_VNET_CIDR" ]]     && CREATE_CMD+=(--vnet-address-space "$DESTINO_VNET_CIDR")
  [[ -n "$DESTINO_STORAGE_NAME" ]]  && CREATE_CMD+=(--storage-name "$DESTINO_STORAGE_NAME")

  "${CREATE_CMD[@]}"
else
  echo ""
  echo "  [SKIP] Criacao de infra pulada (--skip-infra)"
fi

# ===================== PASSO 3: MIGRAR DADOS =====================
if [[ "$SKIP_DATA" != "true" ]]; then
  echo ""
  echo "================================================================"
  echo "  PASSO 3/3: Migrando dados (notebooks, secrets, jobs)"
  echo "================================================================"

  MIGRATE_CMD=("$SCRIPT_DIR/03_migrate_data.sh"
    --profile-origem "$ORIGEM_PROFILE"
    --profile-destino "$DESTINO_PROFILE"
    --export-dir "$DATA_DIR"
  )
  [[ -n "$SECRETS_FILE" ]] && MIGRATE_CMD+=(--secrets-file "$SECRETS_FILE")
  [[ "$SYNC_STORAGE" == "true" ]] && MIGRATE_CMD+=(--sync-storage)

  "${MIGRATE_CMD[@]}"
else
  echo ""
  echo "  [SKIP] Migracao de dados pulada (--skip-data)"
fi

# ===================== RESUMO FINAL =====================
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS=$(( ELAPSED % 60 ))

echo ""
echo "################################################################"
echo "#  MIGRACAO CONCLUIDA!                                        #"
echo "################################################################"
echo ""
echo "  Tempo total: ${MINUTES}m ${SECONDS}s"
echo "  Export dir:  $EXPORT_DIR"
echo ""
echo "  ORIGEM:  $ORIGEM_WS ($ORIGEM_RG)"
echo "  DESTINO: $DESTINO_WS ($DESTINO_RG)"
echo ""
echo "  Proximos passos:"
echo "    1. Verificar secrets (se migrados com placeholder)"
echo "    2. Validar notebooks importados no DESTINO"
echo "    3. Executar um job de teste no DESTINO"
echo "    4. Configurar scheduling dos jobs"
echo "    5. Atualizar DNS/bookmarks para nova workspace"
echo "    6. Pausar jobs na ORIGEM apos validacao"
echo "    7. Validar dados no storage destino (se sincronizado)"
echo "    8. Atualizar mount points/external locations no DESTINO"
echo "################################################################"
