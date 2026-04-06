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
#       [--storage-name <name>]  # opcional, nome custom para storage account destino
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
DEST_STORAGE_NAME=""

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
    --storage-name)       DEST_STORAGE_NAME="$2"; shift 2;;
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

# Storage params
HAS_ADLS=$(jq -r '.storage.hasAdlsGen2 // false' "$CONFIG_FILE")
HAS_AC=$(jq -r '.storage.hasAccessConnector // false' "$CONFIG_FILE")

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
echo "[1/10] Definindo subscription destino..."
az account set --subscription "$DEST_SUBSCRIPTION"

# ===================== RESOURCE GROUP =====================
echo "[2/10] Criando Resource Group: $DEST_RG ..."
az group create \
  --name "$DEST_RG" \
  --location "$LOCATION" \
  --tags purpose=migration-destino created-by=migration-script \
  --output none
echo "  Resource Group criado."

# ===================== VNET + SUBNETS =====================
if [[ "$HAS_VNET" == "true" ]]; then
  echo "[3/10] Criando VNet: $DEST_VNET_NAME ($VNET_CIDR) ..."
  az network vnet create \
    --resource-group "$DEST_RG" \
    --name "$DEST_VNET_NAME" \
    --location "$LOCATION" \
    --address-prefix "$VNET_CIDR" \
    --output none
  echo "  VNet criada."

  # Recriar subnets com as mesmas configs
  SUBNET_COUNT=$(jq '.network.subnets | length' "$CONFIG_FILE")
  echo "[4/10] Criando $SUBNET_COUNT subnets..."

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
  echo "[5/10] Criando NSG..."
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
  echo "[3/10] Sem VNet injection na origem - pulando VNet..."
  echo "[4/10] Pulando subnets..."
  echo "[5/10] Pulando NSG..."
fi

# ===================== WORKSPACE =====================
echo "[6/10] Criando Workspace Databricks: $DEST_WS_NAME ..."
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

# ===================== ADLS GEN2 STORAGE ACCOUNT =====================
DEST_STORAGE_ACCOUNTS=()
DEST_AC_NAME=""

if [[ "$HAS_ADLS" == "true" ]]; then
  STORAGE_COUNT=$(jq '.storage.storageAccounts | length' "$CONFIG_FILE")
  echo "[7/10] Criando $STORAGE_COUNT ADLS Gen2 Storage Account(s)..."

  # Get workspace managed identity principal ID for role assignment
  WS_IDENTITY=$(az databricks workspace show \
    --resource-group "$DEST_RG" \
    --name "$DEST_WS_NAME" \
    --query identity.principalId -o tsv 2>/dev/null || true)

  for i in $(seq 0 $((STORAGE_COUNT - 1))); do
    SRC_SA_NAME=$(jq -r ".storage.storageAccounts[$i].name" "$CONFIG_FILE")
    SA_SKU=$(jq -r ".storage.storageAccounts[$i].sku" "$CONFIG_FILE")
    SA_KIND=$(jq -r ".storage.storageAccounts[$i].kind" "$CONFIG_FILE")
    SA_ACCESS_TIER=$(jq -r ".storage.storageAccounts[$i].accessTier" "$CONFIG_FILE")
    SA_NETWORK_ACTION=$(jq -r ".storage.storageAccounts[$i].networkDefaultAction" "$CONFIG_FILE")

    # Determine destination storage account name
    if [[ -n "$DEST_STORAGE_NAME" && "$STORAGE_COUNT" -eq 1 ]]; then
      NEW_SA_NAME="$DEST_STORAGE_NAME"
    else
      # Generate a new name based on destination workspace (storage names must be 3-24 lowercase alphanum)
      SANITIZED_WS=$(echo "${DEST_WS_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
      NEW_SA_NAME="${SANITIZED_WS}adls${i}"
      # Ensure max 24 chars
      NEW_SA_NAME="${NEW_SA_NAME:0:24}"
    fi

    echo "  Criando storage account: $NEW_SA_NAME (source: $SRC_SA_NAME)..."
    az storage account create \
      --name "$NEW_SA_NAME" \
      --resource-group "$DEST_RG" \
      --location "$LOCATION" \
      --sku "$SA_SKU" \
      --kind "$SA_KIND" \
      --access-tier "$SA_ACCESS_TIER" \
      --enable-hierarchical-namespace true \
      --tags purpose=migration-destino source-storage="$SRC_SA_NAME" \
      --output none
    echo "    Storage account criado: $NEW_SA_NAME"

    DEST_STORAGE_ACCOUNTS+=("$NEW_SA_NAME")

    # Create the same containers as in the source
    CONTAINER_COUNT=$(jq ".storage.storageAccounts[$i].containers | length" "$CONFIG_FILE")
    echo "    Criando $CONTAINER_COUNT containers..."
    for c in $(seq 0 $((CONTAINER_COUNT - 1))); do
      CONTAINER_NAME=$(jq -r ".storage.storageAccounts[$i].containers[$c]" "$CONFIG_FILE")
      az storage container create \
        --name "$CONTAINER_NAME" \
        --account-name "$NEW_SA_NAME" \
        --auth-mode login \
        --output none 2>/dev/null || true
      echo "      Container: $CONTAINER_NAME"
    done

    # Configure storage firewall if source had one
    if [[ "$SA_NETWORK_ACTION" == "Deny" ]]; then
      echo "    Configurando firewall (default-action: Deny)..."
      az storage account update \
        --name "$NEW_SA_NAME" \
        --resource-group "$DEST_RG" \
        --default-action Deny \
        --output none

      # Allow access from the destination VNet subnets if VNet injection is used
      if [[ "$HAS_VNET" == "true" ]]; then
        SUBNET_COUNT=$(jq '.network.subnets | length' "$CONFIG_FILE")
        for s in $(seq 0 $((SUBNET_COUNT - 1))); do
          SNET_NAME=$(jq -r ".network.subnets[$s].name" "$CONFIG_FILE")
          SUBNET_ID="/subscriptions/${DEST_SUBSCRIPTION}/resourceGroups/${DEST_RG}/providers/Microsoft.Network/virtualNetworks/${DEST_VNET_NAME}/subnets/${SNET_NAME}"
          az storage account network-rule add \
            --account-name "$NEW_SA_NAME" \
            --resource-group "$DEST_RG" \
            --subnet "$SUBNET_ID" \
            --output none 2>/dev/null || true
          echo "      VNet rule adicionada para subnet: $SNET_NAME"
        done
      fi
      echo "    Firewall configurado."
    fi

    # Assign Storage Blob Data Contributor role to workspace managed identity
    if [[ -n "$WS_IDENTITY" && "$WS_IDENTITY" != "null" ]]; then
      SA_RESOURCE_ID=$(az storage account show \
        --name "$NEW_SA_NAME" \
        --resource-group "$DEST_RG" \
        --query id -o tsv)
      az role assignment create \
        --assignee "$WS_IDENTITY" \
        --role "Storage Blob Data Contributor" \
        --scope "$SA_RESOURCE_ID" \
        --output none 2>/dev/null || true
      echo "    Role 'Storage Blob Data Contributor' atribuida ao workspace identity."
    fi
  done
else
  echo "[7/10] Sem ADLS Gen2 na origem - pulando storage..."
fi

# ===================== ACCESS CONNECTOR FOR DATABRICKS =====================
if [[ "$HAS_AC" == "true" || "$HAS_ADLS" == "true" ]]; then
  echo "[8/10] Criando Access Connector para Databricks (Unity Catalog)..."
  DEST_AC_NAME="ac-${DEST_WS_NAME}"

  az resource create \
    --resource-group "$DEST_RG" \
    --resource-type "Microsoft.Databricks/accessConnectors" \
    --name "$DEST_AC_NAME" \
    --location "$LOCATION" \
    --properties '{}' \
    --is-full-object false \
    --output none 2>/dev/null || true
  echo "  Access Connector criado: $DEST_AC_NAME"

  # Assign Storage Blob Data Contributor role to the access connector identity
  AC_IDENTITY=$(az resource show \
    --resource-group "$DEST_RG" \
    --resource-type "Microsoft.Databricks/accessConnectors" \
    --name "$DEST_AC_NAME" \
    --query identity.principalId -o tsv 2>/dev/null || true)

  if [[ -n "$AC_IDENTITY" && "$AC_IDENTITY" != "null" ]]; then
    for sa_name in "${DEST_STORAGE_ACCOUNTS[@]}"; do
      SA_RESOURCE_ID=$(az storage account show \
        --name "$sa_name" \
        --resource-group "$DEST_RG" \
        --query id -o tsv)
      az role assignment create \
        --assignee "$AC_IDENTITY" \
        --role "Storage Blob Data Contributor" \
        --scope "$SA_RESOURCE_ID" \
        --output none 2>/dev/null || true
      echo "  Role 'Storage Blob Data Contributor' atribuida ao Access Connector em: $sa_name"
    done
  fi
else
  echo "[8/10] Sem Access Connector necessario - pulando..."
fi

# ===================== PRIVATE ENDPOINT =====================
if [[ "$HAS_PE" == "true" && "$HAS_VNET" == "true" ]]; then
  echo "[9/10] Criando Private Endpoint..."

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
  echo "[9/10] Sem Private Endpoint na origem - pulando..."
fi

# ===================== DATABRICKS CLI =====================
echo "[10/10] Configurando Databricks CLI (profile: $CLI_PROFILE) ..."
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
if [[ "$HAS_ADLS" == "true" ]]; then
echo " Storage Accounts:   ${DEST_STORAGE_ACCOUNTS[*]}"
fi
if [[ -n "$DEST_AC_NAME" ]]; then
echo " Access Connector:   $DEST_AC_NAME"
fi
echo " CLI Profile:        $CLI_PROFILE"
echo ""
echo " Proximo passo: execute o script de migracao de dados"
echo "   ./03_migrate_data.sh --profile-origem migration-origem --profile-destino $CLI_PROFILE"
echo "============================================"
