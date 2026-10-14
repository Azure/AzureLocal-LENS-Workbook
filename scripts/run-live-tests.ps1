<#
.SYNOPSIS
Runs opt-in Capacity KQL integration tests against a real Log Analytics workspace.

.DESCRIPTION
This suite is intentionally excluded from CI because it requires Azure access and
live telemetry. It executes the exact storage, coverage, forecast and network
queries from the split workbook sources, then synthetic storage cases for source
separation, units, duplicate/partial samples, missing values and volume identity.

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

function Test-StorageSources {
    param([string]$WorkspaceId, [string]$AccessToken)

    function Invoke-StorageFixture {
        param([string]$Query)
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
            -Headers @{ Authorization = "Bearer $AccessToken" } -ContentType 'application/json' `
            -Body (@{ query = $Query } | ConvertTo-Json -Depth 10)
        if ($response.error) { throw 'Storage fixture returned a partial query error.' }
        $table = $response.tables[0]
        foreach ($row in $table.rows) {
            $record = [ordered]@{}
            for ($columnIndex = 0; $columnIndex -lt $table.columns.Count; $columnIndex++) {
                $record[$table.columns[$columnIndex].name] = $row[$columnIndex]
            }
            [pscustomobject]$record
        }
    }

    $samples = [Collections.Generic.List[object]]::new()
    $csvCounters = @{ 'Reads/sec' = 10; 'Writes/sec' = 20; 'Avg. sec/Read' = 0.002; 'Avg. sec/Write' = 0.004 }
    foreach ($hostName in @('both', 'duplicates', 'partial', 'zero', 'invalid', 'aggregate-only')) {
        foreach ($counter in $csvCounters.Keys) {
            if ($hostName -eq 'partial' -and $counter -like '*Write*') { continue }
            $counterValue = $csvCounters[$counter]
            if ($hostName -eq 'zero') { $counterValue = 0 }
            if ($hostName -eq 'invalid' -and $counter -like '*Read*') { $counterValue = -1 }
            $sample = [pscustomobject]@{
                TimeGenerated = '2026-01-01T00:01:00Z'; Computer = $hostName; ObjectName = 'Cluster CSVFS'
                CounterName = $counter; InstanceName = $(if ($hostName -eq 'aggregate-only') { '_Total' } else { 'Volume01' })
                CounterValue = $counterValue
            }
            $samples.Add($sample)
            if ($hostName -eq 'duplicates') { $samples.Add($sample) }
        }
    }
    foreach ($counter in @('Disk Transfers/sec', 'Avg. Disk sec/Read', 'Avg. Disk sec/Write')) {
        $samples.Add([pscustomobject]@{
            TimeGenerated = '2026-01-01T00:01:00Z'; Computer = 'both'; ObjectName = 'LogicalDisk'
            CounterName = $counter; InstanceName = 'C:'
            CounterValue = $(if ($counter -eq 'Disk Transfers/sec') { 100 } elseif ($counter -like '*Read') { 0.01 } else { 0.03 })
        })
    }
    $sampleJson = ConvertTo-Json -InputObject $samples.ToArray() -Depth 10 -Compress
    $perfSource = "(print fixtureRow = dynamic($sampleJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), Computer=tostring(fixtureRow.Computer), ObjectName=tostring(fixtureRow.ObjectName), CounterName=tostring(fixtureRow.CounterName), InstanceName=tostring(fixtureRow.InstanceName), CounterValue=todouble(fixtureRow.CounterValue))"
    $insights = [Collections.Generic.List[object]]::new()
    foreach ($hostName in @('both', 'logical-only')) {
        foreach ($counter in @('ReadsPerSecond', 'WritesPerSecond', 'ReadLatencyMs', 'WriteLatencyMs')) {
            $insights.Add([pscustomobject]@{
                TimeGenerated = '2026-01-01T00:01:00Z'; Namespace = 'LogicalDisk'; Name = $counter
                Val = $(if ($counter -like '*PerSecond') { 60 } else { 10 })
                Tags = @{ 'vm.azm.ms/mountId' = 'C:' }
                _ResourceId = "/subscriptions/example/resourceGroups/example/providers/Microsoft.HybridCompute/machines/$hostName"
            })
        }
    }
    $insightsJson = ConvertTo-Json -InputObject $insights.ToArray() -Depth 10 -Compress
    $insightsSource = "(print fixtureRow = dynamic($insightsJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), Namespace=tostring(fixtureRow.Namespace), Name=tostring(fixtureRow.Name), Val=todouble(fixtureRow.Val), Tags=fixtureRow.Tags, _ResourceId=tostring(fixtureRow._ResourceId))"
    $fixtureHeader = 'let trendStart=datetime(2026-01-01); let trendEnd=datetime(2026-01-02); let step=1d; '
    foreach ($tab in @('Capacity-Overview', 'Capacity-SingleCluster', 'Capacity-MultiCluster')) {
        $book = Get-Content -Raw (Join-Path $repoRoot "workbooks/$tab/$tab.workbook") | ConvertFrom-Json
        $items = @(Get-WorkbookItems -Items $book.items)
        foreach ($item in @($items | Where-Object { $_.name -in @('node-storage-latency-trend', 'node-storage-iops-trend', 'sc-storage-latency-node', 'sc-storage-iops-node', 'mc-storage-latency', 'mc-storage-iops') })) {
            $template = [string]$item.content.query
            $start = $template.IndexOf('let perfSamples = Perf')
            $end = $template.IndexOf('let dailySamples =')
            if ($start -lt 0 -or $end -le $start) { throw "Storage fixture boundary missing: $($item.name)" }
            $query = $fixtureHeader + $template.Substring($start, $end - $start)
            $query = $query.Replace('let perfSamples = Perf', "let perfSamples = $perfSource")
            $query = $query.Replace('let insightsSamples = InsightsMetrics', "let insightsSamples = $insightsSource")
            $rows = @(Invoke-StorageFixture -Query ($query + 'hostSamples'))
            $hostColumn = if ($tab -eq 'Capacity-Overview') { 'Computer' } else { 'nodeName' }
            $metricColumn = if ($item.name -like '*latency*') { 'HostLatencyMs' } else { 'HostIOPS' }
            $expectedCsv = if ($item.name -like '*latency*') { 3 } else { 30 }
            $expectedLogical = if ($item.name -like '*latency*') { 20 } else { 100 }
            $bothCsv = @($rows | Where-Object { $_.$hostColumn -eq 'both' -and $_.StorageScope -eq 'CSV' })
            $bothLogical = @($rows | Where-Object { $_.$hostColumn -eq 'both' -and $_.StorageScope -eq 'Logical disks' })
            $duplicate = @($rows | Where-Object { $_.$hostColumn -eq 'duplicates' })
            $zero = @($rows | Where-Object { $_.$hostColumn -eq 'zero' })
            if ($bothCsv.Count -ne 1 -or $bothCsv[0].$metricColumn -ne $expectedCsv -or
                $bothLogical.Count -ne 1 -or $bothLogical[0].$metricColumn -ne $expectedLogical -or
                $duplicate.Count -ne 1 -or $duplicate[0].$metricColumn -ne $expectedCsv -or
                $zero.Count -ne 1 -or $zero[0].$metricColumn -ne 0 -or
                @($rows | Where-Object { $_.$hostColumn -in @('partial', 'invalid', 'aggregate-only') }).Count -ne 0) {
                throw "Storage scope, units, deduplication or missing-data fixture failed: $($item.name)"
            }
            $logicalOnly = @($rows | Where-Object { $_.$hostColumn -eq 'logical-only' })
            if ($query.Contains('let insightsSamples')) {
                $expectedInsights = if ($item.name -like '*latency*') { 10 } else { 120 }
                if ($logicalOnly.Count -ne 1 -or $logicalOnly[0].StorageScope -ne 'Logical disks' -or $logicalOnly[0].$metricColumn -ne $expectedInsights) {
                    throw "Logical-only data was lost or mislabeled: $($item.name)"
                }
            } elseif ($logicalOnly.Count -ne 0) { throw 'Unexpected Insights fallback.' }
            [pscustomobject]@{ Query = "$($item.name)-fixtures"; Rows = $rows.Count; Result = 'Passed' }
        }
    }

    $volumes = @(
        @{ m_Id = 'volume-a'; m_Label = 'Volume01'; m_Size = 100; m_SizeUsed = 25 },
        @{ m_Id = 'volume-a'; m_Label = 'Volume01'; m_Size = 100; m_SizeUsed = 25 },
        @{ m_Id = 'volume-b'; m_Label = 'Volume01'; m_Size = 300; m_SizeUsed = 150 },
        @{ m_Label = 'ClusterPerformanceHistory'; m_Size = 100; m_SizeUsed = 100 },
        @{ m_Label = 'Invalid'; m_Size = 100; m_SizeUsed = 101 },
        @{ m_Label = 'Missing'; m_Size = 100; m_SizeUsed = $null },
        @{ m_Label = 'Empty'; m_Size = 0; m_SizeUsed = 0 }
    )
    $events = @(
        @{ TimeGenerated = '2026-01-01T00:10:00Z'; ClusterId = 'cluster-a'; Volumes = @(@{ m_Label = 'Old'; m_Size = 100; m_SizeUsed = 1 }) },
        @{ TimeGenerated = '2026-01-01T00:20:00Z'; ClusterId = 'cluster-a'; Volumes = $volumes },
        @{ TimeGenerated = '2026-01-01T00:20:00Z'; ClusterId = 'cluster-a'; Volumes = $volumes },
        @{ TimeGenerated = '2026-01-01T00:20:00Z'; ClusterId = 'cluster-b'; Volumes = @(@{ m_Id = 'volume-a'; m_Label = 'Volume01'; m_Size = 200; m_SizeUsed = 100 }) },
        @{ TimeGenerated = '2026-01-01T00:20:00Z'; ClusterId = 'outside-scope'; Volumes = $volumes }
    )
    $eventJson = ConvertTo-Json -InputObject $events -Depth 10 -Compress
    $eventSource = "(print fixtureRow = dynamic($eventJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), EventLog='Microsoft-Windows-SDDC-Management/Operational', EventID=3002, EventData=strcat('<DataItem><UserData><EventData><ArmId>', tostring(fixtureRow.ClusterId), '</ArmId></EventData></UserData></DataItem>'), RenderedDescription=tostring(bag_pack('VolumeList', fixtureRow.Volumes)))"
    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-Overview/Capacity-Overview.workbook') | ConvertFrom-Json
    $template = [string](@(Get-WorkbookItems -Items $book.items) | Where-Object name -EQ 'node-storage-trend').content.query
    $start = $template.IndexOf('let csvClusterMap =')
    $end = $template.IndexOf('let m2 = InsightsMetrics')
    $query = $fixtureHeader + $template.Substring($start, $end - $start)
    $query = $query.Replace('{ClusterNodeMap}', '["node-a:Cluster A:cluster-a","node-b:Cluster A:cluster-a","node-c:Cluster B:cluster-b"]')
    $query = $query.Replace('let csvVolumes = Event', "let csvVolumes = $eventSource")
    $rows = @(Invoke-StorageFixture -Query ($query + 'csvVolumes | summarize TotalBytes=sum(TotalBytes), UsedBytes=sum(UsedBytes), Volumes=count() by ClusterArmId'))
    $clusterA = @($rows | Where-Object ClusterArmId -EQ 'cluster-a')
    $clusterB = @($rows | Where-Object ClusterArmId -EQ 'cluster-b')
    if ($rows.Count -ne 2 -or $clusterA.Count -ne 1 -or $clusterA[0].TotalBytes -ne 400 -or $clusterA[0].UsedBytes -ne 175 -or
        $clusterA[0].Volumes -ne 2 -or $clusterB.Count -ne 1 -or $clusterB[0].TotalBytes -ne 200 -or $clusterB[0].UsedBytes -ne 100) {
        throw 'CSV capacity fixture failed: latest snapshot, duplicate reporter/volume, invalid value or scope handling.'
    }
    [pscustomobject]@{ Query = 'csv-capacity-snapshot-fixtures'; Rows = $rows.Count; Result = 'Passed' }
    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-SingleCluster/Capacity-SingleCluster.workbook') | ConvertFrom-Json
    $template = [string](@(Get-WorkbookItems -Items $book.items) | Where-Object name -EQ 'single-cluster-volume-usage').content.query
    $start = $template.IndexOf('let csvClusterMap =')
    $end = $template.IndexOf('// 2)')
    $query = $fixtureHeader + $template.Substring($start, $end - $start)
    $query = $query.Replace('{SingleCluster}', 'cluster-a').Replace('{ClusterNodeMap}', '["node-a:Cluster A:cluster-a","node-b:Cluster A:cluster-a"]')
    $query = $query.Replace('let csvVolumes = Event', "let csvVolumes = $eventSource")
    $rows = @(Invoke-StorageFixture -Query ($query + 'perVolumePerDay'))
    if ($rows.Count -ne 2 -or @($rows.VolumeLabel | Sort-Object -Unique).Count -ne 2 -or
        @($rows | Where-Object UsedPct -EQ 25).Count -ne 1 -or @($rows | Where-Object UsedPct -EQ 50).Count -ne 1) {
        throw 'CSV per-volume fixture merged different volumes with the same display label.'
    }
    [pscustomobject]@{ Query = 'csv-capacity-volume-label-fixtures'; Rows = $rows.Count; Result = 'Passed' }

    $rankingSamples = [Collections.Generic.List[object]]::new()
    foreach ($clusterIndex in 1..12) {
        foreach ($scope in @('CSV', 'Logical disks')) {
            foreach ($day in 1..2) {
                $rankingSamples.Add([pscustomobject]@{
                    clusterName = 'cluster-{0:00}' -f $clusterIndex
                    StorageScope = $scope
                    TimeGenerated = '2026-01-{0:00}T00:00:00Z' -f $day
                    Value = $(if ($scope -eq 'CSV') { $clusterIndex } else { 13 - $clusterIndex })
                })
            }
        }
    }
    $rankingJson = ConvertTo-Json -InputObject $rankingSamples.ToArray() -Depth 10 -Compress
    $rankingSource = "let rankingSamples = print fixtureRow = dynamic($rankingJson) | mv-expand fixtureRow | project clusterName=tostring(fixtureRow.clusterName), StorageScope=tostring(fixtureRow.StorageScope), TimeGenerated=todatetime(fixtureRow.TimeGenerated), UsedPercent=todouble(fixtureRow.Value), HostLatencyMs=todouble(fixtureRow.Value), HostIOPS=todouble(fixtureRow.Value); let allCapacity=rankingSamples; let dailySamples=rankingSamples; "
    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-Overview/Capacity-Overview.workbook') | ConvertFrom-Json
    $rankingCharts = @(Get-WorkbookItems -Items $book.items | Where-Object { $_.name -match '^node-(logical-)?storage-(trend|latency-trend|iops-trend)$' })
    if ($rankingCharts.Count -ne 6) { throw 'Expected six source-specific storage ranking charts.' }
    foreach ($chart in $rankingCharts) {
        $template = [string]$chart.content.query
        $start = $template.IndexOf('let top5 =')
        if ($start -lt 0) { throw "Missing Top 5 query boundary: $($chart.name)" }
        $rows = @(Invoke-StorageFixture -Query ($rankingSource + $template.Substring($start)))
        $expectedIndices = if ($chart.name -like 'node-logical-*') { 1..5 } else { 8..12 }
        $expectedClusters = @($expectedIndices | ForEach-Object { 'cluster-{0:00}' -f $_ })
        $actualClusters = @($rows.clusterName | Sort-Object -Unique)
        if ($rows.Count -ne 10 -or ($actualClusters -join ',') -cne ($expectedClusters -join ',')) {
            throw "Top 5 fixture selected too many clusters or the wrong storage source: $($chart.name)"
        }
        [pscustomobject]@{ Query = "$($chart.name)-top5-fixtures"; Rows = $rows.Count; Result = 'Passed' }
    }

    $forecastSamples = [Collections.Generic.List[object]]::new()
    foreach ($clusterIndex in 1..4) {
        $days = if ($clusterIndex -le 2) { 2 } else { 3 }
        foreach ($dayIndex in 0..($days - 1)) {
            $forecastSamples.Add(@{
                ClusterArmId = "cluster-$clusterIndex"; clusterName = 'same-name'
                Day = ([datetime]'2026-01-01').AddDays($dayIndex).ToString('yyyy-MM-dd')
                TotalBytes = 100; UsedBytes = $(if ($clusterIndex -eq 4) { 80 - 10 * $dayIndex } else { 10 + 10 * $dayIndex })
            })
        }
    }
    $forecastJson = ConvertTo-Json -InputObject $forecastSamples.ToArray() -Depth 10 -Compress
    $forecastSource = "let trendStart=datetime(2026-01-01); let warnPct=80.0; let critPct=90.0; let csvVolumes=print fixtureRow=dynamic($forecastJson) | mv-expand fixtureRow | project ClusterArmId=tostring(fixtureRow.ClusterArmId), clusterName=tostring(fixtureRow.clusterName), Day=todatetime(fixtureRow.Day), TotalBytes=todouble(fixtureRow.TotalBytes), UsedBytes=todouble(fixtureRow.UsedBytes); let cpuData=datatable(clusterName:string, Resource:string, CurrentAvg:real, SlopePerDay:real)[]; let memData=cpuData; let armIdByCluster=datatable(clusterName:string, armId:string)['same-name','cluster-1','same-name','cluster-2','same-name','cluster-3','same-name','cluster-4']; "
    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-MultiCluster/Capacity-MultiCluster.workbook') | ConvertFrom-Json
    $forecastTemplate = [string](@(Get-WorkbookItems -Items $book.items) | Where-Object name -EQ 'node-exhaustion-forecast-table').content.query
    $forecastStart = $forecastTemplate.IndexOf('let storData =')
    if ($forecastStart -lt 0) { throw 'Storage forecast fixture boundary missing.' }
    foreach ($selectedCluster in @('value::all', 'cluster-3')) {
        $query = $forecastSource + $forecastTemplate.Substring($forecastStart)
        $query = $query.Replace('{ForecastResourceFilter}', 'Storage').Replace('{ForecastClusterFilter}', $selectedCluster)
        $query = $query.Replace('| project ["Cluster Name"]', '| project ArmId, SlopePerDay, ["Cluster Name"]')
        $rows = @(Invoke-StorageFixture -Query $query)
        $expectedCount = if ($selectedCluster -eq 'value::all') { 2 } else { 1 }
        $rising = @($rows | Where-Object ArmId -EQ 'cluster-3')
        if ($rows.Count -ne $expectedCount -or $rising.Count -ne 1 -or $rising[0].'Current Avg %%' -ne 20 -or $rising[0].SlopePerDay -ne 10 -or @($rows | Where-Object { $_.ArmId -in @('cluster-1', 'cluster-2') }).Count -ne 0) {
            throw 'Same-name cluster forecast history or resource filtering failed.'
        }
        if ($selectedCluster -eq 'value::all') {
            $declining = @($rows | Where-Object ArmId -EQ 'cluster-4')
            if ($declining.Count -ne 1 -or $declining[0].'Current Avg %%' -ne 70 -or $declining[0].SlopePerDay -ne -10) { throw 'Same-name cluster forecast values were blended.' }
        }
        [pscustomobject]@{ Query = "storage-forecast-resource-identity-$selectedCluster"; Rows = $rows.Count; Result = 'Passed' }
    }

    $clusterSamples = [Collections.Generic.List[object]]::new()
    foreach ($clusterIndex in 1..7) {
        foreach ($machineIndex in 0..1) {
            foreach ($scope in @('CSV', 'Logical disks')) {
                $clusterSamples.Add([pscustomobject]@{
                    clusterName = 'cluster-{0:00}' -f $clusterIndex
                    nodeName = ('machine-{0:00}-{1}' -f $clusterIndex, $machineIndex)
                    StorageScope = $scope
                    Value = ($clusterIndex * 10 + $machineIndex * 2) * $(if ($scope -eq 'CSV') { 1 } else { 10 })
                })
            }
        }
    }
    $clusterJson = ConvertTo-Json -InputObject $clusterSamples.ToArray() -Depth 10 -Compress
    $clusterSource = "let dailySamples = print fixtureRow = dynamic($clusterJson) | mv-expand fixtureRow | project clusterName=tostring(fixtureRow.clusterName), nodeName=tostring(fixtureRow.nodeName), StorageScope=tostring(fixtureRow.StorageScope), TimeGenerated=datetime(2026-01-01), HostLatencyMs=todouble(fixtureRow.Value), HostIOPS=todouble(fixtureRow.Value); "
    foreach ($tab in @('Capacity-SingleCluster', 'Capacity-MultiCluster')) {
        $book = Get-Content -Raw (Join-Path $repoRoot "workbooks/$tab/$tab.workbook") | ConvertFrom-Json
        $charts = @(Get-WorkbookItems -Items $book.items | Where-Object { $_.name -match '^(sc|mc)-(logical-)?storage-(latency|iops)(-node)?$' })
        if ($charts.Count -ne 4) { throw "Expected four split performance charts in $tab." }
        foreach ($chart in $charts) {
            $template = [string]$chart.content.query
            $start = $template.IndexOf("`r`ndailySamples`r`n")
            if ($start -lt 0) { throw "Missing daily sample boundary: $($chart.name)" }
            $rows = @(Invoke-StorageFixture -Query ($clusterSource + $template.Substring($start)))
            $single = $chart.name.StartsWith('sc-')
            $scope = if ($chart.name.Contains('-logical-')) { 'Logical disks' } else { 'CSV' }
            $expected = @($clusterSamples.ToArray() | Where-Object StorageScope -EQ $scope)
            $key = if ($single) { 'nodeName' } else { 'clusterName' }
            $outputKey = if ($single) { 'Computer' } else { 'clusterName' }
            $expectedGroups = @($expected | Group-Object -Property $key)
            $metric = [string]$chart.content.chartSettings.yAxis[0]
            if ($rows.Count -ne $expectedGroups.Count) { throw "Scope fixture lost machines/clusters or mixed sources: $($chart.name)" }
            foreach ($group in $expectedGroups) {
                $actual = @($rows | Where-Object { $_.$outputKey -eq $group.Name })
                $expectedValue = ($group.Group | Measure-Object -Property Value -Average).Average
                if ($actual.Count -ne 1 -or $actual[0].$metric -ne $expectedValue) { throw "Scope fixture changed aggregation or selected the wrong source: $($chart.name)" }
            }
            [pscustomobject]@{ Query = "$($chart.name)-scope-fixtures"; Rows = $rows.Count; Result = 'Passed' }
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
        param([object[]]$NodeMetadata, [string]$MinimumRatio = '0', [string]$HostFilter = "'*'", [object[]]$Samples, [string]$TargetRatio = '4', [string]$ClusterFilter = "'*'", [object[]]$ResourceSamples)

        $query = $template.Replace('{HyperVNodeCapacityMap}', (ConvertTo-Json -InputObject $NodeMetadata -Depth 10 -Compress))
        $query = $query.Replace('{HyperVInvHostFilter}', $HostFilter).Replace('{HyperVNodeRatioFilter}', $MinimumRatio)
        $query = $query.Replace('{HyperVNodeTargetRatio}', $TargetRatio)
        $query = $query.Replace('{HyperVNodeClusterFilter}', $ClusterFilter)
        if ($PSBoundParameters.ContainsKey('Samples')) {
            $samplesJson = ConvertTo-Json -InputObject $Samples -Depth 10 -Compress
            $source = "(print fixtureRow = dynamic($samplesJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), Computer=tostring(fixtureRow.Computer), _ResourceId=tostring(fixtureRow.HostId), ObjectName=tostring(fixtureRow.ObjectName), CounterName=tostring(fixtureRow.CounterName), InstanceName=tostring(fixtureRow.InstanceName), CounterValue=todouble(fixtureRow.CounterValue))"
            $query = $query.Replace('let raw = materialize(Perf', "let raw = materialize($source")
        }
        if ($PSBoundParameters.ContainsKey('ResourceSamples')) {
            $resourceJson = ConvertTo-Json -InputObject $ResourceSamples -Depth 10 -Compress
            $source = "(print fixtureRow = dynamic($resourceJson) | mv-expand fixtureRow | project id=tostring(fixtureRow.id), name=tostring(fixtureRow.name), type=tostring(fixtureRow.type), subscriptionId=tostring(fixtureRow.subscriptionId), resourceGroup=tostring(fixtureRow.resourceGroup), properties=fixtureRow.properties, tags=fixtureRow.tags)"
            $query = $mapQuery.Replace('resources', $source)
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
            $used = $_.'Memory Used GiB'
            $available = $_.'Memory Free / Available GiB'
            $percentage = $_.'Memory Used %'
            if ($null -eq $available -or $null -eq $percentage -or $used -lt 0 -or $available -lt 0 -or $percentage -lt 0 -or $percentage -gt 100) {
                $true
            } elseif ($used + $available -gt 0) {
                $denominator = $used + $available
                $roundingTolerance = 0.1 + 10 / $denominator
                [math]::Abs($percentage - 100 * $used / $denominator) -gt $roundingTolerance
            }
        })
        Assert-Capacity ($invalidMemory.Count -eq 0) 'node-capacity-live-memory-percentage'
        $filtered = @(Invoke-CapacityQuery -NodeMetadata @($metadata) -MinimumRatio '2')
        Assert-Capacity (@($filtered | Where-Object { $null -eq $_.'V:P CPU Ratio' -or $_.'V:P CPU Ratio' -lt 2 }).Count -eq 0) 'node-capacity-live-minimum-ratio' $filtered.Count

        $fixtureNodes = [System.Collections.Generic.List[object]]::new()
        $fixtureSamples = [System.Collections.Generic.List[object]]::new()
        $scenarios = @('healthy', 'high-ratio', 'duplicates', 'partial', 'migrate-source', 'migrate-target', 'collision-a', 'collision-b', 'other-cluster', 'missing', 'aggregate-only', 'missing-cores', 'ambiguous', 'invalid-memory', 'stale', 'single', 'invalid-cpu', 'missing-committed', 'missing-available', 'zero-memory', 'high-committed', 'zero-committed', 'zero-available')
        foreach ($scenario in $scenarios) {
            $node = [pscustomobject]@{
                hostId = "host-$scenario"; machine = $scenario; cluster = 'cluster-a'; clusterId = 'cluster-a'
                physicalCores = 8; logicalProcessors = 16; memoryGiB = 64
            }
            if ($scenario -eq 'other-cluster') { $node.clusterId = 'cluster-b' }
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
                if ($scenario -ne 'missing-available' -or $sampleAge -eq 2) {
                    $fixtureSamples.Add([pscustomobject]@{
                        TimeGenerated = $sampleTime.ToString('o'); Computer = $scenario; HostId = $node.hostId
                        ObjectName = 'Memory'; CounterName = 'Available Bytes'; InstanceName = ''
                        CounterValue = $(if ($scenario -eq 'invalid-memory') { -1 } elseif ($scenario -in @('zero-memory', 'zero-available')) { 0 } else { 16GB })
                    })
                }
                if ($scenario -ne 'missing-committed' -or $sampleAge -eq 2) {
                    $fixtureSamples.Add([pscustomobject]@{
                        TimeGenerated = $sampleTime.ToString('o'); Computer = $scenario; HostId = $node.hostId
                        ObjectName = 'Memory'; CounterName = 'Committed Bytes'; InstanceName = ''
                        CounterValue = $(if ($scenario -eq 'high-committed') { 128GB } elseif ($scenario -in @('zero-memory', 'zero-committed')) { 0 } else { 32GB })
                    })
                }
            }
        }
        $fixtureRows = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray())
        $byMachine = @{}
        foreach ($row in $fixtureRows) { $byMachine[$row.Machine] = $row }
        Assert-Capacity ($fixtureRows.Count -eq $scenarios.Count) 'node-capacity-fixture-node-preservation'
        Assert-Capacity ($fixtureRows[0].Machine -eq 'high-ratio' -and $fixtureRows[0].'V:P CPU Ratio' -eq 4) 'node-capacity-numeric-descending-sort'
        Assert-Capacity ($byMachine['high-ratio'].'% of V:P Target' -eq 100) 'node-capacity-default-target-percentage'
        $targetFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -TargetRatio '2')
        Assert-Capacity ($targetFixture.Count -eq $fixtureRows.Count -and $targetFixture[0].'V:P CPU Ratio' -eq 4 -and $targetFixture[0].'% of V:P Target' -eq 200) 'node-capacity-target-independent-of-ratio-and-filter'
        $invalidTargetFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -TargetRatio '0')
        Assert-Capacity ($invalidTargetFixture.Count -eq $fixtureRows.Count -and @($invalidTargetFixture | Where-Object { $null -ne $_.'% of V:P Target' }).Count -eq 0) 'node-capacity-invalid-target-unavailable'
        Assert-Capacity ($byMachine['healthy'].'V:P CPU Ratio' -eq 0.5 -and $byMachine['healthy'].'Observed VM vCPUs' -eq 4) 'node-capacity-physical-not-logical-denominator'
        Assert-Capacity ($byMachine['healthy'].'Memory Total GiB' -eq 64 -and $byMachine['healthy'].'Memory Used GiB' -eq 32 -and $byMachine['healthy'].'Memory Free / Available GiB' -eq 16 -and $byMachine['healthy'].'Memory Used %' -eq 66.7) 'node-capacity-memory-calculation'
        Assert-Capacity ($byMachine['high-committed'].'Memory Used GiB' -eq 128 -and $byMachine['high-committed'].'Memory Used %' -eq 88.9) 'node-capacity-committed-above-physical-memory'
        Assert-Capacity ($byMachine['zero-committed'].'Memory Used %' -eq 0 -and $byMachine['zero-available'].'Memory Used %' -eq 100) 'node-capacity-memory-percentage-boundaries'
        Assert-Capacity ($byMachine['healthy'].'Avg CPU % (15 min)' -eq 20 -and $byMachine['healthy'].'Avg CPU Free %' -eq 80) 'node-capacity-host-cpu-calculation'
        Assert-Capacity ($byMachine['duplicates'].'Observed VM vCPUs' -eq 4) 'node-capacity-deduplication'
        foreach ($scenario in @('partial', 'migrate-source', 'migrate-target', 'collision-a', 'collision-b', 'missing', 'aggregate-only', 'missing-cores', 'ambiguous', 'stale', 'single')) {
            Assert-Capacity ($null -eq $byMachine[$scenario].'V:P CPU Ratio' -and $null -eq $byMachine[$scenario].'% of V:P Target') "node-capacity-unavailable-$scenario"
        }
        Assert-Capacity ($byMachine['other-cluster'].'V:P CPU Ratio' -eq 0.5) 'node-capacity-duplicate-name-cluster-scope'
        foreach ($scenario in @('invalid-memory', 'missing-committed', 'missing-available', 'zero-memory', 'missing', 'stale')) {
            Assert-Capacity ($null -eq $byMachine[$scenario].'Memory Used %' -and $null -eq $byMachine[$scenario].'Memory Used GiB' -and $null -eq $byMachine[$scenario].'Memory Free / Available GiB' -and $byMachine[$scenario].Status -like '*memory unavailable*') "node-capacity-memory-unavailable-$scenario"
        }
        Assert-Capacity ($null -eq $byMachine['invalid-cpu'].'Avg CPU % (15 min)') 'node-capacity-invalid-host-cpu'
        $filteredFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -MinimumRatio '2')
        Assert-Capacity ($filteredFixture.Count -eq 1 -and $filteredFixture[0].Machine -eq 'high-ratio') 'node-capacity-ratio-filter-excludes-unknown'
        $hostFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -HostFilter "'healthy'")
        Assert-Capacity ($hostFixture.Count -eq 1 -and $hostFixture[0].Machine -eq 'healthy') 'node-capacity-host-filter'
        $clusterFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -ClusterFilter "'cluster-b'")
        Assert-Capacity ($clusterFixture.Count -eq 1 -and $clusterFixture[0].Machine -eq 'other-cluster') 'node-capacity-cluster-filter-distinguishes-identical-names'
        $multiClusterFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -ClusterFilter "'cluster-a','cluster-b'")
        Assert-Capacity ($multiClusterFixture.Count -eq ($fixtureRows.Count - 1) -and @($multiClusterFixture | Where-Object Machine -EQ 'ambiguous').Count -eq 0) 'node-capacity-multi-cluster-excludes-unresolved'
        Assert-Capacity (@($multiClusterFixture | Where-Object Machine -EQ 'missing').Count -eq 1 -and @($multiClusterFixture | Where-Object { $_.Machine -eq 'collision-a' -and $null -eq $_.'V:P CPU Ratio' }).Count -eq 1) 'node-capacity-cluster-filter-preserves-missing-and-collision-checks'
        $combinedFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -ClusterFilter "'cluster-b'" -MinimumRatio '2')
        Assert-Capacity ($combinedFixture.Count -eq 0) 'node-capacity-cluster-and-ratio-intersection'
        $unmatchedFixture = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -ClusterFilter "'not-in-scope'")
        Assert-Capacity ($unmatchedFixture.Count -eq 0) 'node-capacity-unmatched-cluster-empty'

        $identityNodes = @(
            [pscustomobject]@{ hostId = 'domain-a'; machine = 'node01'; cluster = 'cluster-a'; clusterId = 'cluster-a'; physicalCores = 8; memoryGiB = 64 },
            [pscustomobject]@{ hostId = 'domain-b'; machine = 'node01'; cluster = 'cluster-b'; clusterId = 'cluster-b'; physicalCores = 8; memoryGiB = 64 }
        )
        $identitySamples = foreach ($node in $identityNodes) {
            foreach ($sample in @($fixtureSamples.ToArray() | Where-Object HostId -EQ 'host-healthy')) {
                [pscustomobject]@{
                    TimeGenerated = $sample.TimeGenerated; Computer = "node01.$($node.hostId).example"; HostId = $node.hostId
                    ObjectName = $sample.ObjectName; CounterName = $sample.CounterName
                    InstanceName = $sample.InstanceName; CounterValue = $sample.CounterValue
                }
            }
        }
        $identityRows = @(Invoke-CapacityQuery -NodeMetadata $identityNodes -Samples $identitySamples -HostFilter "'node01.domain-a.example'")
        Assert-Capacity ($identityRows.Count -eq 1 -and $identityRows[0].clusterLink.EndsWith('cluster-a')) 'node-capacity-fqdn-selection-does-not-expand-short-name'
        $identityRows = @(Invoke-CapacityQuery -NodeMetadata $identityNodes -Samples @() -HostFilter "'node01.domain-a.example'")
        Assert-Capacity ($identityRows.Count -eq 0) 'node-capacity-ambiguous-missing-telemetry-excluded'
        $identityRows = @(Invoke-CapacityQuery -NodeMetadata @($identityNodes[0]) -Samples @() -HostFilter "'node01.domain-a.example'")
        Assert-Capacity ($identityRows.Count -eq 1) 'node-capacity-unique-historical-fqdn-retained'
        $identityRows = @(Invoke-CapacityQuery -NodeMetadata @($identityNodes[1]) -Samples $identitySamples -HostFilter "'node01.domain-a.example'")
        Assert-Capacity ($identityRows.Count -eq 0) 'node-capacity-existing-telemetry-blocks-short-name-fallback'

        $resourceSamples = @(
            @{ id = 'host-fqdn'; name = 'node1.example.test'; type = 'microsoft.hybridcompute/machines'; subscriptionId = 'example'; resourceGroup = 'group-a'; properties = @{ cloudMetadata = @{ provider = 'AzSHCI' }; detectedProperties = @{ model = 'Example Server' } } },
            @{ id = 'host-short'; name = 'node2'; type = 'microsoft.hybridcompute/machines'; subscriptionId = 'example'; resourceGroup = 'group-a'; properties = @{ cloudMetadata = @{ provider = 'AzSHCI' }; detectedProperties = @{ model = 'Example Server' } } },
            @{ id = 'cluster-a'; name = 'cluster-a'; type = 'microsoft.azurestackhci/clusters'; subscriptionId = 'example'; resourceGroup = 'group-a'; tags = @{}; properties = @{ reportedProperties = @{ nodes = @(@{ name = 'node1'; coreCount = 8 }, @{ name = 'node2.example.test'; coreCount = 16 }) } } }
        )
        $metadataRows = @(Invoke-CapacityQuery -NodeMetadata @() -ResourceSamples $resourceSamples)
        $metadataFixture = @($metadataRows[0].value | ConvertFrom-Json)
        Assert-Capacity ($metadataFixture.Count -eq 2 -and @($metadataFixture | Where-Object { $_.hostId -eq 'host-fqdn' -and $_.clusterId -eq 'cluster-a' -and $_.physicalCores -eq 8 }).Count -eq 1 -and @($metadataFixture | Where-Object { $_.hostId -eq 'host-short' -and $_.clusterId -eq 'cluster-a' -and $_.physicalCores -eq 16 }).Count -eq 1) 'node-capacity-metadata-normalizes-both-name-forms'
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
| where type == 'microsoft.azurestackhci/clusters'
| extend nodes = todynamic(properties.reportedProperties.nodes)
| mv-expand node = nodes
| extend nodeShort = tolower(tostring(split(tostring(node.name), '.')[0]))
| where isnotempty(nodeShort)
| project nodeRG = tolower(resourceGroup), clusterName = name, armId = tostring(id), nodeShort
'@
    $mappingJson = az graph query --subscription $SubscriptionId --subscriptions $SubscriptionId `
        --graph-query ($mappingQuery -replace '\r?\n', ' ') --first 1000 --output json --only-show-errors
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

    $accessToken = az account get-access-token --tenant $account.tenantId --resource 'https://api.loganalytics.io' `
        --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not authenticate to the confirmed tenant.' }

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
        $query = $query.Replace('{ForecastTimeRange:start}', "ago($($Days)d)").Replace('{ForecastTimeRange:end}', 'now()')
        $query = $query.Replace('{ForecastHorizonDays}', '7').Replace('{WarningThreshold}', '80').Replace('{CriticalThreshold}', '90')
        $query = $query.Replace('{ForecastResourceFilter}', 'value::all').Replace('{ForecastClusterFilter}', 'value::all')

        $unresolvedParameters = @([regex]::Matches(
            $query,
            '\{[A-Za-z_][A-Za-z0-9_]*(?::\w+)?\}'
        ) | ForEach-Object Value | Sort-Object -Unique)
        if ($unresolvedParameters.Count -gt 0) {
            throw "Unresolved workbook parameters in $($spec.name): $($unresolvedParameters -join ', ')"
        }

        $logBody = @{
            query = $query
            timespan = "P$($Days)D"
        }
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://api.loganalytics.io/v1/workspaces/$($workspace.customerId)/query" `
            -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json' `
            -Body ($logBody | ConvertTo-Json -Depth 10)
        if ($response.error) {
            throw "Live Log Analytics query returned a partial error: $($spec.name)"
        }

        $rowCount = @($response.tables[0].rows).Count
        if ($rowCount -eq 0) {
            throw "Live Log Analytics query returned no rows: $($spec.name)"
        }

        [pscustomobject]@{ Query = $spec.name; Rows = $rowCount; Result = 'Passed' }
    }
    $results = @($results) + @(Test-StorageSources -WorkspaceId $workspace.customerId -AccessToken $accessToken)
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