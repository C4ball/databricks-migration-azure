#!/bin/bash
###############################################################################
# 02_create_destino_infra.sh
#
# Le o arquivo migration_config.json exportado da ORIGEM e recria toda a
# infraestrutura na conta/subscription DESTINO:
#   - Resource Group
#   - VNet + Subnets (com delegations e NSG)
#   - Databricks Workspace (com VNet injection)
#   - Private Endpoint + Private DNS Zone
#   - Configura Databricks CLI profile
#
# Uso:
#   ./02_create_destino_infra.sh \
#       --config <path/to/migration_config.json> \
#       --subscription <destino-subscription-id> \
#       --resource-group <destino-rg-name> \
#       --workspace-name <destino-ws-name> \
#       --vnet-name <destino-vnet-name> \
#       --cli-profile <databricks-cli-profile> \
#       [--location <azure-region>]  # opcional, herda da ORIGEM se omitido
#       [--vnet-address-space <cidr>]  # opcional, herda da ORIGEM se omitido
###############################################################################
set -euo pipefail

# ===================== PARAMETROS =====================
CONFIG_FILE=""
DEST_SUBSCRIPTION=""
DEST_RG=""
DEST_WS_NAME=""
DEST_VNET_NAME=""
CLI_PROFILE="migration-destino"
LOCATION=""
VNET_CIDR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)             CONFIG_FILE="$2"; shift 2;;
    --subscription)       DEST_SUBSCRIPTION="$2"; shift 2;;
    --resource-group)     DEST_RG="$2"; shift 2;;
    --workspace-name)     DEST_WS_NAME="$2"; shift 2;;
    --vnet-name)          DEST_VNET_NAME="$2"; shift 2;;
    --cli-profile)        CLI_PROFILE="$2"; shift 2;;
    --location)           LOCATION="$2"; shift 2;;
    --vnet-address-space) VNET_CIDR="$2"; shift 2;;
    *) echo "Parametro desconhecido: $1"; exit 1;;
  esac
done

if [[ -z "$CONFIG_FILE" || -z "$DEST_SUBSCRIPTION" || -z "$DEST_RG" || -z "$DEST_WS_NAME" ]]; then
  echo "Uso: $0 --config <file> --subscription <sub> --resource-group <rg> --workspace-name <ws> --vnet-name <vnet>"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERRO: Arquivo de config nao encontrado: $CONFIG_FILE"
  exit 1
fi

# ===================== LER CONFIG DA ORIGEM =====================
echo "============================================"
echo " Lendo configuracao da ORIGEM..."
echo "============================================"

# Workspace params
SRC_LOCATION=$(jq -r '.workspace.location' "$CONFIG_FILE")
SKU=$(jq -r '.workspace.sku' "$CONFIG_FILE")
PUBLIC_NETWORK=$(jq -r '.workspace.publicNetworkAccess' "$CONFIG_FILE")
NSG_RULES=$(jq -r '.workspace.requiredNsgRules' "$CONFIG_FILE")
NO_PUBLIC_IP=$(jq -r '.workspace.enableNoPublicIp' "$CONFIG_FILE")

# Network params
HAS_VNET=$(jq -r '.network.hasVnetInjection' "$CONFIG_FILE")
SRC_VNET_CIDR=$(jq -r '.network.vnetAddressSpace' "$CONFIG_FILE")
HOST_SUBNET_NAME=$(jq -r '.network.hostSubnet' "$CONFIG_FILE")
CONTAINER_SUBNET_NAME=$(jq -r '.network.containerSubnet' "$CONFIG_FILE")

# Private Endpoint params
HAS_PE=$(jq -r '.privateEndpoint.enabled' "$CONFIG_FILE")
PE_SUBNET_NAME=$(jq -r '.privateEndpoint.subnet' "$CONFIG_FILE")
PE_GROUP_ID=$(jq -r '.privateEndpoint.groupId' "$CONFIG_FILE")

# Defaults
LOCATION="${LOCATION:-$SRC_LOCATION}"
VNET_CIDR="${VNET_CIDR:-$SRC_VNET_CIDR}"

if [[ "$HAS_VNET" == "true" && -z "$DEST_VNET_NAME" ]]; then
  DEST_VNET_NAME="vnet-${DEST_WS_NAME}"
fi

echo "  Destino Subscription: $DEST_SUBSCRIPTION"
echo "  Destino RG: $DEST_RG"
echo "  Destino Workspace: $DEST_WS_NAME"
echo "  Location: $LOCATION"
echo "  SKU: $SKU"
echo "  VNet Injection: $HAS_VNET"
echo "  Private Endpoint: $HAS_PE"
echo ""

# ===================== SET SUBSCRIPTION =====================
echo "[1/8] Definindo subscription destino..."
az account set --subscription "$DEST_SUBSCRIPTION"

# ===================== RESOURCE GROUP =====================
echo "[2/8] Criando Resource Group: $DEST_RG ..."
az group create \
  --name "$DEST_RG" \
  --location "$LOCATION" \
  --tags purpose=migration-destino created-by=migration-script \
  --output none
echo "  Resource Group criado."

# ===================== VNET + SUBNETS =====================
if [[ "$HAS_VNET" == "true" ]]; then
  echo "[3/8] Criando VNet: $DEST_VNET_NAME ($VNET_CIDR) ..."
  az network vnet create \
    --resource-group "$DEST_RG" \
    --name "$DEST_VNET_NAME" \
    --location "$LOCATION" \
    --address-prefix "$VNET_CIDR" \
    --output none
  echo "  VNet criada."

  # Recriar subnets com as mesmas configs
  SUBNET_COUNT=$(jq '.network.subnets | length' "$CONFIG_FILE")
  echo "[4/8] Criando $SUBNET_COUNT subnets..."

  for i in $(seq 0 $((SUBNET_COUNT - 1))); do
    SNET_NAME=$(jq -r ".network.subnets[$i].name" "$CONFIG_FILE")
    SNET_PREFIX=$(jq -r ".network.subnets[$i].addressPrefix" "$CONFIG_FILE")
    SNET_DELEGATION=$(jq -r ".network.subnets[$i].delegations[0] // empty" "$CONFIG_FILE")

    DELEGATION_ARG=""
    if [[ -n "$SNET_DELEGATION" && "$SNET_DELEGATION" != "null" ]]; then
      DELEGATION_ARG="--delegations $SNET_DELEGATION"
    fi

    az network vnet subnet create \
      --resource-group "$DEST_RG" \
      --vnet-name "$DEST_VNET_NAME" \
      --name "$SNET_NAME" \
      --address-prefix "$SNET_PREFIX" \
      $DELEGATION_ARG \
      --output none
    echo "  Subnet: $SNET_NAME ($SNET_PREFIX) delegation=$SNET_DELEGATION"
  done

  # ===================== NSG =====================
  echo "[5/8] Criando NSG..."
  NSG_NAME="nsg-${DEST_WS_NAME}"
  az network nsg create \
    --resource-group "$DEST_RG" \
    --name "$NSG_NAME" \
    --location "$LOCATION" \
    --output none
  echo "  NSG criado: $NSG_NAME"

  # Associar NSG as subnets com delegation (host e container)
  for i in $(seq 0 $((SUBNET_COUNT - 1))); do
    SNET_NAME=$(jq -r ".network.subnets[$i].name" "$CONFIG_FILE")
    HAS_NSG=$(jq -r ".network.subnets[$i].hasNsg" "$CONFIG_FILE")
    if [[ "$HAS_NSG" == "true" ]]; then
      az network vnet subnet update \
        --resource-group "$DEST_RG" \
        --vnet-name "$DEST_VNET_NAME" \
        --name "$SNET_NAME" \
        --network-security-group "$NSG_NAME" \
        --output none
      echo "  NSG associado a subnet: $SNET_NAME"
    fi
  done
else
  echo "[3/8] Sem VNet injection na origem - pulando VNet..."
  echo "[4/8] Pulando subnets..."
  echo "[5/8] Pulando NSG..."
fi

# ===================== WORKSPACE =====================
echo "[6/8] Criando Workspace Databricks: $DEST_WS_NAME ..."
echo "  (Isso pode levar 5-10 minutos...)"

WS_CMD="az databricks workspace create \
  --resource-group $DEST_RG \
  --name $DEST_WS_NAME \
  --location $LOCATION \
  --sku $SKU"

if [[ "$HAS_VNET" == "true" ]]; then
  DEST_VNET_ID="/subscriptions/${DEST_SUBSCRIPTION}/resourceGroups/${DEST_RG}/providers/Microsoft.Network/virtualNetworks/${DEST_VNET_NAME}"
  WS_CMD="$WS_CMD \
    --vnet $DEST_VNET_ID \
    --public-subnet $HOST_SUBNET_NAME \
    --private-subnet $CONTAINER_SUBNET_NAME \
    --public-network-access $PUBLIC_NETWORK \
    --required-nsg-rules $NSG_RULES"

  if [[ "$NO_PUBLIC_IP" == "true" ]]; then
    WS_CMD="$WS_CMD --enable-no-public-ip"
  fi
fi

eval "$WS_CMD" --output none
echo "  Workspace criado!"

# Obter URL
WS_URL=$(az databricks workspace show \
  --resource-group "$DEST_RG" \
  --name "$DEST_WS_NAME" \
  --query workspaceUrl -o tsv)
WS_ID=$(az databricks workspace show \
  --resource-group "$DEST_RG" \
  --name "$DEST_WS_NAME" \
  --query id -o tsv)
echo "  URL: https://$WS_URL"

# ===================== PRIVATE ENDPOINT =====================
if [[ "$HAS_PE" == "true" && "$HAS_VNET" == "true" ]]; then
  echo "[7/8] Criando Private Endpoint..."

  PE_NAME="pe-${DEST_WS_NAME}"
  PE_CONN_NAME="pe-conn-${DEST_WS_NAME}"

  az network private-endpoint create \
    --name "$PE_NAME" \
    --resource-group "$DEST_RG" \
    --vnet-name "$DEST_VNET_NAME" \
    --subnet "$PE_SUBNET_NAME" \
    --private-connection-resource-id "$WS_ID" \
    --group-id "$PE_GROUP_ID" \
    --connection-name "$PE_CONN_NAME" \
    --location "$LOCATION" \
    --output none
  echo "  Private Endpoint criado: $PE_NAME"

  # Private DNS Zone
  DNS_ZONE="privatelink.azuredatabricks.net"
  echo "  Criando Private DNS Zone: $DNS_ZONE ..."
  az network private-dns zone create \
    --resource-group "$DEST_RG" \
    --name "$DNS_ZONE" \
    --output none

  # Link DNS Zone to VNet
  az network private-dns link vnet create \
    --resource-group "$DEST_RG" \
    --zone-name "$DNS_ZONE" \
    --name "link-${DEST_VNET_NAME}" \
    --virtual-network "$DEST_VNET_NAME" \
    --registration-enabled false \
    --output none
  echo "  DNS Zone vinculada a VNet."

  # DNS Zone Group for auto-registration
  az network private-endpoint dns-zone-group create \
    --resource-group "$DEST_RG" \
    --endpoint-name "$PE_NAME" \
    --name default \
    --private-dns-zone "$DNS_ZONE" \
    --zone-name databricks \
    --output none
  echo "  DNS Zone Group criada."
else
  echo "[7/8] Sem Private Endpoint na origem - pulando..."
fi

# ===================== DATABRICKS CLI =====================
echo "[8/8] Configurando Databricks CLI (profile: $CLI_PROFILE) ..."
databricks auth login --host "https://$WS_URL" --profile "$CLI_PROFILE" 2>/dev/null || true

# ===================== RESUMO FINAL =====================
echo ""
echo "============================================"
echo " Infraestrutura DESTINO criada com sucesso!"
echo "============================================"
echo ""
echo " Subscription:       $DEST_SUBSCRIPTION"
echo " Resource Group:     $DEST_RG"
echo " Workspace:          $DEST_WS_NAME"
echo " URL:                https://$WS_URL"
echo " Location:           $LOCATION"
echo " SKU:                $SKU"
if [[ "$HAS_VNET" == "true" ]]; then
echo " VNet:               $DEST_VNET_NAME ($VNET_CIDR)"
echo " Host Subnet:        $HOST_SUBNET_NAME"
echo " Container Subnet:   $CONTAINER_SUBNET_NAME"
echo " No Public IP:       $NO_PUBLIC_IP"
echo " NSG:                $NSG_NAME"
fi
if [[ "$HAS_PE" == "true" ]]; then
echo " Private Endpoint:   $PE_NAME"
echo " Private DNS:        $DNS_ZONE"
fi
echo " CLI Profile:        $CLI_PROFILE"
echo ""
echo " Proximo passo: execute o script de migracao de dados"
echo "   ./03_migrate_data.sh --profile-origem migration-origem --profile-destino $CLI_PROFILE"
echo "============================================"
