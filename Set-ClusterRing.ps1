# PowerShell script to assign/update a 'Ring' tag on Azure Local (Azure Stack HCI) clusters
# Requires Az CLI or Az PowerShell module and appropriate permissions

param(
    [Parameter(Mandatory)]
    [string]$ClusterName,
    [Parameter(Mandatory)]
    [string]$ResourceGroup,
    [Parameter(Mandatory)]
    [string]$RingValue
)

# Example: .\Set-ClusterRing.ps1 -ClusterName "MyCluster" -ResourceGroup "MyRG" -RingValue "Ring1"

Write-Host "Assigning Ring='$RingValue' to cluster '$ClusterName' in resource group '$ResourceGroup'..."

# Get current tags
$cluster = az resource show --resource-type Microsoft.AzureStackHCI/clusters --name $ClusterName --resource-group $ResourceGroup --query tags -o json | ConvertFrom-Json
if (-not $cluster) { $cluster = @{} }

# Set or update the Ring tag
$cluster.Ring = $RingValue

# Convert tags back to JSON
$tagsJson = $cluster | ConvertTo-Json -Compress

# Update the cluster resource with the new tags
az resource update --resource-type Microsoft.AzureStackHCI/clusters --name $ClusterName --resource-group $ResourceGroup --set tags="$tagsJson"

Write-Host "Ring tag assignment complete."
