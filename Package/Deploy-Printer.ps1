<#
    .SYNOPSIS
    Installs or removes a printer from the local system

    .DESCRIPTION
    The Deploy-Printer.ps1 script will install the drivers found in the sub folder 32bit, 64bit, or arm64
    depending the system architecture into the windows driver store. Once drivers are installed a new
    TCP/IP printer is created on the the local system.

    .PARAMETER DriverName
    Specifies the driver that the new printer queue should use when it is created.

    .PARAMETER PrinterName
    Specifies the name that the new Printer queue should be created with.

    .PARAMETER PrinterHostAddress
    Specifies the IP address or FQDN that the printer can be found at. A standard TCP/IP printer port is created
    using this as its PrinterHostAddress value.

    .PARAMETER Remove
    If this switch is used, the script will remove the printer and the printer port from the system instead.
    Note that the Printer Driver is not removed the system, only the printer queue and printer port are removed.

    .CHANGELOG
    Date         Author          Description
    ----         ------          ---------------------------
    2024-08-26   Nathan Dennis   Initial version
    2025-12-01   Nathan Dennis   Added function to install the publisher certificate for signed drivers.

#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param (
    [Parameter(
        Mandatory=$true,
        ParameterSetName="Install")
    ]
    [string]$DriverName,

    [Parameter(
        Mandatory=$true,
        ParameterSetName="Install")
    ]
    [string]$PrinterHostAddress,

    [Parameter(
        Mandatory=$true,
        ParameterSetName="Install")
    ]
    [Parameter(
        Mandatory=$true,
        ParameterSetName="Remove")
    ]
    [string]$PrinterName,

    [Parameter(
        Mandatory=$false,
        ParameterSetName="Remove")
    ]
    [switch]$Remove
)


#Write to a log file on the system
function Write-Log {
    param (
        [parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Verbose','Information','Warning','Error','Critical')]
        [string]$Severity = 'Information'
    )

    $LogFile = Join-Path -Path $LogFilePath -ChildPath $("$($PrinterName).log")

    Try {
        #Don't write verbose records to the log file
        if ($Severity -ne "Verbose"){
            
            [pscustomobject]@{
                Time = (Get-date -Format "yyyy-MM-dd HH:mm:ss")
                Severity = $Severity
                Message = $Message
            } | Export-Csv -Path $LogFile -Append -NoTypeInformation
        }

        # Add a trailing record to mark the script failure
        if ($Severity -eq "Critical"){
            
            [pscustomobject]@{
                Time = (Get-date -Format "yyyy-MM-dd HH:mm:ss")
                Severity = $Severity
                Message = "####### SCRIPT CRITICAL FAILURE #######"
            } | Export-Csv -Path $LogFile -Append -NoTypeInformation
        }

        switch ($Severity) {
            "Verbose" { Write-Verbose -Message $Message }
            "Warning" { Write-Warning -Message $Message }
            "Error" { Write-Error -Message $Message}
            "Critical" {
                Write-Host -ForegroundColor Red "CRITICAL: $Message"
                Write-Host -ForegroundColor Red "CRITICAL: Unable to continue installation script"
                Write-Host -ForegroundColor Red "####### SCRIPT CRITICAL FAILURE #######"
            }
            Default { Write-Information -MessageData $Message -InformationAction Continue }
        }

    }
    Catch [System.Exception] {
        Write-Warning -Message "Unable to add log entry to $LogFile file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
}


# Function to get absolute path of PrinterDriver folder based on the system architecture
# and the folder the script is run from
function Get-DriverPath {
    $ScriptPath = $PSScriptRoot
    $DriverPath = "64bit"

    $Arch = ([System.Runtime.InteropServices.RuntimeInformation,mscorlib]::OSArchitecture.ToString().ToLower())

    Write-Log "$Arch Architecture Detected"

    switch ($Arch)
    {
        "x64" {$DriverPath = "64bit"}
        "x86" {$DriverPath = "32bit"}
        "arm64" {$DriverPath = "arm64"}
        default{
            Write-Log "Unknown System Architecture: $Arch" -Severity Critical
            Exit 1
        }
    } 
    
    return (Join-Path -Path $ScriptPath -ChildPath $DriverPath)
}

# Function to install printer driver into the windows driver store using pnputil.exe
# The powershell command Add-PrinterDriver cannot add drivers that are not aleady in the store.
function Install-PrinterDriver {
    param (
        [Parameter(
            Mandatory=$true,
            Position=0)]
        [string]$DriverPath
    )

    Write-Log -Message "Installing printer driver from path: $DriverPath"

    if ( Test-Path -Path $DriverPath ){
        $infFile = Get-ChildItem -Path $DriverPath -Filter *.inf
    
        if ($null -eq $infFile) {
            Write-Log "No inf files exist in the driver folder" -Severity Critical
            Exit 1
        }else{
            Write-Log ("{0} inf files located in directory" -f $infFile.Count)
        }

        #Get all the catalog files in the driver folder and install their publisher certificates
        $catFiles = Get-ChildItem -Path $DriverPath -Filter *.cat

        #For each catalog file found, extract the publisher certificate and add it to the trusted publishers store
        if ($null -ne $catFiles) {
            foreach ($catFile in $catFiles) {
                Write-Log -Message "Installing publisher certificate from catalog file: $($catFile.FullName)"

                try{
                    $cert = Get-AuthenticodeSignature -FilePath $catFile.FullName

                    if ($cert.SignerCertificate -ne $null) {
                        Write-Log -Message "Importing certificate issued to $($cert.SignerCertificate.Subject) into Trusted Publishers store"

                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher","LocalMachine")
                        $store.Open("ReadWrite")
                        $store.Add($cert.SignerCertificate)
                        $store.Close()
                    }else{
                        Write-Log -Message "No signer certificate found in catalog file: $($catFile.FullName)" -Severity Warning
                    }
                }
                catch{
                    Write-Log -Message "Failed to import certificate from catalog file: $($catFile.FullName). Error: $($_.Exception.Message)" -Severity Error
                }
            }
        }

        #Install the driver using pnputil.exe
        pnputil.exe /add-Driver "$DriverPath/*.inf" /install | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Log -Message "Printer drivers installed successfully."
        }elseif ($LASTEXITCODE -eq 259) {
            Write-Log -Message "Printer drivers already installed."
        }elseif ($LASTEXITCODE -eq 3010) {
            Write-Log -Message "Printer drivers installed successfully. System restart required" -Severity Warning
        } else {
            throw [System.Exception]::New("pnputil.exe return code of $LASTEXITCODE was received while installing the driver")
        }
    }else{
        Write-Log "$DriverPath does not exist.`nDrivers for each architecture must be placed in a sub folder named x86, x64, arm64" -Severity Critical
        Exit 1
    }
}

# Attempts connecting to the printer on the required IP address
# Will return true if connection is established, false otherwise
function Test-PrinterAvailable {
    param (
        [string]$PrinterHostAddress
    )

    try{
        $TcpClient = [System.Net.Sockets.TcpClient]::new()
        #Attempt a TCP connection to the standard printer port.
        $TcpClient.Connect($PrinterHostAddress, 9100)

        #If the connection fails to connect then it raises an error, Because 
        #there is nothing that needs to be done with the connection, close it.
        $TcpClient.Close()

        Write-Log -Message "Succesfully connected to printer at $PrinterHostAddress on port 9100 using TCP/IP"
        return $true

    }catch{
        Write-Log -Message "Unable to connect to printer at $PrinterHostAddress on port 9100" -Severity Warning
        return $false
    }
}

# Function to install a local printer
function Install-LocalPrinter {
    param (
        [string]$DriverName,
        [string]$PrinterName,
        [string]$PrinterHostAddress,
        [bool]$SNMP
    )

    # Creating a Standard TCP/IP Port
    $PortName = "$PrinterHostAddress"
    $PrinterPortExists = $true

    try{
        Get-PrinterPort -Name $PortName -ErrorAction Stop | Out-Null
    }catch{
        #An error means that the command didn't find the port
        $PrinterPortExists = $false
        Write-Log "No existing TCP/IP Port $PortName was found on system"
    }

    #If there is no printer port already present then create one
    if (! $PrinterPortExists){
        try{
            Test-PrinterAvailable -PrinterHostAddress $PrinterHostAddress | Out-Null

            Write-Log -Message "Creating a Standard TCP/IP Port for $PrinterHostAddress"
            
            Add-PrinterPort -Name $PortName -PrinterHostAddress $PrinterHostAddress -PortNumber 9100 -ErrorAction Stop
        }
        catch{
            throw $_.Exception
        }
    }else{
        Write-Log -Message "Using existing TCP/IP Port $PortName" -Severity Warning
    }
    

    #Check to see if the printer is already setup on the system
    $ExistingPrinter = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if ($null -eq $ExistingPrinter){
        #Printer doesn't exist so create it
        Write-Log "Installing the printer using driver: $DriverName"

        try{
            Write-Log "Adding Printer driver $DriverName to print spooler"
            Add-PrinterDriver -Name $DriverName -ErrorAction Stop
        }
        catch{
            throw $_.Exception
        }

        try{
            Write-Log "Adding Printer Queue $PrinterName on port $PortName using driver $DriverName"
            Add-Printer -Name $PrinterName -PortName $PortName -DriverName $DriverName -ErrorAction Stop      
        }
        catch{
            throw $_.Exception
        }
        
        
        Write-Log "$PrinterName was installed successfully."

    }else{
        #Printer already exists
        Write-Log "$PrinterName already exists on the system." -Severity Warning
    }
}


###########################################################
# Script entry point
###########################################################

#Create the temp folder to store log files in
$LogFilePath = (Join-Path -Path $env:SystemRoot -ChildPath $("temp\install-printer"))
[System.IO.Directory]::CreateDirectory($LogFilePath) | Out-Null

$argsString = ""
If ($ENV:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    Write-Log "Powershell Process is 32Bit, restarting in 64Bit" -Severity Warning

    Try {
        foreach($k in $MyInvocation.BoundParameters.keys)
        {
            switch($MyInvocation.BoundParameters[$k].GetType().Name)
            {
                "SwitchParameter" {if($MyInvocation.BoundParameters[$k].IsPresent) { $argsString += "-$k " } }
                "String"          { $argsString += "-$k `"$($MyInvocation.BoundParameters[$k])`" " }
                "Int32"           { $argsString += "-$k $($MyInvocation.BoundParameters[$k]) " }
                "Boolean"         { $argsString += "-$k `$$($MyInvocation.BoundParameters[$k]) " }
            }
        }
        Start-Process -FilePath "$ENV:WINDIR\SysNative\WindowsPowershell\v1.0\PowerShell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$($PSScriptRoot)\Deploy-Printer.ps1`" $($argsString)" -Wait -NoNewWindow
    }
    Catch {
        Write-Log "Failed to start a 64Bit Powershell session" -Severity Critical
        Exit 1
    }

    Exit $LASTEXITCODE
}else{
    Write-Log "Powershell session is $ENV:PROCESSOR_ARCHITECTURE" -Severity Verbose
}

if (! $Remove){
    Write-Log -Message "####### Staring Printer Installation #######"

    try{
        $DriverPath = Get-DriverPath
        Install-PrinterDriver -DriverPath $DriverPath -ErrorAction stop
        Install-LocalPrinter -DriverName $DriverName -PrinterName $PrinterName -PrinterHostAddress $PrinterHostAddress
    }
    catch{
        $Fields =[PSCustomObject]@{
            Message = $_.Exception.Message
            ScriptName = $_.InvocationInfo.ScriptName
            LineNumber = $_.InvocationInfo.ScriptLineNumber
            PositionMessage = $_.InvocationInfo.PositionMessage
            Exception = $_.Exception
        }

        Write-Log -Message ($Fields | Format-List -Force | Out-String) -Severity Error

        exit 1
    }
}else{
    Write-Log -Message "####### Staring Printer Removal #######"

    Try {
        #Check to see if the printer already exists.
        $Printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
        if ($Printer) {
            Write-Log -Message "Removing $PrinterName" -Severity Information
            Remove-Printer -Name $PrinterName -Confirm:$false

            $PrinterPort = Get-printerPort -Name $Printer.PortName -ErrorAction SilentlyContinue
            if ($PrinterPort){
                Write-Log -Message "Removing Printer Port $($Printer.PortName)"
                Remove-PrinterPort -Name $Printer.PortName -ComputerName $env:computername -Confirm:$false
            }
        }else{
            Write-Log -Message "$PrinterName was found on the system"
        }
    }
    Catch {
        $Fields =[PSCustomObject]@{
            Message = $_.Exception.Message
            ScriptName = $_.InvocationInfo.ScriptName
            LineNumber = $_.InvocationInfo.ScriptLineNumber
            PositionMessage = $_.InvocationInfo.PositionMessage
            Exception = $_.Exception
        }

        Write-Log -Message ($Fields | Format-List -Force | Out-String) -Severity Error

        exit 1
    }

}