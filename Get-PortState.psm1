<#
.SYNOPSIS
This checks remote computers or devices for open TCP ports by attempting a TCP socket
connection to the specified port or ports using the .NET Net.Sockets.TcpClient class.

.DESCRIPTION
Use the parameter -ComputerName to specify the target computer(s), and the parameter
-Port to specify port(s) to check.

Examples:
Get-PortState -Comp server01 -Port 3389, 445, 80
Get-PortState -Comp (gc hosts.txt) -Port 22,80 -NoPing -AsJob

Copyright (c) 2012, Svendsen Tech.
All rights reserved.
Author: Joakim Svendsen

More extensive documenatation online:
http://www.powershelladmin.com
http://www.powershelladmin.com/wiki/Check_for_open_TCP_ports_using_PowerShell

.PARAMETER ComputerName
Target computer name(s) or IP address(es).
.PARAMETER Port
TCP port(s) to check whether are open.
.PARAMETER ExportToCsv
Create a CSV report and save it to the specified file name, using UTF-8 encoding.
The file will be overwritten without you being prompted, if it exists.
.PARAMETER Timeout
Timeout in millliseconds before the script considers a port closed. Default 3000 ms
(3 seconds). For speeding things up. Only in effect when used with the -AsJob parameter.
.PARAMETER AsJob
Use one job for each port connection. This allows you to override the possibly lengthy
timeout from the connecting socket, and a port is considered closed if we haven't been
able to connect within the allowed time. Default 3000 ms. See the -Timeout parameter.
This may be quite resource-consuming! Ports that are determined to be closed via timeout
will be tagged with a "(t)" for timeout.
.PARAMETER Dns
Try to determine IP if given a host name or host name if given an IP. Multiple values
are joined with semicolons: ";".
.PARAMETER NoPing
Do not try to ping the target computer if this is specified. By default, the script
skips the port checks on targets that do not respond to ICMP ping and populate the
fields with hyphens for these hosts. Be aware that computers that do not resolve via
DNS/WINS/NetBIOS will also be reported as having failed the ping check.
.PARAMETER ContinueOnPingFail
Try to check the target computer for open ports even if it does not respond to ping.
Be aware that computers that do not resolve via DNS/WINS/NetBIOS will also be processed like
this (and it should report them as "closed").
.PARAMETER Quiet
Do not display results with Write-Host directly as the script progresses.
.PARAMETER NoSummary
Do not display a summary at the end. The summary includes start and end time of the script,
and the output file name if you specified -ExportToCsv.
#>

function Get-PortState {

param([Parameter(Mandatory=$true)][string[]] $ComputerName,
      [Parameter(Mandatory=$true)][int[]] $Port,
      [string] $ExportToCsv = '', # initialize to a false value
      [int]    $Timeout = 3000, # initialize to three seconds
      [switch] $AsJob,
      [switch] $Dns,
      [switch] $NoPing,
      [switch] $ContinueOnPingFail,
      [switch] $NoSummary,
      [switch] $Quiet = $false
     )

$StartTime = Get-Date

if ($Timeout -ne 3000 -and -not $AsJob)  { Write-Host -Fore Red "Warning. Timeout not in effect without -AsJob" }
if ($ContinueOnPingFail -and $NoPing) { Write-Host -Fore Red "Warning. -ContinueOnPingFail not in effect with -NoPing" }

# Main data hash. Assumes computer names are unique. If the same computer is
# specified multiple times, it will be processed multiple times, and the data
# from the last time it was processed will overwrite the older data.
$script:Data = @{}

# Process each computer specified.
foreach ($Computer in $ComputerName) {
    
    # Initialize a new custom PowerShell object to hold the data.
    $script:Data.$Computer = New-Object PSObject
    Add-Member -Name 'ComputerName' -Value $Computer -MemberType NoteProperty -InputObject $script:Data.$Computer
    
    # Try to ping if -Ping was specified.
    if (-not $NoPing) {
        
        if (Test-Connection -Count 1 -ErrorAction SilentlyContinue $Computer) {
            
            # Produce output to the host and add data to the object.
            Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Responded to ICMP ping."
            Add-Member -Name 'Ping' -Value 'Yes' -MemberType NoteProperty -InputObject $script:Data.$Computer
            
        }
        
        else {
            
            # Produce output to the host and add data to the object.
            Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Did not respond to ICMP ping."
            Add-Member -Name 'Ping' -Value 'No' -MemberType NoteProperty -InputObject $script:Data.$Computer
            
            # If -ContinueOnPingFail was not specified, do this:
            if (-not $ContinueOnPingFail) {
                
                # Set all port states to "-" (not checked).
                foreach ($SinglePort in $Port) {
                    Add-Member -Name $SinglePort -Value '-' -MemberType NoteProperty -InputObject $script:Data.$Computer
                }
                
                # Continue to the next iteration/computer in the loop.
                continue
                
            }
            
        }
        
    }
    
    if ($Dns) {
        
        $ErrorActionPreference = 'SilentlyContinue'
        $HostEntry = [System.Net.Dns]::GetHostEntry($Computer)
        $Result = $?
        $ErrorActionPreference = $MyEAP
        
        # It looks like it's "successful" even when it isn't, for any practical purposes (pass in IP, get IP as .HostName)...
        if ($Result) {
            
            ## This is a best-effort attempt at handling things flexibly.
            ##
            # I think this should mostly work... If I pass in an IPv4 address that doesn't
            # resolve to a host name, the same IP seems to be used to populate the HostName property.
            # So this means that you'll get the IP address twice for IPs that don't resolve, but
            # it will still say it resolved. For IPs that do resolve to a host name, you will
            # correctly get the host name in the IP/DNS column. For host names or IPs that resolve to
            # one or more IP addresses, you will get the IPs joined together with semicolons.
            # Both IPv6 and IPv4 may be reported depending on your environment.
            if ( ($HostEntry.HostName -split '\.')[0] -ieq ($Computer -split '\.')[0] ) {
                $IPDns = ($HostEntry | Select -Expand AddressList | Select -Expand IPAddressToString) -join ';'
            }
            else {
                $IPDns = $HostEntry.HostName
            }
            
            # Produce output to the host and add data to the object.
            Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Resolved to: $IPDns"
            Add-Member -Name 'IP/DNS' -Value $IPDns -MemberType NoteProperty -InputObject $script:Data.$Computer
            
        }
        
        # This seems useless in my test environment, but who knows.
        else {
            
            Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Did not resolve."
            Add-Member -Name 'IP/DNS' -Value '-' -MemberType NoteProperty -InputObject $script:Data.$Computer
            
        }
        
    } # end of if $Dns
    
    # Here we check if the ports are open and store data in the object.
    foreach ($SinglePort in $Port) {
        
        if ($AsJob) {
            
            # This implementation using jobs is to support a custom timeout before proceeding.
            # Default: 3000 milliseconds (3 seconds).
            
            $Job = Start-Job -ArgumentList $Computer, $SinglePort -ScriptBlock {
                
                param([string] $Computer, [int] $SinglePort)
                
                # Create a new Net.Sockets.TcpClient object to use for testing open TCP ports.
                # It needs to be created inside the job's script block.
                $Socket = New-Object Net.Sockets.TcpClient
                
                # Suppress error messages
                $ErrorActionPreference = 'SilentlyContinue'
                
                # Try to connect
                $Socket.Connect($Computer, $SinglePort)
                
                # Make error messages visible again
                $ErrorActionPreference = 'Continue'
                
                if ($Socket.Connected) {
                    
                    # Close the socket.
                    $Socket.Close()
                    
                    # Return success string
                    'connected'
                    
                }
                 
                else {
                    
                    'not connected'
                    
                }
            
            } # end of script block
            
            # If we check the state of the job without a little nap, we'll probably have to
            # sleep longer because it hasn't finished yet. About 250 ms seems to work in my environment.
            # Adding a little... Maybe I should make this a parameter to the script as well.
            Start-Sleep -Milliseconds 400
            
            if ($Job.State -ne 'Completed') {
                
                #Write-UnlessQuiet -Quiet: $Quiet 'Sleeping...'
                Start-Sleep -Milliseconds $Timeout
                
            }
            
            if ($Job.State -eq 'Completed') {
                
                # Get the results (either 'connected' or 'not connected')
                $JobResult = Receive-Job $Job
                
                if ($JobResult -ieq 'connected') {
                    
                    # Produce output to the host and add data to the object.
                    Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Port $SinglePort is open"
                    Add-Member -Name $SinglePort -Value 'Open' -MemberType NoteProperty -InputObject $script:Data.$Computer
                    
                    
                }
                
                else {
                    
                    # Produce output to the host and add data to the object.
                    Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Port $SinglePort is closed or filtered"
                    Add-Member -Name $SinglePort -Value 'Closed' -MemberType NoteProperty -InputObject $script:Data.$Computer
                    
                }
                
            }
            
            # Assume we couldn't connect within the timeout period.
            else {
                
                # Produce output to the host and add data to the object.
                Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Port $SinglePort is closed or filtered (timeout: $Timeout ms)"
                Add-Member -Name $SinglePort -Value 'Closed (t)' -MemberType NoteProperty -InputObject $script:Data.$Computer
                
            }
            
            # Stopping and removing the job causes it to wait beyond the timeout... Let's accumulate crap.
            #Stop-Job -Job $Job
            #Remove-Job -Force -Job $Job
            
            $Job = $null
            
        } # end of if ($AsJob)
        
        # Do it the usual way without jobs. No custom timeout support.
        else {
            
            # Create a new Net.Sockets.TcpClient object to use for testing open TCP ports.
            $Socket = New-Object Net.Sockets.TcpClient
            
            # Suppress error messages
            $ErrorActionPreference = 'SilentlyContinue'
            
            # Try to connect
            $Socket.Connect($Computer, $SinglePort)
            
            # Make error messages visible again
            $ErrorActionPreference = $MyEAP
            
            if ($Socket.Connected) {
                
                # Produce output to the host and add data to the object.
                Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Port $SinglePort is open"
                Add-Member -Name $SinglePort -Value 'Open' -MemberType NoteProperty -InputObject $script:Data.$Computer
                
                # Close the socket.
                $Socket.Close()
                
            }
             
            else {
                
                # Produce output to the host and add data to the object.
                Write-UnlessQuiet -Quiet: $Quiet "${Computer}: Port $SinglePort is closed or filtered"
                Add-Member -Name $SinglePort -Value 'Closed' -MemberType NoteProperty -InputObject $script:Data.$Computer
                
            }
            
            # Reset the variable. Apparently necessary.
            $Socket = $null
            
        }
        
    } # end of foreach port
    
} # end of foreach computer

# Create a properties hash to use with Select-Object later.
$script:Properties = ,@{n='ComputerName'; e={$_.Name}}

# Add the ping and DNS headers if necessary.
if (-not $NoPing) { $script:Properties += @{n='Ping'; e={$_.Value.Ping}} }
if ($Dns) { $script:Properties += @{n='IP/DNS'; e={$_.Value.'IP/DNS'}} }

# Create the dynamic properties with this hack.
$Port | Sort-Object | ForEach-Object {
    $script:Properties += @{n="Port $_"; e=[ScriptBlock]::Create("`$_.Value.[string]$_")}
}

$ErrorActionPreference = 'Continue'
# If they want CSV, (try to) create the file they specified
if ($ExportToCsv) {
    $script:Data.GetEnumerator() | Sort Name | Select-Object $script:Properties |
        ConvertTo-Csv -NoTypeInformation | Set-Content -Encoding utf8 $ExportToCsv
}
$ErrorActionPreference = $MyEAP

# Display summary results.
if (-not $NoSummary) {
    
    Write-Host -ForegroundColor Green @"

Start time:  $StartTime
End time:    $(Get-Date)

$(if ($ExportToCsv) { "Output file: $ExportToCsv" })
"@
    
}

# Finally, emit formatted objects to the pipeline.
$script:Data.GetEnumerator() | Sort Name | Select-Object $script:Properties #| Format-Table -AutoSize

} # end of Get-PortState function

function Get-PortStateLast {
    
    # Just return the data from the last run with the last dynamic properties,
    # or nothing if Get-PortState hasn't been run prior to this.
    if ($script:Data.Count) {
        $script:Data.GetEnumerator() | Sort Name | Select-Object $script:Properties #| Format-Table -AutoSize
    }
    else {
        throw 'No data has been collected yet, or the module was reloaded.'
    }
    
}

####### END OF FUNCTIONS #######

Set-StrictMode -Version Latest
$script:MyEAP = 'Stop'
$ErrorActionPreference = $MyEAP

$script:Data = @{}
$script:Properties = @{}

#Export-ModuleMember -Function Get-PortState, Get-PortStateLast
