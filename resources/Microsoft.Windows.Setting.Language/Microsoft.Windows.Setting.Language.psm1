# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

using namespace System.Collections.Generic

function Test-LanguagePackAvailability {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Language
    )

    # Do not rely on Get-WindowsCapability as it requires elevation + it can take time to run
    $languagePacks = Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty MUILanguages

    if ($null -eq $languagePacks) {
        return $false
    }

    if ($languagePacks -notcontains $Language) {
        return $false
    }

    return $true
}

function Test-UserLanguageList {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Language
    )

    $localeList = Get-WinUserLanguageList

    if ($null -eq $localeList) {
        return $false
    }

    if ($localeList.LanguageTag -notcontains $Language) {
        return $false
    }

    return $false
}

function Get-LanguageList {
    $languageList = Get-Language
    $out = [List[Language]]::new()

    foreach ($language in $languageList) {
        $language = [Language]::new($language.LanguageId, $true)
        $out.Add($language)
    }

    return $out
}
#endregion Functions

#region Classes
<#
.SYNOPSIS
    The `Language` DSC Resource allows you to install, update, and uninstall languages on your local Windows machine.

.PARAMETER LocaleName
    The name of the language. This is the language tag that represents the language. For example, `en-US` represents English (United States).
    To get a full list of languages available, use the `Get-LocaleList` function or Export() method.

.PARAMETER Exist
    Indicates whether the package should exist. Defaults to $true.

.EXAMPLE
    PS C:\> Invoke-DscResource -ModuleName Microsoft.Windows.Setting.Language -Name Language -Method Set -Property @{ LocaleName = 'en-US' }

    This example installs the English (United States) language on the local machine.
#>
[DscResource()]
class Language {
    [DscProperty(Key)]
    [string] $LanguageId

    [DscProperty()]
    [bool] $Exist = $true

    static [hashtable] $InstalledLanguages

    Language() {
        [Language]::GetInstalledLanguages()
    }

    Language([string] $LanguageId, [bool] $Exist) {
        $this.LanguageId = $LanguageId
        $this.Exist = $Exist
    }

    [Language] Get() {
        $currentState = [Language]::InstalledLanguages[$this.LanguageId]

        if ($null -ne $currentState) {
            return $currentState
        }

        return @{
            LanguageId = $this.LanguageId
            Exist      = $false
        }
    }

    [void] Set() {
        if ($this.Test()) {
            return
        }

        if ($this.Exist) {
            # use the LanguagePackManagement module to install the language (requires elevation). International does not have a cmdlet to install language
            Install-Language -Language $this.LanguageId
        } else {
            Uninstall-Language -Language $this.LanguageId
        }
    }

    [bool] Test() {
        $currentState = $this.Get()

        if ($currentState.Exist -ne $this.Exist) {
            return $false
        }

        return $true
    }

    static [Language[]] Export() {
        return Get-LanguageList
    }

    #region Language helper functions
    static [void] GetInstalledLanguages() {
        [Language]::InstalledLanguages = @{}

        foreach ($language in [Language]::Export()) {
            [Language]::InstalledLanguages[$language.LanguageId] = $language
        }
    }
    #endRegion Language helper functions
}

<#
.SYNOPSIS
    The `DisplayLanguage` DSC Resource allows you to set the display language on your local Windows machine.

.PARAMETER LocaleName
    The name of the display language. This is the language tag that represents the language. For example, `en-US` represents English (United States).

.PARAMETER Exist
    Indicates whether the display language should be set. Defaults to $true.

.EXAMPLE
    PS C:\> Invoke-DscResource -ModuleName Microsoft.Windows.Setting.Language -Name DisplayLanguage -Method Set -Property @{ LocaleName = 'en-US' }

    This example sets the display language to English (United States) on the user.
#>
[DscResource()]
class DisplayLanguage {

    [DscProperty(Key)]
    [string] $LocaleName

    [DscProperty()]
    [bool] $Exist = $true

    hidden [string] $KeyName = 'LocaleName'

    DisplayLanguage() {
        # Don't rely on the registry key to determine the current display language nor the user locale
        $this.LocaleName = (Get-WinSystemLocale).Name
        $this.Exist = $true
    }

    [DisplayLanguage] Get() {
        $currentState = [DisplayLanguage]::new()

        if ($currentState.LocaleName -ne $this.LocaleName) {
            $currentState.Exist = $false
        }

        return $currentState
    }

    [void] Set() {
        if ($this.Test()) {
            return
        }

        if (Test-LanguagePackAvailability -Language $this.LocaleName) {
            if (-not (Test-UserLanguageList)) {
                # The language is installed through different means
                # To reflect the language in the immersive control panel, we need to add it to the user language list
                $existingList = Get-WinUserLanguageList
                $existingList.Add($this.LocaleName)
                Set-WinUserLanguageList -LanguageList $existingList
            }
            Set-WinUILanguageOverride -Language $this.LocaleName -Force
        }
    }

    [bool] Test() {
        $currentState = $this.Get()

        if ($currentState.Exist -ne $this.Exist) {
            return $false
        }

        return $true
    }
}

[DscResource()]
class Region {
    [DscProperty(Key)]
    [string] $GeoId

    [DscProperty(NotConfigurable)]
    [string] $HomeLocation

    [DscProperty()]
    [bool] $Exist = $true

    Region() {
        # Get the current region settings
        $region = Get-WinHomeLocation

        # Set the properties
        $this.GeoId = $region.GeoId
        $this.HomeLocation = $region.HomeLocation
        $this.Exist = $true
    }

    [Region] Get() {
        $currentState = [Region]::new()

        if ($currentState.GeoId -ne $this.GeoId) {
            $currentState.Exist = $false
        }

        return $currentState
    }

    [void] Set() {
        if ($this.Test()) {
            return
        }
        Set-WinHomeLocation -GeoId $this.GeoId -Force
    }

    [bool] Test() {
        $currentState = $this.Get()

        if ($currentState.Exist -ne $this.Exist) {
            return $false
        }

        return $true
    }
}
#endRegion classes
