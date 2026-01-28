# Sample PowerShell script to collect GPU inventory and usage on a Hyper-V host (Windows)
# This script uses WMI and (if available) NVIDIA tools to gather GPU info and assignment

# Get GPU inventory (all video controllers)
Write-Host "=== GPU Inventory (Win32_VideoController) ==="
Get-WmiObject Win32_VideoController | Select-Object Name, DeviceID, AdapterRAM, DriverVersion, Status | Format-Table -AutoSize

# Get GPU assignment to VMs (Discrete Device Assignment)
Write-Host "\n=== GPU Assignment to VMs (Discrete Device Assignment) ==="
$assignedGPUs = Get-VM | ForEach-Object {
    $vm = $_
    $gpu = Get-VMGpuPartitionAdapter -VMName $vm.Name -ErrorAction SilentlyContinue
    if ($gpu) {
        [PSCustomObject]@{
            VMName = $vm.Name
            GPUEnabled = $gpu.Enabled
            MinPartitionVRAM = $gpu.MinPartitionVRAM
            MaxPartitionVRAM = $gpu.MaxPartitionVRAM
        }
    }
}
$assignedGPUs | Format-Table -AutoSize

# If NVIDIA GPUs are present, use nvidia-smi for detailed usage (requires NVIDIA drivers)
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    Write-Host "\n=== NVIDIA GPU Usage (nvidia-smi) ==="
    nvidia-smi
} else {
    Write-Host "\nNVIDIA GPU not detected or nvidia-smi not available."
}

# For real-time usage (if supported by WMI)
Write-Host "\n=== Real-time GPU Usage (WMI, if available) ==="
try {
    Get-WmiObject -Namespace root\CIMV2 -Class Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | \
        Select-Object Name, UtilizationPercentage | Format-Table -AutoSize
} catch {
    Write-Host "No real-time GPU usage counters available via WMI."
}
