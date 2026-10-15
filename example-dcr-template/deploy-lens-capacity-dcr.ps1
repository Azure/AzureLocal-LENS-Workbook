<#
.SYNOPSIS
Deploys the LENS Capacity DCR and associates reported Azure Local nodes.
.DESCRIPTION
Replace the placeholders or supply parameters. Requires Azure CLI, resource-graph
and monitor-control-service extensions, an existing workspace, and AMA on hosts.
Use -WhatIf for read-only discovery. -Rollback removes only matching associations;
it deliberately leaves the DCR and collected logs intact.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SubId = '<subscription-id>',
    [string]$DcrRG = '<dcr-resource-group>',
    [string]$DcrName = 'dcr-azurelocal-lens-capacity-perf',
    [string]$DcraName = 'azlocal-lens-capacity-dcra',
    [string]$LawResourceId = '/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>',
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'dcr-azurelocal-capacity-perf.json'),
    [string]$DeploymentName = 'dcr-azurelocal-capacity-perf',
    [switch]$UpdateExistingDcr,
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments --subscription $SubId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI failed; review the preceding error. Earlier changes may remain.' }
    $output
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in with az login first.' }
if ($SubId -match '[<>]' -or $DcrRG -match '[<>]' -or (-not $Rollback -and $LawResourceId -match '[<>]')) {
    throw 'Replace the subscription, DCR resource group, and workspace placeholders before running.'
}
$null = [guid]::Parse($SubId)
if (-not $Rollback -and -not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
    throw 'Download the ARM template beside this script or supply -TemplateFile.'
}
$account = Invoke-AzCli -Arguments @('account', 'show', '-o', 'json') | ConvertFrom-Json
if ($account.id -ine $SubId) { throw 'Azure CLI resolved a different subscription.' }
$DcrId = "/subscriptions/$SubId/resourceGroups/$DcrRG/providers/Microsoft.Insights/dataCollectionRules/$DcrName"

$hostQuery = @"
resources
| where type =~ 'microsoft.hybridcompute/machines'
| where subscriptionId =~ '$SubId'
| where properties.cloudMetadata.provider =~ 'AzSHCI'
| project id = tolower(id), name, resourceGroup, location, model = tostring(properties.detectedProperties.model)
| join kind=leftouter (
    resources
    | where type =~ 'microsoft.azurestackhci/clusters'
    | where subscriptionId =~ '$SubId'
    | mv-expand node = properties.reportedProperties.nodes limit 2000
    | extend reportedName = tolower(tostring(node.name))
    | extend nodeKey = tolower(strcat(subscriptionId, '/', resourceGroup, '/', tostring(split(tostring(node.name), '.')[0])))
    | project clusterId = tolower(id), clusterName = name, reportedName, nodeKey
    | join kind=inner (
        resources
        | where type =~ 'microsoft.hybridcompute/machines'
        | where subscriptionId =~ '$SubId'
        | where properties.cloudMetadata.provider =~ 'AzSHCI'
        | extend arcName = tolower(name)
        | extend nodeKey = tolower(strcat(subscriptionId, '/', resourceGroup, '/', tostring(split(name, '.')[0])))
        | project arcId = tolower(id), arcName, nodeKey
    ) on nodeKey
    | where arcName == reportedName or indexof(arcName, '.') < 0 or indexof(reportedName, '.') < 0
    | summarize matchingHostIds = make_set(arcId), clusterIds = make_set(clusterId), clusters = make_set(clusterName) by nodeKey, reportedName
    | where array_length(matchingHostIds) == 1
    | mv-expand id = matchingHostIds to typeof(string)
    | extend clusterCount = array_length(clusterIds)
    | summarize reportedNodeCount = count(), membershipCount = max(clusterCount), clusters = make_set(clusters) by id
    | where reportedNodeCount == 1
) on id
| project id, name, resourceGroup, location, model, clusters, membershipCount = coalesce(membershipCount, 0)
| order by id asc
"@ -replace '\r?\n', ' '
$machineList = [System.Collections.Generic.List[object]]::new()
$skipToken = $null
do {
    $graphArguments = @('graph', 'query', '--subscriptions', $SubId, '-q', $hostQuery, '--first', '1000', '-o', 'json')
    if ($skipToken) { $graphArguments += @('--skip-token', $skipToken) }
    $page = Invoke-AzCli -Arguments $graphArguments | ConvertFrom-Json
    foreach ($machine in @($page.data)) { $machineList.Add($machine) }
    $skipToken = $page.skip_token
} while ($skipToken)
$candidates = @($machineList.ToArray() | Sort-Object id -Unique)
if ($candidates.Count -lt $page.total_records) { throw 'Host discovery was truncated; no resources changed.' }
$review = @($candidates | Where-Object membershipCount -NE 1)
if ($review.Count -gt 0) {
    Write-Warning "$($review.Count) machines have missing or ambiguous reported membership and will not be changed. Review their registration and cluster node metadata."
    $review | Select-Object name, resourceGroup, model, membershipCount | Format-Table -AutoSize | Out-Host
}
$Machines = @($candidates | Where-Object membershipCount -EQ 1)
if ($Machines.Count -eq 0) { throw 'No unambiguous reported Azure Local nodes found; no resources changed.' }
Write-Host "Subscription: $($account.name) ($SubId)"
Write-Host "DCR: $DcrId"
$Machines | Select-Object name, resourceGroup, location, model, clusters | Format-Table -AutoSize | Out-Host

$matchingAssociations = [System.Collections.Generic.List[object]]::new()
foreach ($machine in $Machines) {
    $associations = @(Invoke-AzCli -Arguments @(
        'monitor', 'data-collection', 'rule', 'association', 'list-by-resource',
        '--resource', $machine.id, '-o', 'json'
    ) | ConvertFrom-Json)
    $named = @($associations | Where-Object name -EQ $DcraName)
    if (@($named | Where-Object { $_.dataCollectionRuleId -ine $DcrId }).Count -gt 0) {
        throw "Association name conflict on $($machine.name); no resources changed."
    }
    if ($named.Count -gt 0) { $matchingAssociations.Add($machine) }
}

if ($Rollback) {
    if ($PSCmdlet.ShouldProcess("$($matchingAssociations.Count) reviewed hosts", "Remove associations to $DcrId")) {
        foreach ($machine in $matchingAssociations) {
            $association = Invoke-AzCli -Arguments @(
                'monitor', 'data-collection', 'rule', 'association', 'show',
                '--name', $DcraName, '--resource', $machine.id, '-o', 'json'
            ) | ConvertFrom-Json
            if ($association.dataCollectionRuleId -ine $DcrId) { throw 'Association now targets another DCR; stopping.' }
            Invoke-AzCli -Arguments @(
                'monitor', 'data-collection', 'rule', 'association', 'delete',
                '--name', $DcraName, '--resource', $machine.id, '--yes', '-o', 'none'
            )
            $remaining = @(Invoke-AzCli -Arguments @(
                'monitor', 'data-collection', 'rule', 'association', 'list-by-resource',
                '--resource', $machine.id, '-o', 'json'
            ) | ConvertFrom-Json)
            if (@($remaining | Where-Object name -EQ $DcraName).Count -gt 0) { throw 'Association removal verification failed.' }
        }
        Write-Host "Removed $($matchingAssociations.Count) associations. DCR and collected logs were retained."
    }
    return
}

$workspace = Invoke-AzCli -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'show', '--ids', $LawResourceId, '-o', 'json'
) | ConvertFrom-Json
if (-not $workspace.location) { throw 'Could not resolve workspace region.' }
$LawRegion = $workspace.location
$rules = @(Invoke-AzCli -Arguments @(
    'monitor', 'data-collection', 'rule', 'list', '--resource-group', $DcrRG, '-o', 'json'
) | ConvertFrom-Json)
if (@($rules | Where-Object id -EQ $DcrId).Count -gt 0 -and -not $UpdateExistingDcr) {
    throw 'DCR already exists. Review its definition and use -UpdateExistingDcr only for an intentional replacement.'
}
Write-Host "Workspace: $($workspace.name); region: $LawRegion; hosts: $($Machines.Count)"
Write-Warning 'Review overlapping DCRs: AMA does not deduplicate ingestion. This script does not install AMA.'
if (-not $PSCmdlet.ShouldProcess($DcrId, "Deploy template and associate $($Machines.Count) reviewed hosts")) { return }

Invoke-AzCli -Arguments @(
    'deployment', 'group', 'create', '--resource-group', $DcrRG,
    '--name', $DeploymentName, '--template-file', $TemplateFile,
    '--parameters', ('workspaceResourceId=' + $LawResourceId),
    ('dcrName=' + $DcrName), ('location=' + $LawRegion), '-o', 'none'
)
$deployedId = Invoke-AzCli -Arguments @(
    'deployment', 'group', 'show', '--resource-group', $DcrRG,
    '--name', $DeploymentName, '--query', 'properties.outputs.dcrResourceId.value', '-o', 'tsv'
)
if ($deployedId -ine $DcrId) { throw 'Deployment output did not match the expected DCR ID.' }
foreach ($machine in $Machines) {
    Invoke-AzCli -Arguments @(
        'monitor', 'data-collection', 'rule', 'association', 'create',
        '--name', $DcraName, '--resource', $machine.id, '--rule-id', $DcrId, '-o', 'none'
    )
    $association = Invoke-AzCli -Arguments @(
        'monitor', 'data-collection', 'rule', 'association', 'show',
        '--name', $DcraName, '--resource', $machine.id, '-o', 'json'
    ) | ConvertFrom-Json
    if ($association.dataCollectionRuleId -ine $DcrId) { throw 'Association verification failed.' }
}
Write-Host "Verified $($Machines.Count) host associations. Verify Perf and Event ingestion after AMA refreshes."