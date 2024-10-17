# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

#region Functions
function Get-DotNetPath
{
    if ($IsWindows)
    {
        $dotNetPath = "$env:ProgramFiles\dotnet\dotnet.exe"
        if (-not (Test-Path $dotNetPath))
        {
            $dotNetPath = "${env:ProgramFiles(x86)}\dotnet\dotnet.exe"
            if (-not (Test-Path $dotNetPath))
            {
                throw "dotnet.exe not found in Program Files or Program Files (x86)"
            }
        }
    }
    elseif ($IsMacOS)
    {
        $dotNetPath = "/usr/local/share/dotnet/dotnet"
        if (-not (Test-Path $dotNetPath))
        {
            $dotNetPath = "/usr/local/bin/dotnet"
            if (-not (Test-Path $dotNetPath))
            {
                throw "dotnet not found in /usr/local/share/dotnet or /usr/local/bin"
            }
        }
    }
    elseif ($IsLinux)
    {
        $dotNetPath = "/usr/share/dotnet/dotnet"
        if (-not (Test-Path $dotNetPath))
        {
            $dotNetPath = "/usr/bin/dotnet"
            if (-not (Test-Path $dotNetPath))
            {
                throw "dotnet not found in /usr/share/dotnet or /usr/bin"
            }
        }
    }
    else
    {
        throw "Unsupported operating system"
    }

    Write-Verbose -Message "'dotnet' found at $dotNetPath"
    return $dotNetPath
}

function Get-DotNetToolArguments
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $PackageId,
        [Parameter(Mandatory = $false)]
        [string] $Version,
        [Parameter(Mandatory = $false)]
        [bool]   $PreRelease,
        [Parameter(Mandatory = $false)]
        [string] $ToolPathDirectory,
        [bool]   $Exist,
        [switch] $Downgrade
    )

    $arguments = @($PackageId)

    if (-not ($PSBoundParameters.ContainsKey("ToolPathDirectory")))
    {
        $arguments += "--global"
    }

    if ($PSBoundParameters.ContainsKey("Prerelease") -and $PSBoundParameters.ContainsKey("Version"))
    {
        # do it with version instead of pre
        $null = $PSBoundParameters.Remove("Prerelease")
    }

    # mapping table of command line arguments
    $mappingTable = @{
        Version           = "--version {0}"
        PreRelease        = "--prerelease"
        ToolPathDirectory = "--tool-path {0}"
        Downgrade         = '--allow-downgrade'
    }
    
    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        if ($mappingTable.ContainsKey($_.Key)) 
        {
            if ($_.Value -ne $false -and -not (([string]::IsNullOrEmpty($_.Value))))
            {
                $arguments += ($mappingTable[$_.Key] -f $_.Value)
            }
        }
    }

    return ($arguments -join " ")
}

# TODO: when https://github.com/dotnet/sdk/pull/37394 is documented and version is released with option simple use --format=JSON

function Convert-DotNetToolOutput
{
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [string[]] $Output
    )

    process
    {
        # Split the output into lines
        $lines = $Output | Select-Object -Skip 2

        # Initialize an array to hold the custom objects
        $inputObject = @()

        # Skip the header lines and process each line
        foreach ($line in $lines)
        {
            # Split the line into columns
            $columns = $line -split '\s{2,}'

            # Create a custom object for each line
            $customObject = [PSCustomObject]@{
                PackageId = $columns[0]
                Version   = $columns[1]
                Commands  = $columns[2]
            }

            # Add the custom object to the array
            $inputObject += $customObject
        }

        return $inputObject
    }
}

function Get-InstalledDotNetToolPackages
{
    [CmdletBinding()]
    param (
        [string] $PackageId,
        [string] $Version,
        [bool]   $PreRelease,
        [Parameter(Mandatory = $false)]
        [ValidateScript({
                if (-Not ($_ | Test-Path -PathType Container) )
                {
                    throw "Directory does not exist" 
                }
                return $true
            })]
        [string] $ToolPathDirectory,
        [bool]   $Exist
    )

    $resultSet = [System.Collections.Generic.List[DotNetToolPackage]]::new()
    $listCommand = "tool list --global"
    $installDir = Join-Path -Path $env:USERPROFILE '.dotnet' 'tools'

    if ($PSBoundParameters.ContainsKey('ToolPathDirectory'))
    {
        $listCommand = "tool list --tool-path $ToolPathDirectory"
        $installDir = $ToolPathDirectory
    }

    $result = Invoke-DotNet -Command $listCommand
    $packages = Convert-DotNetToolOutput -Output $result

    if ($null -eq $packages)
    {
        Write-Debug -Message "No packages found."
        return
    }

    if (-not [string]::IsNullOrEmpty($PackageId))
    {
        $packages = $packages | Where-Object { $_.PackageId -eq $PackageId }
    }

    foreach ($package in $packages)
    {
        # flags to determine the existence of the package
        $isPrerelease = $false
        $preReleasePackage = $package.Version -Split "-"
        if ($preReleasePackage.Count -gt 1)
        {
            # set the pre-release flag to true to build the object
            $isPrerelease = $true
        }

        $resultSet.Add([DotNetToolPackage]::new(
                $package.PackageId, $package.Version, $package.Commands, $isPrerelease, $installDir, $true
            ))
    }

    return $resultSet
}

function Get-SemVer($version)
{
    $version -match "^(?<major>\d+)(\.(?<minor>\d+))?(\.(?<patch>\d+))?(\-(?<pre>[0-9A-Za-z\-\.]+))?(\+(?<build>[0-9A-Za-z\-\.]+))?$" | Out-Null
    $major = [int]$matches['major']
    $minor = [int]$matches['minor']
    $patch = [int]$matches['patch']
    
    if ($null -eq $matches['pre']) { $pre = @() }
    else { $pre = $matches['pre'].Split(".") }

    $revision = 0
    if ($pre.Length -gt 1)
    {
        $revision = Get-HighestRevision -InputArray $pre
    }

    return [version]$version = "$major.$minor.$patch.$revision" 
}

function Get-HighestRevision
{
    param (
        [Parameter(Mandatory = $true)]
        [array]$InputArray
    )

    # Filter the array to keep only integers
    $integers = $InputArray | ForEach-Object {
        $_ -as [int]
    }

    # Return the highest integer
    if ($integers.Count -gt 0)
    {
        return ($integers | Measure-Object -Maximum).Maximum
    }
    else
    {
        return $null
    }
}

function Install-DotNetToolPackage
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $PackageId,
        [string] $Version,
        [bool]   $PreRelease,
        [string] $ToolPathDirectory,
        [bool]   $Exist
    )

    $installArgument = Get-DotNetToolArguments @PSBoundParameters
    $arguments = "tool install $installArgument --ignore-failed-sources"
    Write-Verbose -Message "Installing dotnet tool package with arguments: $arguments"

    Invoke-DotNet -Command $arguments
}

function Update-DotNetToolPackage
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $PackageId,
        [string] $Version,
        [bool]   $PreRelease,
        [string] $ToolPathDirectory,
        [bool]   $Exist,
        [switch] $Downgrade
    )

    if ($Downgrade.IsPresent)
    {
        if (-not (Assert-DotNetToolDowngrade))
        {
            Throw "Downgrade is not supported in this version of dotnet tool. Please upgrade to a version that supports downgrade."
        }
    }

    $installArgument = Get-DotNetToolArguments @PSBoundParameters
    $arguments = "tool update $installArgument --ignore-failed-sources"
    Write-Verbose -Message "update dotnet tool package with arguments: $arguments"

    Invoke-DotNet -Command $arguments
}

function Assert-DotNetToolDowngrade
{
    [version]$version = Invoke-DotNet -Command '--version'

    if ($version.Build -lt 200)
    {
        return $false
    }

    return $true
}

function Uninstall-DotNetToolPackage
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $PackageId,
        [string] $ToolPathDirectory
    )

    $installArgument = Get-DotNetToolArguments @PSBoundParameters
    $arguments = "tool uninstall $installArgument" 
    Write-Verbose -Message "Uninstalling dotnet tool package with arguments: $arguments"
        
    Invoke-DotNet -Command $arguments
}

function Invoke-DotNet
{
    param (
        [Parameter(Mandatory = $true)]
        [string] $Command
    )

    try
    {
        Invoke-Expression "& `"$DotNetCliPath`" $Command"
    }
    catch
    {
        throw "Executing dotnet.exe with {$Command} failed."
    }
}

# Keeps the path of the code.exe CLI path.
$DotNetCliPath = Get-DotNetPath

#endregion Functions

#region Classes
<#
.SYNOPSIS
    This class is used to install and uninstall .NET SDK tools globally or use the tool path directory.
#>
[DSCResource()]
class DotNetToolPackage
{
    [DscProperty(Key)]
    [string] $PackageId

    [DscProperty()]
    [string] $Version

    [DscProperty()]
    [string[]] $Commands

    [DscProperty()]
    [bool] $Prerelease = $false

    [DscProperty()]
    [string] $ToolPathDirectory

    [DscProperty()]
    [bool] $Exist = $true

    static [hashtable] $InstalledPackages

    DotNetToolPackage()
    {
        [DotNetToolPackage]::GetInstalledPackages()
    }

    DotNetToolPackage([string] $PackageId, [string] $Version, [string[]] $Commands, [bool] $PreRelease, [string] $ToolPathDirectory, [bool] $Exist)
    {
        $this.PackageId = $PackageId
        $this.Version = $Version
        $this.Commands = $Commands
        $this.PreRelease = $PreRelease
        $this.ToolPathDirectory = $ToolPathDirectory
        $this.Exist = $Exist
    }

    [DotNetToolPackage] Get()
    {
        # get the properties of the object currently set
        $properties = $this.ToHashTable()

        # refresh installed packages
        [DotNetToolPackage]::GetInstalledPackages($properties)

        # current state
        $currentState = [DotNetToolPackage]::InstalledPackages[$this.PackageId]

        if ($null -ne $currentState)
        {
            if ($this.Version -and ($this.Version -ne $currentState.Version))
            {
                # See treatment: https://learn.microsoft.com/en-us/nuget/concepts/package-versioning?tabs=semver20sort#normalized-version-numbers
                # in this case, we misuse revision if beta,alpha, rc are present and grab the highest revision
                $installedVersion = Get-Semver -Version $currentState.Version
                $currentVersion = Get-Semver -Version $this.Version
                if ($currentVersion -gt $installedVersion -or $currentState -le $currentState)
                {
                    $currentState.Exist = $false
                }
            }

            return $currentState
        }
        
        return [DotNetToolPackage]@{
            PackageId         = $this.PackageId
            Version           = $this.Version
            Commands          = $this.Commands
            PreRelease        = $this.PreRelease
            ToolPathDirectory = $this.ToolPathDirectory
            Exist             = $false
        }
    }

    Set()
    {
        if ($this.Test())
        {
            return
        }

        $currentPackage = [DotNetToolPackage]::InstalledPackages[$this.PackageId]
        if ($currentPackage -and $this.Exist)
        {
            if ($this.Version -lt $currentPackage.Version)
            {
                $this.Downgrade($false)
            }
            else
            {
                $this.Upgrade($false)
            }
        }
        elseif ($this.Exist)
        {
            $this.Install($false)
        }
        else
        {
            $this.Uninstall($false)
        }
    }

    [bool] Test()
    {
        $currentState = $this.Get()
        if ($currentState.Exist -ne $this.Exist)
        {
            return $false
        }

        if ($null -ne $this.Version -or $this.Version -ne $currentState.Version -and $this.PreRelease -ne $currentState.PreRelease)
        {
            return $false
        }
        return $true
    }

    static [DotNetToolPackage[]] Export()
    {
        return [DotNetToolPackage]::Export(@{})
    }

    static [DotNetToolPackage[]] Export([hashtable] $filterProperties)
    {
        $packages = Get-InstalledDotNetToolPackages @filterProperties

        return $packages
    }

    #region DotNetToolPackage helper functions
    static [void] GetInstalledPackages()
    {   
        [DotNetToolPackage]::InstalledPackages = @{}

        foreach ($extension in [DotNetToolPackage]::Export())
        {
            [DotNetToolPackage]::InstalledPackages[$extension.PackageId] = $extension
        }
    }

    static [void] GetInstalledPackages([hashtable] $filterProperties)
    {   
        [DotNetToolPackage]::InstalledPackages = @{}

        foreach ($extension in [DotNetToolPackage]::Export($filterProperties))
        {
            [DotNetToolPackage]::InstalledPackages[$extension.PackageId] = $extension
        }
    }

    [void] Upgrade([bool] $preTest)
    {
        if ($preTest -and $this.Test())
        {
            return
        }

        $params = $this.ToHashTable()   

        Update-DotNetToolpackage @params
        [DotNetToolPackage]::GetInstalledPackages()
    }

    [void] Downgrade([bool] $preTest)
    {
        if ($preTest -and $this.Test())
        {
            return
        }

        $params = $this.ToHashTable()   
        $params.Add('Downgrade', $true)

        Update-DotNetToolpackage @params
        [DotNetToolPackage]::GetInstalledPackages()
    }

    [void] Install([bool] $preTest)
    {
        if ($preTest -and $this.Test())
        {
            return
        }

        $params = $this.ToHashTable()   

        Install-DotNetToolpackage @params
        [DotNetToolPackage]::GetInstalledPackages()
    }

    [void] Install()
    {
        $this.Install($true)
    }

    [void] Uninstall([bool] $preTest)
    {
        $params = $this.ToHashTable()

        $uninstallParams = @{
            PackageId = $this.PackageId
        }

        if ($params.ContainsKey('ToolPathDirectory'))
        {
            $uninstallParams.Add('ToolPathDirectory', $params['ToolPathDirectory'])
        }

        Uninstall-DotNetToolpackage @uninstallParams
        [DotNetToolPackage]::GetInstalledPackages()
    }

    [void] Uninstall()
    {
        $this.Uninstall($true)
    }

    [hashtable] ToHashTable()
    {
        $parameters = @{}
        foreach ($property in $this.PSObject.Properties)
        {
            if (-not ([string]::IsNullOrEmpty($property.Value)))
            {
                $parameters[$property.Name] = $property.Value
            }
        }

        return $parameters
    }
    #endregion DotNetToolPackage helper functions
}
#endregion Classes