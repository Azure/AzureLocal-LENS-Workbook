<#
.SYNOPSIS
Runs opt-in Capacity KQL integration tests against a real Log Analytics workspace.

.DESCRIPTION
This suite is intentionally excluded from CI because it requires Azure access and
live telemetry. It validates the six storage IOPS/latency queries changed in
v1.0.6 plus every related storage-usage and network-throughput chart, using
the exact query text from the split workbook sources.

IMPORTANT FOR AI/CODING AGENTS:
1. Run `az account list --query "[?state=='Enabled'].{Name:name,Id:id}" -o table`
   to discover candidate subscription IDs. Never guess or reuse a stored ID.
2. Show the intended subscription name/ID to the user and ask them to confirm
   that it is the correct live-integration environment.
3. Only after explicit user confirmation, invoke this script with
   `-ConfirmEnvironment`. Never copy environment IDs into source, PR text,
   comments, commits, logs committed to git, or documentation.

Human operators may omit -ConfirmEnvironment and confirm interactively.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$WorkspaceResourceId,

    [string]$ClusterResourceId,

    [ValidateRange(1, 90)]
    [int]$Days = 30,

    [switch]$ConfirmEnvironment
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tempFiles = [System.Collections.Generic.List[string]]::new()

function New-TemporaryJsonFile {
    param([Parameter(Mandatory)][object]$Value)

    $path = [IO.Path]::GetTempFileName()
    $tempFiles.Add($path)
    [IO.File]::WriteAllText(
        $path,
        ($Value | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
    return $path
}

function Get-WorkbookItems {
    param([object[]]$Items)

    foreach ($item in $Items) {
        $item
        if ($item.content -and $item.content.items) {
            Get-WorkbookItems -Items $item.content.items
        }
    }
}

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required.'
    }

    $accountsJson = az account list --all --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list Azure CLI subscriptions. Run az login and retry.'
    }
    $accounts = @($accountsJson -join [Environment]::NewLine | ConvertFrom-Json) |
        Where-Object state -EQ 'Enabled'

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $accounts | Select-Object name, id | Format-Table -AutoSize
        throw 'Select the correct environment and rerun with -SubscriptionId. Coding agents must ask the user to confirm it first.'
    }

    $account = $accounts | Where-Object id -EQ $SubscriptionId | Select-Object -First 1
    if (-not $account) {
        throw 'The supplied subscription is not an enabled subscription in the current Azure CLI session.'
    }

    $workspaceParts = $WorkspaceResourceId.Trim('/') -split '/'
    if ($workspaceParts.Count -lt 8 -or $workspaceParts[0] -ne 'subscriptions') {
        throw 'WorkspaceResourceId must be a Log Analytics workspace ARM resource ID.'
    }
    if ($workspaceParts[1] -ne $SubscriptionId) {
        throw 'The workspace and confirmed subscription IDs do not match.'
    }

    $workspace = az monitor log-analytics workspace show --ids $WorkspaceResourceId --output json 2>$null |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $workspace.customerId) {
        throw 'The supplied Log Analytics workspace could not be resolved.'
    }

    Write-Host 'Live integration test target:'
    Write-Host ("  Subscription: {0} ({1})" -f $account.name, $account.id)
    Write-Host ("  Workspace:    {0}" -f $workspace.name)
    Write-Host ("  Lookback:     {0} days" -f $Days)

    if (-not $ConfirmEnvironment) {
        $answer = Read-Host 'Is this the correct live-integration environment? Type YES to continue'
        if ($answer -cne 'YES') {
            throw 'Live integration tests cancelled; environment was not confirmed.'
        }
    }

    $mappingQuery = @'
resources
| where type == "microsoft.azurestackhci/clusters"
| extend nodes = todynamic(properties.reportedProperties.nodes)
| mv-expand node = nodes
| extend nodeShort = tolower(tostring(split(tostring(node.name), '.')[0]))
| where isnotempty(nodeShort)
| project nodeRG = tolower(resourceGroup), clusterName = name, armId = tostring(id), nodeShort
'@
    $argBodyPath = New-TemporaryJsonFile -Value @{
        subscriptions = @($SubscriptionId)
        query = $mappingQuery
        options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
    }
    $mappingJson = az rest --method post `
        --url 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
        --body "@$argBodyPath" --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure Resource Graph mapping query failed.'
    }
    $mappingRows = @(($mappingJson -join [Environment]::NewLine | ConvertFrom-Json).data)
    if ($mappingRows.Count -eq 0) {
        throw 'No Azure Local node mappings were returned for the confirmed subscription.'
    }

    if ($ClusterResourceId) {
        $selectedCluster = $mappingRows | Where-Object armId -EQ $ClusterResourceId | Select-Object -First 1
        if (-not $selectedCluster) {
            throw 'ClusterResourceId was not found in the confirmed subscription node mapping.'
        }
    } else {
        $selectedCluster = $mappingRows | Sort-Object clusterName, nodeShort | Select-Object -First 1
    }

    $clusterRGMap = @($mappingRows |
        ForEach-Object { '{0}:{1}' -f $_.nodeRG, $_.clusterName } |
        Sort-Object -Unique)
    $clusterNodeMap = @($mappingRows |
        ForEach-Object { '{0}:{1}:{2}' -f $_.nodeShort, $_.clusterName, $_.armId } |
        Sort-Object -Unique)
    $clusterRGJson = ConvertTo-Json -InputObject $clusterRGMap -Compress
    $clusterNodeJson = ConvertTo-Json -InputObject $clusterNodeMap -Compress

    $manifestPath = Join-Path $PSScriptRoot 'live-test-queries.json'
    $querySpecs = @((Get-Content -Raw $manifestPath | ConvertFrom-Json).queries)
    if ($querySpecs.Count -eq 0) {
        throw 'The live integration query manifest is empty.'
    }

    $results = foreach ($spec in $querySpecs) {
        $workbookPath = Join-Path $repoRoot $spec.file
        $workbook = Get-Content -Raw $workbookPath | ConvertFrom-Json
        $item = Get-WorkbookItems -Items $workbook.items |
            Where-Object name -EQ $spec.name |
            Select-Object -First 1
        if (-not $item) {
            throw "Workbook query not found: $($spec.name)"
        }

        $query = [string]$item.content.query
        $query = $query.Replace('{NodeTrendsTimeRange:start}', "ago($($Days)d)")
        $query = $query.Replace('{NodeTrendsTimeRange:end}', 'now()')
        $query = $query.Replace('{ClusterRGMap}', $clusterRGJson)
        $query = $query.Replace('{ClusterNodeMap}', $clusterNodeJson)
        $query = $query.Replace('{ChartClusterFilter}', "'value::all'")
        $query = $query.Replace('{SingleCluster}', [string]$selectedCluster.armId)

        $unresolvedParameters = @([regex]::Matches(
            $query,
            '\{[A-Za-z_][A-Za-z0-9_]*(?::\w+)?\}'
        ) | ForEach-Object Value | Sort-Object -Unique)
        if ($unresolvedParameters.Count -gt 0) {
            throw "Unresolved workbook parameters in $($spec.name): $($unresolvedParameters -join ', ')"
        }

        $logBodyPath = New-TemporaryJsonFile -Value @{
            query = $query
            timespan = "P$($Days)D"
        }
        $resultJson = az rest --method post `
            --url "https://api.loganalytics.io/v1/workspaces/$($workspace.customerId)/query" `
            --resource 'https://api.loganalytics.io' `
            --body "@$logBodyPath" --output json 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Live Log Analytics query failed: $($spec.name)"
        }

        $response = $resultJson -join [Environment]::NewLine | ConvertFrom-Json
        $rowCount = @($response.tables[0].rows).Count
        if ($rowCount -eq 0) {
            throw "Live Log Analytics query returned no rows: $($spec.name)"
        }

        [pscustomobject]@{ Query = $spec.name; Rows = $rowCount; Result = 'Passed' }
    }

    $results | Format-Table -AutoSize
    $resultsDirectory = Join-Path $repoRoot 'test-results'
    [void][IO.Directory]::CreateDirectory($resultsDirectory)
    $nunitPath = Join-Path $resultsDirectory 'live-integration-nunit.xml'
    $timestamp = [DateTime]::UtcNow.ToString('o')
    $testCases = @($results | ForEach-Object {
        $queryName = [Security.SecurityElement]::Escape([string]$_.Query)
        '    <test-case name="{0}" result="Passed"><properties><property name="Rows" value="{1}" /></properties></test-case>' -f $queryName, $_.Rows
    }) -join [Environment]::NewLine
    $nunitXml = @"
<?xml version="1.0" encoding="utf-8"?>
<test-run name="LENS.LiveIntegration" testcasecount="$($results.Count)" result="Passed" total="$($results.Count)" passed="$($results.Count)" failed="0" start-time="$timestamp" end-time="$timestamp">
    <test-suite type="TestFixture" name="Capacity storage and network queries" testcasecount="$($results.Count)" result="Passed" total="$($results.Count)" passed="$($results.Count)" failed="0">
$testCases
    </test-suite>
</test-run>
"@
    [IO.File]::WriteAllText($nunitPath, $nunitXml, [Text.UTF8Encoding]::new($false))
    Write-Host ("NUnit XML report written to: {0}" -f $nunitPath)
    Write-Host ("Live integration tests passed: {0}/{0}" -f $results.Count)
} finally {
    foreach ($tempFile in $tempFiles) {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}