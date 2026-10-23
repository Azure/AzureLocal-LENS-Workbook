$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'run-live-tests.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Live-test harness syntax failed.' }
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-LogAnalyticsQuery'
}, $true)
if (-not $definition) { throw 'Log Analytics request helper not found.' }
. ([scriptblock]::Create($definition.Extent.Text))
$SubscriptionId = '00000000-0000-0000-0000-000000000001'
$account = [pscustomobject]@{ tenantId = '00000000-0000-0000-0000-000000000002' }
$script:tokenCalls = 0
$script:httpCalls = 0
$script:failAuth = $false
$script:emptyToken = $false
$script:partialError = $false
$script:httpError = $false
$script:wrongTenant = $false
$script:wrongSubscription = $false
function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function az {
    Assert-Check (($args[0..1] -join ' ') -eq 'account get-access-token') 'Unexpected CLI command.'
    Assert-Check ($args[[array]::IndexOf($args, '--subscription') + 1] -eq $SubscriptionId) 'Missing confirmed subscription.'
    Assert-Check ($args -notcontains '--tenant') 'Azure CLI does not accept both tenant and subscription.'
    Assert-Check ($args[[array]::IndexOf($args, '--resource') + 1] -eq 'https://api.loganalytics.io') 'Wrong token audience.'
    $script:tokenCalls++
    $global:LASTEXITCODE = if ($script:failAuth) { 1 } else { 0 }
    @{
        accessToken = $(if (-not $script:emptyToken) { "synthetic-token-$script:tokenCalls" } else { '' })
        tenant = $(if ($script:wrongTenant) { 'different-tenant' } else { $account.tenantId })
        subscription = $(if ($script:wrongSubscription) { 'different-subscription' } else { $SubscriptionId })
    } | ConvertTo-Json
}
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body)
    $script:httpCalls++
    Assert-Check ($Headers.Authorization -eq "Bearer synthetic-token-$script:tokenCalls") 'A stale token was reused.'
    Assert-Check ($Method -eq 'Post' -and $Uri -eq 'https://api.loganalytics.io/v1/workspaces/example-workspace/query') 'Request target changed.'
    $decoded = $Body | ConvertFrom-Json
    Assert-Check ($decoded.query -eq 'print value=1' -and $decoded.timespan -eq 'P30D') 'Query body changed.'
    if ($script:httpError) { throw 'synthetic HTTP failure' }
    if ($script:partialError) { return @{ error = @{ code = 'PartialError' } } }
    @{ tables = @(@{ rows = @(@(1)) }) }
}
function Assert-Failure {
    param([string]$Expected)
    $caught = $null
    try { $null = Invoke-LogAnalyticsQuery -WorkspaceId 'example-workspace' -Body @{ query = 'print value=1'; timespan = 'P30D' } }
    catch { $caught = $_ }
    Assert-Check ($caught -and $caught.Exception.Message -like "*$Expected*") "Expected failure was not propagated: $Expected"
}
$body = @{ query = 'print value=1'; timespan = 'P30D' }
$null = Invoke-LogAnalyticsQuery -WorkspaceId 'example-workspace' -Body $body
$null = Invoke-LogAnalyticsQuery -WorkspaceId 'example-workspace' -Body $body
Assert-Check ($script:tokenCalls -eq 2 -and $script:httpCalls -eq 2) 'Every request must acquire its current CLI-managed token.'
$script:failAuth = $true
Assert-Failure 'Could not authenticate'
Assert-Check ($script:httpCalls -eq 2) 'Failed authentication must not issue an HTTP request.'
$script:failAuth = $false; $script:emptyToken = $true
Assert-Failure 'Could not authenticate'
Assert-Check ($script:httpCalls -eq 2) 'An empty token must not issue an HTTP request.'
$script:emptyToken = $false; $script:wrongTenant = $true
Assert-Failure 'outside the confirmed'
Assert-Check ($script:httpCalls -eq 2) 'An unexpected tenant must not issue an HTTP request.'
$script:wrongTenant = $false; $script:wrongSubscription = $true
Assert-Failure 'outside the confirmed'
Assert-Check ($script:httpCalls -eq 2) 'An unexpected subscription must not issue an HTTP request.'
$script:wrongSubscription = $false; $script:partialError = $true
Assert-Failure 'partial query error'
$script:partialError = $false; $script:httpError = $true
Assert-Failure 'synthetic HTTP failure'
Write-Host 'Live-query authentication checks passed: per-request renewal, target/body preservation, auth failures, empty tokens, partial errors and HTTP failures.'
