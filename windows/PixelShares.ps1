# Temporary Pixel SMB shares used by both Windows pickers.
function Get-PixelSessionShares {
    Get-SmbShare -IncludeHidden -ErrorAction Stop | Where-Object {
        $_.Name -imatch '^PixelBackup(?:Data|Plan)?-[0-9a-f]{32}$'
    }
}

function New-PixelShareRegistration([string]$Name, [string]$Path) {
    $label = if ($Name.StartsWith('PixelBackup-')) { 'PixelBackup picker ' } else { 'PixelBackup session ' }
    [pscustomobject]@{
        Name = $Name
        Path = $Path
        Scope = '*'
        Tag = $label + [guid]::NewGuid().ToString('N')
    }
}

function Open-PixelReadShare($Registration, [string]$Account) {
    $published = New-SmbShare -Name $Registration.Name -Path $Registration.Path -ReadAccess $Account `
        -Temporary -CachingMode None -Description $Registration.Tag -ErrorAction Stop
    $Registration.Scope = $published.ScopeName
    $actual = @(Get-PixelSessionShares | Where-Object {
        $_.Name -eq $Registration.Name -and $_.ScopeName -eq $Registration.Scope
    })
    if ($actual.Count -ne 1 -or $actual[0].Path -ne $Registration.Path -or
        $actual[0].Description -cne $Registration.Tag -or -not $actual[0].Temporary -or $actual[0].CachingMode -ne 'None') {
        throw "Windows could not verify the temporary share $($Registration.Name)."
    }
    $access = @(Get-SmbShareAccess -InputObject $actual[0] -ErrorAction Stop)
    if ($access.Count -ne 1 -or $access[0].AccountName -ne $Account -or
        $access[0].AccessControlType -ne 'Allow' -or $access[0].AccessRight -ne 'Read') {
        throw "Windows reported unexpected access permissions for $($Registration.Name)."
    }
    $actual[0]
}

function Close-PixelReadShare($Registration) {
    $candidates = @(Get-PixelSessionShares | Where-Object Name -eq $Registration.Name)
    if (-not $candidates.Count) { return }
    $ours = @($candidates | Where-Object {
        $_.ScopeName -eq $Registration.Scope -and $_.Path -eq $Registration.Path -and $_.Description -ceq $Registration.Tag
    })
    if ($ours.Count -eq 1) { Remove-SmbShare -InputObject $ours[0] -Force -ErrorAction Stop }
    if (Get-PixelSessionShares | Where-Object Name -eq $Registration.Name) {
        throw "A share named $($Registration.Name) remains. Inspect its scope, path and description in Get-SmbShare."
    }
}
