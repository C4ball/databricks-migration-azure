# Databricks Workspace Migration - Azure

Scripts e guia para migração completa de uma Databricks Workspace entre contas/subscriptions Azure, incluindo:

- **Infraestrutura**: VNet injection, Private Endpoints, DNS Zones, NSG
- **Dados**: Notebooks, Secret Scopes, Jobs/Workflows
- **Compatibilidade**: Bash (Linux/macOS) e PowerShell (Windows)

## Documentação Completa

📄 [Guia de Migração - Google Doc](https://docs.google.com/document/d/1hDxIK24voBr7R232iOK5hCXTKmL742MU6k78F2Z8-YY/edit)

## Estrutura do Repositório

```
├── README.md
├── docs/
│   └── guia-migracao.md          # Guia passo a passo (Fases 0-10)
├── scripts/
│   ├── bash/                     # Scripts para Linux/macOS
│   │   ├── migrate.sh            # Script master
│   │   ├── 01_export_origem_config.sh
│   │   ├── 02_create_destino_infra.sh
│   │   └── 03_migrate_data.sh
│   ├── powershell/               # Scripts para Windows
│   │   ├── migrate.ps1
│   │   ├── 01_export_origem_config.ps1
│   │   ├── 02_create_destino_infra.ps1
│   │   └── 03_migrate_data.ps1
│   └── secrets_values.json       # Template para valores de secrets
```

## Quick Start

### Pré-requisitos

| Ferramenta | Instalação |
|------------|------------|
| Azure CLI | `brew install azure-cli` / `winget install Microsoft.AzureCLI` |
| Databricks CLI | [Instruções](https://docs.databricks.com/dev-tools/cli/install.html) |
| Python 3 | `brew install python3` / `winget install Python.Python.3.12` |
| jq (apenas Bash) | `brew install jq` / `apt install jq` |

### Autenticação

```bash
# Azure
az login
az account set --subscription "<subscription-id>"

# Databricks CLI - configurar profiles para origem e destino
databricks auth login --host https://<origem-url> --profile meu-profile-origem
databricks auth login --host https://<destino-url> --profile meu-profile-destino
```

### Execução (Bash)

```bash
cd scripts/bash
chmod +x *.sh

# Ver o plano sem executar
./migrate.sh \
    --origem-subscription "<sub-origem>" \
    --origem-resource-group "<rg-origem>" \
    --origem-workspace "<ws-origem>" \
    --origem-cli-profile "<profile-origem>" \
    --destino-subscription "<sub-destino>" \
    --destino-resource-group "<rg-destino>" \
    --destino-workspace "<ws-destino>" \
    --destino-cli-profile "<profile-destino>" \
    --dry-run

# Executar migração completa
./migrate.sh \
    --origem-subscription "<sub-origem>" \
    --origem-resource-group "<rg-origem>" \
    --origem-workspace "<ws-origem>" \
    --origem-cli-profile "<profile-origem>" \
    --destino-subscription "<sub-destino>" \
    --destino-resource-group "<rg-destino>" \
    --destino-workspace "<ws-destino>" \
    --destino-cli-profile "<profile-destino>" \
    --secrets-file ../secrets_values.json
```

### Execução (PowerShell)

```powershell
cd scripts\powershell

# Ver o plano sem executar
.\migrate.ps1 `
    -OrigemSubscription "<sub-origem>" `
    -OrigemResourceGroup "<rg-origem>" `
    -OrigemWorkspace "<ws-origem>" `
    -OrigemCliProfile "<profile-origem>" `
    -DestinoSubscription "<sub-destino>" `
    -DestinoResourceGroup "<rg-destino>" `
    -DestinoWorkspace "<ws-destino>" `
    -DestinoCliProfile "<profile-destino>" `
    -DryRun

# Executar migração completa
.\migrate.ps1 `
    -OrigemSubscription "<sub-origem>" `
    -OrigemResourceGroup "<rg-origem>" `
    -OrigemWorkspace "<ws-origem>" `
    -OrigemCliProfile "<profile-origem>" `
    -DestinoSubscription "<sub-destino>" `
    -DestinoResourceGroup "<rg-destino>" `
    -DestinoWorkspace "<ws-destino>" `
    -DestinoCliProfile "<profile-destino>" `
    -SecretsFile ..\secrets_values.json
```

## O Que os Scripts Fazem

### Passo 1: Exportar Configuração da Origem (`01_export_origem_config`)
- Exporta configuração da workspace (SKU, location, network)
- Exporta VNet, subnets (com delegations), NSG
- Exporta Private Endpoints e DNS Zones
- Gera `migration_config.json` consolidado

### Passo 2: Criar Infraestrutura no Destino (`02_create_destino_infra`)
- Cria Resource Group
- Cria VNet com mesmas subnets e CIDRs
- Cria NSG e associa às subnets
- Cria Workspace Databricks com VNet injection
- Cria Private Endpoint com DNS Zone

### Passo 3: Migrar Dados (`03_migrate_data`)
- **Notebooks**: export-dir / import-dir recursivo
- **Secret Scopes**: recria scopes e secrets (valores via arquivo JSON ou placeholder)
- **Jobs**: exporta, limpa campos read-only, recria com mapeamento de IDs

## Flags Úteis

| Flag | Bash | PowerShell | Descrição |
|------|------|------------|-----------|
| Dry run | `--dry-run` | `-DryRun` | Mostra plano sem executar |
| Pular infra | `--skip-infra` | `-SkipInfra` | Só migra dados |
| Pular dados | `--skip-data` | `-SkipData` | Só cria infra |
| Help | `--help` | `Get-Help .\migrate.ps1` | Documentação completa |

## Formato do Arquivo de Secrets

Os valores de secrets não são exportáveis pela API do Databricks. Forneça um JSON com os valores:

```json
{
  "nome-do-scope": {
    "chave1": "valor-real-1",
    "chave2": "valor-real-2"
  }
}
```

Se não fornecido, secrets são criados com `PLACEHOLDER` e devem ser atualizados manualmente.

## Referências

- [Migrate data applications to Azure Databricks](https://learn.microsoft.com/en-us/azure/databricks/migration/)
- [VNet injection Azure](https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/vnet-inject)
- [Private Link Azure](https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/private-link-standard)
- [Databricks CLI reference](https://docs.databricks.com/aws/en/dev-tools/cli/reference/workspace-commands)
- [Jobs API](https://docs.databricks.com/api/workspace/jobs)
- [Databricks Labs Migrate Tool](https://github.com/databrickslabs/migrate)
- [Terraform Exporter](https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides/experimental-exporter)
