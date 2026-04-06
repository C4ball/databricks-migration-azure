#!/bin/bash
###############################################################################
# 01_export_origem_config.sh
#
# Exporta toda a configuracao de infraestrutura da Workspace ORIGEM
# (Workspace, VNet, Subnets, NSG, Private Endpoint, DNS)
# para um diretorio local, gerando um JSON consolidado que sera usado
# pelo script 02_create_destino_infra.sh para recriar na conta destino.
#
# Uso:
#   ./01_export_origem_config.sh \
#       --subscription <subscription-id> \
#       --resource-group <rg-name> \
#       --workspace-name <ws-name> \
#       --output-dir <path>
###############################################################################
set -euo pipefail

# ===================== PARAMETROS =====================
SUBSCRIPTION=""
RESOURCE_GROUP=""
WORKSPACE_NAME=""
OUTPUT_DIR="./origem-export"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)     SUBSCRIPTION="$2"; shift 2;;
    --resource-group)   RESOURCE_GROUP="$2"; shift 2;;
    --workspace-name)   WORKSPACE_NAME="$2"; shift 2;;
    --output-dir)       OUTPUT_DIR="$2"; shift 2;;
    *) echo "Parametro desconhecido: $1"; exit 1;;
  esac
done

if [[ -z "$SUBSCRIPTION" || -z "$RESOURCE_GROUP" || -z "$WORKSPACE_NAME" ]]; then
  echo "Uso: $0 --subscription <sub-id> --resource-group <rg> --workspace-name <ws>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "============================================"
echo " Exportando configuracao da ORIGEM"
echo " Subscription: $SUBSCRIPTION"
echo " Resource Group: $RESOURCE_GROUP"
echo " Workspace: $WORKSPACE_NAME"
echo " Output: $OUTPUT_DIR"
echo "============================================"

# ===================== SET SUBSCRIPTION =====================
echo "[1/7] Definindo subscription..."
az account set --subscription "$SUBSCRIPTION"

# ===================== EXPORT WORKSPACE =====================
echo "[2/7] Exportando workspace..."
az databricks workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WORKSPACE_NAME" \
  --output json > "$OUTPUT_DIR/workspace.json"

# Extrair parametros chave
LOCATION=$(jq -r '.location' "$OUTPUT_DIR/workspace.json")
SKU=$(jq -r '.sku.name' "$OUTPUT_DIR/workspace.json")
PUBLIC_NETWORK=$(jq -r '.publicNetworkAccess // "Enabled"' "$OUTPUT_DIR/workspace.json")
NSG_RULES=$(jq -r '.requiredNsgRules // "AllRules"' "$OUTPUT_DIR/workspace.json")
NO_PUBLIC_IP=$(jq -r '.parameters.enableNoPublicIp.value' "$OUTPUT_DIR/workspace.json")
VNET_ID=$(jq -r '.parameters.customVirtualNetworkId.value // empty' "$OUTPUT_DIR/workspace.json")
HOST_SUBNET=$(jq -r '.parameters.customPublicSubnetName.value // empty' "$OUTPUT_DIR/workspace.json")
CONTAINER_SUBNET=$(jq -r '.parameters.customPrivateSubnetName.value // empty' "$OUTPUT_DIR/workspace.json")

HAS_VNET_INJECTION="false"
if [[ -n "$VNET_ID" && "$VNET_ID" != "null" ]]; then
  HAS_VNET_INJECTION="true"
fi

echo "  Location: $LOCATION"
echo "  SKU: $SKU"
echo "  VNet Injection: $HAS_VNET_INJECTION"

# ===================== EXPORT VNET (se existir) =====================
VNET_NAME=""
VNET_ADDRESS_SPACE=""
if [[ "$HAS_VNET_INJECTION" == "true" ]]; then
  VNET_NAME=$(echo "$VNET_ID" | awk -F'/' '{print $NF}')
  echo "[3/7] Exportando VNet: $VNET_NAME ..."
  az network vnet show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --output json > "$OUTPUT_DIR/vnet.json"
  VNET_ADDRESS_SPACE=$(jq -r '.addressSpace.addressPrefixes[0]' "$OUTPUT_DIR/vnet.json")

  # ===================== EXPORT SUBNETS =====================
  echo "[4/7] Exportando subnets..."
  az network vnet subnet list \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --output json > "$OUTPUT_DIR/subnets.json"

  # ===================== EXPORT NSG =====================
  echo "[5/7] Exportando NSGs..."
  # Detectar NSGs associados as subnets
  NSG_IDS=$(jq -r '.[].networkSecurityGroup.id // empty' "$OUTPUT_DIR/subnets.json" | sort -u | grep -v '^$' || true)
  NSG_NAMES=()
  idx=0
  for nsg_id in $NSG_IDS; do
    nsg_name=$(echo "$nsg_id" | awk -F'/' '{print $NF}')
    NSG_NAMES+=("$nsg_name")
    az network nsg show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$nsg_name" \
      --output json > "$OUTPUT_DIR/nsg_${idx}.json"
    echo "  NSG: $nsg_name"
    idx=$((idx + 1))
  done
else
  echo "[3/7] Sem VNet injection - pulando VNet..."
  echo "[4/7] Sem VNet injection - pulando subnets..."
  echo "[5/7] Sem VNet injection - pulando NSG..."
fi

# ===================== EXPORT PRIVATE ENDPOINTS =====================
echo "[6/7] Exportando Private Endpoints..."
WS_RESOURCE_ID=$(jq -r '.id' "$OUTPUT_DIR/workspace.json")
PE_LIST=$(az network private-endpoint list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?privateLinkServiceConnections[0].privateLinkServiceId=='$WS_RESOURCE_ID'].name" \
  --output tsv 2>/dev/null || true)

HAS_PRIVATE_ENDPOINT="false"
PE_SUBNET=""
PE_GROUP_ID=""
if [[ -n "$PE_LIST" ]]; then
  HAS_PRIVATE_ENDPOINT="true"
  for pe_name in $PE_LIST; do
    az network private-endpoint show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$pe_name" \
      --output json > "$OUTPUT_DIR/private_endpoint.json"
    PE_SUBNET=$(jq -r '.subnet.id' "$OUTPUT_DIR/private_endpoint.json" | awk -F'/' '{print $NF}')
    PE_GROUP_ID=$(jq -r '.privateLinkServiceConnections[0].groupIds[0]' "$OUTPUT_DIR/private_endpoint.json")
    echo "  PE: $pe_name (subnet: $PE_SUBNET, group: $PE_GROUP_ID)"
  done

  # Exportar Private DNS Zone
  echo "  Exportando Private DNS Zone..."
  az network private-dns zone list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?name=='privatelink.azuredatabricks.net']" \
    --output json > "$OUTPUT_DIR/private_dns.json" 2>/dev/null || echo "[]" > "$OUTPUT_DIR/private_dns.json"
else
  echo "  Nenhum Private Endpoint encontrado"
fi

# ===================== GERAR CONFIG CONSOLIDADA =====================
echo "[7/7] Gerando config consolidada..."

# Montar subnets config
SUBNETS_JSON="[]"
if [[ "$HAS_VNET_INJECTION" == "true" ]]; then
  SUBNETS_JSON=$(jq '[.[] | {
    name: .name,
    addressPrefix: .addressPrefix,
    delegations: [.delegations[]?.serviceName],
    hasNsg: (if .networkSecurityGroup then true else false end)
  }]' "$OUTPUT_DIR/subnets.json")
fi

cat > "$OUTPUT_DIR/migration_config.json" << JSONEOF
{
  "source": {
    "subscription": "$SUBSCRIPTION",
    "resourceGroup": "$RESOURCE_GROUP",
    "workspaceName": "$WORKSPACE_NAME"
  },
  "workspace": {
    "location": "$LOCATION",
    "sku": "$SKU",
    "publicNetworkAccess": "$PUBLIC_NETWORK",
    "requiredNsgRules": "$NSG_RULES",
    "enableNoPublicIp": $NO_PUBLIC_IP
  },
  "network": {
    "hasVnetInjection": $HAS_VNET_INJECTION,
    "vnetName": "$VNET_NAME",
    "vnetAddressSpace": "$VNET_ADDRESS_SPACE",
    "hostSubnet": "$HOST_SUBNET",
    "containerSubnet": "$CONTAINER_SUBNET",
    "subnets": $SUBNETS_JSON
  },
  "privateEndpoint": {
    "enabled": $HAS_PRIVATE_ENDPOINT,
    "subnet": "$PE_SUBNET",
    "groupId": "${PE_GROUP_ID:-databricks_ui_api}"
  },
  "privateDns": {
    "zoneName": "privatelink.azuredatabricks.net"
  }
}
JSONEOF

echo ""
echo "============================================"
echo " Exportacao concluida!"
echo " Config: $OUTPUT_DIR/migration_config.json"
echo "============================================"
cat "$OUTPUT_DIR/migration_config.json" | python3 -m json.tool
