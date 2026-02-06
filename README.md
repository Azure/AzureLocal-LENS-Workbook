# Azure Local LENS (Lifecycle, Events & Notification Status) Workbook

## Latest Version: v0.8.0

📥 **[Copy / Paste (or download) the latest Workbook JSON](https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/refs/heads/main/AzureLocal-LENS-Workbook.json)**

Azure Local Lifecycle, Events & Notification Status (LENS) workbook brings together the signals you need to understand your Azure Local estate through a fleet lens. Instead of jumping between individual resources, you can use a consistent set of views to compare instances, spot outliers, and drill into the focus areas that need attention. LENS workbook provides comprehensive visibility into cluster health, update readiness, and workload status across your entire Azure Local fleet.

**Important:** This is a community-driven / open-source project, (not officially supported by Microsoft), for any issues, requests or feedback, please [raise an Issue](https://aka.ms/AzureLocalLENS/issues) (note: no time scales or guarantees can be provided for responses to issues.)

## Recent Changes (v0.8.0)

### Bug Fixes
- **Update Attempts by Day Chart Date Ordering** ([Issue #24](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/24)): Fixed the "Update Attempts by Day" bar chart on the Update Progress tab not displaying dates in chronological order. The root cause was the chart's `group by state` rendering, which processed each state series (Succeeded, Failed, InProgress) independently — each series contributed its own dates to the x-axis in isolation, producing interleaved non-chronological ordering. Fixed by pivoting the KQL query to produce one row per time bucket with `Succeeded`, `Failed`, and `InProgress` as separate columns using `countif()`, eliminating the per-series grouping and guaranteeing a single chronologically ordered row sequence.

- **Update Run History Excludes Resolved Failures**: Improved the "Update Run History and Error Details" table to automatically exclude failed update runs when a subsequent run for the exact same Update Name version (e.g., `Solution12.2601.1002.38`) has completed successfully on the same cluster. This reduces noise by hiding failures that have been resolved by a successful retry.

- **Clusters Currently Updating View Progress Link**: Fixed the "View Progress" link in the "Clusters Currently Updating" table which was not displaying update step data in the Azure portal. The link now uses the correct portal URL format with `updateName~/null` instead of passing the specific update name.

### New Features
- **Current Step in Clusters Currently Updating**: Added a "Current Step" column to the "Clusters Currently Updating" table showing the deepest currently-executing step from the update run's progress hierarchy. This is extracted by walking the nested steps structure (up to 8 levels deep) to find the most specific `InProgress` step, falling back to the top-level progress description when deeper step data is unavailable.
- **Step Duration in Clusters Currently Updating**: Added a "Step Duration" column showing how long the cluster has been on its current update step (e.g., "2h 15m", "1d 3h 42m"). Calculated from the step's `startTimeUtc` against the current time.

### Improvements
- **CI/CD Pipeline**: Added GitHub Actions workflow for automated unit testing of workbook JSON structure, KQL query validation, and version consistency checks with NUnit XML test result output

- **Continuous Timeline on Update Attempts by Day Chart**: The bar chart now fills date gaps with zero-count entries using a date scaffold, ensuring a continuous timeline with no missing days/weeks/months even when there is no update activity.

- **Dynamic Time Granularity on Deployment Line Charts**: Both the "Azure Local Clusters Deployment Over Time" and "AKS Arc Cluster Deployments Over Time" line charts now use daily data points for time ranges of 1 month or less, weekly data points for up to 3 months, and monthly data points for longer ranges. Date gaps are also filled with zero-count entries for a continuous timeline.

> See [Appendix: Previous Version Changes](#appendix-previous-version-changes) for older release notes.

---

## How to Import the Workbook

1. **Navigate to Azure Monitor Workbooks**
   - Open the [Azure portal](https://portal.azure.com)
   - Search for "Monitor" in the search bar and select **Monitor**
   - In the left navigation, select **Workbooks**

2. **Create a New Workbook**
   - Click **+ New** to create a new workbook
   - In the empty workbook, click the **Advanced Editor** button (</> icon) in the toolbar

3. **Import the JSON Template**
   - In the Advanced Editor, select the **Gallery Template** tab
   - Delete any existing content in the editor
   - Copy the entire contents of the [`AzureLocal-LENS-Workbook.json`](https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/refs/heads/main/AzureLocal-LENS-Workbook.json) file
   - Paste the JSON content into the editor
   - Click **Apply**

4. **Save the Workbook**
   - Click **Done Editing** to exit edit mode
   - Click **Save** or **Save As** in the toolbar
   - Provide a name (e.g., "Azure Local LENS Workbook")
   - Select a subscription, resource group, and location to save the workbook
   - Click **Save**

5. **Pin to Dashboard (Optional)**
   - After saving, you can pin individual tiles or the entire workbook to an Azure dashboard for quick access

### Alternative Import Method

You can also import directly from the Workbooks gallery:

1. Go to **Monitor** > **Workbooks**
2. Click **+ New**
3. Click the **</>** (Advanced Editor) button
4. Select **Gallery Template** tab
5. Paste the JSON content and click **Apply**

## Prerequisites

- Access to Azure subscriptions containing Azure Local clusters:
- **Reader permissions** on the resources you want to monitor
  - The workbook automatically queries across **all subscriptions you have access to** within your Microsoft Entra tenant.
  - You will only see data for resources where you have at least Reader access
  - **Azure Lighthouse**: If you have Azure Lighthouse delegations configured, Azure Resource Graph will also query across delegated subscriptions in customer tenants, allowing cross-tenant visibility from your managing tenant.
  - **Note**: Data is scoped to your Microsoft Entra tenant (plus any Lighthouse-delegated subscriptions) - you cannot query resources in other tenants without Lighthouse delegation
- Access to Azure Monitor Workbooks in the Azure portal.

## Overview

This workbook uses Azure Resource Graph queries to aggregate and display real-time information about your Azure Local infrastructure. It's designed to help administrators and operations teams quickly identify issues, track update progress, and maintain overall cluster health across multiple clusters and subscriptions.

## Features

1. **Navigate to Azure Monitor Workbooks**
   - Open the [Azure portal](https://portal.azure.com)
   - Search for "Monitor" in the search bar and select **Monitor**
   - In the left navigation, select **Workbooks**

2. **Create a New Workbook**
   - Click **+ New** to create a new workbook
   - In the empty workbook, click the **Advanced Editor** button (</> icon) in the toolbar

3. **Import the JSON Template**
   - In the Advanced Editor, select the **Gallery Template** tab
   - Delete any existing content in the editor
   - Copy the entire contents of the [`AzureLocal-LENS-Workbook.json`](https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/refs/heads/main/AzureLocal-LENS-Workbook.json) file
   - Paste the JSON content into the editor
   - Click **Apply**

4. **Save the Workbook**
   - Click **Done Editing** to exit edit mode
   - Click **Save** or **Save As** in the toolbar
   - Provide a name (e.g., "Azure Local LENS Workbook")
   - Select a subscription, resource group, and location to save the workbook
   - Click **Save**

5. **Pin to Dashboard (Optional)**
   - After saving, you can pin individual tiles or the entire workbook to an Azure dashboard for quick access

### Alternative Import Method

You can also import directly from the Workbooks gallery:

1. Go to **Monitor** > **Workbooks**
2. Click **+ New**
3. Click the **</>** (Advanced Editor) button
4. Select **Gallery Template** tab
5. Paste the JSON content and click **Apply**

## Prerequisites

- Access to Azure subscriptions containing Azure Local clusters:
- **Reader permissions** on the resources you want to monitor
  - The workbook automatically queries across **all subscriptions you have access to** within your Microsoft Entra tenant.
  - You will only see data for resources where you have at least Reader access
  - **Azure Lighthouse**: If you have Azure Lighthouse delegations configured, Azure Resource Graph will also query across delegated subscriptions in customer tenants, allowing cross-tenant visibility from your managing tenant.
  - **Note**: Data is scoped to your Microsoft Entra tenant (plus any Lighthouse-delegated subscriptions) - you cannot query resources in other tenants without Lighthouse delegation
- Access to Azure Monitor Workbooks in the Azure portal.

## Overview

This workbook uses Azure Resource Graph queries to aggregate and display real-time information about your Azure Local infrastructure. It's designed to help administrators and operations teams quickly identify issues, track update progress, and maintain overall cluster health across multiple clusters and subscriptions.

## Features

The workbook is organized into seven tabs:

📊 Azure Local Instances | 📋 System Health | 🔄 Update Progress | 🖥️ Azure Local Machines | 🔗 ARB Status | 💻 Azure Local VMs | ☸️ AKS Arc Clusters

### 📊 Azure Local Instances
A high-level overview of your entire Azure Local estate, including:
- **Visual Summary Charts**: Pie charts showing cluster connectivity, health status, and Azure Resource Bridge (ARB) status
- **Azure Local Totals and Connectivity**: Tile metrics for total clusters, connected/disconnected clusters, connection percentage, total machines, and offline ARBs
- **Health and Patching Status**: Healthy clusters, health warnings, failed prechecks, failed extensions, and health percentage
- **Update Compliance**: 
  - Tiles showing clusters on supported release (green), unsupported release (red), updates available, updates in progress, and update failures
  - Version compliance calculated based on the YYMM component of the cluster version (e.g., `xx.2512.x.x` = December 2025 release) with 6-month rolling support window
  - Links to Lifecycle cadence and Latest releases documentation
  - Solution Version Distribution bar chart showing cluster counts by version
- **Workload Summary**: Total Azure Local VMs and AKS Arc clusters
- **Cluster Details Charts**: 
  - OS version distribution (e.g., 24H2, 23H2)
  - Hardware class distribution (Small, Medium, Large)
  - Billing model breakdown
  - Hardware vendor/model distribution
- **All Clusters Table**: Comprehensive list with solution version, node count, total cores, total memory, OS version, hardware class, manufacturer, model, last sync, and registration date
- **Stale Clusters Warning**: Table showing clusters that haven't synced in 24+ hours with color-coded severity

![Azure Local Instances](images/summary-dashboard-screenshot.png)

![Azure Local Instances - Clusters](images/summary-dashboard-2-screenshot.png)

### 📋 System Health
Detailed view of cluster system health and update readiness:
- Health state distribution chart
- Version distribution across clusters
- Summary of health states by update status
- Failed prechecks analysis with filtering by cluster, health state, and severity
- **Failure By Reason Summary** table with:
  - Filter by cluster to narrow down to specific clusters
  - **Filter by severity** to focus on Critical and Warning issues (defaults to excluding Informational)
  - Sorted by cluster count (highest first) to identify issues affecting the most clusters
  - Detailed failure reason summaries showing affected clusters and occurrence counts
- Link to Microsoft documentation for troubleshooting Azure Local updates

![System Health](images/update-readiness-and-system-health-screenshot.png)

### 🔄 Update Progress
Track the progress of ongoing updates across your clusters with detailed status information:
- **Update Attempts by Day** stacked bar chart showing update attempts per day with status breakdown (Succeeded, Failed, InProgress)
- Update state summary tiles and pie chart distribution
- **Clusters Currently Updating** table with live status
- **Clusters with Updates Available** table with:
  - Direct link to apply One Time Update in Azure Update Manager
  - Link to Azure Local Known Issues documentation
- **All Cluster Update Status** table with information about the 6-month support window
- **Update Run History and Error Details** table showing recent update runs with:
  - Cluster name and update name
  - **Details** column (3rd column) with direct link to view update run details in Azure portal
  - State and status with icons (success/failed/in-progress)
  - Current step description showing what the update is doing
  - **Error Message** column displaying extracted error details for failed updates (click to view full error)
  - Human-readable duration format (e.g., "1h 7m 15s" instead of ISO 8601 format)
  - Start time and last updated timestamps

![Update Progress](images/update-progress-screenshot.png)

### 🖥️ Azure Local Machines
Comprehensive view of physical server machines in Azure Local clusters:
- **Last Refreshed timestamp** and documentation links
- **Machine Overview**:
  - Connection status summary tiles (Total, Connected, Disconnected)
  - Connection status pie chart
  - Hardware vendor distribution pie chart
  - OS version distribution pie chart
  - Arc Agent version distribution pie chart
  - License type distribution pie chart
- **All Machines Table** (sorted with Connected first) with details including:
  - Machine name and cluster association
  - Connection status with icons
  - vCPUs (logical core count) and memory (GB)
  - Hardware vendor, model, and processor
  - Solution version, IP address, and OS version
  - Last status change
- **Disconnected Machines** warning table showing:
  - Disconnected nodes with OS version information
  - Time since disconnection
  - Associated cluster and resource group details
- **Machine Extensions**:
  - Filter by extension status (Succeeded, Failed, Creating, Updating, Deleting)
  - Filter by extension name
  - Extension status summary table and bar chart
  - Failed extensions table with error details
- **Network Adapter Details**:
  - Filter by Machine Name and NIC Status (Up/Down)
  - **Note**: Cluster Tag filtering is not supported for this section due to Azure Resource Graph query limitations
  - NIC Status Distribution pie chart showing Up/Down/Disconnected counts (respects filters)
  - NIC information from edge devices including adapter name, type, status, and interface description
  - Machine Name column showing actual host names (joined from hybrid compute machines)
  - Cluster column with link to the Azure Local cluster resource in Azure portal
  - NIC Type (Virtual or Physical) derived from interface description
  - Status with icons (Up = green, Down = red)
  - Driver version for each network adapter
  - IP address, subnet mask, default gateway, and DNS servers
  - MAC address for hardware identification

![Azure Local Machines](images/physical-nodes-screenshot.png)

![Physical Machine Extensions](images/physical-nodes-extensions-screenshot.png)

### 🔗 ARB Status
Monitor the status of Azure Resource Bridge appliances:
- Warning banner about 45-day offline limit (displayed below Offline ARBs section) with link to troubleshooting documentation
- ARB status summary per Azure Local instance with pie chart
  - Shows all ARBs including orphaned ones (where cluster has been deleted)
  - "Unknown" displayed for HCIClusterConnectivity when cluster is missing
  - Sorted with Running status first
- Offline ARB appliances table showing ALL offline ARBs regardless of cluster connection status
- **Last Modified** timestamp and **Days Since Last Modified** with color coding:
  - Green: 0 days
  - Yellow: 1-14 days
  - Red: More than 14 days
- All ARB appliances table with filters for ARB Status and Cluster Name
- Shows "Connected" (green) for Running ARBs or days since last modified (yellow) for Offline ARBs
- Direct links to open ARB and cluster resources in the Azure portal
- **ARB Alert Rules Configuration** (toggle to show/hide):
  - Table with direct links to create Resource Health and Activity Log alerts for each ARB
  - Recommended alert types with severity guidance
  - Step-by-step instructions for manual alert creation
  - Quick links to Action Groups, Alert Rules, and documentation

![Azure Resource Bridges Status](images/arb-offline-screenshot.png)

### 💻 Azure Local VMs
Monitor virtual machines running on Azure Local clusters:
- VM status summary tiles showing total VMs and connection status
- VM connection status distribution pie chart
- OS distribution pie chart showing operating system breakdown
- VMs by resource group distribution
- Bar chart showing VM deployments over time based on OS install date (configurable 1-24 months)
- Complete list of all VMs with details including:
  - OS SKU and version
  - vCPUs and memory (GB)
  - IP address
  - Domain name
  - Agent version
  - OS install date and last status change
- VMs grouped by hosting Azure Local cluster with hardware specs
- VM distribution bar chart by cluster

![Azure Local VMs](images/azure-local-vms-screenshot.png)

![Azure Local VMs - By Cluster](images/azure-local-vms-2-screenshot.png)

### ☸️ AKS Arc Clusters
Monitor AKS Arc clusters running on Azure Local:
- Summary tiles showing total clusters, connected/offline, and provisioning state
- Connectivity status distribution pie chart
- Kubernetes version distribution pie chart
- Provisioning state pie chart
- Bar chart showing cluster deployments over time (configurable 3-24 months)
- Complete list of all AKS Arc clusters with details including:
  - Node count and total core count
  - Kubernetes and agent versions
  - Distribution type
  - Last connectivity time
  - Certificate expiration date
  - Cluster creation date
- Certificate expiration warning table showing clusters with certificates expiring within 30 days
- **AKS Arc Cluster Extensions**:
  - Filter by extension status (Succeeded, Failed, Creating, Updating, Deleting)
  - Filter by extension name
  - Extension status summary table and bar chart (similar to Node Extensions)
  - Failed extensions table with error details

![AKS Arc Clusters](images/aks-clusters-screenshot.png)

## Quick Actions and Knowledge Links

The workbook includes convenient quick action links to:
- 🔔 Create Azure Monitor Alert Rules
- 📜 View Activity Log
- 💡 Azure Advisor Recommendations
- 🏥 Azure Service Health Status
- 📚 Azure Local Documentation
- 🔄 Azure Local Update Guide

## Parameters

The workbook provides several filtering options to help you focus on specific resources:

### Scope Filters
- **Subscriptions**: Filter data by one or more Azure subscriptions (defaults to all accessible subscriptions)

### Resource Group Filter
- **Resource Group Filter**: Optional wildcard filter for resource group names
  - Use `*` as a wildcard character to match any sequence of characters
  - Examples:
    - `*-prod-*` matches resource groups containing "-prod-" (e.g., "rg-hci-prod-01", "azure-prod-cluster")
    - `*hci*` matches any resource group containing "hci"
    - `rg-*` matches resource groups starting with "rg-"
  - Leave empty to show all resource groups

### Cluster Tag Filter
- **Cluster Tag Name**: The name of the tag to filter by (e.g., "Environment", "Team", "CostCenter")
- **Cluster Tag Value**: The value of the tag to match (e.g., "Production", "IT-Ops")
- **Note**: Tag filtering applies **only to Azure Local clusters** - it does not filter AKS Arc clusters or Azure Local VMs
- Both Tag Name and Tag Value must be provided for the filter to take effect

### Time Range
- **Time Range**: Select the time range for time-based queries (1 day to 30 days, or custom)

## Usage Tips

- Use the subscription filter to focus on specific environments (e.g., production vs. development)
- Regularly check the System Health tab before scheduling maintenance windows
- Monitor the ARB Status tab to ensure Azure Arc connectivity is healthy
- Export data to Excel using the export button on grids for reporting purposes
- Set up Azure Monitor alerts based on the queries in this workbook for proactive monitoring

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on reporting issues, submitting pull requests, development practices, and running tests.

## License

See the repository's LICENSE file for details.

---

## Appendix: Previous Version Changes

### v0.7.9

#### New Features
- **Dependency Information Column with SBE Details** ([Issue #20](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/20)) (Update Progress tab): Added a new **Dependency Information** column to the "📦 Clusters with Updates Available" table:
  - Shows SBE version with ⚠️ warning icon as a clickable link only when the update state is **AdditionalContentRequired** or **HasPrerequisite**
  - Clicking the link opens a flyout showing Solution Builder Extension (SBE) details:
    - **Publisher**: The OEM/hardware vendor name
    - **Family**: The SBE family identifier
    - **Version**: The SBE version that will be installed
    - **Release Notes**: Link to SBE release documentation
  - This helps identify when OEM-specific content needs to be downloaded before an update can proceed

- **Update Status Column with Emoji Icons** (System Health tab): Added visual emoji icons to the "Update Status" column in both the "System Health Checks Overview" and "Update Readiness Summary" tables:
  - 🔄 Updates available
  - ⚠️ Needs attention
  - ✅ Up to date / Applied successfully
  - ⏳ Update in progress / Preparation in progress
  - ❌ Update failed / Preparation failed

- **Tip for Update Progress Tab** (System Health tab): Added a tip below the "System Health Checks Overview" table recommending users review the "📦 Clusters with Updates Available" table in the Update Progress tab for more details

#### Improvements
- **Renamed "Update Readiness" tab to "System Health"**: The tab has been renamed to better reflect its purpose of showing overall cluster system health status, not just update readiness
- **Renamed "State" to "Update Status"** (System Health tab): The "State" column in the "System Health Checks Overview" table has been renamed to "Update Status" for clarity and consistency with the "Update Readiness Summary" table
- **Renamed "SBE Version" to "Current SBE Version"** (Update Progress tab): The "SBE Version" column in the "📦 Clusters with Updates Available" table has been renamed to "Current SBE Version" for clarity, and moved to appear after "Current Version"
- **Removed Update Dependency Column** (System Health tab): The "Update Dependency" column has been removed from the "System Health Checks Overview" table as this information is now shown in the "📦 Clusters with Updates Available" table in the Update Progress tab
- **Column Order Update** (Update Progress tab): In the "📦 Clusters with Updates Available" table, "Update State" now appears before "Dependency Information"

### v0.7.81

#### New Features

- **Clickable Count Columns** ([Issue #16](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/16)) (Azure Local Instances tab):
  - **Nodes** column now links to the cluster's Machines page in Azure Portal
  - **VMs** column now links to the cluster's Virtual Machines page in Azure Portal
  - **AKS Arc** column now links to the cluster's Kubernetes Clusters page in Azure Portal

- **VM Count and AKS Arc Count Columns Relocated** ([Issue #16](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/16)) (Azure Local Instances tab):
  - Moved **VMs** and **AKS Arc** columns from "System Health Checks Overview" table (System Health tab) to the "📊 All Azure Local Clusters" table
  - Counts now use proper relationship chain through Custom Location and Arc Resource Bridge for improved accuracy when resources are in different resource groups

- **Update Filters** ([Issue #15](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/15)):
  - Added **Filter by Update Available** multi-select dropdown to "📦 Clusters with Updates Available" table (Update Progress tab) - filters clusters by specific available update versions

#### Improvements

- **Increased Table Row Limits**: All tables now support up to 2,000 rows (previously 250) to prevent "Results were limited to the first 250 rows" warnings
- **Column Label Improvements** (Azure Local Instances tab):
  - Renamed "Node Count" to "Nodes"
  - Renamed "VM Count" to "VMs"
  - Renamed "AKS Arc Count" to "AKS Arc"
  - Renamed "Total Cores" to "Cores"
  - Renamed "Total Memory (GB)" to "Memory (GB)"

- **Update Run History Improvements** (Update Progress tab):
  - Improved **Current Step** detection for failed updates - now correctly identifies the failing step from error messages
  - Made **Cluster Name** column clickable - links directly to the cluster's Updates page in Azure Portal

- **Non-Compliant Flux Configurations Table** (AKS Arc Clusters tab):
  - Renamed **Error Message** column to **Error Details** for consistency
  - Made **Error Details** column clickable - displays full error message in a flyout blade (matching the Update Run History table pattern)
  - Made **Source URL** column clickable - opens the Git repository URL directly

- **AKS Arc Clusters Tab Tip**: Added informational tip explaining that Tag filters do not work when tags are only present on the parent Azure Local cluster (due to Azure Resource Graph query limitations)

#### Bug Fixes

- **Flux Configurations Namespace Column** ([Issue #18](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/18)): Fixed the "All Flux Configurations" table to correctly display the Namespace column (was using incorrect property path `properties.namespace` instead of `properties.configNamespace`)

### v0.7.7

#### New Features

- **Auto-populated Tag Name and Tag Value Filters** ([Issue #9](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/9)):
  - Tag Name and Tag Value filters are now dropdown lists instead of text inputs
  - Dropdown values are auto-populated from Azure Resource Graph based on tags applied to Azure Local clusters
  - Provides better discoverability of available tags and reduces input errors

- **ARB Filtering by Cluster Tags** ([Issue #10](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/10)):
  - Azure Resource Bridge (ARB) status tables now respect Cluster Tag filters
  - When filtering by cluster tags, only ARBs associated with matching clusters are shown
  - Applies to: ARB Status Summary, Offline ARBs table, and All ARBs table
  - Previously, tag filtering was not supported for ARB resources

- **Update Duration Statistics by Solution Update Table** (Update Progress tab):
  - New table showing duration statistics aggregated per Solution Update version ([Issue #6](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/6))
  - Enables comparison of update performance across different solution versions
  - **Columns**: Solution Update, Total Runs, Succeeded, Failed, In Progress, Success Rate (color-coded), Average Duration, Standard Deviation, 95th Percentile, 99th Percentile, Min Duration, Max Duration
  - Helps identify problematic updates or version-specific performance issues
  - Respects all existing filters (Time Range, Solution Update, Resource Group)
  - Export to Excel and refresh buttons available

#### Improvements

- **Detailed Health Check Results Section** (System Health tab):
  - Added dedicated "🔍 Detailed Health Check Results" section header with icon for visual consistency
  - Added separate filter controls directly above the Detailed Health Check Results table for improved usability
  - Filters include: Cluster Name, Health Check State, Health Check Step Status, and Severity
  - Severity filter defaults to "Critical" only (previously shared filters defaulted to Critical and Warning)
  - Documentation and knowledge links now appear between the section header and filters

- **System Health Check Filters** (System Health tab):
  - Changed filter style from "formHorizontal" to "pills" for narrower, more compact dropdown boxes
  - Improved visual consistency with other tabs

- **Success Rate Column Thresholds** (Update Progress tab):
  - Updated color thresholds in both "Overall Update Duration - Analytical Statistics" and "Update Duration Statistics by Solution Update" tables
  - New thresholds: 🟢 Green (90-100%), 🟡 Amber (70-89%), 🔴 Red (0-69%)
  - Fixed threshold comparison logic by outputting numeric values for proper color coding

- **Table Improvements** (Update Progress tab):
  - Renamed "Update Duration - Analytical Statistics" to "Overall Update Duration - Analytical Statistics" for clarity
  - Solution Update column in "Update Duration Statistics by Solution Update" table now auto-expands to show full version text

#### Bug Fixes

- **Clusters Currently Updating Query** (Update Progress tab):
  - Fixed case-sensitivity bug in update run ID extraction (`/updateruns` → `/updateRuns`)
  - Clusters with active update runs now correctly appear in the "Clusters Currently Updating" table

- **Dark Mode Readability** (All tabs):
  - Fixed version banner text being unreadable in dark mode
  - Added explicit text colors to ensure visibility in both light and dark themes

- **Azure Local Physical Machines Section Header** (Physical Machines tab):
  - Fixed corrupted emoji icon in section header (now displays 🖥️)

- **AKS Arc Network Details Table** (AKS Arc Clusters tab):
  - Fixed **IPs Used** and **IPs Available** columns not populating
  - Corrected IP pool property paths from `ipPool.info.usedIPCount`/`availableIPCount` to `ipPool.info.used`/`available` to match the Azure Stack HCI API schema

### v0.7.4

#### New Features

- **AKS Arc Network Details Table** (AKS Arc Clusters tab):
  - New table showing comprehensive network configuration for each AKS Arc cluster
  - **Columns**: AKS Cluster Name (linked), Resource Group, Location, Pod CIDR, Control Plane IP, Logical Network (linked), Network State (with status icons), Load Balancers, Address Prefix, IP Pool Start, IP Pool End, IPs Used, IPs Available, VLAN ID, DNS Servers
  - Data sourced from:
    - `microsoft.kubernetes/connectedclusters` for cluster info
    - `microsoft.hybridcontainerservice/provisionedclusterinstances` for pod CIDR, control plane IP, and logical network IDs
    - `microsoft.azurestackhci/logicalnetworks` for network details (subnets, IP pools, VLAN, DNS)
    - `microsoft.kubernetesruntime/loadbalancers` for load balancer names

- **Load Balancers Table** (AKS Arc Clusters tab):
  - New table showing Kubernetes Runtime load balancer details per AKS Arc cluster
  - **Columns**: AKS Cluster Name (linked), Resource Group, Load Balancer name, Provisioning State (with status icons), Advertise Mode, Addresses
  - Data sourced from `microsoft.kubernetesruntime/loadbalancers` joined with `microsoft.kubernetes/connectedclusters`

- **Duration Statistics Table Improvements** (Update Progress tab):
  - Expanded column names for clarity: "Avg Duration" → "Average Duration", "Std Dev" → "Standard Deviation"
  - Added **95th Percentile** and **99th Percentile** duration columns for better statistical analysis of update durations

- **Update Success Analysis Table Improvements** (Update Progress tab):
  - Added **Percentage** column showing the proportion of each outcome category relative to total unique updates
  - Uses ARG `join kind=inner` with subquery to calculate percentages server-side

### v0.7.3

#### New Features

- **All AKS Arc Clusters Table Enhancements** (AKS Arc Clusters tab):
  - Added **OIDC Issuer URL** column showing the cluster's OIDC issuer URL for workload identity federation
  - Added **Admin Group Object IDs** column showing comma-separated list of Microsoft Entra ID admin group object IDs

- **Kubernetes Version & Upgrade Status Section** (AKS Arc Clusters tab):
  - **Pie Chart**: "Upgrade Status (Minor Available vs Fully Upgraded)" - visualizes cluster count by upgrade availability
    - Yellow = Minor upgrades available
    - Green = Fully upgraded (no minor version upgrades)
  - **Summary Table**: "Version/Upgrade Summary" - counts clusters grouped by current version and available upgrades
  - **Detail Table**: "Kubernetes Version and Available Upgrades" - per-cluster view showing:
    - Cluster name (clickable link to Azure Portal)
    - Resource group, location
    - Current Kubernetes version
    - Available upgrade versions (comma-separated list)
  - Data sourced from `extensibilityresources` upgradeprofiles joined with connectedclusters

- **Tab Navigation Improvements**:
  - Reordered tabs: ARB Status now appears before Azure Local Machines for better logical grouping
  - Updated tab icons for better visual distinction:
    - Azure Local Machines: 🗄️ (file cabinet)
    - Azure Local VMs: 💻 (laptop)

- **All Cluster Update Status Table Improvements** (System Health tab):
  - Renamed **"Days Since Update"** column to **"Last Update Installed"**
  - Updated format from "X days" to "X days ago" for clearer time indication

- **System Health Checks Overview Table Improvements** (System Health tab):
  - Renamed **"Days Since Last Check"** column to **"Age of Health Results"**
  - Added explanatory tip text above table clarifying what "Age of Health Results" represents

- **Update Attempts Details Table Improvements** (Update Progress tab):
  - Moved **Duration** column to appear before Started/Ended columns for better readability

- **Clusters with Updates Available Table** (System Health tab):
  - Renamed action button from "Apply Update" to "Install Update" for consistency with Azure Portal terminology

#### Bug Fixes

- **Clusters Currently Updating Table** (System Health tab):
  - Fixed inconsistency where clusters with active update runs showing "InProgress" in Update Attempts Details table were not appearing in Clusters Currently Updating
  - Query now uses update runs (`updateruns`) as the primary source of truth instead of relying on `updateSummaries.state` which may not be synchronized
  - Ensures consistent display of in-progress updates across both tables

- **Update Progress Tab Improvements**:
  - **New "Solution Update" Filter**: Multi-select dropdown to filter by specific solution update versions
    - Extracts version from full update name (e.g., `Solution12.2601.1002.38/updateRuns/...` → `Solution12.2601.1002.38`)
    - Applied to all update visualizations: chart, pie chart, summary table, and details table
  - **Dynamic Time Series Granularity** for "Update Attempts by Day" chart:
    - Up to 1 month: Daily grouping (`2025-01-15`)
    - 1-3 months: Weekly grouping (`Week of 2025-01-13`)
    - 6, 9, 12 months: Monthly grouping (`2025-01`)
    - Eliminates the "Other" bucket issue when selecting longer time periods
  - **Update Attempts Details Table**: 
    - Added "Solution Update" column showing the extracted version
    - Renamed "Update Name" column to "Update Run" for clarity
  - **Tip Text**: Added helpful tip above filters explaining their purpose
  - **New "Update Analytics" Section** (above Update Attempts Details table):
    - **Duration Statistics**: Summary row showing Total Runs, Succeeded, Failed, In Progress counts with visual bars
      - Success Rate with color-coded thresholds (green ≥90%, yellow ≥70%, red <70%)
      - Average Duration, Standard Deviation, Min and Max durations for succeeded updates
    - **Update Success Analysis Table**: Breakdown of unique updates by outcome category:
      - **First Time Success**: Updates that succeeded on the first run
      - **Resumed After Failure**: Updates that failed initially but were resumed and succeeded
      - **Succeeded (Multiple Runs)**: Updates with multiple runs, all succeeded (no failures)
      - **In Progress**: Updates currently running
      - **Failed (Not Recovered)**: Updates that failed and haven't been retried/recovered
      - Shows count and percentage of total for each outcome
    - **Update Outcomes Distribution Pie Chart**: Visual breakdown of the same outcome categories

### v0.7.2

#### Bug Fixes

- **All AKS Arc Clusters Table - Azure Local Cluster Linking Fix**: Fixed issue where the "Azure Local Cluster" column was showing null for all AKS Arc clusters
  - Redesigned query architecture to use proper relationship chain: AKS Cluster → provisionedclusterinstances (custom location) → customlocations → Arc Bridge → hybridaksextension → `HCIClusterID` → Azure Local Cluster
  - Uses normalized custom location key (lowercased, trimmed) for reliable joins across queries
  - Implemented 2-query + 1-merge pattern to work around ARG cross-table limitations (extensibilityresources + kubernetesconfigurationresources cannot be queried together):
    - Query 1: AKS cluster base info + custom location key + node counts from `extensibilityresources` (provisionedclusterinstances)
    - Query 2: Custom location → Arc Bridge → `kubernetesconfigurationresources` (hybridaksextension) → Azure Local cluster mapping
    - Workbook merge: Joins both results on customLocKey
  - Azure Local Cluster column is now clickable with direct link to the parent cluster
  - Retained Control Plane and Worker Node columns

- **Failed AKS Extensions Table Improvements**:
  - Renamed "Error Message" column to "Error Details"
  - Fixed case-sensitivity issue for error message property extraction
  - Now includes error Code prefix when available (e.g., `InstallationFailed: Helm Upgrade Failed...`)
  - Added clickable "Subscription Name" column with link to subscription in Azure Portal
  - Added clickable flyout for "Error Details" column - click to expand full error message in a context blade with formatted layout

- **Failed Node Extensions Table Improvements**:
  - Renamed "Error Message" column to "Error Details"
  - Added clickable flyout for "Error Details" column - click to expand full error message in a context blade with formatted layout (consistent with Failed AKS Extensions)

### v0.7.0

#### Major Updates and Improvements

- **Azure Local Instances Tab** (formerly "Summary Dashboard"):
  - Renamed tab from "Summary Dashboard" to "Azure Local Instances"
  - **Deployment Trend Charts**: Added deployment over time line charts for:
    - Azure Local Clusters Registered by Month
    - VM Deployments by Month (OS Install Date)
    - AKS Arc Cluster Deployments by Month
  - Each chart shows connected data points with monthly trend visualization
  - Companion data tables (20% width) display monthly breakdown with TOTAL row at top
  - Time range filter for each chart (1-24 months)
  - Made "Solution Version Distribution" chart full width (100%)

- **AKS Arc Clusters Linking**: Improved AKS-to-Azure-Local cluster association
  - Now uses Custom Location → Arc Bridge → Azure Local Cluster linking pattern
  - More accurate association than previous resource group matching approach

- **Clusters Not Synced Recently Table**:
  - Added "Subscription Name" column with clickable link to subscription in Azure Portal

- **Update Readiness Summary Table Improvements**:
  - Added status icons to "Update Status" column:
    - ✅ Green tick for "AppliedSuccessfully"
    - ❌ Red X for "UpdateFailed"
    - ⚠️ Warning triangle for "NeedsAttention"
    - 🕐 Pending icon for "UpdateAvailable"
  - Added "Total" column showing sum of all health states per update status
  - Moved "Total" column to second position (after Update Status)
  - Table now sorted by Total (descending) - largest counts at top
  - Renamed health columns: "Health State: Success", "Health State: Warning", "Health State: Critical"

- **SBE Version Column**: Added "SBE Version" (Solution Builder Extension) column to display currently installed OEM extension version
  - All Azure Local Machines table
  - System Health Checks Overview table (after Azure Connection column)
  - All Cluster Update Status table (after Azure Connection column)
  - Clusters with Updates Available table (after Update State column)

- **New Filter Options**:
  - **Update Run History and Error Details table**: Added filters for Cluster Name, Update Name, State, and Status
  - **All Azure Local Machines and Disconnected Nodes tables**: Added filters for Node Name and Cluster Name

- **Column Naming**: Renamed "Cluster" column to "Cluster Name" in All Azure Local Machines, Disconnected Nodes, All Network Adapters, and Failed Node Extensions tables for consistency

- **Failed Node Extensions Table Improvements** (v0.7.0):
  - Renamed "Machine" to "Machine Name" and moved it to first column
  - Renamed "Cluster" to "Cluster Name" and moved it to fourth column (after Status)
  - Made Cluster Name clickable with link to parent cluster resource

- **Quick Actions Reordered**: Moved Activity Log, Azure Service Health, and Create Alert Rule links to the end of Quick Actions section

- **Cluster Tag Filter Support**: Added comprehensive cluster tag filtering across all tabs
  - All feasible queries now honor the ClusterTagName and ClusterTagValue filter parameters
  - AKS Arc clusters and VMs in the same resource group as matching clusters are also filtered
  - Updated ~35+ queries across Azure Local Instances, Update Readiness, Update Progress, Azure Local VMs, and AKS Arc Clusters tabs
  - Note: ARB tables and NIC Status tables cannot support tag filtering due to Azure Resource Graph join limitations

- **Filter Instructions Updated**: Clarified that cluster tag filter now applies to AKS Arc clusters and VMs via resource group association

- **UI Improvements**:
  - Moved Quick Actions and Knowledge Links above Filter Instructions for better visual separation from Tabs
  - Increased tab font size for improved readability

- **System Health tab**: Added "Top 5 - System Health Check Issues" pie chart showing most common failure reasons

- **Clickable Name Columns**: Made name columns directly clickable with hidden link columns to reduce table width
  - Cluster Name is now clickable in all tables (Summary, Update Readiness, Update Progress, VMs, AKS tabs)
  - Machine Name is now clickable in All Network Adapters table
  - VM Name is now clickable in All Azure Local VMs table
  - Machine column renamed from "Node" and made clickable in Failed Node Extensions table
  - Update Name in Update Attempts Details table is now clickable and links to the update run details view
  - ARB Resource Name in Offline Azure Resource Bridges table is now clickable and links to the ARB resource
  - Remediation column in Detailed Health Check Results is conditionally clickable when it contains a URL

- **Quick Actions Updates**:
  - Added "Solution Builder Extension (SBE) updates" link for OEM-specific updates
  - Added "Azure Local Supportability Forum" link for community support
  - Removed Azure Advisor link

- **Knowledge Links Added**:
  - Added VM extension troubleshooting link below Failed Node Extensions table
  - Added Network ATC intent validation link above All Network Adapters table
  - Added tip for disconnected network adapters: check adapter status using `Get-NetAdapter` on the physical machine
  - Added tip for orphaned ARBs: if Cluster Name shows 'Unknown', the ARB may have been orphaned
  - Reorganized Update Readiness knowledge links for better organization
  - Renamed lifecycle and releases links with more descriptive labels (📚 Knowledge / 📋 Documentation prefixes)

- **ARB Alert Rules Tip**: Expanded guidance text for Azure Resource Bridge alert rule recommendations

- **Auto-Refresh Tips**: Added helpful tips about 5-minute auto-refresh and manual refresh buttons

- **Update Progress Tab Improvements**:
  - **Update Run History and Error Details table**: 
    - Renamed "State" filter to "Update State" with default filter of "Failed"
    - Added note above table indicating default filter is applied
    - Renamed "Error Message" column to "Error Details"
    - "Current Step" column now properly populated for failed updates by extracting from deeply nested progress.steps
    - "Current Step" is only shown for failed updates (empty for succeeded)
    - Enhanced error extraction using hybrid approach:
      - Primary: mv-expand traversal through 8 levels of nested steps for standard error messages
      - Fallback: Regex pattern matching for deeply nested exceptions (up to 13+ levels) that contain "raised an exception:" patterns
    - Improved handling of varied error nesting depths across different cluster configurations
    - Error Details flyout now titled "Error Details" and displays full error message in formatted HTML with table layout for properties
  - **Update Attempts Details table**: Moved "State" column to second position for better visibility
  - **Success / Failure Summary table**: Added small summary table next to pie chart showing Succeeded and Failed counts with percentages; renamed "%" column to "Overall Percentage"
  - Moved pie chart hover tip above the chart for better visibility

- **All Cluster Update Status Table**:
  - Renamed "Available Updates" column to "Update History"
  - Link label changed from "View Updates" to "View History"
  - Links directly to the cluster's update history page in Azure Portal

- **Bug Fixes**:
  - Fixed ARG join limit error in Update Readiness Summary query
  - Updated version banner text with copy/paste hint

### v0.6.9

- **Version Check Banner**: Added prominent styled banner at top of workbook displaying current version with link to [check GitHub for updates](https://aka.ms/AzureLocalLENS)

- **Pie Chart Improvements** (consistent auto-sizing and legend placement):
  - **Azure Local Machines Tab**: Connection Status, Hardware Vendor, OS Version, Arc Agent Version, License Type
  - **Azure Local Machines Tab - NIC Section**: NIC Status Distribution
  - **Update Progress Tab**: Update Attempts by Status Percentages
  - **Azure Local Instances - Cluster Details**: Changed from 1x4 to 2x2 layout for better visibility

- **Empty State Messages** (noDataMessage for better UX):
  - Disconnected Nodes table: "✅ All nodes are connected"
  - Failed Node Extensions table: "✅ No failed extensions found"
  - All Azure Local VMs table: "No Azure Local VMs found in the selected scope"

- **Update Progress Tab**: Added "Last Refreshed" timestamp to header

- **VM Tab Improvements**:
  - Added [Troubleshoot Arc-enabled VMs](https://learn.microsoft.com/azure/azure-local/manage/troubleshoot-arc-enabled-vms) knowledge link
  - Split VM Status Summary into separate "Total VMs" and "Connected VMs" tiles with clear labels

- **System Health tab**: Added prominent styled banner and title above the Update Readiness Summary table with refresh and export buttons

- **All Clusters Table**: Updated cluster link to open directly to the Updates view in Azure Portal

- **All Cluster Update Status Table**: Updated "Days Since Update" color thresholds (60-99 days yellow, 100+ days red)

- **Disconnected Nodes Table**: Added "Status" column with red coloring

- **Knowledge Link Repositioning**: Moved "Send Diagnostic Logs to Microsoft" link above "Clusters Not Synced Recently" section

### v0.6.8

- **Pie Chart Improvements** (consistent auto-sizing and legend placement across all tabs):
  - **Azure Local Instances - Cluster Details**: OS Version, Hardware Class, Billing Model, Hardware Vendor/Model
  - **Azure Local Virtual Machines**: VM Connection Status, OS Distribution, VMs by Resource Group
  - **AKS Arc Clusters**: Connectivity Status, Kubernetes Version Distribution, Provisioning State

- **New Knowledge Links**:
  - **AKS Arc Clusters Tab**: Added [Troubleshoot extension issues for AKS Arc Kubernetes clusters](https://learn.microsoft.com/azure/azure-arc/kubernetes/extensions-troubleshooting) above Failed AKS Extensions table
  - **Azure Local Instances**: Added [Send Diagnostic Logs to Microsoft](https://learn.microsoft.com/azure/azure-local/manage/collect-logs?tabs=azureportal#collect-logs-for-azure-local) below Clusters Not Synced Recently table

### v0.6.7

- **Cluster Link Improvements**:
  - Updated cluster links in update-related tables to open the `/updates` view directly:
    - Cluster Update Status table
    - Clusters Currently Updating table
    - Clusters with Updates Available table
  - Link label changed from "Open Cluster" to "View Updates" for clarity

- **Certificate Expiration Warning Improvements**:
  - Added information banner with link to [certificate rotation documentation](https://learn.microsoft.com/azure/aks/hybrid/rotate-certificates)
  - Enhanced **Days Until Expiration** column with color coding:
    - 🟢 Green: More than 14 days remaining
    - 🟡 Yellow: 8-14 days remaining
    - 🔴 Red: 7 days or less remaining
  - Added refresh and export buttons to the table

- **Clusters with Updates Available**:
  - Added column filtering capability for easier searching

- **System Health tab**:
  - Enlarged pie charts (Health State Distribution, Version Distribution) for better visibility
  - Moved chart legends to bottom position for improved layout
  - Added knowledge link to [Azure Local GitHub Supportability Forum](https://github.com/Azure/AzureLocal-Supportability) for TSGs and known issue mitigations

- **Update Progress Tab**:
  - Moved "Days Since Update" column before "Last Updated" in All Cluster Update Status table
  - Added knowledge link for [Troubleshoot Update failures](https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2#troubleshoot-update-failures) below Clusters Currently Updating table

### v0.6.6

- **ARB Alert Rules Configuration** (new section in ARB Status tab):
  - Added toggle to show/hide Alert Rules setup panel
  - **ARB Alert Rules Table** listing all Arc Resource Bridges with:
    - Current status with visual indicators (Running/Offline)
    - Days offline tracking with color coding (🟢 Online, 🟡 <14 days, 🔴 >14 days)
    - Direct links to create **Resource Health** alerts in Azure Portal
    - Direct links to create **Activity Log** alerts in Azure Portal
  - **Prerequisites documentation**: Action Groups, permissions, Resource Health support
  - **Recommended alert types** with severity guidance:
    - Offline Status (Sev 1)
    - Resource Health - Unavailable (Sev 1)
    - Resource Health - Degraded (Sev 2)
    - Extended Offline >14 days (Sev 0)
  - **Manual alert rule creation steps** including sample ARG query for bulk monitoring
  - **Quick Links**: Create Action Group, View Alert Rules, Resource Health docs, ARB troubleshooting

### v0.6.5

- **Clusters Currently Updating**:
  - Added **Update Run** column with "View Progress" link to open the update history details page in Azure Portal

- **All Azure Resource Bridges (ARB) appliances**:
  - Updated **Days Since Last Modified** column color coding:
    - 🟢 Green: "Connected" for Running ARBs
    - 🟡 Yellow: 1-45 days since last modified
    - 🔴 Red: More than 45 days since last modified

### v0.6.4

- **Network Adapter Details Improvements**:
  - Added filters for the **NIC Status Distribution** pie chart (Machine Name, Machine Connectivity, NIC Status)
  - Reorganized table filters to appear directly above the table (below the pie chart)
  - Added **IP Address** text filter for partial/complete IP address matching
  - Added **Machine Connectivity** dropdown filter to filter by machine connection status
  - Added **Machine Connectivity** column (2nd column) with status icons:
    - ✅ Green tick for "Connected" machines
    - ❌ Red cross for "Disconnected" machines
  - Fixed **Cluster** link to now open the `/machines` view of the cluster in Azure Portal

- **Update Attempts by Day Improvements**:
  - Added **Time Period** filter with consistent options: 1 week (default), 2 weeks, 1 month, 3 months, 6 months, 9 months, 12 months
  - Added **Update Attempts Details** table below the chart showing:
    - Cluster Name with "Open Cluster" link
    - Update Name
    - State with status icons (Succeeded/Failed/InProgress)
    - Started and Ended timestamps
    - Duration (formatted as hours and minutes)
    - Resource Group
  - Added **Update Attempts by Status Percentages** pie chart showing percentage breakdown of update states (Succeeded/Failed/InProgress)

- **Clusters Currently Updating**:
  - Added **Update Installing** column showing which update is currently being installed

- **AKS Arc Clusters Table Improvements**:
  - Added **Masters** column showing the number of control plane (master) nodes
  - Added **Workers** column showing the total number of worker nodes across all agent pools
  - Renamed "Total Node Count" to **Total Nodes** for consistency
  - New columns appear before "Total Nodes" for easy comparison

- **AKS Arc Cluster Deployments Over Time**:
  - Added additional time range options: 1 month, 2 weeks, 1 week (consistent with Update Attempts filter)

### v0.6.3

- **Added Update Available Column**: "Clusters with Updates Available" table now displays the actual update name (e.g., "Solution12.2601.1002.38") from the updates resource
- **Added Update State Column**: New column showing the state of available updates (e.g., "Ready")

### v0.6.2

- **Improved Error Message Display**: Update Run History table now includes expandable row details showing error messages in a formatted markdown code block for better readability
- **Fixed Apply Update Link**: Corrected the "Apply Update" button URL to properly open the Azure Portal Install Updates blade
- **Enhanced Error Message Formatting**: Preserved line breaks in error messages and increased column width for better visibility
- **Column Naming Consistency**: Added proper labelSettings to all tables across all tabs with consistent capitalization and spacing (e.g., "clusterName" → "Cluster Name")

### v0.6.1

- **System Health Naming Updates**: Renamed "Failed Prechecks" to "System Health Filters" and "Cluster Health Overview" to "System Health Checks Overview" for improved clarity and consistency
