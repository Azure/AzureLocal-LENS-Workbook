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

    [switch]$ConfirmEnvironment,

    [switch]$NodeCapacityOnly
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

function Test-NodeCapacity {
    param([string]$TenantId, [string]$WorkspaceId)

    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-HyperV/Capacity-HyperV.workbook') | ConvertFrom-Json
    $items = @(Get-WorkbookItems -Items $book.items)
    $mapQuery = ($items | Where-Object name -EQ 'hyperv-node-capacity-params').content.parameters[0].query
    $mapQuery = $mapQuery.Replace('{ResourceGroupFilter}', '').Replace('{ClusterTagName}', '').Replace('{ClusterTagValue}', '')
    $mapQuery = $mapQuery -replace '\r?\n', ' '
    $mappingResponse = az graph query --subscription $SubscriptionId --subscriptions $SubscriptionId `
        --graph-query $mapQuery --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Node capacity metadata query failed.' }
    $metadata = (($mappingResponse -join [Environment]::NewLine | ConvertFrom-Json).data[0].value | ConvertFrom-Json)
    if (@($metadata).Count -eq 0) { throw 'No Arc node hardware metadata returned.' }
    $template = ($items | Where-Object name -EQ 'hyperv-node-capacity').content.query
    $snapshotEnd = [DateTime]::UtcNow.AddMinutes(-2)
    $template = $template.Replace('now() - 2m', "datetime($($snapshotEnd.ToString('o')))")
    $accessToken = az account get-access-token --tenant $TenantId --resource 'https://api.loganalytics.io' `
        --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not authenticate to the confirmed tenant.' }

    function Invoke-CapacityQuery {
        param([object[]]$NodeMetadata, [string]$MinimumRatio = '0', [string]$HostFilter = "'*'", [object[]]$Samples)

        $query = $template.Replace('{HyperVNodeCapacityMap}', (ConvertTo-Json -InputObject $NodeMetadata -Depth 10 -Compress))
        $query = $query.Replace('{HyperVInvHostFilter}', $HostFilter).Replace('{HyperVNodeRatioFilter}', $MinimumRatio)
        if ($PSBoundParameters.ContainsKey('Samples')) {
            $samplesJson = ConvertTo-Json -InputObject $Samples -Depth 10 -Compress
            $source = "(print fixtureRow = dynamic($samplesJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), Computer=tostring(fixtureRow.Computer), _ResourceId=tostring(fixtureRow.HostId), ObjectName=tostring(fixtureRow.ObjectName), CounterName=tostring(fixtureRow.CounterName), InstanceName=tostring(fixtureRow.InstanceName), CounterValue=todouble(fixtureRow.CounterValue))"
            $query = $query.Replace('let raw = materialize(Perf', "let raw = materialize($source")
        }
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
            -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json' `
            -Body (@{ query = $query; timespan = 'PT1H' } | ConvertTo-Json -Depth 10)
        if ($response.error) { throw 'Node capacity returned a partial query error.' }
        $table = $response.tables[0]
        foreach ($row in $table.rows) {
            $record = [ordered]@{}
            for ($columnIndex = 0; $columnIndex -lt $table.columns.Count; $columnIndex++) {
                $record[$table.columns[$columnIndex].name] = $row[$columnIndex]
            }
            [pscustomobject]$record
        }
    }

    function Assert-Capacity {
        param([bool]$Condition, [string]$Name, [int]$Rows = 1)
        if (-not $Condition) { throw "Node capacity test failed: $Name" }
        [pscustomobject]@{ Query = $Name; Rows = $Rows; Result = 'Passed' }
    }

    try {
        $liveRows = @(Invoke-CapacityQuery -NodeMetadata @($metadata))
        $knownRows = @($liveRows | Where-Object { $null -ne $_.'V:P CPU Ratio' })
        Assert-Capacity ($liveRows.Count -gt 0 -and $knownRows.Count -gt 0) 'node-capacity-live-ratios' $knownRows.Count
        $cpuRows = @($liveRows | Where-Object { $null -ne $_.'Avg CPU % (15 min)' })
        $memoryRows = @($liveRows | Where-Object { $null -ne $_.'Memory Used GiB' })
        Assert-Capacity ($cpuRows.Count -gt 0 -and $memoryRows.Count -gt 0) 'node-capacity-live-host-metrics' $memoryRows.Count
        $invalidMemory = @($memoryRows | Where-Object {
            [math]::Abs($_.'Memory Total GiB' - $_.'Memory Used GiB' - $_.'Memory Free / Available GiB') -gt 0.11
        })
        Assert-Capacity ($invalidMemory.Count -eq 0) 'node-capacity-live-memory-balance'
        $filtered = @(Invoke-CapacityQuery -NodeMetadata @($metadata) -MinimumRatio '2')
        Assert-Capacity (@($filtered | Where-Object { $null -eq $_.'V:P CPU Ratio' -or $_.'V:P CPU Ratio' -lt 2 }).Count -eq 0) 'node-capacity-live-minimum-ratio' $filtered.Count

        $fixtureNodes = [System.Collections.Generic.List[object]]::new()
        $fixtureSamples = [System.Collections.Generic.List[object]]::new()
        $scenarios = @('healthy', 'high-ratio', 'duplicates', 'partial', 'migrate-source', 'migrate-target', 'collision-a', 'collision-b', 'other-cluster', 'missing', 'aggregate-only', 'missing-cores', 'ambiguous', 'invalid-memory', 'stale', 'single', 'invalid-cpu')
        foreach ($scenario in $scenarios) {
            $node = [pscustomobject]@{
                hostId = "host-$scenario"; machine = $scenario; cluster = 'cluster-a'; clusterId = 'cluster-a'
                physicalCores = 8; logicalProcessors = 16; memoryGiB = 64
            }
            if ($scenario -eq 'other-cluster') { $node.cluster = 'cluster-b'; $node.clusterId = 'cluster-b' }
            if ($scenario -eq 'high-ratio') { $node.physicalCores = 1 }
            if ($scenario -eq 'missing-cores') { $node.physicalCores = 0 }
            $fixtureNodes.Add($node)
            if ($scenario -eq 'ambiguous') { $fixtureNodes.Add($node) }
            if ($scenario -eq 'missing') { continue }
            foreach ($sampleAge in @(2, 1)) {
                if ($sampleAge -eq 2 -and $scenario -in @('single', 'migrate-target')) { continue }
                $sampleTime = $snapshotEnd.AddMinutes(-$sampleAge)
                if ($scenario -eq 'stale') { $sampleTime = $sampleTime.AddHours(-1) }
                $vcpuCount = 4
                if ($scenario -eq 'aggregate-only' -or ($scenario -eq 'migrate-source' -and $sampleAge -eq 1)) { $vcpuCount = 0 }
                if ($scenario -eq 'partial' -and $sampleAge -eq 1) { $vcpuCount = 3 }
                $vmName = "vm-$scenario"
                if ($scenario -in @('collision-a', 'collision-b', 'other-cluster')) { $vmName = 'same-name' }
                if ($scenario -in @('migrate-source', 'migrate-target')) { $vmName = 'moving-vm' }
                $instances = @('_Total') + @(for ($vcpuIndex = 0; $vcpuIndex -lt $vcpuCount; $vcpuIndex++) { '{0}:Hv VP {1}' -f $vmName, $vcpuIndex })
                foreach ($instance in $instances) {
                    $sample = [pscustomobject]@{
                        TimeGenerated = $sampleTime.ToString('o'); Computer = $scenario; HostId = $node.hostId
                        ObjectName = 'Hyper-V Hypervisor Virtual Processor'; CounterName = '% Guest Run Time'
                        InstanceName = $instance; CounterValue = 10
                    }
                    $fixtureSamples.Add($sample)
                    if ($scenario -eq 'duplicates') { $fixtureSamples.Add($sample) }
                }
                $fixtureSamples.Add([pscustomobject]@{
                    TimeGenerated = $sampleTime.ToString('o'); Computer = $scenario; HostId = $node.hostId
                    ObjectName = 'Processor'; CounterName = '% Processor Time'; InstanceName = '_Total'
                    CounterValue = $(if ($scenario -eq 'invalid-cpu') { 150 } else { 20 })
                })
                $fixtureSamples.Add([pscustomobject]@{
                    TimeGenerated = $sampleTime.ToString('o'); Computer = $scenario; HostId = $node.hostId
                    ObjectName = 'Memory'; CounterName = 'Available Bytes'; InstanceName = ''
                    CounterValue = $(if ($scenario -eq 'invalid-memory') { 65GB } else { 16GB })
                })
            }
        }
        $fixtureRows = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray())
        $byMachine = @{}
        foreach ($row in $fixtureRows) { $byMachine[$row.Machine] = $row }
        Assert-Capacity ($fixtureRows.Count -eq $scenarios.Count) 'node-capacity-fixture-node-preservation'
        Assert-Capacity ($fixtureRows[0].Machine -eq 'high-ratio' -and $fixtureRows[0].'V:P CPU Ratio' -eq 4) 'node-capacity-numeric-descending-sort'
        Assert-Capacity ($byMachine['healthy'].'V:P CPU Ratio' -eq 0.5 -and $byMachine['healthy'].'Observed VM vCPUs' -eq 4) 'node-capacity-physical-not-logical-denominator'
        Assert-Capacity ($byMachine['healthy'].'Memory Used GiB' -eq 48 -and $byMachine['healthy'].'Memory Free / Available GiB' -eq 16 -and $byMachine['healthy'].'Memory Used %' -eq 75) 'node-capacity-memory-calculation'
        Assert-Capacity ($byMachine['healthy'].'Avg CPU % (15 min)' -eq 20 -and $byMachine['healthy'].'Avg CPU Free %' -eq 80) 'node-capacity-host-cpu-calculation'
        Assert-Capacity ($byMachine['duplicates'].'Observed VM vCPUs' -eq 4) 'node-capacity-deduplication'
        foreach ($scenario in @('partial', 'migrate-source', 'migrate-target', 'collision-a', 'collision-b', 'missing', 'aggregate-only', 'missing-cores', 'ambiguous', 'stale', 'single')) {
            Assert-Capacity ($null -eq $byMachine[$scenario].'V:P CPU Ratio') "node-capacity-unavailable-$scenario"
        }
        Assert-Capacity ($byMachine['other-cluster'].'V:P CPU Ratio' -eq 0.5) 'node-capacity-duplicate-name-cluster-scope'
        Assert-Capacity ($null -eq $byMachine['invalid-memory'].'Memory Used GiB') 'node-capacity-invalid-memory'
        Assert-Capacity ($null -eq $byMachine['invalid-cpu'].'Avg CPU % (15 min)') 'node-capacity-invalid-host-cpu'
        $filteredFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -MinimumRatio '2')
        Assert-Capacity ($filteredFixture.Count -eq 1 -and $filteredFixture[0].Machine -eq 'high-ratio') 'node-capacity-ratio-filter-excludes-unknown'
        $hostFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -HostFilter "'healthy'")
        Assert-Capacity ($hostFixture.Count -eq 1 -and $hostFixture[0].Machine -eq 'healthy') 'node-capacity-host-filter'
    } finally {
        $accessToken = $null
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

    $workspace = az monitor log-analytics workspace show --subscription $SubscriptionId --ids $WorkspaceResourceId --output json 2>$null |
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

    if ($NodeCapacityOnly) {
        $results = @(Test-NodeCapacity -TenantId $account.tenantId -WorkspaceId $workspace.customerId)
    } else {
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
    }

    $results | Format-Table -AutoSize
    $resultsDirectory = Join-Path $repoRoot 'test-results'
    [void][IO.Directory]::CreateDirectory($resultsDirectory)
    $reportName = if ($NodeCapacityOnly) { 'node-capacity-integration-nunit.xml' } else { 'live-integration-nunit.xml' }
    $nunitPath = Join-Path $resultsDirectory $reportName
    $timestamp = [DateTime]::UtcNow.ToString('o')
    $testCases = @($results | ForEach-Object {
        $queryName = [Security.SecurityElement]::Escape([string]$_.Query)
        '    <test-case name="{0}" result="Passed"><properties><property name="Rows" value="{1}" /></properties></test-case>' -f $queryName, $_.Rows
    }) -join [Environment]::NewLine
    $nunitXml = @"
<?xml version="1.0" encoding="utf-8"?>
<test-run name="LENS.LiveIntegration" testcasecount="$($results.Count)" result="Passed" total="$($results.Count)" passed="$($results.Count)" failed="0" start-time="$timestamp" end-time="$timestamp">
    <test-suite type="TestFixture" name="Capacity queries" testcasecount="$($results.Count)" result="Passed" total="$($results.Count)" passed="$($results.Count)" failed="0">
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