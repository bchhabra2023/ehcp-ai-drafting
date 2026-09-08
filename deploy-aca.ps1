<#
.SYNOPSIS
    Deploy EHCP Document Processor backend + frontend to Azure Container Apps.

.DESCRIPTION
    - Creates or updates two Container Apps: ehcp-backend and ehcp-frontend.
    - Uses system-assigned managed identities for both apps.
    - Uses managed identity for Azure Container Registry pulls.
    - Expects non-secret runtime configuration in backend\.env and frontend\.env.
    - Frontend auth secrets must live in Azure Key Vault and be retrieved at runtime
      by the frontend app using its managed identity.

.PARAMETER ResourceGroup
    Azure Resource Group that contains the Container Apps Environment.

.PARAMETER Environment
    Name of the existing Container Apps Environment (managed environment).

.PARAMETER Tag
    Image tag to deploy (default: latest).

.EXAMPLE
    .\deploy-aca.ps1 -ResourceGroup "rg-ehcp" -Environment "cae-ehcp"
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Environment,
    [string]$Tag = "latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Fail([string]$msg) {
    throw $msg
}

$BACKEND_APP = "ehcp-containerapp-backend"
$FRONTEND_APP = "ehcp-containerapp-frontend"

$BACKEND_ENV_FILE = Join-Path $PSScriptRoot "backend\.env"
$FRONTEND_ENV_FILE = Join-Path $PSScriptRoot "frontend\.env"

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-SubStep([string]$msg) {
    Write-Host "   -> $msg" -ForegroundColor Yellow
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

function Assert-Command([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "'$name' is not installed or not on PATH."
    }
}

function Read-EnvFile([string]$path) {
    $result = @{}
    if (-not (Test-Path $path)) {
        Write-Warning ".env file not found at $path"
        return $result
    }

    Get-Content $path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            return
        }

        $idx = $line.IndexOf("=")
        if ($idx -le 0) {
            return
        }

        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        $value = $value -replace '^["'']|["'']$', ''
        $value = ($value -split '\s+#')[0].Trim()
        if ($key -and -not $value.StartsWith("<")) {
            $result[$key] = $value
        }
    }

    return $result
}

function ConvertTo-EnvArgs($values) {
    $args = @()
    foreach ($kv in $values.GetEnumerator()) {
        $args += "$($kv.Key)=$($kv.Value)"
    }
    return $args
}

function Get-AcrServer([string]$resourceGroup) {
    $server = az acr list --resource-group $resourceGroup --query "[0].loginServer" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($server)) {
        Fail "Could not find an Azure Container Registry in resource group '$resourceGroup'."
    }
    return (Get-TrimmedValue $server)
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

function Ensure-RegistryIdentity([string]$name, [string]$resourceGroup, [string]$server) {
    az containerapp registry set `
        --name $name `
        --resource-group $resourceGroup `
        --server $server `
        --identity system `
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

function Assert-RequiredKeys([hashtable]$envVars, [string[]]$requiredKeys, [string]$envFileLabel) {
    foreach ($key in $requiredKeys) {
        if (-not $envVars.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envVars[$key])) {
            Fail "$envFileLabel is missing required value '$key'."
        }
    }
}

function Get-HostPrefix([string]$url, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($url)) {
        Fail "$label URL is empty."
    }

    $uri = [Uri]$url
    $parts = $uri.Host.Split(".")
    if ($parts.Length -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        Fail "Could not derive a resource name from $label URL '$url'."
    }
    return $parts[0]
}

function Assert-NoRemovedSecrets([hashtable]$envVars, [string[]]$forbiddenKeys, [string]$envFileLabel) {
    foreach ($key in $forbiddenKeys) {
        if ($envVars.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($envVars[$key])) {
            Fail "$envFileLabel contains '$key'. This deployment is managed-identity-first; move unsupported secrets to Key Vault and remove direct secret values from app configuration."
        }
    }
}

Assert-Command "az"

Write-Step "Checking Azure CLI login"
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "Not logged in. Run 'az login' first."
}

$backendEnvVars = Read-EnvFile $BACKEND_ENV_FILE
$frontendEnvVars = Read-EnvFile $FRONTEND_ENV_FILE

Assert-NoRemovedSecrets -envVars $backendEnvVars -forbiddenKeys @(
    "AZURE_OPENAI_API_KEY",
    "AZURE_DOCUMENT_INTELLIGENCE_KEY",
    "AZURE_STORAGE_CONNECTION_STRING",
    "COSMOS_DB_KEY",
    "USE_MANAGED_IDENTITY"
) -envFileLabel "backend\.env"

Assert-NoRemovedSecrets -envVars $frontendEnvVars -forbiddenKeys @(
    "ENTRA_CLIENT_SECRET"
) -envFileLabel "frontend\.env"

Assert-RequiredKeys -envVars $backendEnvVars -requiredKeys @(
    "FOUNDRY_ENDPOINT",
    "AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT",
    "AZURE_STORAGE_ACCOUNT_URL",
    "COSMOS_DB_ENDPOINT"
) -envFileLabel "backend\.env"

$frontendAuthEnabled = ($frontendEnvVars["AUTH_ENABLED"] + "").ToLower()
if ($frontendAuthEnabled -eq "true") {
    foreach ($requiredKey in @("AZURE_KEY_VAULT_URL", "ENTRA_CLIENT_SECRET_SECRET_NAME")) {
        if (-not $frontendEnvVars.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace($frontendEnvVars[$requiredKey])) {
            Fail "frontend\.env is missing '$requiredKey'. Auth-enabled deployments must load the Entra client secret from Azure Key Vault."
        }
    }
}

$ACR_SERVER = Get-AcrServer -resourceGroup $ResourceGroup
$BACKEND_IMAGE = "$ACR_SERVER/ehcp-backend:$Tag"
$FRONTEND_IMAGE = "$ACR_SERVER/ehcp-frontend:$Tag"

Write-Step "Deploying backend Container App: $BACKEND_APP"
$backendEnv = ConvertTo-EnvArgs $backendEnvVars

if (Test-ContainerAppExists -name $BACKEND_APP -resourceGroup $ResourceGroup) {
    Write-SubStep "Updating existing backend app"
    Ensure-ContainerAppIdentity -name $BACKEND_APP -resourceGroup $ResourceGroup
    Ensure-RegistryIdentity -name $BACKEND_APP -resourceGroup $ResourceGroup -server $ACR_SERVER

    $backendUpdateArgs = @(
        "containerapp", "update",
        "--name", $BACKEND_APP,
        "--resource-group", $ResourceGroup,
        "--image", $BACKEND_IMAGE,
        "--replace-env-vars"
    ) + $backendEnv + @("-o", "none")
    Invoke-AzCommandLine $backendUpdateArgs
} else {
    Write-SubStep "Creating new backend app"
    $backendCreateArgs = @(
        "containerapp", "create",
        "--name", $BACKEND_APP,
        "--resource-group", $ResourceGroup,
        "--environment", $Environment,
        "--image", $BACKEND_IMAGE,
        "--registry-server", $ACR_SERVER,
        "--registry-identity", "system",
        "--system-assigned",
        "--target-port", "8000",
        "--ingress", "internal",
        "--min-replicas", "1",
        "--max-replicas", "3",
        "--env-vars"
    ) + $backendEnv + @("-o", "none")
    Invoke-AzCommandLine $backendCreateArgs
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Step "Retrieving backend internal FQDN"
$backendFqdn = az containerapp show `
    --name $BACKEND_APP `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" `
    --output tsv
$backendFqdn = Get-TrimmedValue $backendFqdn
$backendUrl = "https://$backendFqdn"

Write-Step "Deploying frontend Container App: $FRONTEND_APP"
$frontendEnvVars["BACKEND_URL"] = $backendUrl
$frontendEnv = ConvertTo-EnvArgs $frontendEnvVars

if (Test-ContainerAppExists -name $FRONTEND_APP -resourceGroup $ResourceGroup) {
    Write-SubStep "Updating existing frontend app"
    Ensure-ContainerAppIdentity -name $FRONTEND_APP -resourceGroup $ResourceGroup
    Ensure-RegistryIdentity -name $FRONTEND_APP -resourceGroup $ResourceGroup -server $ACR_SERVER

    $frontendUpdateArgs = @(
        "containerapp", "update",
        "--name", $FRONTEND_APP,
        "--resource-group", $ResourceGroup,
        "--image", $FRONTEND_IMAGE,
        "--replace-env-vars"
    ) + $frontendEnv + @("-o", "none")
    Invoke-AzCommandLine $frontendUpdateArgs
} else {
    Write-SubStep "Creating new frontend app"
    $frontendCreateArgs = @(
        "containerapp", "create",
        "--name", $FRONTEND_APP,
        "--resource-group", $ResourceGroup,
        "--environment", $Environment,
        "--image", $FRONTEND_IMAGE,
        "--registry-server", $ACR_SERVER,
        "--registry-identity", "system",
        "--system-assigned",
        "--target-port", "8501",
        "--ingress", "external",
        "--min-replicas", "1",
        "--max-replicas", "3",
        "--env-vars"
    ) + $frontendEnv + @("-o", "none")
    Invoke-AzCommandLine $frontendCreateArgs
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$frontendFqdn = az containerapp show `
    --name $FRONTEND_APP `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" `
    --output tsv
$frontendFqdn = Get-TrimmedValue $frontendFqdn

Write-Step "Refreshing runtime RBAC assignments"
$backendPrincipalId = Get-ContainerAppPrincipalId -name $BACKEND_APP -resourceGroup $ResourceGroup
$frontendPrincipalId = Get-ContainerAppPrincipalId -name $FRONTEND_APP -resourceGroup $ResourceGroup

$foundryAccountName = Get-HostPrefix -url $backendEnvVars["FOUNDRY_ENDPOINT"] -label "FOUNDRY_ENDPOINT"
$docIntelAccountName = Get-HostPrefix -url $backendEnvVars["AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT"] -label "AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT"
$storageAccountName = Get-HostPrefix -url $backendEnvVars["AZURE_STORAGE_ACCOUNT_URL"] -label "AZURE_STORAGE_ACCOUNT_URL"
$cosmosAccountName = Get-HostPrefix -url $backendEnvVars["COSMOS_DB_ENDPOINT"] -label "COSMOS_DB_ENDPOINT"

$acrResourceId = Get-TrimmedValue (az acr show --name ($ACR_SERVER -replace '\.azurecr\.io$', '') --resource-group $ResourceGroup --query "id" -o tsv)
$foundryResourceId = Get-TrimmedValue (az cognitiveservices account show --name $foundryAccountName --resource-group $ResourceGroup --query "id" -o tsv)
$docIntelResourceId = Get-TrimmedValue (az cognitiveservices account show --name $docIntelAccountName --resource-group $ResourceGroup --query "id" -o tsv)
$storageResourceId = Get-TrimmedValue (az storage account show --name $storageAccountName --resource-group $ResourceGroup --query "id" -o tsv)

Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "AcrPull" -scope $acrResourceId
Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "Cognitive Services User" -scope $foundryResourceId
Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "Cognitive Services User" -scope $docIntelResourceId
Ensure-RoleAssignment -principalId $backendPrincipalId -roleName "Storage Blob Data Contributor" -scope $storageResourceId
Ensure-CosmosDataRoleAssignment -principalId $backendPrincipalId -accountName $cosmosAccountName -resourceGroup $ResourceGroup
Ensure-RoleAssignment -principalId $frontendPrincipalId -roleName "AcrPull" -scope $acrResourceId

if ($frontendEnvVars.ContainsKey("AZURE_KEY_VAULT_URL") -and -not [string]::IsNullOrWhiteSpace($frontendEnvVars["AZURE_KEY_VAULT_URL"])) {
    $keyVaultName = Get-HostPrefix -url $frontendEnvVars["AZURE_KEY_VAULT_URL"] -label "AZURE_KEY_VAULT_URL"
    $keyVaultResourceId = Get-TrimmedValue (az keyvault show --name $keyVaultName --resource-group $ResourceGroup --query "id" -o tsv)
    Ensure-RoleAssignment -principalId $frontendPrincipalId -roleName "Key Vault Secrets User" -scope $keyVaultResourceId
}

Write-Host "`nDeployment complete." -ForegroundColor Green
Write-Host "   Backend  (internal) : $backendUrl"
Write-Host "   Frontend (public)   : https://$frontendFqdn" -ForegroundColor White
