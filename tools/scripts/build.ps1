<#
 .SYNOPSIS
  Builds docker images from definition files in folder or the entire 
  tree into a container registry.

 .DESCRIPTION
  The script traverses the build root to find all folders with an 
  container.json file builds each one.

  If resource group or registry name is provided, creates or uses the 
  container registry in the resource group to build with. In this case
  you must use az login first to authenticate to azure.

 .PARAMETER Path
  The root folder to start traversing the repository from (Optional).

 .PARAMETER ResourceGroupName
  The name of the resource group to create (Optional).
 .PARAMETER ResourceGroupLocation
  The location of the resource group to create (Optional).
 .PARAMETER Subscription
  The subscription to use (Optional).

 .PARAMETER Debug
  Whether to build debug images.
#>

Param(
    [string] $Path = $null,
    [string] $ResourceGroupName = "testgroup3",
    [string] $ResourceGroupLocation = $null,
    [string] $Subscription = $null,
    [switch] $Debug
)

$startTime = $(Get-Date)
$BuildRoot = & (Join-Path $PSScriptRoot "get-root.ps1") -fileName "*.sln"
if ([string]::IsNullOrEmpty($script:Path)) {
    $script:Path = $BuildRoot
}

$registry = $null
if (![string]::IsNullOrEmpty($script:ResourceGroupName)) {
    # set default subscription if needed
    if (![string]::IsNullOrEmpty($script:Subscription)) {
        Write-Debug "Setting subscription to $($script:Subscription)"
        $argumentList = @("account", "set", "--subscription", $script:Subscription)
        & "az" $argumentList 2>&1 | ForEach-Object { Write-Host "$_" }
        if ($LastExitCode -ne 0) {
            throw "az $($argumentList) failed with $($LastExitCode)."
        }
    }

    # check if group exists and if not create it.
    $argumentList = @("group", "show", "-g", $script:ResourceGroupName)
    $group = & "az" $argumentList 2>$null | ConvertFrom-Json
    if (!$group) {
        if ([string]::IsNullOrEmpty($script:ResourceGroupLocation)) {
            throw "Need a resource group location to create the resource group."
        }
        $argumentList = @("group", "create", "-g", $script:ResourceGroupName, `
            "-l", $script:ResourceGroupLocation)
        $group = & "az" $argumentList | ConvertFrom-Json
        if ($LastExitCode -ne 0) {
            throw "az $($argumentList) failed with $($LastExitCode)."
        }
        Write-Host "Created new Resource group $ResourceGroupName."
    }
    if ([string]::IsNullOrEmpty($script:ResourceGroupLocation)) {
        $script:ResourceGroupLocation = $group.location
    }
    # check if acr exist and if not create it
    $argumentList = @("acr", "list", "-g", $script:ResourceGroupName)
    $registries = & "az" $argumentList 2>$null | ConvertFrom-Json
    $registry = if ($registries) { $registries[0] } else { $null }
    if (!$registry) {
        $argumentList = @("acr", "create", "-g", $script:ResourceGroupName, "-n", `
            "acr$script:ResourceGroupName", "-l", $script:ResourceGroupLocation, `
            "--sku", "Basic", "--admin-enabled", "true")
        $registry = & "az" $argumentList | ConvertFrom-Json
        if ($LastExitCode -ne 0) {
            throw "az $($argumentList) failed with $($LastExitCode)."
        }
        Write-Host "Created new Container registry in $ResourceGroupName."
    }
    else {
        Write-Host "Using Container registry $($registry.name)."
    }

    $argumentList = @("acr", "credential", "show", "--name", $registry.name)
    $credentials = (& "az" $argumentList 2>&1 | ForEach-Object { "$_" }) `
        | ConvertFrom-Json
    if ($LastExitCode -ne 0) {
        throw "az $($argumentList) failed with $($LastExitCode)."
    }
    $user = $credentials.username
    $password = $credentials.passwords[0].value

    # now first upload helm chart to the registry if helm is installed
    if ($script:Path -eq $BuildRoot) {
        $chartName = "azure-industrial-iot"
        $folder = join-path (join-path (join-path $BuildRoot "deploy") "helm") `
            $chartName
        $chart = "$($registry.loginServer)/$($chartName):preview"
        $env:HELM_EXPERIMENTAL_OCI = 1
        $argumentList = @("chart", "save", $folder, $chart)
        & "helm" $argumentList 2>$null
        if ($LastExitCode -ne 0) {
            throw "Failed to save Helm chart $chart as image locally."
        }
        $argumentList = @("registry", "login", $registry.loginServer, `
            "-u", $user, "--password-stdin")
        $password | & "helm" $argumentList  2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            throw "Failed to log into the registry using Helm."
        }
        $argumentList = @("chart", "push", $chart)
        & "helm" $argumentList  2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            throw "Failed to upload Helm chart $chart."
        }
        Write-Host "Helm chart $chart uploaded to $($registry.name) registry."
    }
}

# Traverse from build root and find all container.json metadata files and build
Get-ChildItem $script:Path -Recurse -Include "container.json" `
    | ForEach-Object {

    # Get root
    $dockerFolder = $_.DirectoryName.Replace($BuildRoot, "")
    if (![string]::IsNullOrEmpty($dockerFolder)) {
        $dockerFolder = $dockerFolder.Substring(1)
    }
    $metadata = Get-Content -Raw -Path (join-path $_.DirectoryName "container.json") `
        | ConvertFrom-Json
    if ($metadata) {
        # See if we should build into registry, otherwise build local docker images
        if ($registry) {
            & (Join-Path $PSScriptRoot "acr-build.ps1") -Path $dockerFolder `
                -Debug:$Debug -Registry $registry.name -Fast
        }
        else {
            if ([string]::IsNullOrEmpty($dockerFolder)) {
                $dockerFolder = "."
            }
            & (Join-Path $PSScriptRoot "docker-build.ps1") `
                -ImageName $metadata.name -Path $dockerFolder -Debug:$Debug
        }
    }
}

$elapsedTime = $(Get-Date) - $startTime
Write-Host "Build took $($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)" 
