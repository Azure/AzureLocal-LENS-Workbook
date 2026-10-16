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
    $detailSamples = @($samples.ToArray())
    foreach ($counter in $csvCounters.Keys) {
        $detailSamples += @{ TimeGenerated = '2026-01-01T00:01:00Z'; Computer = 'both'; ObjectName = 'Cluster CSVFS'; CounterName = $counter; InstanceName = 'Volume02'; CounterValue = 2 * $csvCounters[$counter] }
        $detailSamples += @{ TimeGenerated = '2026-01-01T00:01:00Z'; Computer = 'csv-only'; ObjectName = 'Cluster CSVFS'; CounterName = $counter; InstanceName = 'Volume01'; CounterValue = $csvCounters[$counter] }
    }
    foreach ($counter in @('Disk Transfers/sec', 'Avg. Disk sec/Read', 'Avg. Disk sec/Write')) {
        $detailSamples += @{ TimeGenerated = '2026-01-01T00:01:00Z'; Computer = 'both'; ObjectName = 'LogicalDisk'; CounterName = $counter; InstanceName = 'D:'; CounterValue = $(if ($counter -eq 'Disk Transfers/sec') { 200 } elseif ($counter -like '*Read') { 0.02 } else { 0.04 }) }
    }
    foreach ($hostName in @('zero', 'duplicates', 'partial', 'invalid')) {
        foreach ($counter in @('Disk Transfers/sec', 'Avg. Disk sec/Read', 'Avg. Disk sec/Write')) {
            if ($hostName -eq 'partial' -and $counter -ne 'Avg. Disk sec/Read') { continue }
            $counterValue = if ($counter -eq 'Disk Transfers/sec') { 30 } elseif ($counter -like '*Read') { 0.002 } else { 0.004 }
            if ($hostName -eq 'zero') { $counterValue = 0 }
            if ($hostName -eq 'invalid' -and $counter -ne 'Avg. Disk sec/Write') { $counterValue = -1 }
            $sample = @{ TimeGenerated = '2026-01-01T00:01:00Z'; Computer = $hostName; ObjectName = 'LogicalDisk'; CounterName = $counter; InstanceName = 'C:'; CounterValue = $counterValue }
            $detailSamples += $sample
            if ($hostName -eq 'duplicates') { $detailSamples += $sample }
        }
    }
    $detailJson = ConvertTo-Json -InputObject $detailSamples -Depth 10 -Compress
    $detailPerfSource = $perfSource.Replace($sampleJson, $detailJson)
    $detailInsights = @($insights.ToArray())
    foreach ($counter in @('ReadsPerSecond', 'WritesPerSecond')) {
        $detailInsights += @{ TimeGenerated = '2026-01-01T00:01:00Z'; Namespace = 'LogicalDisk'; Name = $counter; Val = 60; Tags = @{ 'vm.azm.ms/mountId' = 'E:' }; _ResourceId = '/subscriptions/example/resourceGroups/example/providers/Microsoft.HybridCompute/machines/both' }
    }
    $detailInsightsJson = ConvertTo-Json -InputObject $detailInsights -Depth 10 -Compress
    $detailInsightsSource = $insightsSource.Replace($insightsJson, $detailInsightsJson)
    $detailBook = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-SingleCluster/Capacity-SingleCluster.workbook') | ConvertFrom-Json
    $detailItems = @(Get-WorkbookItems -Items $detailBook.items)
    foreach ($chart in @($detailItems | Where-Object { $_.type -eq 3 -and $_.name -like 'sc-storage-detail-*' })) {
        $template = [string]$chart.content.query
        $start = $template.IndexOf('let perfSamples = Perf')
        if ($start -lt 0) { throw 'Storage detail fixture boundary missing.' }
        $logicalChart = $chart.name.Contains('-logical-')
        foreach ($scenario in @('selected-source', 'other-source', 'zero', 'duplicates', 'partial', 'invalid')) {
            $machine = if ($scenario -eq 'selected-source') { 'both' } elseif ($scenario -eq 'other-source') { $(if ($logicalChart) { 'csv-only' } else { 'logical-only' }) } else { $scenario }
            $query = $fixtureHeader + "let NodeToCluster=datatable(nodeName:string)['both','zero','duplicates','partial','invalid','aggregate-only','csv-only','logical-only']; " + $template.Substring($start)
            $query = $query.Replace('let perfSamples = Perf', "let perfSamples = $detailPerfSource").Replace('let insightsSamples = InsightsMetrics', "let insightsSamples = $detailInsightsSource")
            $query = $query.Replace('{SCStorageDetailMachine}', $machine)
            $rows = @(Invoke-StorageFixture -Query $query)
            $latencyChart = $chart.name.EndsWith('latency')
            $metric = if ($latencyChart) { 'Avg Latency (ms)' } else { 'Avg IOPS' }
            $expected = @{}
            if ($scenario -eq 'selected-source' -and -not $logicalChart) { $expected['Volume01'] = $(if ($latencyChart) { 3 } else { 30 }); $expected['Volume02'] = $(if ($latencyChart) { 6 } else { 60 }) }
            elseif ($scenario -eq 'selected-source') {
                $expected['C:'] = $(if ($latencyChart) { 20 } else { 100 }); $expected['D:'] = $(if ($latencyChart) { 30 } else { 200 })
                if (-not $latencyChart) { $expected['E:'] = 120 }
            } elseif ($scenario -eq 'zero') { $expected[$(if ($logicalChart) { 'C:' } else { 'Volume01' })] = 0 }
            elseif ($scenario -eq 'duplicates') { $expected[$(if ($logicalChart) { 'C:' } else { 'Volume01' })] = $(if ($latencyChart) { 3 } else { 30 }) }
            if ($rows.Count -ne $expected.Count) { throw "Storage detail row count failed: $($chart.name) / $scenario (expected $($expected.Count), got $($rows.Count))." }
            foreach ($row in $rows) {
                if (-not $expected.ContainsKey([string]$row.Volume) -or $row.$metric -ne $expected[[string]$row.Volume]) { throw "Storage detail values failed: $($chart.name) / $scenario." }
            }
            [pscustomobject]@{ Query = "$($chart.name)-$scenario-fixture"; Rows = $rows.Count; Result = 'Passed' }
        }
    }
    $picker = ($detailItems | Where-Object name -EQ 'sc-storage-detail-filters').content.parameters | Where-Object name -EQ 'SCStorageDetailMachine'
    $pickerQuery = $picker.query.Replace('{NodeTrendsTimeRange:start}', 'datetime(2026-01-01)').Replace('{NodeTrendsTimeRange:end}', 'datetime(2026-01-02)')
    $pickerQuery = $pickerQuery.Replace('{SingleCluster}', 'cluster-a').Replace('{ClusterRGMap}', '["group-a:Cluster A","group-b:Cluster B"]')
    $pickerQuery = $pickerQuery.Replace('{ClusterNodeMap}', '["both:Cluster A:cluster-a","outside:Cluster B:cluster-b"]')
    $pickerQuery = $pickerQuery.Replace('Heartbeat', "(datatable(TimeGenerated:datetime, Computer:string, ResourceGroup:string, OSType:string)[datetime(2026-01-01T00:01:00Z),'both','group-a','Windows',datetime(2026-01-01T00:01:00Z),'outside','group-b','Windows'])")
    $pickerRows = @(Invoke-StorageFixture -Query $pickerQuery)
    if ($pickerRows.Count -ne 1 -or $pickerRows[0].value -ne 'both' -or -not $pickerRows[0].selected) { throw 'Storage detail picker did not scope or default to the selected cluster.' }
    [pscustomobject]@{ Query = 'sc-storage-detail-machine-picker-fixture'; Rows = $pickerRows.Count; Result = 'Passed' }
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

function Test-HyperVDetail {
    param([string]$WorkspaceId, [string]$AccessToken)

    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-HyperV/Capacity-HyperV.workbook') | ConvertFrom-Json
    $items = @(Get-WorkbookItems -Items $book.items)
    $parameters = ($items | Where-Object name -EQ 'hyperv-detail-params').content.parameters
    $vmPicker = ($parameters | Where-Object name -EQ 'HyperVDetailVM').query
    $diskPicker = ($parameters | Where-Object name -EQ 'HyperVDetailDisk').query
    $template = ($items | Where-Object name -EQ 'hyperv-detail-chart').content.query

    function Invoke-DetailQuery {
        param([string]$Query, [string]$Metadata, [string]$VM = '', [string]$Metric = 'cpu', [string[]]$Disk = @(), [string]$Source)
        $diskValues = ($Disk | Where-Object { $_ } | ForEach-Object {
            if ($_ -notmatch '^[A-Za-z0-9+/]*={0,2}$') { throw 'Expected a base64-encoded disk selection.' }
            "'$_'"
        }) -join ','
        $query = $Query.Replace('{HyperVNodeCapacityMap}', $Metadata).
            Replace('{HyperVDetailTimeRange:start}', 'datetime(2026-01-01)').
            Replace('{HyperVDetailTimeRange:end}', 'datetime(2026-01-02)').
            Replace('{HyperVDetailVM}', $VM).Replace('{HyperVDetailMetric}', $Metric).
            Replace('{HyperVDetailDisk}', $diskValues)
        if ($Source) {
            $query = $query.Replace('Perf', $Source)
        } else {
            $query = $query.Replace('datetime(2026-01-01)', "ago($($Days)d)").Replace('datetime(2026-01-02)', 'now()')
        }
        $response = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
            -Headers @{ Authorization = "Bearer $AccessToken" } -ContentType 'application/json' `
            -Body (@{ query = $query } | ConvertTo-Json -Depth 10)
        if ($response.error) { throw 'VM detail query returned a partial error.' }
        $table = $response.tables[0]
        foreach ($row in $table.rows) {
            $record = [ordered]@{}
            for ($index = 0; $index -lt $table.columns.Count; $index++) {
                $record[$table.columns[$index].name] = $row[$index]
            }
            [pscustomobject]$record
        }
    }

    function Encode-DetailValue([string]$Value) {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    }

    $mapTemplate = ($items | Where-Object name -EQ 'hyperv-node-capacity-params').content.parameters[0].query
    $mapQuery = $mapTemplate.Replace('{ResourceGroupFilter}', '').Replace('{ClusterTagName}', '').Replace('{ClusterTagValue}', '') -replace '\r?\n', ' '
    $mapResponse = az graph query --subscription $SubscriptionId --subscriptions $SubscriptionId `
        --graph-query $mapQuery --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'VM detail machine metadata query failed.' }
    $metadata = ($mapResponse -join [Environment]::NewLine | ConvertFrom-Json).data[0].value
    $choices = @(Invoke-DetailQuery -Query $vmPicker -Metadata $metadata)
    if ($choices.Count -eq 0) { throw 'VM detail live picker returned no observations.' }
    [pscustomobject]@{ Query = 'hyperv-detail-vm-picker-live'; Rows = $choices.Count; Result = 'Passed' }
    $selectedVM = [string]$choices[0].value
    $disks = @(Invoke-DetailQuery -Query $diskPicker -Metadata $metadata -VM $selectedVM)
    [pscustomobject]@{ Query = 'hyperv-detail-disk-picker-live'; Rows = $disks.Count; Result = 'Passed' }
    $disk = if ($disks.Count) { [string]$disks[0].value } else { '' }
    foreach ($metric in @('cpu', 'memory', 'disk-throughput', 'disk-iops', 'disk-latency', 'network')) {
        $rows = @(Invoke-DetailQuery -Query $template -Metadata $metadata -VM $selectedVM -Metric $metric -Disk $disk)
        [pscustomobject]@{ Query = "hyperv-detail-$metric-live"; Rows = $rows.Count; Result = 'Passed' }
    }

    $metadata = '[{"hostId":"host-a","machine":"machine-a","cluster":"instance-a"},{"hostId":"host-b","machine":"machine-b","cluster":"instance-b"}]'
    $selectedVM = Encode-DetailValue '["host-a","vm"]'
    $selectedDisk = Encode-DetailValue 'disk-one.vhdx'
    $samples = [Collections.Generic.List[object]]::new()
    function Add-DetailSample([string]$HostId, [string]$ObjectName, [string]$CounterName, [string]$InstanceName, [double]$Value, [string]$Time = '2026-01-01T00:01:00Z') {
        $samples.Add(@{ HostId=$HostId; ObjectName=$ObjectName; CounterName=$CounterName; InstanceName=$InstanceName; CounterValue=$Value; TimeGenerated=$Time })
    }
    Add-DetailSample 'host-a' 'Hyper-V Hypervisor Virtual Processor' '% Guest Run Time' 'vm:Hv VP 0' 20
    Add-DetailSample 'host-a' 'Hyper-V Hypervisor Virtual Processor' '% Guest Run Time' 'vm:Hv VP 1' 40
    Add-DetailSample 'host-a' 'Hyper-V Hypervisor Virtual Processor' '% Guest Run Time' 'vm_other:Hv VP 0' 100
    Add-DetailSample 'host-b' 'Hyper-V Hypervisor Virtual Processor' '% Guest Run Time' 'vm:Hv VP 0' 90
    Add-DetailSample 'host-a' 'Hyper-V Dynamic Memory VM' 'Current Pressure' 'vm' 125
    foreach ($counter in @('Read Bytes/sec', 'Write Bytes/sec', 'Read Operations/Sec', 'Write Operations/Sec', 'Latency')) {
        $value = switch ($counter) { 'Read Bytes/sec' { 1048576 }; 'Write Bytes/sec' { 2097152 }; 'Read Operations/Sec' { 10 }; 'Write Operations/Sec' { 20 }; 'Latency' { 4 } }
        Add-DetailSample 'host-a' 'Hyper-V Virtual Storage Device' $counter 'disk-one.vhdx' $value
        Add-DetailSample 'host-a' 'Hyper-V Virtual Storage Device' $counter 'disk-two.vhdx' ($value*10)
        Add-DetailSample 'host-b' 'Hyper-V Virtual Storage Device' $counter 'disk-one.vhdx' ($value*20)
    }
    foreach ($counter in @('Bytes/sec', 'Bytes Sent/sec', 'Bytes Received/sec')) {
        $value = if ($counter -eq 'Bytes/sec') { 3145728 } else { 1048576 }
        Add-DetailSample 'host-a' 'Hyper-V Virtual Network Adapter' $counter 'vm_nic-one' $value
        Add-DetailSample 'host-a' 'Hyper-V Virtual Network Adapter' $counter 'vm_other_nic' 9999999
    }
    function Get-DetailSource([object[]]$Samples) {
        $json = ConvertTo-Json -InputObject @($Samples) -Depth 10 -Compress
        "(print row=dynamic($json) | mv-expand row | project TimeGenerated=todatetime(row.TimeGenerated), _ResourceId=tostring(row.HostId), ObjectName=tostring(row.ObjectName), CounterName=tostring(row.CounterName), InstanceName=tostring(row.InstanceName), CounterValue=todouble(row.CounterValue))"
    }
    $source = Get-DetailSource $samples.ToArray()
    $expected = @{ cpu=30; memory=125; 'disk-throughput'=3; 'disk-iops'=30; 'disk-latency'=4; network=3 }
    foreach ($metric in $expected.Keys) {
        $rows = @(Invoke-DetailQuery -Query $template -Metadata $metadata -VM $selectedVM -Metric $metric -Disk $selectedDisk -Source $source)
        if (@($rows | Where-Object { $null -eq $_.Value }).Count -eq 0) { throw "VM detail $metric did not preserve missing buckets." }
        $rows = @($rows | Where-Object { $null -ne $_.Value })
        if ($rows.Count -ne 1 -or [math]::Abs($rows[0].Value-$expected[$metric]) -gt 0.00001) { throw "VM detail $metric isolation/units fixture failed." }
        [pscustomobject]@{ Query = "hyperv-detail-$metric-fixture"; Rows = $rows.Count; Result = 'Passed' }
    }
    foreach ($case in @('zero', 'duplicates', 'partial', 'invalid', 'other-host', 'blank-vm', 'blank-disk', 'time-average')) {
        $caseSamples = @($samples.ToArray())
        $vm = $selectedVM
        $disk = $selectedDisk
        $expectedValue = 30
        $expectedRows = 1
        switch ($case) {
            'zero' { $caseSamples = @($caseSamples | ForEach-Object { $copy=$_.Clone(); $copy.CounterValue=0; $copy }); $expectedValue=0 }
            'duplicates' { $caseSamples = @($caseSamples) + @($caseSamples) }
            'partial' { $caseSamples = @($caseSamples | Where-Object CounterName -NE 'Write Operations/Sec'); $expectedRows=0 }
            'invalid' { $caseSamples = @($caseSamples | ForEach-Object { $copy=$_.Clone(); if ($copy.CounterName -eq 'Write Operations/Sec') {$copy.CounterValue=-1}; $copy }); $expectedRows=0 }
            'other-host' { $vm=Encode-DetailValue '["host-c","vm"]'; $expectedRows=0 }
            'blank-vm' { $vm=''; $expectedRows=0 }
            'blank-disk' { $disk=''; $expectedRows=0 }
            'time-average' {
                $caseSamples = @($caseSamples) + @($caseSamples | ForEach-Object { $copy=$_.Clone(); $copy.TimeGenerated='2026-01-01T00:02:00Z'; $copy.CounterValue=[double]$copy.CounterValue*3; $copy })
                $expectedValue=60
            }
        }
        $rows = @(Invoke-DetailQuery -Query $template -Metadata $metadata -VM $vm -Metric 'disk-iops' -Disk $disk -Source (Get-DetailSource $caseSamples))
        $rows = @($rows | Where-Object { $null -ne $_.Value })
        if ($rows.Count -ne $expectedRows -or ($expectedRows -gt 0 -and [math]::Abs($rows[0].Value-$expectedValue) -gt 0.00001)) { throw "VM detail $case fixture failed." }
        [pscustomobject]@{ Query = "hyperv-detail-$case-fixture"; Rows = $rows.Count; Result = 'Passed' }
    }
    $choices = @(Invoke-DetailQuery -Query $vmPicker -Metadata $metadata -Source $source)
    if ($choices.Count -ne 3 -or @($choices | Where-Object value -EQ $selectedVM).Count -ne 1) { throw 'VM detail picker merged same-name machines.' }
    [pscustomobject]@{ Query = 'hyperv-detail-picker-identity-fixture'; Rows = $choices.Count; Result = 'Passed' }
    $disks = @(Invoke-DetailQuery -Query $diskPicker -Metadata $metadata -VM $selectedVM -Source $source)
    if ($disks.Count -ne 2) { throw 'VM detail disk picker did not retain separate disks.' }
    [pscustomobject]@{ Query = 'hyperv-detail-disk-picker-fixture'; Rows = $disks.Count; Result = 'Passed' }
    foreach ($duration in @(1, 3, 7, 14, 30)) {
        $end = ([datetime]'2026-01-01').AddDays($duration).ToString('yyyy-MM-dd')
        $rangeTemplate = $template.Replace('{HyperVDetailTimeRange:end}', "datetime($end)")
        $rows = @(Invoke-DetailQuery -Query $rangeTemplate -Metadata $metadata -VM $selectedVM -Metric 'cpu' -Source $source)
        $stepMinutes = if ($duration -eq 1) { 5 } elseif ($duration -le 7) { 30 } elseif ($duration -le 14) { 60 } else { 120 }
        if ($rows.Count -ne $duration*1440/$stepMinutes -or
            @($rows | Where-Object { $null -ne $_.Value }).Count -ne 1) { throw "VM detail $duration-day resolution fixture failed." }
        [pscustomobject]@{ Query = "hyperv-detail-$duration-day-resolution-fixture"; Rows = $rows.Count; Result = 'Passed' }
    }
    foreach ($case in @('network-pair', 'network-partial', 'latency-pair', 'latency-partial')) {
        $caseSamples = @($samples.ToArray())
        $expectedValue = 2
        $expectedRows = 1
        $metric = 'network'
        if ($case -like 'network-*') {
            $caseSamples = @($caseSamples | Where-Object CounterName -NE 'Bytes/sec')
            if ($case -eq 'network-partial') {
                $caseSamples = @($caseSamples | Where-Object CounterName -NE 'Bytes Received/sec')
                $expectedRows = 0
            }
        } else {
            $metric = 'disk-latency'
            $expectedValue = 4
            $caseSamples = @($caseSamples | Where-Object CounterName -NE 'Latency')
            $caseSamples += @{ HostId='host-a'; ObjectName='Hyper-V Virtual Storage Device'; CounterName='Read Latency'; InstanceName='disk-one.vhdx'; CounterValue=2; TimeGenerated='2026-01-01T00:01:00Z' }
            if ($case -eq 'latency-pair') {
                $caseSamples += @{ HostId='host-a'; ObjectName='Hyper-V Virtual Storage Device'; CounterName='Write Latency'; InstanceName='disk-one.vhdx'; CounterValue=6; TimeGenerated='2026-01-01T00:01:00Z' }
            } else { $expectedRows=0 }
        }
        $rows = @(Invoke-DetailQuery -Query $template -Metadata $metadata -VM $selectedVM -Metric $metric -Disk $selectedDisk -Source (Get-DetailSource $caseSamples))
        $rows = @($rows | Where-Object { $null -ne $_.Value })
        if ($rows.Count -ne $expectedRows -or ($expectedRows -gt 0 -and [math]::Abs($rows[0].Value-$expectedValue) -gt 0.00001)) { throw "VM detail $case fallback fixture failed." }
        [pscustomobject]@{ Query = "hyperv-detail-$case-fixture"; Rows = $rows.Count; Result = 'Passed' }
    }
}

function Test-NodeCapacity {
    param([string]$TenantId, [string]$WorkspaceId)

    $book = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-HyperV/Capacity-HyperV.workbook') | ConvertFrom-Json
    $items = @(Get-WorkbookItems -Items $book.items)
    $mapTemplate = ($items | Where-Object name -EQ 'hyperv-node-capacity-params').content.parameters[0].query
    $mapQuery = $mapTemplate.Replace('{ResourceGroupFilter}', '').Replace('{ClusterTagName}', '').Replace('{ClusterTagValue}', '')
    $mapQuery = $mapQuery -replace '\r?\n', ' '
    $mappingResponse = az graph query --subscription $SubscriptionId --subscriptions $SubscriptionId `
        --graph-query $mapQuery --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Node capacity metadata query failed.' }
    $metadata = (($mappingResponse -join [Environment]::NewLine | ConvertFrom-Json).data[0].value | ConvertFrom-Json)
    if (@($metadata).Count -eq 0) { throw 'No Arc node hardware metadata returned.' }
    $template = ($items | Where-Object name -EQ 'hyperv-node-capacity').content.query
    $hostIdentityTemplate = ($items | Where-Object name -EQ 'hyperv-node-ratio-params').content.parameters |
        Where-Object name -EQ 'HyperVNodeSelectedHostIds' | Select-Object -ExpandProperty query
    $discoveryAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'example-dcr-template/deploy-lens-capacity-dcr.ps1'), [ref]$null, [ref]$null)
    $discoveryAssignment = $discoveryAst.Find({ param($entry)
        $entry -is [System.Management.Automation.Language.AssignmentStatementAst] -and $entry.Left.VariablePath.UserPath -eq 'hostQuery'
    }, $true)
    $discoveryTemplate = $discoveryAssignment.Right.Find({ param($entry)
        $entry -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true).Value
    $discoveryQuery = $discoveryTemplate.Replace('$SubId', $SubscriptionId) -replace '\r?\n', ' '
    $null = az graph query --subscription $SubscriptionId --subscriptions $SubscriptionId `
        --graph-query $discoveryQuery --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'DCR discovery query failed.' }
    $snapshotEnd = [DateTime]::UtcNow.AddMinutes(-2)
    $template = $template.Replace('now() - 2m', "datetime($($snapshotEnd.ToString('o')))")
    $accessToken = az account get-access-token --tenant $TenantId --resource 'https://api.loganalytics.io' `
        --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not authenticate to the confirmed tenant.' }

    function Invoke-CapacityQuery {
        param([object[]]$NodeMetadata, [string]$MinimumRatio = '0', [string]$HostFilter = "'*'", [object[]]$Samples, [string]$TargetRatio = '4', [string]$ClusterFilter = "'*'", [object[]]$ResourceSamples, [object[]]$HistoricalSamples, [switch]$Discovery, [string]$TagName = '', [string]$TagValue = '')

        $query = $template.Replace('{HyperVNodeCapacityMap}', (ConvertTo-Json -InputObject $NodeMetadata -Depth 10 -Compress))
        $query = $query.Replace('{HyperVInvHostFilter}', $HostFilter).Replace('{HyperVNodeRatioFilter}', $MinimumRatio)
        $query = $query.Replace('{HyperVNodeTargetRatio}', $TargetRatio)
        $query = $query.Replace('{HyperVNodeClusterFilter}', $ClusterFilter)
        if ($PSBoundParameters.ContainsKey('Samples')) {
            $samplesJson = ConvertTo-Json -InputObject $Samples -Depth 10 -Compress
            $source = "(print fixtureRow = dynamic($samplesJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), Computer=tostring(fixtureRow.Computer), _ResourceId=tostring(fixtureRow.HostId), ObjectName=tostring(fixtureRow.ObjectName), CounterName=tostring(fixtureRow.CounterName), InstanceName=tostring(fixtureRow.InstanceName), CounterValue=todouble(fixtureRow.CounterValue))"
            $query = $query.Replace('let raw = materialize(Perf', "let raw = materialize($source")
        }
        $selectedHostIds = '[]'
        if ($HostFilter -ne "'*'" -and -not $PSBoundParameters.ContainsKey('ResourceSamples')) {
            $identityQuery = $hostIdentityTemplate.Replace('{HyperVInvHostFilter}', $HostFilter)
            if ($PSBoundParameters.ContainsKey('Samples') -or $PSBoundParameters.ContainsKey('HistoricalSamples')) {
                $history = if ($PSBoundParameters.ContainsKey('HistoricalSamples')) { $HistoricalSamples } else { $Samples }
                $historyJson = ConvertTo-Json -InputObject @($history) -Depth 10 -Compress
                $historySource = "(print fixtureRow = dynamic($historyJson) | mv-expand fixtureRow | project TimeGenerated=todatetime(fixtureRow.TimeGenerated), Computer=tostring(fixtureRow.Computer), _ResourceId=tostring(fixtureRow.HostId), ObjectName=tostring(fixtureRow.ObjectName), CounterName=tostring(fixtureRow.CounterName))"
                $identityQuery = $identityQuery.Replace('Perf', $historySource)
            }
            $identityResponse = Invoke-RestMethod -Method Post `
                -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
                -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json' `
                -Body (@{ query = $identityQuery; timespan = 'P1D' } | ConvertTo-Json -Depth 10)
            if ($identityResponse.error) { throw 'Historical host identity returned a partial query error.' }
            $selectedHostIds = [string]$identityResponse.tables[0].rows[0][0]
        }
        $query = $query.Replace('{HyperVNodeSelectedHostIds}', $selectedHostIds)
        if ($PSBoundParameters.ContainsKey('ResourceSamples')) {
            $resourceJson = ConvertTo-Json -InputObject $ResourceSamples -Depth 10 -Compress
            $source = "(print fixtureRow = dynamic($resourceJson) | mv-expand fixtureRow | project id=tostring(fixtureRow.id), name=tostring(fixtureRow.name), type=tostring(fixtureRow.type), subscriptionId=tostring(fixtureRow.subscriptionId), resourceGroup=tostring(fixtureRow.resourceGroup), location=tostring(fixtureRow.location), properties=fixtureRow.properties, tags=fixtureRow.tags)"
            $resourceTemplate = if ($Discovery) { $discoveryTemplate.Replace('$SubId', 'example') } else { $mapTemplate.Replace('{ResourceGroupFilter}', '').Replace('{ClusterTagName}', $TagName).Replace('{ClusterTagValue}', $TagValue) }
            $query = $resourceTemplate.Replace('resources', $source)
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
        Assert-Capacity $true 'dcr-discovery-live-arg-query'
        $liveRows = @(Invoke-CapacityQuery -NodeMetadata @($metadata))
        $portalAllRows = @(Invoke-CapacityQuery -NodeMetadata @($metadata) -HostFilter "'value::all'" -ClusterFilter "'value::all'")
        Assert-Capacity ($portalAllRows.Count -eq $liveRows.Count -and $portalAllRows.Count -gt 0) 'node-capacity-live-portal-all-selectors'
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
        foreach ($selection in @('host', 'instance', 'both')) {
            $hostSelection = if ($selection -in @('host', 'both')) { "'value::all'" } else { "'*'" }
            $instanceSelection = if ($selection -in @('instance', 'both')) { "'value::all'" } else { "'*'" }
            $allRows = @(Invoke-CapacityQuery -NodeMetadata $fixtureNodes.ToArray() -Samples $fixtureSamples.ToArray() -HostFilter $hostSelection -ClusterFilter $instanceSelection)
            Assert-Capacity ($allRows.Count -eq $fixtureRows.Count -and @($allRows | Where-Object Machine -EQ 'missing').Count -eq 1) "node-capacity-portal-all-$selection-retains-inventory"
        }
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
        $historicalSamples = foreach ($sample in $identitySamples) {
            $historical = $sample.PSObject.Copy()
            $historical.TimeGenerated = $snapshotEnd.AddHours(-4).ToString('o')
            $historical
        }
        $identityRows = @(Invoke-CapacityQuery -NodeMetadata @($identityNodes[0]) -Samples @() -HistoricalSamples $historicalSamples -HostFilter "'node01.domain-a.example'")
        Assert-Capacity ($identityRows.Count -eq 1) 'node-capacity-unique-historical-fqdn-retained'
        Assert-Capacity ($null -eq $identityRows[0].'V:P CPU Ratio' -and $null -eq $identityRows[0].'Avg CPU % (15 min)') 'node-capacity-history-does-not-widen-metric-window'
        $identityRows = @(Invoke-CapacityQuery -NodeMetadata @($identityNodes[0]) -Samples @() -HistoricalSamples $historicalSamples -HostFilter "'node01.domain-b.example'")
        Assert-Capacity ($identityRows.Count -eq 0) 'node-capacity-historical-selection-outside-inventory-excluded'
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

        function Test-HardwareMapping {
            param([string[]]$ArcNames, [string[]]$ReportedNames, [string[]]$ExpectedNames, [string]$Name, [switch]$TagFiltered, [switch]$SeparateClusters)

            $resources = @($ArcNames | ForEach-Object {
                @{ id = "host-$_"; name = $_; type = 'microsoft.hybridcompute/machines'; subscriptionId = 'example'; resourceGroup = 'group-a'; properties = @{ cloudMetadata = @{ provider = 'AzSHCI' }; detectedProperties = @{ model = 'Example Server'; totalPhysicalMemoryInGigabytes = 8 } } }
            })
            if ($SeparateClusters) {
                $resources += @($ReportedNames | ForEach-Object {
                    @{ id = "cluster-$_"; name = "cluster-$_"; type = 'microsoft.azurestackhci/clusters'; subscriptionId = 'example'; resourceGroup = 'group-a'; tags = @{ purpose = $(if ($_ -eq $ReportedNames[0]) { 'selected' } else { 'other' }) }; properties = @{ reportedProperties = @{ nodes = @(@{ name = $_; coreCount = 8; memoryInGiB = 64 }) } } }
                })
            } else {
                $resources += @{ id = 'cluster-a'; name = 'cluster-a'; type = 'microsoft.azurestackhci/clusters'; subscriptionId = 'example'; resourceGroup = 'group-a'; tags = @{ purpose = 'selected' }; properties = @{ reportedProperties = @{ nodes = @($ReportedNames | ForEach-Object { @{ name = $_; coreCount = 8; memoryInGiB = 64 } }) } } }
            }
            $tag = if ($TagFiltered) { @{ TagName = 'purpose'; TagValue = 'selected' } } else { @{} }
            $rows = @(Invoke-CapacityQuery -NodeMetadata @() -ResourceSamples $resources @tag)
            $mappings = @($rows[0].value | ConvertFrom-Json)
            $matched = @($mappings | Where-Object { $_.clusterId })
            $unmatched = @($mappings | Where-Object { -not $_.clusterId })
            $expectedRows = if ($TagFiltered) { $ExpectedNames.Count } else { $ArcNames.Count }
            $valid = $mappings.Count -eq $expectedRows -and $matched.Count -eq $ExpectedNames.Count
            foreach ($expected in $ExpectedNames) {
                $valid = $valid -and @($matched | Where-Object { $_.machine -eq $expected -and $_.physicalCores -eq 8 -and $_.memoryGiB -eq 64 }).Count -eq 1
            }
            $valid = $valid -and @($unmatched | Where-Object { $null -ne $_.physicalCores -or $_.memoryGiB -ne 8 }).Count -eq 0
            Assert-Capacity $valid $Name
        }

        Test-HardwareMapping -ArcNames @('same.a.example', 'same.b.example') -ReportedNames @('same.a.example') -ExpectedNames @('same.a.example') -Name 'node-capacity-metadata-qualified-collision-isolated'
        Test-HardwareMapping -ArcNames @('same.a.example', 'same.b.example') -ReportedNames @('same') -ExpectedNames @() -Name 'node-capacity-metadata-ambiguous-arc-matches-unavailable'
        Test-HardwareMapping -ArcNames @('same') -ReportedNames @('same.a.example', 'same.b.example') -ExpectedNames @() -Name 'node-capacity-metadata-ambiguous-reported-matches-unavailable'
        Test-HardwareMapping -ArcNames @('same.b.example') -ReportedNames @('same.a.example') -ExpectedNames @() -Name 'node-capacity-metadata-incompatible-qualified-names-unavailable'
        Test-HardwareMapping -ArcNames @('same.a.example', 'same.b.example') -ReportedNames @('same.a.example', 'same.b.example') -ExpectedNames @('same.a.example', 'same.b.example') -Name 'node-capacity-metadata-distinct-qualified-machines-retained'
        Test-HardwareMapping -ArcNames @('same') -ReportedNames @('same.a.example', 'same.b.example') -ExpectedNames @() -SeparateClusters -TagFiltered -Name 'node-capacity-metadata-tag-filter-does-not-hide-ambiguity'
        Test-HardwareMapping -ArcNames @('same.a.example') -ReportedNames @('same.a.example') -ExpectedNames @('same.a.example') -TagFiltered -Name 'node-capacity-metadata-unambiguous-tagged-match-retained'
        Test-HardwareMapping -ArcNames @('same') -ReportedNames @('same', 'same') -ExpectedNames @() -Name 'node-capacity-metadata-duplicate-reported-rows-unavailable'

        $discoveryResources = @(
            @{ id = 'qualified-host'; name = 'node01.host.example' },
            @{ id = 'qualified-guest'; name = 'node01.guest.example' },
            @{ id = 'nested-host'; name = 'nested.example' },
            @{ id = 'short-collision-a'; name = 'collision.a.example' },
            @{ id = 'short-collision-b'; name = 'collision.b.example' },
            @{ id = 'reported-collision'; name = 'repeated' },
            @{ id = 'mixed-a'; name = 'mixed.a.example' },
            @{ id = 'mixed-b'; name = 'mixed.b.example' },
            @{ id = 'duplicate-report'; name = 'duplicate.example' }
        ) | ForEach-Object {
            $_.type = 'microsoft.hybridcompute/machines'; $_.subscriptionId = 'example'; $_.resourceGroup = 'group-a'
            $_.properties = @{ cloudMetadata = @{ provider = 'AzSHCI' }; detectedProperties = @{ model = 'Virtual Machine' } }
            $_
        }
        $discoveryResources += @{ id = 'cluster-a'; name = 'cluster-a'; type = 'microsoft.azurestackhci/clusters'; subscriptionId = 'example'; resourceGroup = 'group-a'; properties = @{ reportedProperties = @{ nodes = @(@{ name = 'node01.host.example' }, @{ name = 'nested' }, @{ name = 'collision' }, @{ name = 'repeated.a.example' }, @{ name = 'repeated.b.example' }, @{ name = 'mixed.a.example' }, @{ name = 'duplicate.example' }, @{ name = 'duplicate.example' }) } } }
        $discoveryResources += @{ id = 'cluster-b'; name = 'cluster-b'; type = 'microsoft.azurestackhci/clusters'; subscriptionId = 'example'; resourceGroup = 'group-a'; properties = @{ reportedProperties = @{ nodes = @(@{ name = 'mixed' }) } } }
        $discoveryRows = @(Invoke-CapacityQuery -NodeMetadata @() -ResourceSamples $discoveryResources -Discovery)
        $eligible = @($discoveryRows | Where-Object membershipCount -EQ 1)
        Assert-Capacity ($discoveryRows.Count -eq 9 -and $eligible.Count -eq 2 -and @($eligible | Where-Object id -EQ 'qualified-host').Count -eq 1 -and @($eligible | Where-Object id -EQ 'nested-host').Count -eq 1) 'dcr-discovery-qualified-collision-and-nested-hosts'
        Assert-Capacity (@($discoveryRows | Where-Object { $_.id -in @('short-collision-a', 'short-collision-b', 'reported-collision', 'qualified-guest') -and $_.membershipCount -eq 0 }).Count -eq 4) 'dcr-discovery-ambiguous-matches-excluded'
        Assert-Capacity (@($discoveryRows | Where-Object { $_.id -in @('mixed-a', 'mixed-b') -and $_.membershipCount -eq 0 }).Count -eq 2) 'dcr-discovery-mixed-name-ambiguity-preserved'
        Assert-Capacity (@($discoveryRows | Where-Object { $_.id -eq 'duplicate-report' -and $_.membershipCount -eq 0 }).Count -eq 1) 'dcr-discovery-duplicate-reported-rows-excluded'
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

    $detailBook = Get-Content -Raw (Join-Path $repoRoot 'workbooks/Capacity-SingleCluster/Capacity-SingleCluster.workbook') | ConvertFrom-Json
    $picker = (@(Get-WorkbookItems -Items $detailBook.items) | Where-Object name -EQ 'sc-storage-detail-filters').content.parameters | Where-Object name -EQ 'SCStorageDetailMachine'
    $pickerQuery = $picker.query.Replace('{NodeTrendsTimeRange:start}', "ago($($Days)d)").Replace('{NodeTrendsTimeRange:end}', 'now()')
    $pickerQuery = $pickerQuery.Replace('{SingleCluster}', [string]$selectedCluster.armId).Replace('{ClusterRGMap}', $clusterRGJson).Replace('{ClusterNodeMap}', $clusterNodeJson)
    $pickerResponse = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.io/v1/workspaces/$($workspace.customerId)/query" `
        -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json' -Body (@{ query = $pickerQuery; timespan = "P$($Days)D" } | ConvertTo-Json)
    if ($pickerResponse.error -or @($pickerResponse.tables[0].rows).Count -eq 0) { throw 'Storage detail machine picker returned no eligible machines.' }
    $detailMachine = [string]$pickerResponse.tables[0].rows[0][0]

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
        foreach ($timeParameter in @('McForecastTimeRange', 'McPerformanceTimeRange')) {
            $query = $query.Replace("{$($timeParameter):start}", "ago($($Days)d)")
            $query = $query.Replace("{$($timeParameter):end}", 'now()')
        }
        $query = $query.Replace('{ClusterRGMap}', $clusterRGJson)
        $query = $query.Replace('{ClusterNodeMap}', $clusterNodeJson)
        # Guest resource links are outside this suite's inventory/metric coverage.
        $query = $query.Replace('{ArcMachineMap}', '[]')
        $query = $query.Replace('{ChartClusterFilter}', "'value::all'")
        $query = $query.Replace('{SingleCluster}', [string]$selectedCluster.armId)
        $query = $query.Replace('{SCStorageDetailMachine}', $detailMachine)
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
        if ($item.content.query -match '\{Cluster(?:RG|Node)Map\}') {
            foreach ($mapValue in @('', '[]')) {
                $emptyQuery = $query.Replace("parse_json('$clusterRGJson')", "parse_json('$mapValue')").Replace("parse_json('$clusterNodeJson')", "parse_json('$mapValue')")
                if ($emptyQuery -eq $query) { throw "Empty-map fixture did not replace a mapping: $($spec.name)" }
                $emptyResponse = Invoke-RestMethod -Method Post `
                    -Uri "https://api.loganalytics.io/v1/workspaces/$($workspace.customerId)/query" `
                    -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json' `
                    -Body (@{ query = $emptyQuery; timespan = "P$($Days)D" } | ConvertTo-Json -Depth 10)
                if ($emptyResponse.error) { throw "Empty-map query returned a partial error: $($spec.name)" }
                $suffix = if ($mapValue -eq '') { 'unset-maps' } else { 'empty-array-maps' }
                [pscustomobject]@{ Query = "$($spec.name)-$suffix"; Rows = @($emptyResponse.tables[0].rows).Count; Result = 'Passed' }
            }
        }
    }
    $results = @($results) + @([pscustomobject]@{ Query = 'sc-storage-detail-machine-picker-live'; Rows = @($pickerResponse.tables[0].rows).Count; Result = 'Passed' }) + @(Test-StorageSources -WorkspaceId $workspace.customerId -AccessToken $accessToken) + @(Test-HyperVDetail -WorkspaceId $workspace.customerId -AccessToken $accessToken)
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