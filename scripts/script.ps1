param(
    [Parameter(Mandatory = $true)]
    [string]$accountName,

    [Parameter(Mandatory = $true)]
    [string]$location,

    [Parameter(Mandatory = $true)]
    [string]$objectId,

    [Parameter(Mandatory = $true)]
    [string]$purviewResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$rootCollectionName,

    [Parameter(Mandatory = $true)]
    [string]$resourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$storageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$subscriptionId
)

$ErrorActionPreference = 'Stop'

Write-Host 'Purview ADLS Demo Deployment Script'
Write-Host 'Configures Purview collections, ADLS sample data, an ADLS managed-identity scan, and a glossary.'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host 'Installing required Azure PowerShell modules...'
    Install-Module -Name Az.Accounts -Force -AllowClobber -Scope CurrentUser -Repository PSGallery
    Install-Module -Name Az.Storage -Force -AllowClobber -Scope CurrentUser -Repository PSGallery

    Import-Module -Name Az.Accounts -Force
    Import-Module -Name Az.Storage -Force
    Write-Host 'Required modules loaded successfully.'
}
catch {
    Write-Error "Failed to load required modules: $($_.Exception.Message)"
    throw
}

$pv_endpoint = "https://${accountName}.purview.azure.com"

function Get-AzureManagementToken {
    try {
        $response = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' `
            -Headers @{ Metadata = 'true' } `
            -Method GET
        return $response.access_token
    }
    catch {
        Write-Error "Failed to get Azure Management token: $($_.Exception.Message)"
        throw
    }
}

function Get-PurviewToken {
    $response = Invoke-RestMethod `
        -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fpurview.azure.net%2F' `
        -Headers @{ Metadata = 'true' } `
        -Method GET
    return $response.access_token
}

function Add-PurviewRootCollectionAdmin {
    param(
        [string]$subscriptionId,
        [string]$resourceGroupName,
        [string]$accountName,
        [string]$objectId,
        [string]$accessToken
    )

    $uri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Purview/accounts/${accountName}/addRootCollectionAdmin?api-version=2021-07-01"
    $body = @{ objectId = $objectId } | ConvertTo-Json
    $headers = @{
        Authorization = "Bearer $accessToken"
        'Content-Type' = 'application/json'
    }

    Write-Host 'Adding the deployment managed identity as Purview root collection administrator...'

    try {
        Invoke-RestMethod `
            -Uri $uri `
            -Method POST `
            -Body $body `
            -Headers $headers | Out-Null

        Write-Host 'Deployment managed identity added as Purview root collection administrator.'
    }
    catch {
        $statusCode = [int]$_.Exception.Response.StatusCode

        if ($statusCode -eq 409) {
            Write-Warning 'The deployment managed identity is already a Purview root collection administrator. Continuing.'
        }
        else {
            throw
        }
    }
}



function Invoke-PurviewWeb {
    param(
        [string]$uri,
        [string]$accessToken,
        [string]$method,
        [AllowNull()][string]$body
    )

    $retryCount = 0
    while ($retryCount -lt 3) {
        try {
            $parameters = @{
                Uri = $uri
                Headers = @{ Authorization = "Bearer $accessToken" }
                ContentType = 'application/json'
                Method = $method
            }
            if ($null -ne $body) {
                $parameters.Body = $body
            }

            $response = Invoke-WebRequest @parameters
            if ([string]::IsNullOrWhiteSpace($response.Content)) {
                return $null
            }
            return $response.Content | ConvertFrom-Json -Depth 20
        }
        catch {
            $retryCount++
            Write-Warning "Purview request failed, attempt ${retryCount} of 3: $($_.Exception.Message)"
            if ($retryCount -ge 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Get-MetadataPolicy {
    param([string]$accessToken, [string]$collectionName)
    $uri = "${pv_endpoint}/policystore/collections/${collectionName}/metadataPolicy?api-version=2021-07-01"
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'GET' -body $null
}

function Add-RoleAssignmentToPolicy {
    param([object]$policy, [string]$principalId, [string]$roleName)

    foreach ($attributeRule in $policy.properties.attributeRules) {
        if ($attributeRule.name.StartsWith("purviewmetadatarole_builtin_${roleName}:")) {
            foreach ($conditionArray in $attributeRule.dnfCondition) {
                foreach ($condition in $conditionArray) {
                    if ($condition.attributeName -eq 'principal.microsoft.id' -and
                        $condition.attributeValueIncludedIn -notcontains $principalId) {
                        $condition.attributeValueIncludedIn += $principalId
                    }
                }
            }
        }
    }
}

function Set-MetadataPolicy {
    param([string]$accessToken, [string]$metadataPolicyId, [object]$payload)
    $uri = "${pv_endpoint}/policystore/metadataPolicies/${metadataPolicyId}?api-version=2021-07-01"
    $body = $payload | ConvertTo-Json -Depth 20
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'PUT' -body $body
}

function New-PurviewCollection {
    param([string]$accessToken, [string]$friendlyName, [string]$parentCollection)

    $collectionName = -join ((97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
    $uri = "${pv_endpoint}/account/collections/${collectionName}?api-version=2019-11-01-preview"
    $payload = @{
        name = $collectionName
        parentCollection = @{
            type = 'CollectionReference'
            referenceName = $parentCollection
        }
        friendlyName = $friendlyName
    }
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'PUT' -body ($payload | ConvertTo-Json -Depth 10)
}

function Set-PurviewSource {
    param([string]$accessToken, [hashtable]$payload)
    $uri = "${pv_endpoint}/scan/datasources/$($payload.name)?api-version=2018-12-01-preview"
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'PUT' -body ($payload | ConvertTo-Json -Depth 10)
}

function Set-PurviewScan {
    param([string]$accessToken, [string]$dataSourceName, [hashtable]$payload)
    $uri = "${pv_endpoint}/scan/datasources/${dataSourceName}/scans/$($payload.name)?api-version=2018-12-01-preview"
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'PUT' -body ($payload | ConvertTo-Json -Depth 10)
}

function Start-PurviewScan {
    param([string]$accessToken, [string]$dataSourceName, [string]$scanName)
    $uri = "${pv_endpoint}/scan/datasources/${dataSourceName}/scans/${scanName}/run?api-version=2018-12-01-preview"
    $body = @{ scanLevel = 'Full' } | ConvertTo-Json
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'POST' -body $body
}

function New-PurviewGlossary {
    param([string]$accessToken)
    $uri = "${pv_endpoint}/catalog/api/atlas/v2/glossary"
    $payload = @{ name = 'Epicor Demo Glossary'; qualifiedName = 'Epicor Demo Glossary' }
    return Invoke-PurviewWeb -uri $uri -accessToken $accessToken -method 'POST' -body ($payload | ConvertTo-Json)
}

function Import-PurviewGlossaryTerms {
    param([string]$accessToken, [string]$glossaryGuid, [string]$templateUri)

    $filename = Join-Path $PWD 'import-terms-sample.csv'
    Invoke-RestMethod -Uri $templateUri -OutFile $filename
    $uri = "${pv_endpoint}/catalog/api/atlas/v2/glossary/${glossaryGuid}/terms/import?includeTermHierarchy=true&api-version=2021-05-01-preview"

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $accessToken)
    $multipart = New-Object System.Net.Http.MultipartFormDataContent
    $stream = [System.IO.File]::OpenRead($filename)
    $fileContent = New-Object System.Net.Http.StreamContent($stream)
    $multipart.Add($fileContent, 'file', 'import-terms-sample.csv')

    try {
        $result = $client.PostAsync($uri, $multipart).Result
        if (-not $result.IsSuccessStatusCode) {
            throw "Glossary import failed with HTTP status $($result.StatusCode)."
        }
    }
    finally {
        $stream.Dispose()
        $multipart.Dispose()
        $client.Dispose()
    }
}

Write-Host 'Verifying Azure authentication context...'
$context = Get-AzContext
if (-not $context) {
    Connect-AzAccount -Identity | Out-Null
    $context = Get-AzContext
}
Write-Host "Authenticated subscription: $($context.Subscription.Id)"

$managementToken = Get-AzureManagementToken
Add-PurviewRootCollectionAdmin `
    -subscriptionId $subscriptionId `
    -resourceGroupName $purviewResourceGroupName `
    -accountName $accountName `
    -objectId $objectId `
    -accessToken $managementToken

$accessToken = Get-PurviewToken

Write-Host 'Assigning managed identity Purview data curator and data source administrator roles...'
$rootPolicy = Get-MetadataPolicy -accessToken $accessToken -collectionName $rootCollectionName
Add-RoleAssignmentToPolicy -policy $rootPolicy -principalId $objectId -roleName 'data-curator'
Add-RoleAssignmentToPolicy -policy $rootPolicy -principalId $objectId -roleName 'data-source-administrator'
Set-MetadataPolicy -accessToken $accessToken -metadataPolicyId $rootPolicy.id -payload $rootPolicy | Out-Null

$accessToken = Get-PurviewToken

Write-Host 'Creating demo collections...'
$collectionData = New-PurviewCollection -accessToken $accessToken -friendlyName 'Epicor Demo Data' -parentCollection $rootCollectionName
$collectionGovernance = New-PurviewCollection -accessToken $accessToken -friendlyName 'Epicor Governance' -parentCollection $rootCollectionName
$collectionDataName = $collectionData.name
Write-Host "Created collections: $($collectionData.friendlyName), $($collectionGovernance.friendlyName)"
Start-Sleep -Seconds 30

Write-Host 'Downloading and uploading sample data to ADLS Gen2...'
$containerName = 'bing'
#$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
#$storageContext = $storageAccount.Context

$storageAccount = Get-AzStorageAccount `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName

$storageContext = New-AzStorageContext `
    -StorageAccountName $storageAccountName `
    -UseConnectedAccount


#$existingContainer = Get-AzStorageContainer -Name $containerName -Context $storageContext -ErrorAction SilentlyContinue
#if (-not $existingContainer) {
#    New-AzStorageContainer -Name $containerName -Context $storageContext -Permission Off | Out-Null
#}

$workFolder = Join-Path $PWD 'bing-sample'
$zipPath = Join-Path $PWD 'bing-sample.zip'
if (Test-Path $workFolder) { Remove-Item -Path $workFolder -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item -Path $zipPath -Force }

$repoUrl = 'https://api.github.com/repos/microsoft/BingCoronavirusQuerySet/zipball/master'
Invoke-RestMethod -Uri $repoUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $workFolder -Force

$sampleFiles = Get-ChildItem -Path $workFolder -File -Recurse
foreach ($file in $sampleFiles) {
    $blobName = $file.FullName.Substring($workFolder.Length).TrimStart([char[]]'\/')
    Set-AzStorageBlobContent -File $file.FullName -Container $containerName -Blob $blobName -Context $storageContext -Force | Out-Null
}
Write-Host "Uploaded $($sampleFiles.Count) sample files to container '${containerName}'."

Write-Host 'Registering ADLS Gen2 source in Purview...'
$sourcePayload = @{
    id = 'datasources/AzureDataLakeStorage'
    kind = 'AdlsGen2'
    name = 'AzureDataLakeStorage'
    properties = @{
        collection = @{
            referenceName = $collectionDataName
            type = 'CollectionReference'
        }
        location = $location
        endpoint = "https://${storageAccountName}.dfs.core.windows.net/"
        resourceGroup = $resourceGroupName
        resourceName = $storageAccountName
        subscriptionId = $subscriptionId
    }
}
Set-PurviewSource -accessToken $accessToken -payload $sourcePayload | Out-Null

Write-Host 'Creating managed-identity ADLS scan...'
$randomId = -join (((48..57) + (65..90) + (97..122)) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
$scanName = "Scan-${randomId}"
$scanPayload = @{
    kind = 'AdlsGen2Msi'
    name = $scanName
    properties = @{
        scanRulesetName = 'AdlsGen2'
        scanRulesetType = 'System'
        collection = @{
            type = 'CollectionReference'
            referenceName = $collectionDataName
        }
    }
}
Set-PurviewScan -accessToken $accessToken -dataSourceName $sourcePayload.name -payload $scanPayload | Out-Null

Write-Host "Starting scan '${scanName}'..."
Start-PurviewScan -accessToken $accessToken -dataSourceName $sourcePayload.name -scanName $scanName | Out-Null

Write-Host 'Creating and populating the demo glossary...'
try {
    $glossary = New-PurviewGlossary -accessToken $accessToken
    $termsUri = 'https://raw.githubusercontent.com/tayganr/purviewlab/main/assets/import-terms-sample.csv'
    Import-PurviewGlossaryTerms -accessToken $accessToken -glossaryGuid $glossary.guid -templateUri $termsUri
    Write-Host 'Glossary terms imported.'
}
catch {
    Write-Warning "Glossary setup did not complete: $($_.Exception.Message)"
    Write-Warning 'The ADLS source and scan were still configured. You can import glossary terms manually later.'
}

Write-Host ''
Write-Host 'Purview ADLS demo deployment completed.'
Write-Host "Purview account: ${accountName}"
Write-Host "ADLS account: ${storageAccountName}"
Write-Host "ADLS container: ${containerName}"
Write-Host "Purview scan: ${scanName}"
Write-Host 'The scan was submitted and may take several minutes to populate Data Map assets.'
