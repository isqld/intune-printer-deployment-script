<#
    .SYNOPSIS
    Packages the drivers and install scripts found in the Package sub directory into a InTune Win32 install package

    .DESCRIPTION
    The Create_printerDeployment script create the install.cmd and remove.cmd files in the Package directory,
    then package the folder into a InTune Win32 package ready for deployment.

    .PARAMETER DriverName
    Specifies the driver that the new printer queue should use when it is created.

    .PARAMETER PrinterName
    Specifies the name that the new Printer queue should be created with.

    .PARAMETER PrinterHostAddress
    Specifies the IP address or FQDN that the printer can be found at.

    .CHANGELOG
    v1.0 - Initial release
    v1.1 - Added check in detection script to look for the correct driver name. This is to allow upgrading or 
            superseding existing printer installations in InTune.
#>
[CmdletBinding()]
param (
    [Parameter(
        Mandatory=$true)
    ]
    [string]$DriverName,

    [Parameter(
        Mandatory=$true)
    ]
    [string]$PrinterHostAddress,

    [Parameter(
        Mandatory=$true)
    ]
    [string]$PrinterName
)

#Define file names and urls that the script will use
$PackagePath = Join-Path -Path $PSScriptRoot -ChildPath "\Package"
$InstallFileName = "install.cmd"
$InstallFilePath = Join-Path -Path $PackagePath -ChildPath $InstallFileName
$RemoveFileName = "remove.cmd"
$RemoveFilePath = Join-Path -Path $PackagePath -ChildPath $RemoveFileName
$DetectionFilePath = Join-Path -Path $PSScriptRoot -ChildPath "Detect-Printer.ps1"
$IntunePrepTool = Join-Path -Path $PSScriptRoot -ChildPath "InTuneWinAppUtil.exe"

$Url = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe"

$InstallCmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -file .\Deploy-Printer.ps1 -DriverName `"$DriverName`" -PrinterName `"$PrinterName`" -PrinterHostAddress `"$PrinterHostAddress`""
$RemoveCmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -file .\Deploy-Printer.ps1 -PrinterName `"$PrinterName`" -Remove"

Write-Host "Creating the Install and Remove cmd files for the package"
Out-File -InputObject $Installcmd -Encoding Default -FilePath $InstallFilePath
Out-File -InputObject $Removecmd -Encoding Default -FilePath $RemoveFilePath

Write-Host "Creating the powershell detection script"
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append( '$RegKey = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Print\Printers\' )
[void]$sb.AppendLine( "$PrinterName`"" )
[void]$sb.Append( '$PrintDriverName = "')
[void]$sb.AppendLine( "$DriverName`"")
[void]$sb.AppendLine( '$Detected = Get-ItemProperty -Path $RegKey -ErrorAction SilentlyContinue' )
[void]$sb.AppendLine( 'if ($null -ne $Detected) {' )
[void]$sb.AppendLine( '    if ($Detected."Printer Driver" -eq $PrintDriverName) {' )
[void]$sb.AppendLine( '        Write-Host "Printer Detected!"' )
[void]$sb.AppendLine( '        Exit 0' )
[void]$sb.AppendLine( '    }else{' )
[void]$sb.AppendLine( '        Write-Host "Printer Detected but Driver does not match!"' )
[void]$sb.AppendLine( '        Exit 1' )
[void]$sb.AppendLine( '    }' )
[void]$sb.AppendLine( '}else{' )
[void]$sb.AppendLine( '    Write-Host "Printer Not Detected!"' )
[void]$sb.AppendLine( '    Exit 1' )
[void]$sb.AppendLine( '}' )

Out-File -InputObject $($sb.ToString()) -Encoding Default -FilePath $DetectionFilePath

if (!(Test-Path -Path $intunePrepTool)){
    Write-Host "Downloading the InTune Win32 Content Prep Tool"
    Invoke-WebRequest -Uri $Url -OutFile $IntunePrepTool
}

Write-Host "Creating the InTune Win32 Package"
.\InTuneWinAppUtil.exe -c $PackagePath -s $InstallFileName -o $PSScriptRoot -q

$textInfo = (Get-Culture).TextInfo
$IntuneWinFile = $textInfo.ToTitleCase($(Join-Path -Path $PSScriptRoot -ChildPath "$PrinterName.intunewin").ToString().ToLower()).Replace(" ", "_")
Write-Host "Renaming Package file to $IntuneWinFile"
$IntuneSourceFile = Join-Path -Path $PSScriptRoot -ChildPath "install.intunewin"
Rename-Item -Path $IntuneSourceFile -NewName "$IntuneWinFile"