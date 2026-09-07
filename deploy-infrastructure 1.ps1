<#
.SYNOPSIS
    Full infrastructure deployment for the EHCP Drafting application.

.DESCRIPTION
    Provisions Azure resources, enables system-assigned managed identities wherever
    supported, deploys a Foundry resource plus Foundry project for model hosting,
    creates Azure Key Vault for residual secrets, assigns runtime RBAC, builds the
    app images with ACR Tasks, and deploys the backend + frontend to Azure Container
    Apps using managed identities only for runtime Azure service access.

.PARAMETER SubscriptionId
    Azure Subscription ID.

.PARAMETER ResourceGroup
    Resource Group name to create or reuse.

.PARAMETER Location
    Azure region (default: swedencentral).

.PARAMETER Prefix
    Naming prefix for all resources.

.PARAMETER FoundryModelName
    Model name to deploy into the Foundry resource.

.PARAMETER FoundryModelVersion
    Model version to deploy.

.PARAMETER FoundryModelFormat
    Model provider / format name for deployment.

.PARAMETER FoundryModelSkuName
    Model deployment SKU.

.PARAMETER FoundryModelCapacity
    Model deployment capacity.

.PARAMETER SkipInfra
    Skip infrastructure creation and only build + deploy apps plus refresh RBAC.
#>

param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = "swedencentral",
    [string]$Prefix = "ehcp-org",
    [string]$FoundryModelName = "gpt-5.2",
    [string]$FoundryModelVersion = "2025-12-11",
    [string]$FoundryModelFormat = "OpenAI",
    [string]$FoundryModelSkuName = "GlobalStandard",
    [int]$FoundryModelCapacity = 20,
    [switch]$SkipInfra
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
if ($null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Fail([string]$msg) {
    throw $msg
}

function Write-Step([string]$msg) {
    Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "$('=' * 60)" -ForegroundColor Cyan
}

function Write-SubStep([string]$msg) {
    Write-Host "  -> $msg" -ForegroundColor Yellow
}

function Write-Done([string]$msg) {
    Write-Host "  [done] $msg" -ForegroundColor Green
}

function Invoke-AzCommandLine([string[]]$arguments) {
    $escaped = $arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }

    $commandLine = "az " + ($escaped -join " ")
    & $env:ComSpec /d /c $commandLine
}

function Get-TrimmedValue($value) {
    if ($null -eq $value) {
        return $null
    }

    return "$value".Trim()
}

function Ensure-Command([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "'$name' is not installed or not on PATH."
    }
}

function Test-ContainerAppExists([string]$name, [string]$resourceGroup) {
    $query = "[?name=='{0}'] | length(@)" -f $name
    $count = az containerapp list --resource-group $resourceGroup --query $query -o tsv 2>$null
    return ($LASTEXITCODE -eq 0 -and [int]$count -gt 0)
}

function Ensure-ContainerAppIdentity([string]$name, [string]$resourceGroup) {
    az containerapp identity assign `
        --name $name `
        --resource-group $resourceGroup `
        --system-assigned `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Ensure-ContainerRegistryIdentity([string]$name, [string]$resourceGroup, [string]$server) {
    az containerapp registry set `
        --name $name `
        --resource-group $resourceGroup `
        --server $server `
        --identity system `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Ensure-RoleAssignment([string]$principalId, [string]$roleName, [string]$scope) {
    $query = "[?roleDefinitionName=='{0}'] | length(@)" -f $roleName
    $existing = az role assignment list `
        --assignee $principalId `
        --scope $scope `
        --query $query `
        -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and [int]$existing -gt 0) {
        return
    }

    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role $roleName `
        --scope $scope `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Ensure-CosmosDataRoleAssignment([string]$principalId, [string]$accountName, [string]$resourceGroup) {
    $roleDefinitionId = "00000000-0000-0000-0000-000000000002"
    $query = "[?principalId=='{0}' && roleDefinitionId=='{1}'] | length(@)" -f $principalId, $roleDefinitionId
    $existing = az cosmosdb sql role assignment list `
        --account-name $accountName `
        --resource-group $resourceGroup `
        --query $query `
        -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and [int]$existing -gt 0) {
        return
    }

    az cosmosdb sql role assignment create `
        --account-name $accountName `
        --resource-group $resourceGroup `
        --scope "/" `
        --principal-id $principalId `
        --role-definition-id $roleDefinitionId `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Get-ContainerAppPrincipalId([string]$name, [string]$resourceGroup) {
    $principalId = az containerapp show `
        --name $name `
        --resource-group $resourceGroup `
        --query "identity.principalId" `
        -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
        Fail "Could not resolve principal ID for Container App '$name'."
    }
    return (Get-TrimmedValue $principalId)
}

function New-StorageAccountName([string]$prefixToken) {
    $name = ($prefixToken + "storage").ToLower()
    $name = $name -replace '[^a-z0-9]', ''
    if ($name.Length -gt 24) { $name = $name.Substring(0, 24) }
    if ($name.Length -lt 3) { $name = ($name + "sto").Substring(0, 3) }
    return $name
}

function New-KeyVaultName([string]$prefixToken, [string]$subscriptionId) {
    $token = ($subscriptionId -replace '-', '').ToLower()
    if ($token.Length -gt 5) { $token = $token.Substring(0, 5) }
    $name = ($prefixToken + "kv" + $token).ToLower()
    $name = $name -replace '[^a-z0-9-]', ''
    if ($name.Length -gt 24) { $name = $name.Substring(0, 24) }
    if ($name.Length -lt 3) { $name = ($name + "kvx").Substring(0, 3) }
    return $name.Trim('-')
}

Ensure-Command "az"

$prefixSlug = ($Prefix.ToLower() -replace '[^a-z0-9-]', '-') -replace '-+', '-'
$prefixSlug = $prefixSlug.Trim('-')
if ([string]::IsNullOrWhiteSpace($prefixSlug)) { $prefixSlug = "ehcp" }

$prefixToken = ($Prefix.ToLower() -replace '[^a-z0-9]', '')
if ([string]::IsNullOrWhiteSpace($prefixToken)) { $prefixToken = "ehcp" }

$ACR_NAME = ("${prefixToken}draftregistry")
if ($ACR_NAME.Length -gt 50) { $ACR_NAME = $ACR_NAME.Substring(0, 50) }
$ACR_SERVER = "$ACR_NAME.azurecr.io"

$FOUNDRY_NAME = "${prefixSlug}-foundry"
$FOUNDRY_PROJECT_NAME = "${prefixSlug}-project"
$FOUNDRY_DEPLOYMENT = $FoundryModelName
$DOC_INTEL_NAME = "${prefixSlug}-docintel"
$VNET_NAME = "${prefixSlug}-vnet"
$CONTAINERAPPS_SUBNET = "snet-containerapps"
$PRIVATE_ENDPOINT_SUBNET = "snet-private-endpoints"
$CONTAINERAPPS_SUBNET_PREFIX = "10.42.0.0/23"
$PRIVATE_ENDPOINT_SUBNET_PREFIX = "10.42.2.0/27"
$VNET_ADDRESS_PREFIX = "10.42.0.0/16"
$STORAGE_ACCOUNT = New-StorageAccountName -prefixToken $prefixToken
$STORAGE_CONTAINER = "ehcp-outputs"
$STORAGE_PRIVATE_ENDPOINT = "${prefixSlug}-storage-blob-pe"
$STORAGE_PRIVATE_DNS_ZONE = "privatelink.blob.core.windows.net"
$COSMOS_ACCOUNT = "${prefixSlug}-cosmos"
$COSMOS_PRIVATE_ENDPOINT = "${prefixSlug}-cosmos-sql-pe"
$COSMOS_PRIVATE_DNS_ZONE = "privatelink.documents.azure.com"
$COSMOS_DATABASE = "ehcp-audit"
$COSMOS_CONTAINER_ACTIVITY = "activity-logs"
$COSMOS_CONTAINER_JOB = "job-logs"
$KEY_VAULT_NAME = New-KeyVaultName -prefixToken $prefixToken -subscriptionId $SubscriptionId
$KEY_VAULT_PRIVATE_ENDPOINT = "${prefixSlug}-keyvault-pe"
$KEY_VAULT_PRIVATE_DNS_ZONE = "privatelink.vaultcore.azure.net"
$KEY_VAULT_SECRET_NAME = "entra-client-secret"
$CAE_NAME = "${prefixSlug}-environment"
$BACKEND_APP = "${prefixSlug}-backend"
$FRONTEND_APP = "${prefixSlug}-frontend"
$LOG_ANALYTICS = "${prefixSlug}-logs"

Write-Step "Pre-flight checks"
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "Not logged in. Run 'az login' first."
}

Write-SubStep "Setting subscription: $SubscriptionId"
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Done "Subscription set"

if (-not $SkipInfra) {
    Write-Step "1. Resource Group: $ResourceGroup"
    az group create --name $ResourceGroup --location $Location -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Done "Resource Group ready"

    Write-Step "2. Virtual network for Container Apps and Storage private endpoint"
    $vnetExists = az network vnet show `
        --name $VNET_NAME `
        --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vnetExists)) {
        Write-SubStep "Using existing VNet: $VNET_NAME"
    } else {
        az network vnet create `
            --name $VNET_NAME `
            --resource-group $ResourceGroup `
            --location $Location `
            --address-prefixes $VNET_ADDRESS_PREFIX `
            --subnet-name $CONTAINERAPPS_SUBNET `
            --subnet-prefixes $CONTAINERAPPS_SUBNET_PREFIX `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $privateEndpointSubnetExists = az network vnet subnet show `
        --name $PRIVATE_ENDPOINT_SUBNET `
        --resource-group $ResourceGroup `
        --vnet-name $VNET_NAME `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($privateEndpointSubnetExists)) {
        Write-SubStep "Using existing private-endpoint subnet: $PRIVATE_ENDPOINT_SUBNET"
    } else {
        az network vnet subnet create `
            --name $PRIVATE_ENDPOINT_SUBNET `
            --resource-group $ResourceGroup `
            --vnet-name $VNET_NAME `
            --address-prefixes $PRIVATE_ENDPOINT_SUBNET_PREFIX `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    az network vnet subnet update `
        --name $CONTAINERAPPS_SUBNET `
        --resource-group $ResourceGroup `
        --vnet-name $VNET_NAME `
        --delegations Microsoft.App/environments `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    az network vnet subnet update `
        --name $PRIVATE_ENDPOINT_SUBNET `
        --resource-group $ResourceGroup `
        --vnet-name $VNET_NAME `
        --disable-private-endpoint-network-policies true `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Done "Virtual network and subnets ready"

    Write-Step "3. Azure Container Registry: $ACR_NAME"
    $acrInRg = Get-TrimmedValue (az acr list --resource-group $ResourceGroup --query "[0].name" -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and $acrInRg) {
        $ACR_NAME = $acrInRg
        $ACR_SERVER = "$ACR_NAME.azurecr.io"
        Write-SubStep "Using existing ACR in resource group: $ACR_NAME"
    } else {
        $acrNameAvailable = az acr check-name --name $ACR_NAME --query "nameAvailable" -o tsv
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if ($acrNameAvailable -ne "true") {
            $resourceToken = ($ResourceGroup.ToLower() -replace '[^a-z0-9]', '')
            if ([string]::IsNullOrWhiteSpace($resourceToken)) { $resourceToken = "rg" }
            $subToken = ($SubscriptionId -replace '-', '').ToLower()
            if ($subToken.Length -gt 6) { $subToken = $subToken.Substring(0, 6) }
            $altAcrName = ("{0}{1}acr{2}" -f $prefixToken, $resourceToken, $subToken).ToLower() -replace '[^a-z0-9]', ''
            if ($altAcrName.Length -gt 50) { $altAcrName = $altAcrName.Substring(0, 50) }

            $altAvailable = az acr check-name --name $altAcrName --query "nameAvailable" -o tsv
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            if ($altAvailable -ne "true") {
                Fail "No available ACR name found for '$ACR_NAME' or fallback '$altAcrName'."
            }

            Write-SubStep "ACR name '$ACR_NAME' is unavailable globally. Using '$altAcrName'."
            $ACR_NAME = $altAcrName
            $ACR_SERVER = "$ACR_NAME.azurecr.io"
        }

        az acr create `
            --name $ACR_NAME `
            --resource-group $ResourceGroup `
            --location $Location `
            --sku Basic `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    az acr update --name $ACR_NAME --resource-group $ResourceGroup --admin-enabled false -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $acrPrincipalId = az acr identity show `
        --name $ACR_NAME `
        --resource-group $ResourceGroup `
        --query "principalId" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrPrincipalId)) {
        az acr identity assign `
            --identities [system] `
            --name $ACR_NAME `
            --resource-group $ResourceGroup `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "ACR ready with admin auth disabled"

    Write-Step "4. Microsoft Foundry Resource + Project"
    $foundryExists = az cognitiveservices account show `
        --name $FOUNDRY_NAME --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($foundryExists)) {
        Write-SubStep "Using existing Foundry resource: $FOUNDRY_NAME"
        az cognitiveservices account identity assign `
            --name $FOUNDRY_NAME `
            --resource-group $ResourceGroup `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        az cognitiveservices account create `
            --name $FOUNDRY_NAME `
            --resource-group $ResourceGroup `
            --location $Location `
            --kind AIServices `
            --sku S0 `
            --custom-domain $FOUNDRY_NAME `
            --assign-identity `
            --allow-project-management true `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "Foundry resource ready"

    $projectExists = az cognitiveservices account project show `
        --name $FOUNDRY_NAME `
        --resource-group $ResourceGroup `
        --project-name $FOUNDRY_PROJECT_NAME `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($projectExists)) {
        Write-SubStep "Using existing Foundry project: $FOUNDRY_PROJECT_NAME"
    } else {
        az cognitiveservices account project create `
            --name $FOUNDRY_NAME `
            --resource-group $ResourceGroup `
            --project-name $FOUNDRY_PROJECT_NAME `
            --location $Location `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "Foundry project ready"

    Write-SubStep "Deploying model '$FoundryModelName' as '$FOUNDRY_DEPLOYMENT'"
    $deploymentState = az cognitiveservices account deployment show `
        --name $FOUNDRY_NAME `
        --resource-group $ResourceGroup `
        --deployment-name $FOUNDRY_DEPLOYMENT `
        --query "properties.provisioningState" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $deploymentState) {
        Write-SubStep "Using existing Foundry deployment: $FOUNDRY_DEPLOYMENT"
    } else {
        az cognitiveservices account deployment create `
            --name $FOUNDRY_NAME `
            --resource-group $ResourceGroup `
            --deployment-name $FOUNDRY_DEPLOYMENT `
            --model-name $FoundryModelName `
            --model-version $FoundryModelVersion `
            --model-format $FoundryModelFormat `
            --sku-capacity $FoundryModelCapacity `
            --sku-name $FoundryModelSkuName `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "Foundry deployment ready"

    Write-Step "5. Azure Document Intelligence: $DOC_INTEL_NAME"
    $docIntelExists = az cognitiveservices account show `
        --name $DOC_INTEL_NAME --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($docIntelExists)) {
        Write-SubStep "Using existing Document Intelligence account: $DOC_INTEL_NAME"
        az cognitiveservices account identity assign `
            --name $DOC_INTEL_NAME `
            --resource-group $ResourceGroup `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        az cognitiveservices account create `
            --name $DOC_INTEL_NAME `
            --resource-group $ResourceGroup `
            --location $Location `
            --kind FormRecognizer `
            --sku S0 `
            --custom-domain $DOC_INTEL_NAME `
            --assign-identity `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "Document Intelligence ready"

    Write-Step "6. Azure Storage Account: $STORAGE_ACCOUNT"
    $storageExists = az storage account show `
        --name $STORAGE_ACCOUNT --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($storageExists)) {
        Write-SubStep "Using existing storage account: $STORAGE_ACCOUNT"
    } else {
        az storage account create `
            --name $STORAGE_ACCOUNT `
            --resource-group $ResourceGroup `
            --location $Location `
            --sku Standard_LRS `
            --kind StorageV2 `
            --public-network-access Disabled `
            --assign-identity `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    az storage account update `
        --name $STORAGE_ACCOUNT `
        --resource-group $ResourceGroup `
        --assign-identity `
        --public-network-access Disabled `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-SubStep "Creating blob container: $STORAGE_CONTAINER"
    az storage container-rm create `
        --name $STORAGE_CONTAINER `
        --storage-account $STORAGE_ACCOUNT `
        --resource-group $ResourceGroup `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $storagePrivateDnsExists = az network private-dns zone show `
        --resource-group $ResourceGroup `
        --name $STORAGE_PRIVATE_DNS_ZONE `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($storagePrivateDnsExists)) {
        Write-SubStep "Using existing private DNS zone: $STORAGE_PRIVATE_DNS_ZONE"
    } else {
        az network private-dns zone create `
            --resource-group $ResourceGroup `
            --name $STORAGE_PRIVATE_DNS_ZONE `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $storageDnsLinkName = "${VNET_NAME}-blob-link"
    $storageDnsLinkExists = az network private-dns link vnet show `
        --resource-group $ResourceGroup `
        --zone-name $STORAGE_PRIVATE_DNS_ZONE `
        --name $storageDnsLinkName `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($storageDnsLinkExists)) {
        Write-SubStep "Using existing private DNS VNet link: $storageDnsLinkName"
    } else {
        az network private-dns link vnet create `
            --resource-group $ResourceGroup `
            --zone-name $STORAGE_PRIVATE_DNS_ZONE `
            --name $storageDnsLinkName `
            --virtual-network $VNET_NAME `
            --registration-enabled false `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $storageResourceId = az storage account show `
        --name $STORAGE_ACCOUNT `
        --resource-group $ResourceGroup `
        --query "id" -o tsv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $storagePrivateEndpointExists = az network private-endpoint show `
        --name $STORAGE_PRIVATE_ENDPOINT `
        --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($storagePrivateEndpointExists)) {
        Write-SubStep "Using existing storage private endpoint: $STORAGE_PRIVATE_ENDPOINT"
    } else {
        az network private-endpoint create `
            --name $STORAGE_PRIVATE_ENDPOINT `
            --resource-group $ResourceGroup `
            --location $Location `
            --vnet-name $VNET_NAME `
            --subnet $PRIVATE_ENDPOINT_SUBNET `
            --private-connection-resource-id $storageResourceId `
            --group-id blob `
            --connection-name "${STORAGE_PRIVATE_ENDPOINT}-conn" `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $storageDnsZoneGroupExists = az network private-endpoint dns-zone-group show `
        --resource-group $ResourceGroup `
        --endpoint-name $STORAGE_PRIVATE_ENDPOINT `
        --name default `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($storageDnsZoneGroupExists)) {
        Write-SubStep "Using existing storage private DNS zone group"
    } else {
        az network private-endpoint dns-zone-group create `
            --resource-group $ResourceGroup `
            --endpoint-name $STORAGE_PRIVATE_ENDPOINT `
            --name default `
            --private-dns-zone $STORAGE_PRIVATE_DNS_ZONE `
            --zone-name $STORAGE_PRIVATE_DNS_ZONE `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "Storage account and container ready"

    Write-Step "7. Azure Cosmos DB: $COSMOS_ACCOUNT"
    $cosmosExists = az cosmosdb show `
        --name $COSMOS_ACCOUNT --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($cosmosExists)) {
        Write-SubStep "Using existing Cosmos DB account: $COSMOS_ACCOUNT"
        az cosmosdb identity assign --name $COSMOS_ACCOUNT --resource-group $ResourceGroup -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        az cosmosdb create `
            --name $COSMOS_ACCOUNT `
            --resource-group $ResourceGroup `
            --locations regionName=$Location failoverPriority=0 `
            --default-consistency-level Session `
            --kind GlobalDocumentDB `
            --assign-identity `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-SubStep "Creating database: $COSMOS_DATABASE"
    az cosmosdb sql database create `
        --account-name $COSMOS_ACCOUNT `
        --resource-group $ResourceGroup `
        --name $COSMOS_DATABASE `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-SubStep "Creating container: $COSMOS_CONTAINER_ACTIVITY"
    az cosmosdb sql container create `
        --account-name $COSMOS_ACCOUNT `
        --resource-group $ResourceGroup `
        --database-name $COSMOS_DATABASE `
        --name $COSMOS_CONTAINER_ACTIVITY `
        --partition-key-path "/partitionKey" `
        --throughput 400 `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-SubStep "Creating container: $COSMOS_CONTAINER_JOB"
    az cosmosdb sql container create `
        --account-name $COSMOS_ACCOUNT `
        --resource-group $ResourceGroup `
        --database-name $COSMOS_DATABASE `
        --name $COSMOS_CONTAINER_JOB `
        --partition-key-path "/partitionKey" `
        --throughput 400 `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $cosmosPublicAccess = az cosmosdb show `
        --name $COSMOS_ACCOUNT `
        --resource-group $ResourceGroup `
        --query "publicNetworkAccess" -o tsv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($cosmosPublicAccess -eq "Disabled") {
        $cosmosPrivateDnsExists = az network private-dns zone show `
            --resource-group $ResourceGroup `
            --name $COSMOS_PRIVATE_DNS_ZONE `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($cosmosPrivateDnsExists)) {
            Write-SubStep "Using existing Cosmos private DNS zone: $COSMOS_PRIVATE_DNS_ZONE"
        } else {
            az network private-dns zone create `
                --resource-group $ResourceGroup `
                --name $COSMOS_PRIVATE_DNS_ZONE `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        $cosmosDnsLinkName = "${VNET_NAME}-cosmos-link"
        $cosmosDnsLinkExists = az network private-dns link vnet show `
            --resource-group $ResourceGroup `
            --zone-name $COSMOS_PRIVATE_DNS_ZONE `
            --name $cosmosDnsLinkName `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($cosmosDnsLinkExists)) {
            Write-SubStep "Using existing Cosmos private DNS VNet link: $cosmosDnsLinkName"
        } else {
            az network private-dns link vnet create `
                --resource-group $ResourceGroup `
                --zone-name $COSMOS_PRIVATE_DNS_ZONE `
                --name $cosmosDnsLinkName `
                --virtual-network $VNET_NAME `
                --registration-enabled false `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        $cosmosResourceId = az cosmosdb show `
            --name $COSMOS_ACCOUNT `
            --resource-group $ResourceGroup `
            --query "id" -o tsv
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        $cosmosPrivateEndpointExists = az network private-endpoint show `
            --name $COSMOS_PRIVATE_ENDPOINT `
            --resource-group $ResourceGroup `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($cosmosPrivateEndpointExists)) {
            Write-SubStep "Using existing Cosmos private endpoint: $COSMOS_PRIVATE_ENDPOINT"
        } else {
            az network private-endpoint create `
                --name $COSMOS_PRIVATE_ENDPOINT `
                --resource-group $ResourceGroup `
                --location $Location `
                --vnet-name $VNET_NAME `
                --subnet $PRIVATE_ENDPOINT_SUBNET `
                --private-connection-resource-id $cosmosResourceId `
                --group-id Sql `
                --connection-name "${COSMOS_PRIVATE_ENDPOINT}-conn" `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        $cosmosDnsZoneGroupExists = az network private-endpoint dns-zone-group show `
            --resource-group $ResourceGroup `
            --endpoint-name $COSMOS_PRIVATE_ENDPOINT `
            --name default `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($cosmosDnsZoneGroupExists)) {
            Write-SubStep "Using existing Cosmos private DNS zone group"
        } else {
            az network private-endpoint dns-zone-group create `
                --resource-group $ResourceGroup `
                --endpoint-name $COSMOS_PRIVATE_ENDPOINT `
                --name default `
                --private-dns-zone $COSMOS_PRIVATE_DNS_ZONE `
                --zone-name $COSMOS_PRIVATE_DNS_ZONE `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }
    Write-Done "Cosmos DB ready"

    Write-Step "8. Azure Key Vault: $KEY_VAULT_NAME"
    $vaultExists = az keyvault show --name $KEY_VAULT_NAME --resource-group $ResourceGroup --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vaultExists)) {
        Write-SubStep "Using existing Key Vault: $KEY_VAULT_NAME"
        az keyvault update `
            --name $KEY_VAULT_NAME `
            --resource-group $ResourceGroup `
            --enable-rbac-authorization true `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        az keyvault create `
            --name $KEY_VAULT_NAME `
            --resource-group $ResourceGroup `
            --location $Location `
            --enable-rbac-authorization true `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $keyVaultPublicAccess = az keyvault show `
        --name $KEY_VAULT_NAME `
        --resource-group $ResourceGroup `
        --query "properties.publicNetworkAccess" -o tsv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($keyVaultPublicAccess -eq "Disabled") {
        $keyVaultPrivateDnsExists = az network private-dns zone show `
            --resource-group $ResourceGroup `
            --name $KEY_VAULT_PRIVATE_DNS_ZONE `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($keyVaultPrivateDnsExists)) {
            Write-SubStep "Using existing Key Vault private DNS zone: $KEY_VAULT_PRIVATE_DNS_ZONE"
        } else {
            az network private-dns zone create `
                --resource-group $ResourceGroup `
                --name $KEY_VAULT_PRIVATE_DNS_ZONE `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        $keyVaultDnsLinkName = "${VNET_NAME}-keyvault-link"
        $keyVaultDnsLinkExists = az network private-dns link vnet show `
            --resource-group $ResourceGroup `
            --zone-name $KEY_VAULT_PRIVATE_DNS_ZONE `
            --name $keyVaultDnsLinkName `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($keyVaultDnsLinkExists)) {
            Write-SubStep "Using existing Key Vault private DNS VNet link: $keyVaultDnsLinkName"
        } else {
            az network private-dns link vnet create `
                --resource-group $ResourceGroup `
                --zone-name $KEY_VAULT_PRIVATE_DNS_ZONE `
                --name $keyVaultDnsLinkName `
                --virtual-network $VNET_NAME `
                --registration-enabled false `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        $keyVaultResourceId = az keyvault show `
            --name $KEY_VAULT_NAME `
            --resource-group $ResourceGroup `
            --query "id" -o tsv
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        $keyVaultPrivateEndpointExists = az network private-endpoint show `
            --name $KEY_VAULT_PRIVATE_ENDPOINT `
            --resource-group $ResourceGroup `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($keyVaultPrivateEndpointExists)) {
            Write-SubStep "Using existing Key Vault private endpoint: $KEY_VAULT_PRIVATE_ENDPOINT"
        } else {
            az network private-endpoint create `
                --name $KEY_VAULT_PRIVATE_ENDPOINT `
                --resource-group $ResourceGroup `
                --location $Location `
                --vnet-name $VNET_NAME `
                --subnet $PRIVATE_ENDPOINT_SUBNET `
                --private-connection-resource-id $keyVaultResourceId `
                --group-id vault `
                --connection-name "${KEY_VAULT_PRIVATE_ENDPOINT}-conn" `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }

        $keyVaultDnsZoneGroupExists = az network private-endpoint dns-zone-group show `
            --resource-group $ResourceGroup `
            --endpoint-name $KEY_VAULT_PRIVATE_ENDPOINT `
            --name default `
            --query "name" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($keyVaultDnsZoneGroupExists)) {
            Write-SubStep "Using existing Key Vault private DNS zone group"
        } else {
            az network private-endpoint dns-zone-group create `
                --resource-group $ResourceGroup `
                --endpoint-name $KEY_VAULT_PRIVATE_ENDPOINT `
                --name default `
                --private-dns-zone $KEY_VAULT_PRIVATE_DNS_ZONE `
                --zone-name $KEY_VAULT_PRIVATE_DNS_ZONE `
                -o none
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }
    Write-Done "Key Vault ready"

    Write-Step "9. Log Analytics + Container Apps Environment"
    az monitor log-analytics workspace create `
        --workspace-name $LOG_ANALYTICS `
        --resource-group $ResourceGroup `
        --location $Location `
        -o none
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $LOG_ANALYTICS_ID = az monitor log-analytics workspace show `
        --workspace-name $LOG_ANALYTICS `
        --resource-group $ResourceGroup `
        --query "customerId" -o tsv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $LOG_ANALYTICS_KEY = az monitor log-analytics workspace get-shared-keys `
        --workspace-name $LOG_ANALYTICS `
        --resource-group $ResourceGroup `
        --query "primarySharedKey" -o tsv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $caeExists = az containerapp env show `
        --name $CAE_NAME `
        --resource-group $ResourceGroup `
        --query "name" -o tsv 2>$null
    $caeShowExitCode = $LASTEXITCODE
    $containerAppsSubnetId = az network vnet subnet show `
        --resource-group $ResourceGroup `
        --vnet-name $VNET_NAME `
        --name $CONTAINERAPPS_SUBNET `
        --query "id" -o tsv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($caeShowExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($caeExists)) {
        Write-SubStep "Using existing Container Apps Environment: $CAE_NAME"
    } else {
        az containerapp env create `
            --name $CAE_NAME `
            --resource-group $ResourceGroup `
            --location $Location `
            --logs-workspace-id $LOG_ANALYTICS_ID `
            --logs-workspace-key $LOG_ANALYTICS_KEY `
            --infrastructure-subnet-resource-id $containerAppsSubnetId `
            -o none
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Done "Container Apps Environment ready"
} else {
    Write-Step "SkipInfra: Resolving existing resource details"

    $acrInRg = az acr list --resource-group $ResourceGroup --query "[0].name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $acrInRg) {
        $ACR_NAME = $acrInRg
        $ACR_SERVER = "$ACR_NAME.azurecr.io"
    }
}

$FOUNDRY_ENDPOINT = az cognitiveservices account show `
    --name $FOUNDRY_NAME `
    --resource-group $ResourceGroup `
    --query "properties.endpoint" -o tsv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$FOUNDRY_ENDPOINT = Get-TrimmedValue $FOUNDRY_ENDPOINT

$DI_ENDPOINT = az cognitiveservices account show `
    --name $DOC_INTEL_NAME `
    --resource-group $ResourceGroup `
    --query "properties.endpoint" -o tsv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$DI_ENDPOINT = Get-TrimmedValue $DI_ENDPOINT

$COSMOS_ENDPOINT = az cosmosdb show `
    --name $COSMOS_ACCOUNT `
    --resource-group $ResourceGroup `
    --query "documentEndpoint" -o tsv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$COSMOS_ENDPOINT = Get-TrimmedValue $COSMOS_ENDPOINT

$KEY_VAULT_URI = az keyvault show `
    --name $KEY_VAULT_NAME `
    --resource-group $ResourceGroup `
    --query "properties.vaultUri" -o tsv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$KEY_VAULT_URI = Get-TrimmedValue $KEY_VAULT_URI

Write-Step "9. Building & pushing Docker images to ACR"
$SCRIPT_DIR = $PSScriptRoot
$APP_ROOT = Join-Path $SCRIPT_DIR "ehcp_agent_final"
if (-not (Test-Path $APP_ROOT)) {
    $APP_ROOT = $SCRIPT_DIR
}

$BACKEND_DIR = Join-Path $APP_ROOT "backend"
$FRONTEND_DIR = Join-Path $APP_ROOT "frontend"

if (-not (Test-Path $BACKEND_DIR)) { Fail "Backend directory not found: $BACKEND_DIR" }
if (-not (Test-Path $FRONTEND_DIR)) { Fail "Frontend directory not found: $FRONTEND_DIR" }

az acr build `
    --registry $ACR_NAME `
    --image "${prefixSlug}-backend:latest" `
    --file (Join-Path $BACKEND_DIR "Dockerfile") `
    --no-logs `
    $BACKEND_DIR `
    -o none
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Done "Backend image pushed"

az acr build `
    --registry $ACR_NAME `
    --image "${prefixSlug}-frontend:latest" `
    --file (Join-Path $FRONTEND_DIR "Dockerfile") `
    --no-logs `
    $FRONTEND_DIR `
    -o none
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Done "Frontend image pushed"

Write-Step "10. Deploying backend Container App: $BACKEND_APP"
$backendEnvVars = @(
    "FOUNDRY_ENDPOINT=$FOUNDRY_ENDPOINT",
    "FOUNDRY_PROJECT_NAME=$FOUNDRY_PROJECT_NAME",
    "FOUNDRY_MODEL_NAME=$FOUNDRY_DEPLOYMENT",
    "FOUNDRY_API_VERSION=2025-04-01-preview",
    "MODEL_TEMPERATURE=0",
    "MODEL_MAX_TOKENS=30",
    "AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT=$DI_ENDPOINT",
    "AZURE_STORAGE_ACCOUNT_URL=https://$STORAGE_ACCOUNT.blob.core.windows.net",
    "AZURE_STORAGE_CONTAINER_NAME=$STORAGE_CONTAINER",
    "COSMOS_DB_ENDPOINT=$COSMOS_ENDPOINT",
    "COSMOS_DB_DATABASE=$COSMOS_DATABASE",
    "COSMOS_DB_CONTAINER=$COSMOS_CONTAINER_ACTIVITY",
    "COSMOS_DB_JOB_CONTAINER=$COSMOS_CONTAINER_JOB",
    "AUTH_ENABLED=false",
    "ENTRA_TENANT_ID=",
    "ENTRA_CLIENT_ID=",
    "AUDIT_LOG_ENABLED=false",
    "BACKEND_HOST=0.0.0.0",
    "BACKEND_PORT=8000",
    "BACKEND_WORKERS=4"
)

if (Test-ContainerAppExists -name $BACKEND_APP -resourceGroup $ResourceGroup) {
    Ensure-ContainerAppIdentity -name $BACKEND_APP -resourceGroup $ResourceGroup
    Ensure-ContainerRegistryIdentity -name $BACKEND_APP -resourceGroup $ResourceGroup -server $ACR_SERVER

    $backendUpdateArgs = @(
        "containerapp", "update",
        "--name", $BACKEND_APP,
        "--resource-group", $ResourceGroup,
        "--image", "$ACR_SERVER/${prefixSlug}-backend:latest",
        "--replace-env-vars"
    ) + $backendEnvVars + @("-o", "none")
    Invoke-AzCommandLine $backendUpdateArgs
} else {
    $backendCreateArgs = @(
        "containerapp", "create",
        "--name", $BACKEND_APP,
        "--resource-group", $ResourceGroup,
        "--environment", $CAE_NAME,
        "--image", "$ACR_SERVER/${prefixSlug}-backend:latest",
        "--registry-server", $ACR_SERVER,
        "--registry-identity", "system",
        "--system-assigned",
        "--target-port", "8000",
        "--ingress", "internal",
        "--min-replicas", "1",
        "--max-replicas", "3",
        "--cpu", "2.0",
        "--memory", "4.0Gi",
        "--env-vars"
    ) + $backendEnvVars + @("-o", "none")
    Invoke-AzCommandLine $backendCreateArgs
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Done "Backend deployed"

Write-Step "11. Deploying frontend Container App: $FRONTEND_APP"
$backendFqdn = az containerapp show `
    --name $BACKEND_APP --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$backendFqdn = Get-TrimmedValue $backendFqdn
$backendUrl = "https://$backendFqdn"

$frontendEnvVars = @(
    "BACKEND_URL=$backendUrl",
    "FRONTEND_URL=",
    "AUTH_ENABLED=false",
    "ENTRA_TENANT_ID=",
    "ENTRA_CLIENT_ID=",
    "ENTRA_FRONTEND_CLIENT_ID=",
    "ENTRA_BACKEND_CLIENT_ID=",
    "ENTRA_SCOPE=",
    "ENTRA_REDIRECT_URI=",
    "AZURE_KEY_VAULT_URL=$KEY_VAULT_URI",
    "ENTRA_CLIENT_SECRET_SECRET_NAME=$KEY_VAULT_SECRET_NAME"
)

if (Test-ContainerAppExists -name $FRONTEND_APP -resourceGroup $ResourceGroup) {
    Ensure-ContainerAppIdentity -name $FRONTEND_APP -resourceGroup $ResourceGroup
    Ensure-ContainerRegistryIdentity -name $FRONTEND_APP -resourceGroup $ResourceGroup -server $ACR_SERVER

    $frontendUpdateArgs = @(
        "containerapp", "update",
        "--name", $FRONTEND_APP,
        "--resource-group", $ResourceGroup,
        "--image", "$ACR_SERVER/${prefixSlug}-frontend:latest",
        "--replace-env-vars"
    ) + $frontendEnvVars + @("-o", "none")
    Invoke-AzCommandLine $frontendUpdateArgs
} else {
    $frontendCreateArgs = @(
        "containerapp", "create",
        "--name", $FRONTEND_APP,
        "--resource-group", $ResourceGroup,
        "--environment", $CAE_NAME,
        "--image", "$ACR_SERVER/${prefixSlug}-frontend:latest",
        "--registry-server", $ACR_SERVER,
        "--registry-identity", "system",
        "--system-assigned",
        "--target-port", "8501",
        "--ingress", "external",
        "--min-replicas", "1",
        "--max-replicas", "3",
        "--cpu", "1.0",
        "--memory", "2.0Gi",
        "--env-vars"
    ) + $frontendEnvVars + @("-o", "none")
    Invoke-AzCommandLine $frontendCreateArgs
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Done "Frontend deployed"

Write-Step "12. Assigning runtime RBAC"
$backendPrincipalId = Get-ContainerAppPrincipalId -name $BACKEND_APP -resourceGroup $ResourceGroup
$frontendPrincipalId = Get-ContainerAppPrincipalId -name $FRONTEND_APP -resourceGroup $ResourceGroup

$acrResourceId = Get-TrimmedValue (az acr show --name $ACR_NAME --resource-group $ResourceGroup --query "id" -o tsv)
$foundryResourceId = Get-TrimmedValue (az cognitiveservices account show --name $FOUNDRY_NAME --resource-group $ResourceGroup --query "id" -o tsv)
$docIntelResourceId = Get-TrimmedValue (az cognitiveservices account show --name $DOC_INTEL_NAME --resource-group $ResourceGroup --query "id" -o tsv)
$storageResourceId = Get-TrimmedValue (az storage account show --name $STORAGE_ACCOUNT --resource-group $ResourceGroup --query "id" -o tsv)
$keyVaultResourceId = Get-TrimmedValue (az keyvault show --name $KEY_VAULT_NAME --resource-group $ResourceGroup --query "id" -o tsv)

Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "AcrPull" -scope $acrResourceId
Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "Cognitive Services User" -scope $foundryResourceId
Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "Cognitive Services User" -scope $docIntelResourceId
Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "Storage Blob Data Contributor" -scope $storageResourceId
Ensure-CosmosDataRoleAssignment -principalId $backendPrincipalId -accountName $COSMOS_ACCOUNT -resourceGroup $ResourceGroup
Ensure-RoleAssignment -principalId $frontendPrincipalId -roleName "AcrPull" -scope $acrResourceId
Ensure-RoleAssignment -principalId $frontendPrincipalId -roleName "Key Vault Secrets User" -scope $keyVaultResourceId
Write-Done "Runtime RBAC applied"

$frontendFqdn = az containerapp show `
    --name $FRONTEND_APP `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$frontendFqdn = Get-TrimmedValue $frontendFqdn

$frontendRuntimeEnvVars = @(
    "BACKEND_URL=$backendUrl",
    "FRONTEND_URL=https://$frontendFqdn",
    "AUTH_ENABLED=false",
    "ENTRA_TENANT_ID=",
    "ENTRA_CLIENT_ID=",
    "ENTRA_FRONTEND_CLIENT_ID=",
    "ENTRA_BACKEND_CLIENT_ID=",
    "ENTRA_SCOPE=",
    "ENTRA_REDIRECT_URI=https://$frontendFqdn",
    "AZURE_KEY_VAULT_URL=$KEY_VAULT_URI",
    "ENTRA_CLIENT_SECRET_SECRET_NAME=$KEY_VAULT_SECRET_NAME"
)

$frontendFinalizeArgs = @(
    "containerapp", "update",
    "--name", $FRONTEND_APP,
    "--resource-group", $ResourceGroup,
    "--image", "$ACR_SERVER/${prefixSlug}-frontend:latest",
    "--replace-env-vars"
) + $frontendRuntimeEnvVars + @("-o", "none")
Invoke-AzCommandLine $frontendFinalizeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "$('=' * 60)" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "$('=' * 60)" -ForegroundColor Green
Write-Host ""
Write-Host "  RESOURCES READY:" -ForegroundColor White
Write-Host "  Resource Group        : $ResourceGroup"
Write-Host "  Container Registry    : $ACR_SERVER"
Write-Host "  Foundry Resource      : $FOUNDRY_NAME"
Write-Host "  Foundry Project       : $FOUNDRY_PROJECT_NAME"
Write-Host "  Foundry Endpoint      : $FOUNDRY_ENDPOINT"
Write-Host "  Document Intelligence : $DI_ENDPOINT"
Write-Host "  Storage Account       : $STORAGE_ACCOUNT"
Write-Host "  Cosmos DB             : $COSMOS_ENDPOINT"
Write-Host "  Key Vault             : $KEY_VAULT_URI"
Write-Host "  Container Apps Env    : $CAE_NAME"
Write-Host ""
Write-Host "  APPLICATION URLS:" -ForegroundColor White
Write-Host "  Frontend (public)     : https://$frontendFqdn" -ForegroundColor Cyan
Write-Host "  Backend  (internal)   : $backendUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor White
Write-Host "  1. Create your Entra app registrations for the frontend and backend API."
Write-Host "  2. Store the frontend app secret in Key Vault:"
Write-Host "     az keyvault secret set --vault-name $KEY_VAULT_NAME --name $KEY_VAULT_SECRET_NAME --value '<frontend-app-client-secret>'"
Write-Host "  3. Update the frontend Container App env vars with ENTRA_TENANT_ID, ENTRA_FRONTEND_CLIENT_ID, ENTRA_BACKEND_CLIENT_ID, and ENTRA_SCOPE."
Write-Host "  4. Update the backend Container App env vars with ENTRA_TENANT_ID and ENTRA_CLIENT_ID."
Write-Host "  5. Enable AUTH_ENABLED=true on both apps once the Entra values and Key Vault secret are ready."
Write-Host ""
