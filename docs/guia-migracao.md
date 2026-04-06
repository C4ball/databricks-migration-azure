# Guia de Migracao: Databricks Workspace entre Contas Azure

## Visao Geral

Migracao de uma Workspace Databricks de uma Conta Azure (origem) para uma nova Conta Azure (destino), reutilizando o mesmo Azure Data Lake Storage (ADLS Gen2).

---

## Fase 0 -- Pre-requisitos e Planejamento

### 0.1 Inventario da Workspace Origem

- Listar todos os notebooks, repos, libraries
- Documentar clusters (configs, init scripts, policies)
- Exportar lista de jobs e pipelines DLT
- Mapear secrets scopes e seus valores
- Documentar permissoes (ACLs de notebooks, clusters, jobs)
- Listar SQL Warehouses e dashboards
- Documentar Unity Catalog: metastore, catalogs, schemas, external locations
- Listar mount points existentes (dbutils.fs.mounts())
- Documentar IP Access Lists, Private Links, VNet configs

### 0.2 Ferramentas Necessarias

- Databricks CLI (v0.18+) configurado para ambas workspaces
- Terraform (opcional, mas recomendado para IaC)
- Azure CLI (az) autenticado em ambas subscriptions
- databricks-sync ou scripts customizados para migracao em massa

### 0.3 Configurar Profiles do Databricks CLI

```
# Profile da workspace origem
databricks configure --profile ORIGEM --host https://<origem>.azuredatabricks.net --token

# Profile da workspace destino
databricks configure --profile DESTINO --host https://<destino>.azuredatabricks.net --token
```

### Referencias - Fase 0

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Migrate data applications to Azure Databricks | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/migration/) |
| Docs | Databricks CLI reference | [Databricks Docs](https://docs.databricks.com/aws/en/dev-tools/cli/reference/workspace-commands) |
| Tool | Databricks Labs Migrate Tool | [GitHub](https://github.com/databrickslabs/migrate) |
| Tool | Terraform Exporter | [Terraform Registry](https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides/experimental-exporter) |
| Docs | Export workspace data | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/privacy/export-workspace-data) |

---

## Fase 1 -- Preparar a Nova Conta Azure e Workspace

### 1.1 Criar Resource Group e Workspace na Nova Conta

```
az group create --name rg-databricks-new --location eastus2

az databricks workspace create \
  --resource-group rg-databricks-new \
  --name dbw-new-workspace \
  --location eastus2 \
  --sku premium
```

### 1.2 Reutilizar o Mesmo Storage Account (ADLS Gen2)

**Ponto critico:** Para compartilhar o mesmo Storage entre contas Azure, e necessario configurar acesso cross-tenant ou mover o Storage.

**Opcao A -- Cross-Tenant Access** (recomendado se ambas contas coexistem temporariamente):

1. No Storage Account (conta origem), adicionar uma Role Assignment para o Service Principal / Managed Identity da nova workspace
2. Usar Azure Lighthouse ou Cross-tenant RBAC para conceder Storage Blob Data Contributor

```
NEW_WS_PRINCIPAL=$(az databricks workspace show \
  --resource-group rg-databricks-new \
  --name dbw-new-workspace \
  --query identity.principalId -o tsv)

az role assignment create \
  --assignee $NEW_WS_PRINCIPAL \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/<sub-origem>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>
```

**Opcao B -- Mover o Storage Account** para a nova subscription:

```
az resource move \
  --destination-group rg-databricks-new \
  --destination-subscription-id <nova-subscription-id> \
  --ids /subscriptions/<sub-origem>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>
```

**ATENCAO:** A Opcao B causa downtime. So executar apos a migracao dos metadados.

### 1.3 Configurar Unity Catalog Metastore (se aplicavel)

```
databricks unity-catalog metastores create \
  --profile DESTINO \
  --name "metastore-new" \
  --storage-root "abfss://metastore@<storage>.dfs.core.windows.net/unity-catalog"
```

### Referencias - Fase 1

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Move Azure resources between subscriptions | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-resource-group-and-subscription) |
| Docs | Move resources overview | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-resources-overview) |
| Docs | Get started with Unity Catalog Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/data-governance/unity-catalog/get-started) |
| Docs | What is Unity Catalog | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/data-governance/unity-catalog/) |
| Docs | Unity Catalog Terraform setup | [Terraform Registry](https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides/unity-catalog-azure) |
| Video | Unity Catalog Setup Step by Step | [YouTube](https://www.youtube.com/watch?v=M2Et5aBj2aw) |

---

## Fase 2 -- Migrar Identidades e Permissoes

### 2.1 Sincronizar Usuarios e Grupos

```
databricks users list --profile ORIGEM --output json > users_origem.json
databricks groups list --profile ORIGEM --output json > groups_origem.json
```

**Recomendado:** Configurar SCIM provisioning (via Entra ID) na nova workspace ao inves de migrar manualmente.

### 2.2 Migrar Secret Scopes

```
databricks secrets list-scopes --profile ORIGEM --output json > scopes.json
databricks secrets list --scope <scope-name> --profile ORIGEM
databricks secrets create-scope --scope <scope-name> --profile DESTINO
databricks secrets put-secret --scope <scope-name> --key <key> --profile DESTINO
```

**ATENCAO:** Secrets nao sao exportaveis. Voce precisara dos valores originais (Key Vault, docs internos, etc.)

### Referencias - Fase 2

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | SCIM provisioning with Entra ID | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/admin/users-groups/scim/aad) |
| Docs | Sync users and groups from Entra ID | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/admin/users-groups/scim/) |
| Docs | Secret management | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/secrets/) |
| Docs | Secret scopes | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/secrets/secret-scopes) |
| Docs | Secrets CLI commands | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/cli/reference/secrets-commands) |

---

## Fase 3 -- Migrar Notebooks, Repos e Arquivos

### 3.1 Notebooks do Workspace

```
databricks workspace export_dir / ./notebooks_backup --profile ORIGEM
databricks workspace import_dir ./notebooks_backup / --profile DESTINO --overwrite
```

### 3.2 Repos (Git Integration)

```
databricks repos list --profile ORIGEM --output json > repos.json

databricks repos create \
  --url https://github.com/org/repo.git \
  --provider github \
  --path /Repos/user@email.com/repo-name \
  --profile DESTINO
```

### 3.3 DBFS Files

```
databricks fs cp -r dbfs:/ ./dbfs_backup --profile ORIGEM
databricks fs cp -r ./dbfs_backup dbfs:/ --profile DESTINO
```

Se reutilizando o mesmo ADLS, os dados no storage ja estarao acessiveis -- foco apenas em arquivos dentro do DBFS root.

### Referencias - Fase 3

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Import and export notebooks Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/notebooks/notebook-export-import) |
| Docs | Workspace CLI commands | [Databricks Docs](https://docs.databricks.com/aws/en/dev-tools/cli/reference/workspace-commands) |
| Docs | Workspace API Export | [Databricks API](https://docs.databricks.com/api/workspace/workspace/export) |
| Docs | Workspace API Import | [Databricks API](https://docs.databricks.com/api/workspace/workspace/import) |
| Docs | Git folders (Repos) Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/repos/) |
| Docs | Create and manage Git folders | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/repos/git-operations-with-repos) |

---

## Fase 4 -- Migrar Clusters e Policies

### 4.1 Cluster Policies

```
databricks cluster-policies list --profile ORIGEM --output json > policies.json
databricks cluster-policies create --json-file policy.json --profile DESTINO
```

### 4.2 Cluster Configurations

```
databricks clusters list --profile ORIGEM --output json > clusters.json

# Para cada cluster, recriar com a mesma config
# Remover campos read-only: cluster_id, state, creator_user_name, etc.
databricks clusters create --json-file cluster_config.json --profile DESTINO
```

### 4.3 Init Scripts

Se armazenados no DBFS, ja foram copiados na Fase 3.3. Se armazenados em volumes UC ou ADLS, ja estao acessiveis via storage compartilhado. Verificar referencias nos cluster configs.

### Referencias - Fase 4

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Create and manage compute policies | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/admin/clusters/policies) |
| Docs | Compute policy reference | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/admin/clusters/policy-definition) |
| Docs | Cluster Policies CLI commands | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/cli/reference/cluster-policies-commands) |
| Docs | Cluster Policies API | [Databricks API](https://docs.databricks.com/api/azure/workspace/clusterpolicies) |

---

## Fase 5 -- Migrar Jobs e Pipelines

### 5.1 Jobs

```
databricks jobs list --all --profile ORIGEM --output json > jobs.json

for job_id in $(jq -r '.[].job_id' jobs.json); do
  databricks jobs get --job-id $job_id --profile ORIGEM --output json > "job_${job_id}.json"
done

# Limpar campos read-only e recriar
databricks jobs create --json-file job_clean.json --profile DESTINO
```

**Script auxiliar para limpeza do JSON:**

```
import json, glob

for f in glob.glob("job_*.json"):
    with open(f) as fh:
        job = json.load(fh)
    settings = job.get("settings", job)
    for key in ["job_id", "created_time", "creator_user_name"]:
        settings.pop(key, None)
        job.pop(key, None)
    with open(f.replace("job_", "job_clean_"), "w") as fh:
        json.dump(settings, fh, indent=2)
```

### 5.2 Delta Live Tables (DLT) Pipelines

```
databricks pipelines list --profile ORIGEM --output json > pipelines.json

for pid in $(jq -r '.[].pipeline_id' pipelines.json); do
  databricks pipelines get --pipeline-id $pid --profile ORIGEM --output json > "pipeline_${pid}.json"
done

databricks pipelines create --json-file pipeline_clean.json --profile DESTINO
```

### 5.3 Workflows com Orchestration (Asset Bundles)

Se usando Databricks Asset Bundles (DAB), re-deploy com:

```
databricks bundle deploy --profile DESTINO
```

### Referencias - Fase 5

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Automate job creation and management Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/jobs/automate) |
| Docs | Jobs API reference | [Databricks API](https://docs.databricks.com/api/workspace/jobs) |
| Docs | Jobs API Create | [Databricks API](https://docs.databricks.com/api/workspace/jobs/create) |
| Docs | Pipelines API reference | [Databricks API](https://docs.databricks.com/api/workspace/pipelines) |
| Docs | What is Delta Live Tables | [Databricks Docs](https://docs.databricks.com/en/delta-live-tables/index.html) |
| Docs | DLT Tutorial | [Databricks Docs](https://docs.databricks.com/en/delta-live-tables/tutorial-pipelines.html) |
| Docs | Databricks Asset Bundles | [Databricks Docs](https://docs.databricks.com/aws/en/dev-tools/bundles/) |
| Docs | Bundle deploy tutorial | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/bundles/workspace-tutorial) |

---

## Fase 6 -- Migrar Unity Catalog (Metadados)

### 6.1 External Locations e Storage Credentials

```
databricks storage-credentials list --profile ORIGEM

databricks storage-credentials create \
  --name "adls-credential" \
  --azure-managed-identity \
  --access-connector-id "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Databricks/accessConnectors/<connector>" \
  --profile DESTINO

databricks external-locations create \
  --name "ext-raw-data" \
  --url "abfss://raw@<storage>.dfs.core.windows.net/" \
  --credential-name "adls-credential" \
  --profile DESTINO
```

### 6.2 Catalogs, Schemas e Tables

**Para tabelas managed** (dados no metastore root): Recriar DDL via SHOW CREATE TABLE para cada tabela e re-executar.

**Para tabelas external** (dados no ADLS compartilhado): Apenas recriar os metadados (DDL) -- os dados ja estao no storage.

```
CREATE TABLE catalog.schema.table
USING DELTA
LOCATION 'abfss://container@storage.dfs.core.windows.net/path/to/table';
```

### 6.3 Views, Functions e Permissions

```
-- Exportar grants
SHOW GRANTS ON CATALOG my_catalog;
SHOW GRANTS ON SCHEMA my_catalog.my_schema;

-- Replicar no destino
GRANT USE CATALOG ON CATALOG my_catalog TO group_name;
GRANT SELECT ON SCHEMA my_catalog.my_schema TO group_name;
```

### Referencias - Fase 6

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Create external locations Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/external-locations) |
| Docs | Connect to cloud storage using UC | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/) |
| Docs | Azure managed identities in UC | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/azure-managed-identities) |
| Docs | Manage external locations | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/manage-external-locations) |

---

## Fase 7 -- Migrar SQL Warehouses e Dashboards

### 7.1 SQL Warehouses

```
databricks warehouses list --profile ORIGEM --output json > warehouses.json
databricks warehouses create --json-file warehouse_config.json --profile DESTINO
```

### 7.2 SQL Dashboards e Queries (Lakeview / Legacy)

```
databricks lakeview list --profile ORIGEM --output json > dashboards.json
databricks lakeview get --dashboard-id <id> --profile ORIGEM --output json > dashboard.json
databricks lakeview create --json-file dashboard.json --profile DESTINO
```

### 7.3 SQL Alerts

```
databricks alerts list --profile ORIGEM --output json > alerts.json
```

Recriar manualmente com as mesmas configs e queries.

### Referencias - Fase 7

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | Create a SQL warehouse Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/compute/sql-warehouse/create) |
| Docs | SQL warehouse admin settings | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/admin/sql/) |
| Docs | Lakeview API reference | [Databricks API](https://docs.databricks.com/api/workspace/lakeview) |
| Docs | Manage dashboards with APIs | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/dashboards/tutorials/workspace-dashboard-api) |
| Docs | Dashboard API tutorial | [Databricks Docs](https://docs.databricks.com/aws/en/dashboards/tutorials/dashboard-crud-api) |

---

## Fase 8 -- Migrar Configuracoes de Rede e Seguranca

### 8.1 VNet Peering / Private Link

- Reconfigurar VNet injection na nova subscription
- Reestabelecer Private Endpoints para o Storage Account
- Atualizar NSG rules e UDR routes

### 8.2 IP Access Lists

```
databricks ip-access-lists list --profile ORIGEM --output json > ip_lists.json
databricks ip-access-lists create --json-file ip_list.json --profile DESTINO
```

### 8.3 Diagnostic Logging

- Reconfigurar Azure Monitor Diagnostic Settings na nova workspace
- Apontar para o mesmo Log Analytics Workspace ou criar novo

### Referencias - Fase 8

| Tipo | Descricao | Link |
|------|-----------|------|
| Docs | VNet injection Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/vnet-inject) |
| Docs | Private Link Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/private-link-standard) |
| Docs | Inbound Private Link | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/front-end-private-connect) |
| Docs | Private Link concepts | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/network/concepts/private-link) |
| Docs | IP Access Lists Azure | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/ip-access-list) |
| Docs | IP Access Lists workspace | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/ip-access-list-workspace) |
| Docs | IP Access Lists API | [Databricks API](https://docs.databricks.com/api/workspace/ipaccesslists) |

---

## Fase 9 -- Validacao

### 9.1 Checklist de Validacao

| Item | Comando de Verificacao | Status |
|------|------------------------|--------|
| Notebooks importados | databricks workspace list / --profile DESTINO | Pendente |
| Clusters criam com sucesso | databricks clusters list --profile DESTINO | Pendente |
| Jobs existem e estao configurados | databricks jobs list --profile DESTINO | Pendente |
| Pipelines DLT criados | databricks pipelines list --profile DESTINO | Pendente |
| Storage acessivel | Executar notebook de teste com leitura/escrita no ADLS | Pendente |
| Unity Catalog funcional | SHOW CATALOGS; SHOW SCHEMAS IN catalog; | Pendente |
| Secrets disponiveis | databricks secrets list --scope scope --profile DESTINO | Pendente |
| SQL Warehouses operacionais | Executar query de teste | Pendente |
| Permissoes corretas | Testar acesso com diferentes usuarios | Pendente |
| Jobs executam com sucesso | Disparar run manual dos jobs criticos | Pendente |

### 9.2 Teste End-to-End

1. Executar um job completo que leia do storage, processe e escreva
2. Validar que pipelines DLT iniciam e processam dados
3. Confirmar que dashboards renderizam corretamente
4. Verificar que alertas disparam conforme esperado

---

## Fase 10 -- Cutover e Decommission

### 10.1 Cutover

1. Pausar todos os jobs na workspace origem
2. Ativar schedules dos jobs na workspace destino
3. Atualizar DNS / bookmarks internos
4. Comunicar equipes sobre a nova URL da workspace
5. Se movendo o Storage (Opcao B): executar az resource move agora

### 10.2 Periodo de Coexistencia (recomendado: 2-4 semanas)

- Manter workspace origem em read-only (remover permissoes de escrita)
- Monitorar jobs na nova workspace
- Resolver issues de migracao

### 10.3 Decommission

- Deletar workspace origem apos validacao completa
- Remover role assignments temporarios de cross-tenant
- Limpar resource group antigo

---

## Resumo de Riscos e Mitigacoes

| Risco | Mitigacao |
|-------|-----------|
| Secrets perdidos | Documentar todos os valores ANTES da migracao |
| IDs de cluster mudam | Script para mapear old_id para new_id nos jobs |
| Permissoes nao replicadas | Usar SCIM/Entra ID para sync automatico |
| Downtime no storage move | Usar cross-tenant access primeiro, mover depois |
| Tabelas managed sem dados | Fazer backup com DEEP CLONE antes de migrar |
| Mount points quebrados | Recriar mounts ou migrar para External Locations (UC) |

---

## Referencias Gerais e Ferramentas

### Documentacao Oficial

| Recurso | Link |
|---------|------|
| Microsoft Learn - Azure Databricks Migration | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/migration/) |
| Databricks Documentation | [Databricks Docs](https://docs.databricks.com/) |
| Azure Databricks on Microsoft Learn | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/databricks/) |

### Ferramentas de Migracao

| Ferramenta | Link |
|------------|------|
| Databricks Labs Migrate Tool | [GitHub](https://github.com/databrickslabs/migrate) |
| Terraform Exporter | [Terraform Registry](https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides/experimental-exporter) |
| Databricks Terraform Provider | [GitHub](https://github.com/databricks/terraform-provider-databricks) |

### Videos

| Titulo | Link |
|--------|------|
| Unity Catalog Setup Step by Step | [YouTube](https://www.youtube.com/watch?v=M2Et5aBj2aw) |
| Databricks Asset Bundles - Unifying Tool for Deployment | [Class Central](https://www.classcentral.com/course/youtube-databricks-asset-bundles-a-unifying-tool-for-deployment-on-databricks-306362) |
| Delta Live Tables Best Practices | [Class Central](https://www.classcentral.com/course/youtube-delta-live-tables-in-depth-best-practices-for-intelligent-data-pipelines-306192) |

### Artigos da Comunidade

| Titulo | Link |
|--------|------|
| Databricks Workspace Migration (Medium) | [Medium - D One](https://medium.com/d-one/databricks-workspace-migration-ce450e3931da) |
| Guide to Recovering and Migrating Azure Databricks Workspaces | [Medium - Tauqeer Khan](https://medium.com/@tauqeerkhan755/comprehensive-guide-to-recovering-and-migrating-azure-databricks-workspaces-95399747a186) |
| Microsoft Q&A - Migrate Databricks Workloads | [Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5493452/migrate-databricks-workloads-from-one-azure-accoun) |
# Apendice B: Scripts Parametrizados de Migracao

---

## Visao Geral dos Scripts

Quatro scripts bash parametrizados automatizam todo o processo de migracao. O usuario passa subscription, resource group, workspace e demais informacoes tanto para origem como destino.

| Script | Funcao |
|--------|--------|
| **migrate.sh** | Script master que orquestra os 3 passos |
| 01_export_origem_config.sh | Exporta configuracao de infra da ORIGEM |
| 02_create_destino_infra.sh | Recria infra identica no DESTINO |
| 03_migrate_data.sh | Migra notebooks, secrets e jobs |

---

## migrate.sh - Script Master

Orquestra todo o processo de migracao em 3 passos. Aceita todos os parametros de origem e destino em uma unica chamada.

### Parametros Obrigatorios

| Parametro | Descricao |
|-----------|-----------|
| --origem-subscription | Azure Subscription ID da conta origem |
| --origem-resource-group | Resource Group da workspace origem |
| --origem-workspace | Nome da workspace Databricks origem |
| --origem-cli-profile | Profile do Databricks CLI para a origem |
| --destino-subscription | Azure Subscription ID da conta destino |
| --destino-resource-group | Resource Group para a workspace destino |
| --destino-workspace | Nome da workspace Databricks destino |
| --destino-cli-profile | Profile do Databricks CLI para o destino |

### Parametros Opcionais

| Parametro | Descricao | Default |
|-----------|-----------|---------|
| --destino-vnet-name | Nome da VNet no destino | vnet-WORKSPACE |
| --destino-location | Regiao Azure do destino | Herda da origem |
| --destino-vnet-address-space | CIDR da VNet destino | Herda da origem |
| --secrets-file | JSON com valores dos secrets | Nenhum (usa placeholder) |
| --export-dir | Diretorio para exportacao | Auto-gerado com timestamp |
| --skip-infra | Pula criacao de infra | false |
| --skip-data | Pula migracao de dados | false |
| --dry-run | Mostra plano sem executar | false |
| --help | Mostra documentacao completa | - |

### Exemplo 1: Migracao Completa (infra + dados)

```
./migrate.sh \
    --origem-subscription "aaaa-bbbb-1111-cccc" \
    --origem-resource-group "rg-prod" \
    --origem-workspace "dbw-prod" \
    --origem-cli-profile "prod-origem" \
    --destino-subscription "dddd-eeee-2222-ffff" \
    --destino-resource-group "rg-prod-new" \
    --destino-workspace "dbw-prod-new" \
    --destino-cli-profile "prod-destino" \
    --destino-vnet-name "vnet-prod-new" \
    --secrets-file ./secrets_values.json
```

### Exemplo 2: Apenas Migrar Dados (infra ja criada)

```
./migrate.sh \
    --origem-subscription "aaaa-bbbb-1111-cccc" \
    --origem-resource-group "rg-prod" \
    --origem-workspace "dbw-prod" \
    --origem-cli-profile "prod-origem" \
    --destino-subscription "dddd-eeee-2222-ffff" \
    --destino-resource-group "rg-prod-new" \
    --destino-workspace "dbw-prod-new" \
    --destino-cli-profile "prod-destino" \
    --skip-infra
```

### Exemplo 3: Dry Run (apenas ver o plano)

```
./migrate.sh \
    --origem-subscription "aaaa-bbbb-1111-cccc" \
    --origem-resource-group "rg-prod" \
    --origem-workspace "dbw-prod" \
    --origem-cli-profile "prod-origem" \
    --destino-subscription "dddd-eeee-2222-ffff" \
    --destino-resource-group "rg-prod-new" \
    --destino-workspace "dbw-prod-new" \
    --destino-cli-profile "prod-destino" \
    --dry-run
```

### Exemplo 4: Apenas Criar Infra (sem migrar dados)

```
./migrate.sh \
    --origem-subscription "aaaa-bbbb-1111-cccc" \
    --origem-resource-group "rg-prod" \
    --origem-workspace "dbw-prod" \
    --origem-cli-profile "prod-origem" \
    --destino-subscription "dddd-eeee-2222-ffff" \
    --destino-resource-group "rg-prod-new" \
    --destino-workspace "dbw-prod-new" \
    --destino-cli-profile "prod-destino" \
    --skip-data
```

---

## 01_export_origem_config.sh - Exportar Infra da Origem

Exporta toda a configuracao de infraestrutura da workspace origem para um JSON consolidado.

### Parametros

| Parametro | Obrigatorio | Descricao |
|-----------|-------------|-----------|
| --subscription | Sim | Azure Subscription ID |
| --resource-group | Sim | Resource Group da workspace |
| --workspace-name | Sim | Nome da workspace |
| --output-dir | Nao | Diretorio de saida (default: ./origem-export) |

### Uso

```
./01_export_origem_config.sh \
    --subscription "3f2e4d32-8e8d-46d6-82bc-5bb8d962328b" \
    --resource-group "rg-production" \
    --workspace-name "dbw-production" \
    --output-dir ./export
```

### O Que Exporta

- Workspace: SKU, location, network settings, no-public-ip
- VNet: address space, subnets, delegations
- NSG: rules e associacoes com subnets
- Private Endpoints: subnet, group ID, connection status
- Private DNS Zones: zone name e VNet links

### Saida

Gera o arquivo **migration_config.json** com toda a configuracao consolidada, usado como input pelo script 02.

---

## 02_create_destino_infra.sh - Criar Infra no Destino

Le o migration_config.json e recria toda a infraestrutura na conta destino.

### Parametros

| Parametro | Obrigatorio | Descricao |
|-----------|-------------|-----------|
| --config | Sim | Caminho para o migration_config.json |
| --subscription | Sim | Subscription ID do destino |
| --resource-group | Sim | Resource Group do destino |
| --workspace-name | Sim | Nome da workspace destino |
| --vnet-name | Nao | Nome da VNet (default: vnet-WORKSPACE) |
| --cli-profile | Nao | Profile do CLI (default: migration-destino) |
| --location | Nao | Regiao Azure (default: herda da origem) |
| --vnet-address-space | Nao | CIDR da VNet (default: herda da origem) |

### Uso

```
./02_create_destino_infra.sh \
    --config ./export/migration_config.json \
    --subscription "dddd-eeee-2222-ffff" \
    --resource-group "rg-prod-new" \
    --workspace-name "dbw-prod-new" \
    --vnet-name "vnet-prod-new" \
    --cli-profile "prod-destino"
```

### O Que Cria (em ordem)

1. Resource Group
2. VNet com mesmo address space da origem
3. Subnets com mesmas CIDRs e delegations
4. NSG associado as subnets com delegation Databricks
5. Workspace Databricks com VNet injection
6. Private Endpoint com Private DNS Zone e VNet link

---

## 03_migrate_data.sh - Migrar Dados

Migra notebooks, secret scopes e jobs via Databricks CLI.

### Parametros

| Parametro | Obrigatorio | Descricao |
|-----------|-------------|-----------|
| --profile-origem | Sim | Profile do CLI da origem |
| --profile-destino | Sim | Profile do CLI do destino |
| --export-dir | Nao | Diretorio de exportacao (default: ./migration-export) |
| --secrets-file | Nao | JSON com valores reais dos secrets |

### Uso

```
./03_migrate_data.sh \
    --profile-origem "prod-origem" \
    --profile-destino "prod-destino" \
    --export-dir ./export/data \
    --secrets-file ./secrets_values.json
```

### O Que Migra

| Fase | Recurso | Metodo | Observacoes |
|------|---------|--------|-------------|
| 1 | Notebooks | workspace export-dir / import-dir | Exporta toda a arvore recursivamente |
| 2 | Secret Scopes | list-scopes + create-scope + put-secret | Valores nao sao exportaveis pela API |
| 3 | Jobs | jobs get + limpeza JSON + jobs create | Remove campos read-only automaticamente |

### Formato do Arquivo de Secrets

```
{
  "scope_name_1": {
    "key1": "valor_real_1",
    "key2": "valor_real_2"
  },
  "scope_name_2": {
    "key_a": "valor_real_a"
  }
}
```

Se o arquivo nao for fornecido, secrets sao criados com valor **PLACEHOLDER** e devem ser atualizados manualmente.

### Saidas

- **notebooks/**: Notebooks exportados em formato .py/.sql/.scala
- **secrets/**: Metadata dos scopes e keys (valores nao incluidos)
- **jobs/**: Definicoes completas dos jobs + **job_id_mapping.csv** com mapeamento de IDs antigo para novo

---

## Pre-requisitos

Antes de executar os scripts, instale e configure:

1. **Azure CLI** (az): autenticado nas subscriptions origem e destino

```
az login
az account set --subscription <subscription-id>
```

2. **Databricks CLI**: profiles configurados para ambas workspaces

```
databricks auth login --host https://<workspace-url> --profile <profile-name>
```

3. **jq**: processador JSON de linha de comando (usado pelos scripts)

```
brew install jq    # macOS
apt install jq     # Ubuntu/Debian
```

4. **Python 3**: necessario para limpeza de JSON dos jobs

---

## Resultado da Simulacao Real

A simulacao foi executada em duas workspaces Azure na subscription field-eng com a seguinte configuracao:

### Ambiente

| | ORIGEM | DESTINO |
|---|---|---|
| **Subscription** | field-eng (3f2e4d32...) | field-eng (3f2e4d32...) |
| **Resource Group** | rg-migration-sim | rg-destino-new |
| **Workspace** | dbw-origem | dbw-destino |
| **URL** | [adb-7405608326341930](https://adb-7405608326341930.10.azuredatabricks.net) | [adb-7405609879665351](https://adb-7405609879665351.11.azuredatabricks.net) |
| **VNet** | vnet-dbricks-origem (10.0.0.0/16) | vnet-dbricks-destino (10.0.0.0/16) |
| **Host Subnet** | snet-dbricks-host (10.0.1.0/24) | snet-dbricks-host (10.0.1.0/24) |
| **Container Subnet** | snet-dbricks-container (10.0.2.0/24) | snet-dbricks-container (10.0.2.0/24) |
| **No Public IP** | true | true |
| **Private Endpoint** | pe-dbw-origem (Approved) | pe-dbw-destino (Approved) |
| **Private DNS** | privatelink.azuredatabricks.net | privatelink.azuredatabricks.net |
| **Storage SKU** | Standard_GRS | Standard_GRS |

### Checklist de Validacao

| Check | Status | Detalhes |
|-------|--------|----------|
| Notebooks | **PASS** | 3/3 migrados, conteudo verificado |
| Secret Scopes | **PASS** | 1 scope, 3 secrets migrados com valores reais |
| Jobs | **PASS** | 2 jobs com schedules, tasks e cluster configs identicos |
| Unity Catalog | **PASS** | Metastore compartilhado, catalogs acessiveis em ambas |
| DBFS / Storage | **PASS** | Estrutura identica, mesmo SKU |
| Rede (VNet/PE/NSG) | **PASS** | Configuracao de seguranca identica |

### Mapeamento de Job IDs

| Job | ORIGEM ID | DESTINO ID |
|-----|-----------|------------|
| ETL_Pipeline_Daily | 929861468812674 | 59622167266487 |
| Analytics_Report_Weekly | 480628664634304 | 1006679308452613 |
# Apendice C: Execucao no Windows

---

## Visao Geral

Os scripts de migracao estao disponiveis em duas versoes:

| Versao | Diretorio | Requisitos |
|--------|-----------|------------|
| **Bash** (Linux/macOS) | migration-scripts/ | bash, jq, python3 |
| **PowerShell** (Windows) | migration-scripts/powershell/ | PowerShell 5.1+ ou PowerShell 7+ |

Ambas as versoes sao funcionalmente identicas e produzem os mesmos resultados.

---

## Opcao 1: PowerShell Nativo (Recomendado para Windows)

### Pre-requisitos Windows

1. **Azure CLI**: Instalar via MSI ou winget

```
winget install Microsoft.AzureCLI
```

2. **Databricks CLI**: Instalar via winget ou download direto

```
winget install Databricks.DatabricksCLI
```

3. **Python 3**: Instalar via Microsoft Store ou python.org

```
winget install Python.Python.3.12
```

4. **PowerShell 7+** (recomendado, mas funciona com 5.1):

```
winget install Microsoft.PowerShell
```

### Autenticacao

```
# Azure CLI
az login
az account set -s "<subscription-id>"

# Databricks CLI
databricks auth login --host https://<workspace-url> --profile <profile-name>
```

### Scripts PowerShell Disponiveis

| Script | Funcao |
|--------|--------|
| **migrate.ps1** | Script master que orquestra os 3 passos |
| 01_export_origem_config.ps1 | Exporta infra da ORIGEM |
| 02_create_destino_infra.ps1 | Cria infra no DESTINO |
| 03_migrate_data.ps1 | Migra notebooks, secrets e jobs |

### Exemplo: Migracao Completa no PowerShell

```
.\migrate.ps1 `
    -OrigemSubscription "aaaa-bbbb-1111" `
    -OrigemResourceGroup "rg-prod" `
    -OrigemWorkspace "dbw-prod" `
    -OrigemCliProfile "prod-origem" `
    -DestinoSubscription "dddd-eeee-2222" `
    -DestinoResourceGroup "rg-prod-new" `
    -DestinoWorkspace "dbw-prod-new" `
    -DestinoCliProfile "prod-destino" `
    -DestinoVnetName "vnet-prod-new" `
    -SecretsFile .\secrets_values.json
```

### Exemplo: Dry Run no PowerShell

```
.\migrate.ps1 `
    -OrigemSubscription "aaaa-bbbb-1111" `
    -OrigemResourceGroup "rg-prod" `
    -OrigemWorkspace "dbw-prod" `
    -OrigemCliProfile "prod-origem" `
    -DestinoSubscription "dddd-eeee-2222" `
    -DestinoResourceGroup "rg-prod-new" `
    -DestinoWorkspace "dbw-prod-new" `
    -DestinoCliProfile "prod-destino" `
    -DryRun
```

### Exemplo: Apenas Dados (infra ja existe)

```
.\migrate.ps1 `
    -OrigemSubscription "aaaa-bbbb-1111" `
    -OrigemResourceGroup "rg-prod" `
    -OrigemWorkspace "dbw-prod" `
    -OrigemCliProfile "prod-origem" `
    -DestinoSubscription "dddd-eeee-2222" `
    -DestinoResourceGroup "rg-prod-new" `
    -DestinoWorkspace "dbw-prod-new" `
    -DestinoCliProfile "prod-destino" `
    -SkipInfra
```

### Diferenca de Sintaxe: Bash vs PowerShell

| Conceito | Bash | PowerShell |
|----------|------|------------|
| Parametros | --origem-subscription | -OrigemSubscription |
| Flags booleanas | --skip-infra | -SkipInfra |
| Continuacao de linha | \ (backslash) | ` (backtick) |
| Executar script | ./migrate.sh | .\migrate.ps1 |
| Help | --help | Get-Help .\migrate.ps1 -Full |

### Politica de Execucao (Windows)

Se o PowerShell bloquear a execucao de scripts, execute:

```
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Opcao 2: WSL (Windows Subsystem for Linux)

### Instalacao do WSL

```
wsl --install
```

Reinicie o computador apos a instalacao.

### Instalar Dependencias no WSL

```
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Databricks CLI
curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

# jq e Python
sudo apt update && sudo apt install -y jq python3
```

### Autenticacao no WSL

```
az login
databricks auth login --host https://<workspace-url> --profile <profile-name>
```

### Executar os Scripts Bash

```
cd /mnt/c/Users/<seu-usuario>/migration-scripts/
chmod +x *.sh

./migrate.sh \
    --origem-subscription "aaaa-bbbb-1111" \
    --origem-resource-group "rg-prod" \
    --origem-workspace "dbw-prod" \
    --origem-cli-profile "prod-origem" \
    --destino-subscription "dddd-eeee-2222" \
    --destino-resource-group "rg-prod-new" \
    --destino-workspace "dbw-prod-new" \
    --destino-cli-profile "prod-destino"
```

### Consideracoes do WSL

- Os scripts bash rodam sem nenhuma modificacao
- Acesse seus arquivos Windows via /mnt/c/
- O Azure CLI no WSL usa credenciais separadas do Windows (precisa fazer az login novamente)
- O Databricks CLI no WSL tambem usa profiles separados

---

## Opcao 3: Git Bash

### Instalacao

Instale o [Git for Windows](https://git-scm.com/download/win) que inclui o Git Bash.

### Limitacoes

- Maioria dos comandos funciona normalmente
- Caminhos Windows podem causar problemas (use barras / ao inves de \)
- Alguns comandos interativos podem nao funcionar corretamente
- Recomendado apenas para uso rapido; para producao, use PowerShell ou WSL

### Executar

```
cd /c/Users/<seu-usuario>/migration-scripts/
./migrate.sh --help
```

---

## Tabela Comparativa das Opcoes

| Criterio | PowerShell | WSL | Git Bash |
|----------|------------|-----|----------|
| **Instalacao** | Nativa no Windows | Requer instalacao WSL | Incluso com Git |
| **Compatibilidade** | 100% (scripts dedicados) | 100% (scripts bash originais) | ~90% |
| **Desempenho** | Nativo | Quase nativo | Bom |
| **Suporte corporativo** | Excelente | Bom | Basico |
| **Recomendado para** | Producao / Cliente | Desenvolvedores | Uso rapido |
