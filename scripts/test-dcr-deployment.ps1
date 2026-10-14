$ErrorActionPreference = 'Stop'
$deploymentScript = Join-Path $PSScriptRoot '../example-dcr-template/deploy-lens-capacity-dcr.ps1'
$settings = @{
    SubId = '00000000-0000-0000-0000-000000000001'
    DcrRG = 'example-monitoring'
    DcrName = 'example-lens'
    DcraName = 'example-association'
    LawResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-monitoring/providers/Microsoft.OperationalInsights/workspaces/example-workspace'
}
$ruleId = "/subscriptions/$($settings.SubId)/resourceGroups/$($settings.DcrRG)/providers/Microsoft.Insights/dataCollectionRules/$($settings.DcrName)"

function Reset-Scenario {
    $global:DcrTestState = @{
        Subscription = $settings.SubId
        RuleId = $ruleId
        AssociationName = $settings.DcraName
        Calls = [System.Collections.Generic.List[object]]::new()
        Associations = @{}
        Existing = $false
        Fail = ''
        WrongIdentity = $false
        Truncated = $false
        Nodes = @(
            @{ id = '/example/nodes/physical'; name = 'physical'; membershipCount = 1; model = 'Example Server' },
            @{ id = '/example/nodes/unmatched'; name = 'unmatched'; membershipCount = 0; model = 'Virtual Machine' },
            @{ id = '/example/nodes/nested'; name = 'nested'; membershipCount = 1; model = 'Virtual Machine' },
            @{ id = '/example/nodes/ambiguous'; name = 'ambiguous'; membershipCount = 2; model = 'Example Server' }
        )
    }
}

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Writes {
    @($global:DcrTestState.Calls | Where-Object { $_ -contains 'create' -or $_ -contains 'delete' })
}

function Invoke-Scenario {
    param([hashtable]$Options = @{}, [string]$ExpectedError = '')
    $caught = ''
    $output = ''
    try { $output = & $deploymentScript @settings @Options -Confirm:$false 6>&1 3>&1 | Out-String }
    catch { $caught = $_.Exception.Message }
    if ($ExpectedError) {
        Assert-Check ($caught -like "*$ExpectedError*") "Expected '$ExpectedError'; received '$caught'."
    } elseif ($caught) { throw $caught }
    $output
}

if (Test-Path Function:global:az) { throw 'An az function already exists; run this test in a fresh PowerShell process.' }
function global:az {
    $arguments = @($args)
    $state = $global:DcrTestState
    $state.Calls.Add($arguments)
    $global:LASTEXITCODE = 0
    $subscriptionIndex = [array]::IndexOf($arguments, '--subscription')
    if ($subscriptionIndex -lt 0 -or $arguments[$subscriptionIndex + 1] -ne $state.Subscription) {
        throw 'Missing explicit subscription.'
    }
    $prefix = ($arguments | Select-Object -First 2) -join ' '
    if ($prefix -eq $state.Fail) { $global:LASTEXITCODE = 1; return }
    if ($prefix -eq 'account show') { return (@{ id = $state.Subscription; name = 'Example' } | ConvertTo-Json) }
    if ($prefix -eq 'graph query') {
        $secondPage = $arguments -contains '--skip-token'
        $rows = if ($secondPage) { @($state.Nodes[2], $state.Nodes[3]) } else { @($state.Nodes[0], $state.Nodes[1]) }
        return (@{ data = $rows; total_records = 4; skip_token = $(if ($secondPage -or $state.Truncated) { $null } else { 'page-two' }) } | ConvertTo-Json -Depth 8)
    }
    if ($prefix -eq 'monitor log-analytics') { return '{"name":"example-workspace","location":"eastus"}' }
    if ($prefix -eq 'deployment group') {
        if ($arguments[2] -eq 'show') { return $state.RuleId }
        if ($arguments[2] -eq 'create') {
            Assert-Check ($arguments -contains 'location=eastus') 'Workspace region must be passed explicitly.'
            Assert-Check ($arguments -contains 'dcrName=example-lens') 'DCR name must be passed explicitly.'
            return
        }
    }
    if ($arguments[3] -eq 'list') {
        if ($state.Existing) { return (ConvertTo-Json -InputObject @(@{ id = $state.RuleId })) }
        return '[]'
    }
    if ($arguments[3] -eq 'association') {
        $operation = $arguments[4]
        $resource = $arguments[[array]::IndexOf($arguments, '--resource') + 1]
        switch ($operation) {
            'list-by-resource' { return (ConvertTo-Json -InputObject @($state.Associations[$resource] | Where-Object { $_ })) }
            'create' { $state.Associations[$resource] = @{ name = $state.AssociationName; dataCollectionRuleId = $state.RuleId }; return }
            'show' {
                if ($state.WrongIdentity) { return '{"dataCollectionRuleId":"/example/other-rule"}' }
                return ($state.Associations[$resource] | ConvertTo-Json)
            }
            'delete' { $state.Associations.Remove($resource); return }
        }
    }
    throw "Unexpected mocked CLI command: $prefix"
}

try {
    Reset-Scenario
    $null = Invoke-Scenario @{ WhatIf = $true }
    Assert-Check (@(Get-Writes).Count -eq 0) 'WhatIf must not write.'
    Assert-Check (@($global:DcrTestState.Calls | Where-Object { $_ -contains '--skip-token' }).Count -eq 1) 'Discovery must follow pagination.'

    Reset-Scenario
    $output = Invoke-Scenario
    Assert-Check ($output -match 'Verified 2 host associations') 'Success count must include the physical and nested nodes only.'
    Assert-Check (@(Get-Writes).Count -eq 3) 'Expected one deployment and two associations.'
    Assert-Check ($global:DcrTestState.Associations.ContainsKey('/example/nodes/nested')) 'Nested member must be included.'
    Assert-Check (-not $global:DcrTestState.Associations.ContainsKey('/example/nodes/unmatched')) 'Unmatched machine must be excluded.'
    Assert-Check (-not $global:DcrTestState.Associations.ContainsKey('/example/nodes/ambiguous')) 'Ambiguous machine must be excluded.'

    $global:DcrTestState.Calls.Clear()
    $null = Invoke-Scenario @{ Rollback = $true; WhatIf = $true }
    Assert-Check (@(Get-Writes).Count -eq 0) 'Rollback WhatIf must not write.'
    $global:DcrTestState.Calls.Clear()
    $global:DcrTestState.Associations['/example/nodes/nested'].name = 'unrelated-association'
    $output = Invoke-Scenario @{ Rollback = $true }
    Assert-Check ($output -match 'Removed 1 associations') 'Rollback must count only matching names.'
    Assert-Check (@(Get-Writes).Count -eq 1 -and $global:DcrTestState.Associations.Count -eq 1) 'Rollback must leave unrelated associations and the DCR intact.'

    Reset-Scenario
    $global:DcrTestState.Existing = $true
    $null = Invoke-Scenario -ExpectedError 'DCR already exists'
    Assert-Check (@(Get-Writes).Count -eq 0) 'Existing DCR must be protected.'
    $output = Invoke-Scenario @{ UpdateExistingDcr = $true }
    Assert-Check ($output -match 'Verified 2 host associations') 'Explicit DCR update should work.'

    Reset-Scenario
    $global:DcrTestState.Associations['/example/nodes/physical'] = @{ name = $settings.DcraName; dataCollectionRuleId = '/example/other-rule' }
    $null = Invoke-Scenario -ExpectedError 'Association name conflict'
    Assert-Check (@(Get-Writes).Count -eq 0) 'Conflicting association must prevent writes.'

    Reset-Scenario
    $global:DcrTestState.Fail = 'graph query'
    $null = Invoke-Scenario -ExpectedError 'Azure CLI failed'
    Assert-Check (@(Get-Writes).Count -eq 0) 'CLI discovery failure must prevent writes.'

    Reset-Scenario
    $global:DcrTestState.Truncated = $true
    $null = Invoke-Scenario -ExpectedError 'discovery was truncated'
    Assert-Check (@(Get-Writes).Count -eq 0) 'Truncated discovery must prevent writes.'

    Reset-Scenario
    $global:DcrTestState.WrongIdentity = $true
    $null = Invoke-Scenario -ExpectedError 'Association verification failed'
    Assert-Check (@(Get-Writes).Count -eq 2) 'Verification failure must stop after the first association.'

    Reset-Scenario
    $global:DcrTestState.Associations['/example/nodes/physical'] = @{ name = $settings.DcraName; dataCollectionRuleId = $ruleId }
    $global:DcrTestState.WrongIdentity = $true
    $null = Invoke-Scenario @{ Rollback = $true } -ExpectedError 'Association now targets another DCR'
    Assert-Check (@(Get-Writes).Count -eq 0) 'Rollback must recheck identity before deleting.'
    Write-Host 'PASS: DCR deployment, pagination, membership, preview, failure, update and rollback checks (mocked Azure CLI).'
} finally {
    Remove-Item Function:global:az
    Remove-Variable DcrTestState -Scope Global
}