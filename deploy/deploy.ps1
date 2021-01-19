﻿<#
 .SYNOPSIS
  Deploys Industrial IoT platform to Azure.

 .DESCRIPTION
  Deploys the Industrial IoT platform and dependencies in an 
  interactive way to Azure subscriptions.  

 .PARAMETER Type
  The type of deployment (minimum, local, simulation, all).
  Defaults to all.

 .PARAMETER Version
  Set to a version number that corresponds to an mcr image tag
  of the concrete release you want to deploy.
  If not set deploys current master branch ("preview").

 .PARAMETER DockerServer
  An optional name of an Azure container registry to deploy 
  containers from.

 .PARAMETER SourceUri
  Source uri where the deployment scripts and template artifacts can be
  found.  Defaults to github repo if not provided.

 .PARAMETER AadPreConfiguration
  The aad configuration object (use aad-register.ps1 to create object).
  If not provided, calls aad-register.ps1.

 .PARAMETER SimulationProfile
  If you are deploying a simulation, the simulation profile to use
  If not provided, uses default.

 .PARAMETER NumberOfSimulationsPerEdge
  Number of simulations to deploy per edge.

 .PARAMETER NumberOfLinuxGateways
  Number of Linux gateways to deploy into the simulation.

 .PARAMETER NumberOfWindowsGateways
  Number of Windows gateways to deploy into the simulation.

 .PARAMETER TenantId
  An optional tenant id that should be used to access the subscriptions.

 .PARAMETER EnvironmentName
  The cloud environment to use, defaults to AzureCloud.
#>

param(
    [ValidateSet("minimum", "local", "simulation", "production", "all")] 
    [string] $Type = "all",
    [string] $Version = $null,
    [string] $DockerServer = $null,
    [string] $SourceUri = $null,
    [object] $AadPreConfiguration = $null,
    [string] $SimulationProfile = $null,
    [int] $NumberOfLinuxGateways = 0,
    [int] $NumberOfWindowsGateways = 0,
    [int] $NumberOfSimulationsPerEdge = 0,
    [string] $TenantId = $null,
    [string] $EnvironmentName = "AzureCloud"
)

# -------------------------------------------------------------------------------
Import-Module Az 
Import-Module Az.ManagedServiceIdentity -WarningAction SilentlyContinue
$script:ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
Remove-Module pwsh-setup -ErrorAction SilentlyContinue
Import-Module $(join-path $script:ScriptDir pwsh-setup.psm1)
$ErrorActionPreference = "Stop"

$script:requiredProviders = @(
    "microsoft.devices",
    "microsoft.documentdb",
    "microsoft.servicebus",
    "microsoft.eventhub",
    "microsoft.storage",
    "microsoft.keyvault",
    "microsoft.compute",
    "microsoft.managedidentity",
    "microsoft.insights",
    "microsoft.containerservice",
    "microsoft.containerregistry"
)
# -------------------------------------------------------------------------------

# Filter locations for provider and resource type
Function Select-ResourceGroupLocations() {
    param (
        $locations,
        [Parameter(Mandatory=$true)] [string] $provider,
        [Parameter(Mandatory=$true)] [string] $typeName
    )
    $regions = @()
    foreach ($item in $(Get-AzResourceProvider -ProviderNamespace $provider)) {
        foreach ($resourceType in $item.ResourceTypes) {
            if ($resourceType.ResourceTypeName -eq $typeName) {
                foreach ($region in $resourceType.Locations) {
                    $regions += $region
                }
            }
        }
    }
    if ($regions.Count -gt 0) {
        $locations = $locations | Where-Object {
            return $_.DisplayName -in $regions
        }
    }
    return $locations
}

# Update resource group tags
Function Set-ResourceGroupTags() {
    Param(
        [Parameter(Mandatory=$true)] [string] $rgName,
        [Parameter(Mandatory=$true)] [string] $state,
        [string] $version
    )
    $resourceGroup = Get-AzResourceGroup -ResourceGroupName $rgName
    if (!$resourceGroup) {
        return
    }
    $tags = $resourceGroup.Tags
    if (!$tags) {
        $tags = @{}
    }
    $update = $false
    if (![string]::IsNullOrEmpty($state)) {
        if ($tags.ContainsKey("IoTSuiteState")) {
            if ($tags.IoTSuiteState -ne $state) {
                $tags.IoTSuiteState = $state
                $update = $true
            }
        }
        else {
            $tags += @{ "IoTSuiteState" = $state }
            $update = $true
        }
    }
    if (![string]::IsNullOrEmpty($version)) {
        if ($tags.ContainsKey("IoTSuiteVersion")) {
            if ($tags.IoTSuiteVersion -ne $version) {
                $tags.IoTSuiteVersion = $version
                $update = $true
            }
        }
        else {
            $tags += @{ "IoTSuiteVersion" = $version }
            $update = $true
        }
    }
    $type = "AzureIndustrialIoT"
    if ($tags.ContainsKey("IoTSuiteType")) {
        if ($tags.IoTSuiteType -ne $type) {
            $tags.IoTSuiteType = $type
            $update = $true
        }
    }
    else {
        $tags += @{ "IoTSuiteType" = $type }
        $update = $true
    }
    if (!$update) {
        return
    }
    $resourceGroup = Set-AzResourceGroup -Name $rgName -Tag $tags
}

# Get env file content from deployment
Function Get-EnvironmentVariables() {
    Param(
        [Parameter(Mandatory=$true)] [string] $rgName,
        [Parameter(Mandatory=$true)] [object] $deployment
    )
    $var = $rgName
    if (![string]::IsNullOrEmpty($rgName)) {
        Write-Output "PCS_RESOURCE_GROUP=$($srgName)"
    }
    $var = $deployment.Outputs["keyVaultUri"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_KEYVAULT_URL=$($var)"
    }
    $var = $deployment.Outputs["clientAppId"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_AUTH_PUBLIC_CLIENT_APPID=$($var)"
    }
    $var = $deployment.Outputs["tenantId"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_AUTH_TENANT=$($var)"
    }
    $var = $deployment.Outputs["serviceUrl"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_SERVICE_URL=$($var)"
    }
}

# -------------------------------------------------------------------------------
$templateParameters = @{ }

# Select branch component - default to master
$branchName = $env:BUILD_SOURCEBRANCH
if (![string]::IsNullOrEmpty($branchName)) {
    if ($branchName.StartsWith("refs/heads/")) {
        $branchName = $branchName.Replace("refs/heads/", "")
    }
    else {
        # try git
        $branchName = $null
    }
}
# Try to use git to get a branch name and repo to deploy from 
if ([string]::IsNullOrEmpty($branchName)) {
    try {
        $argumentList = @("rev-parse", "--abbrev-ref", "@{upstream}")
        $symbolic = (& "git" $argumentList 2>&1 | ForEach-Object { "$_" });
        if ($LastExitCode -ne 0) {
            throw "git $($argumentList) failed with $($LastExitCode)."
        }
        $remote = $symbolic.Split('/')[0]
        $argumentList = @("remote", "get-url", $remote)
        $branchName = $symbolic.Replace("$($remote)/", "")
        if ($branchName -eq "HEAD") {
            Write-Warning "$($symbolic) is not a branch - using master."
            $branchName = "master"
        }
    }
    catch {
        # use the repo url -as is-
        $branchName = $null
    }
}
if (![string]::IsNullOrEmpty($branchName) -and
    ([string]::IsNullOrEmpty($script:SourceUri))) {
    # deploy from the named branch on github
    $script:SourceUri = "https://raw.githubusercontent.com/Azure/Industrial-IoT"
}

# Select version of the docker images to deploy 
if ([string]::IsNullOrEmpty($script:Version)) {
    if (![string]::IsNullOrEmpty($branchName) -and 
        ($branchName.StartsWith("release/"))) {
        $script:Version = $branchName.Replace("release/", "")
        # default docker server is mcr so no need to set it here
    }
    else {
        $script:Version = "preview"
        if ([string]::IsNullOrEmpty($script:DockerServer)) {
            $script:DockerServer = "industrialiotdev.azurecr.io"
        }
    }
}

Write-Host "Using '$($script:Version)' version..."
# Get or create new resource group for deployment
$first = $true
$resourceGroupName = $null
while ([string]::IsNullOrEmpty($resourceGroupName) `
        -or ($resourceGroupName -notmatch "^[a-z0-9-_]*$")) {
    if ($first -eq $false) {
        Write-Host "Use alphanumeric characters as well as '-' or '_'."
    }
    else {
        Write-Host
        Write-Host "Please provide a name for the resource group."
        $first = $false
    }
    $resourceGroupName = Read-Host -Prompt ">"
}

# Select application name
$applicationName = $null
if (($script:Type -eq "local") -or ($script:Type -eq "simulation")) {
    if ([string]::IsNullOrEmpty($applicationName) `
            -or ($applicationName -notmatch "^[a-z0-9-]*$")) {
        $applicationName = $resourceGroupName.Replace('_', '-')
    }
    if ($script:Type -eq "local") {
        $templateParameters.Add("deployOptionalServices", $true)
    }
}
else {
    if ($script:Type -eq "all") {
        $templateParameters.Add("deployOptionalServices", $true)
    }

    $first = $true
    while ([string]::IsNullOrEmpty($applicationName) `
            -or ($applicationName -notmatch "^[a-z0-9-]*$")) {
        if ($first -eq $false) {
            Write-Host "You can only use alphanumeric characters as well as '-'."
        }
        else {
            Write-Host
            Write-Host "Please specify a name for your application."
            $first = $false
        }
        if ($resourceGroupName -match "^[a-z0-9-]*$") {
            Write-Host "Hit enter to use $($resourceGroupName)."
        }
        $applicationName = Read-Host -Prompt ">"
        if ([string]::IsNullOrEmpty($applicationName)) {
            $applicationName = $resourceGroupName
        }
    }
}

Write-Host "... Using '$($applicationName)' as name for the deployment."
$templateParameters.Add("applicationName", $applicationName)

# Select source of the scripts and templates consumed during deployment
if (![string]::IsNullOrEmpty($branchName)) {
    Write-Host "... Deploying using artifacts in GitHub branch '$($branchName)' at '$($script:SourceUri)'."
    $script:SourceUri = "$($script:SourceUri)/$($branchName)"
}
else {
    # deploy from storage account
    Write-Host "... Deploying using artifacts from '$($script:SourceUri)'."
}
$templateUrl = "$($script:SourceUri)/deploy/templates/";
$templateParameters.Add("templateUrl", $templateUrl)

# Select containers to deploy and where from.
if ($script:Type -ne "local") {
    if (![string]::IsNullOrEmpty($script:Version)) {
        $templateParameters.Add("imagesTag", $script:Version)
    }
    if (![string]::IsNullOrEmpty($script:DockerServer)) {
        $templateParameters.Add("dockerServer", $script:DockerServer)
    }
    Write-Host "... Deploying $($script:Version) tagged containers from $($script:DockerServer)."
}
else {
    Write-Host "... Local development deployment - no containers will be deployed."
}
if (($script:Type -eq "local") -or ($script:Type -eq "simulation")) {
    $templateParameters.Add("deployPlatformComponents", $false)
}
else {
    $templateParameters.Add("deployPlatformComponents", $true)
    Write-Host "... Deploying platform using Helm chart."
}

# Configure simulation
if ($script:Type -eq "simulation") {
    if ([string]::IsNullOrEmpty($script:SimulationProfile)) {
        $script:SimulationProfile = "default"
    }
    if ((-not $script:NumberOfLinuxGateways) -or `
        ($script:NumberOfLinuxGateways -eq 0)) {
        $script:NumberOfLinuxGateways = 1
    }
    if ((-not $script:NumberOfWindowsGateways) -or `
        ($script:NumberOfWindowsGateways -eq 0)) {
        $script:NumberOfWindowsGateways = 1
    }
    if ((-not $script:NumberOfSimulationsPerEdge) -or `
        ($script:NumberOfSimulationsPerEdge -eq 0)) {
        $script:NumberOfSimulationsPerEdge = 1
    }

    $templateParameters.Add("simulationProfile", $script:SimulationProfile)
    $templateParameters.Add("numberOfLinuxGateways", $script:NumberOfLinuxGateways)
    $templateParameters.Add("numberOfWindowsGateways", $script:NumberOfWindowsGateways)
    $templateParameters.Add("numberOfSimulations", $script:NumberOfSimulationsPerEdge)
    Write-Host "... Deploying simulation."
}

# -------------------------------------------------------------------------------

# Log in - allow user to switch subscription
Write-Host "Preparing deployment..."
$context = Connect-ToAzure -EnvironmentName $script:EnvironmentName `
    -TenantId $script:TenantId -SwitchSubscription
$script:TenantId = $context.Tenant.Id
$subscriptionName = $context.Subscription.Name
$subscriptionId = $context.Subscription.Id
Write-Host "... Subscription $subscriptionName ($subscriptionId) selected."

# Create resource group
$resourceGroupLocation = $null
$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName `
    -ErrorAction SilentlyContinue
if (!$resourceGroup) {
    # Filter resource namespaces
    $locations = Get-AzLocation | Where-Object {
        foreach ($provider in $script:requiredProviders) {
            if ($_.Providers -notcontains $provider) {
                return $false
            }
        }
        return $true
    }

    # Filter resource types - TODO read parameters from table
    $locations = Select-ResourceGroupLocations -locations $locations `
        -provider "microsoft.devices" -typeName "provisioningServices"
    $locations = Select-ResourceGroupLocations -locations $locations `
        -provider "microsoft.insights" -typeName "components"

    Write-Host "Please choose a location for your deployment from this list (using its Index):"
    $script:index = 0
    $locations | Format-Table -AutoSize -property `
    @{Name = "Index"; Expression = { ($script:index++) } }, `
    @{Name = "Location"; Expression = { $_.DisplayName } } `
    | Out-Host
    while ($true) {
        $option = Read-Host -Prompt ">"
        try {
            if ([int]$option -ge 1 -and [int]$option -le $locations.Count) {
                break
            }
        }
        catch {
            Write-Host "Invalid index '$($option)' provided."
        }
        Write-Host "Choose from the list using an index between 1 and $($locations.Count)."
    }
    $resourceGroupLocation = $locations[$option - 1].Location
    $resourceGroup = New-AzResourceGroup -Name $resourceGroupName `
        -Location $resourceGroupLocation
    Write-Host `
        "... Created new resource group $($resourceGroupName) in $($resourceGroup.Location)."
    Set-ResourceGroupTags -rgName $resourceGroupName -state "Created"
    $script:deleteOnErrorPrompt = $True
}
else {
    Set-ResourceGroupTags -rgName $resourceGroupName -state "Updating"
    $resourceGroupLocation = $resourceGroup.Location
    Write-Host "... Using existing resource group $($resourceGroupName)..."
    $script:deleteOnErrorPrompt = $False
}

# Configure simulation VM sizes based on what is available in subscription
if ($script:Type -eq "simulation") {

    # Get all vm skus available in the location and in the account
    $availableVms = Get-AzComputeResourceSku | Where-Object {
        ($_.ResourceType.Contains("virtualMachines")) -and `
        ($_.Locations -icontains $resourceGroupLocation) -and `
        ($_.Restrictions.Count -eq 0)
    }
    # Sort based on sizes and filter minimum requirements
    $availableVmNames = $availableVms  | Select-Object -ExpandProperty Name -Unique
    # We will use VM with at least 2 cores and 8 GB of memory as gateway host.
    $edgeVmSizes = Get-AzVMSize $resourceGroupLocation `
    | Where-Object { $availableVmNames -icontains $_.Name } `
    | Where-Object {
        ($_.NumberOfCores -ge 2) -and `
        ($_.MemoryInMB -ge 8192) -and `
        ($_.OSDiskSizeInMB -ge 1047552) -and `
        ($_.ResourceDiskSizeInMB -gt 8192)
    } `
    | Sort-Object -Property `
        NumberOfCores, MemoryInMB, ResourceDiskSizeInMB, Name
    # Pick top
    if ($edgeVmSizes.Count -ne 0) {
        $edgeVmSize = $edgeVmSizes[0].Name
        Write-Host "... Using $($edgeVmSize) as VM size for all edge simulation gateway hosts..."
        $templateParameters.Add("edgeVmSize", $edgeVmSize)
    }

    # We will use VM with at least 1 core and 2 GB of memory for hosting PLC simulation containers.
    $simulationVmSizes = Get-AzVMSize $resourceGroupLocation `
    | Where-Object { $availableVmNames -icontains $_.Name } `
    | Where-Object {
        ($_.NumberOfCores -ge 1) -and `
        ($_.MemoryInMB -ge 2048) -and `
        ($_.OSDiskSizeInMB -ge 1047552) -and `
        ($_.ResourceDiskSizeInMB -ge 4096)
    } `
    | Sort-Object -Property `
        NumberOfCores, MemoryInMB, ResourceDiskSizeInMB, Name
    # Pick top
    if ($simulationVmSizes.Count -ne 0) {
        $simulationVmSize = $simulationVmSizes[0].Name
        Write-Host "... Using $($simulationVmSize) as VM size for all edge simulation hosts..."
        $templateParameters.Add("simulationVmSize", $simulationVmSize)
    }
}

# Configure aad registration
if (!$script:AadPreConfiguration) {
    $msi = & (Join-Path $script:ScriptDir "create-sp.ps1") -Context $context `
        -Name "deploy_aad_msi" -ResourceGroup $resourceGroupName  `
        -Location $resourceGroupLocation -Subscription $subscriptionId
    if ([string]::IsNullOrWhiteSpace($msi.aadPrincipalId)) {
        Write-Error "Failed to create managed service identity for application registration."
        throw $($msi | ConvertTo-Json)
    }
    $templateParameters.Add("aadPrincipalId", $msi.aadPrincipalId)
}
elseif (($script:AadPreConfiguration -is [string]) -and (Test-Path $script:AadPreConfiguration)) {
    # read configuration from file
    $script:AadPreConfiguration = Get-Content -Raw -Path $script:AadPreConfiguration `
        | ConvertFrom-Json
    $templateParameters.Add("aadPreConfiguration", $script:AadPreConfiguration)
}

# Add IoTSuiteType tag. This tag will be applied for all resources.
$tags = @{"IoTSuiteType" = "AzureIndustrialIoT-$($script:Version)-PS1" }
$templateParameters.Add("tags", $tags)

if ($script:dumpTemplateParameterJson) {
    return $templateParameters
}
else {
    Write-Host "The following template parameters will be used:"
    $templateParameters
}

# Update tags to show deploying
Set-ResourceGroupTags -rgName $resourceGroupName -state "Deploying" -version $branchName

# -------------------------------------------------------------------------------

# Do the deployment
$script:requiredProviders | ForEach-Object { `
    $ns = $_
    Write-Host "... Registering $ns..."
    Register-AzResourceProvider -ProviderNamespace $ns `
} | Out-Null
while ($true) {
    try {
        Write-Host "Starting deployment..."

        $StartTime = $(Get-Date)
        Write-Host "... Start time: $($StartTime.ToShortTimeString())"

        # Start the deployment from template Url
        $deployment = New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
            -TemplateUri "$($templateUrl)azuredeploy.json" `
            -DeploymentDebugLogLevel All `
            -SkipTemplateParameterPrompt -TemplateParameterObject $templateParameters
        if ($deployment.ProvisioningState -ne "Succeeded") {
            Set-ResourceGroupTags -rgName $resourceGroupName -state "Failed"
            throw "Deployment $($deployment.ProvisioningState)."
        }

        Set-ResourceGroupTags -rgName $resourceGroupName -state "Complete"
  
        $elapsedTime = $(Get-Date) - $StartTime
        Write-Host "... Elapsed time (hh:mm:ss): $($elapsedTime.ToString("hh\:mm\:ss"))" 

        Write-Host "Deployment succeeded."

        # Create environment file
        $rootDir = Get-RootFolder $script:ScriptDir
        $writeFile = $false
        $ENVVARS = Join-Path $rootDir ".env"
        $prompt = "Save environment as $ENVVARS for local development? [y/n]"
        $reply = Read-Host -Prompt $prompt
        if ($reply -match "[yY]") {
            $writeFile = $true
        }
        if ($writeFile) {
            if (Test-Path $ENVVARS) {
                $prompt = "Overwrite existing .env file in $rootDir? [y/n]"
                if ($reply -match "[yY]") {
                    Remove-Item $ENVVARS -Force
                }
                else {
                    $writeFile = $false
                }
            }
        }

        if ($writeFile) {
            Get-EnvironmentVariables -rgName $resourceGroupName `
                -deployment $deployment | Out-File -Encoding ascii -FilePath $ENVVARS
            Write-Host
            Write-Host ".env file created in $rootDir."
            Write-Host
            Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Warning "!The file contains security keys to your Azure resources!"
            Write-Warning "! Safeguard the contents of this file, or delete it now !"
            Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Host
        }
        else {
            Get-EnvironmentVariables -rgName $resourceGroupName `
                -deployment $deployment | Out-Default
        }
        return
    }
    catch {
        $ex = $_
        Write-Host $_.Exception.Message
        Write-Host "Deployment failed."

        $deleteResourceGroup = $false
        $retry = Read-Host -Prompt "Try again? [y/n]"
        if ($retry -match "[yY]") {
            continue
        }
        if ($script:deleteOnErrorPrompt) {
            $reply = Read-Host -Prompt "Delete resource group? [y/n]"
            $deleteResourceGroup = ($reply -match "[yY]")
        }
        if ($deleteResourceGroup) {
            try {
                Write-Host "Removing resource group $($resourceGroupName)..."
                Remove-AzResourceGroup -ResourceGroupName $resourceGroupName -Force
            }
            catch {
                Write-Warning $_.Exception.Message
            }
        }
        throw $ex
    }
}
# -------------------------------------------------------------------------------
