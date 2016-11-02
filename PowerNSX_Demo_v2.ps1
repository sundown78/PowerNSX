<#
 
 pure & dilettante "copy" of Nick Bradford´s excellent VMworld 2016 NET7514 demo script. 
 
 my particular thanks therefore go to Nick Bradford, nbradford@vmware.com
 https://networkinferno.net/powernsx
 https://github.com/vmware/powernsx
 
 #>

#Defaults
    $nsxcluster = "labcloud-LAB"
    $nsxdatastore = "netapp_nfs_03"

#Password-Encryption-Decryption-Hell-Function :-)
function PasswordHell { 
    $pwcsv = Import-Csv C:\PowerCLI\Passwords.csv
    #$pwcsv | out-gridview

    $nsxpassword = $pwcsv | where {$_.System -eq "NSX"}
    $vcsapassword = $pwcsv | where {$_.System -eq "VCSA"}

    $nsxpassword =  $nsxpassword.EncPassword | ConvertTo-SecureString
    $Marshal = [System.Runtime.InteropServices.Marshal]
    $Bstr = $Marshal::SecureStringToBSTR($nsxpassword)
    $nsxpassword = $Marshal::PtrToStringAuto($Bstr)
    $Marshal::ZeroFreeBSTR($Bstr)

    $vcsapassword = $vcsapassword.EncPassword | ConvertTo-SecureString
    $Marshal = [System.Runtime.InteropServices.Marshal]
    $Bstr = $Marshal::SecureStringToBSTR($vcsapassword)
    $vcsapassword = $Marshal::PtrToStringAuto($Bstr)
    $Marshal::ZeroFreeBSTR($Bstr)
}
    PasswordHell

#Connect to NSX & vCenter
    connect-nsxserver -server "192.168.222.21" -username admin -password $nsxpassword -viusername administrator@vsphere.local -vipassword $vcsapassword -ViWarningAction "Ignore"

$Deploy = @(
    {$tz = Get-NsxTransportZone},
    #NSX LogicalSwitch(es)
    {$webls = New-NsxLogicalSwitch -TransportZone $tz -Name webls},
    {$appls = New-NsxLogicalSwitch -TransportZone $tz -Name appls},
    {$dbls = New-NsxLogicalSwitch -TransportZone $tz -Name dbls},
    {$transitls = New-NsxLogicalSwitch -TransportZone $tz -Name transitls}
    #NSX Edge
    {$uplink = New-NsxEdgeInterfaceSpec -Index 0 -Name uplink -type uplink -ConnectedTo (Get-VDPortgroup internal) -PrimaryAddress 192.168.119.150 -SubnetPrefixLength 24 -SecondaryAddresses 192.168.119.151},
    {$transit = New-NsxEdgeInterfaceSpec -Index 1 -Name transit -type internal -ConnectedTo (Get-nsxlogicalswitch transitls) -PrimaryAddress 172.16.1.1 -SubnetPrefixLength 29},
    {new-nsxedge -Name edge01 -Cluster (get-cluster $nsxcluster) -Datastore (get-datastore $nsxdatastore) -Password Concat01!Concat01! -FormFactor compact -Interface $uplink,$transit -FwDefaultPolicyAllow},
    {get-nsxedge edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -DefaultGatewayAddress 192.168.119.2 -confirm:$false},
    {get-nsxedge edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -EnableBgp -LocalAS 100 -RouterId 192.168.119.200 -confirm:$false},
    {get-nsxedge edge01 | Get-NsxEdgeRouting | Set-NsxEdgeBgp -DefaultOriginate -confirm:$false},
    {get-nsxedge edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -EnableBgpRouteRedistribution -confirm:$false},
    {get-nsxedge edge01 | Get-NsxEdgeRouting | New-NsxEdgeBgpNeighbour -IpAddress 172.16.1.3 -RemoteAS 200 -confirm:$false},
    {get-nsxedge edge01 | Get-NsxEdgeRouting | New-NsxEdgeRedistributionRule -Learner bgp -FromStatic -confirm:$false}
    #NSX LogicalRouter
    {$uplinklif = New-NsxLogicalRouterInterfaceSpec -Name Uplink -Type uplink -ConnectedTo (Get-NsxLogicalSwitch transitls) -PrimaryAddress 172.16.1.2 -SubnetPrefixLength 29},
    {$weblif = New-NsxLogicalRouterInterfaceSpec -Name web -Type internal -ConnectedTo (Get-NsxLogicalSwitch webls) -PrimaryAddress 10.0.1.1 -SubnetPrefixLength 24},
    {$applif = New-NsxLogicalRouterInterfaceSpec -Name app -Type internal -ConnectedTo (Get-NsxLogicalSwitch appls) -PrimaryAddress 10.0.2.1 -SubnetPrefixLength 24},
    {$dblif = New-NsxLogicalRouterInterfaceSpec -Name db -Type internal -ConnectedTo (Get-NsxLogicalSwitch dbls) -PrimaryAddress 10.0.3.1 -SubnetPrefixLength 24},
    {New-NsxLogicalRouter -Name LogicalRouter01 -ManagementPortGroup (Get-VDPortgroup internal) -Interface $uplinklif,$weblif,$applif,$dblif -Cluster (get-cluster $nsxcluster) -Datastore (get-datastore $nsxdatastore)},
    {get-nsxlogicalrouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -EnableBgp -ProtocolAddress 172.16.1.3 -ForwardingAddress 172.16.1.2 -LocalAS 200 -RouterId 172.16.1.3 -confirm:$false},
    {get-nsxlogicalrouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -EnableBgpRouteRedistribution -confirm:$false},
    {Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterRedistributionRule -FromConnected -Learner bgp -confirm:$false},
    {Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterBgpNeighbour -IpAddress 172.16.1.1 -RemoteAS 100 -ForwardingAddress 172.16.1.2 -ProtocolAddress 172.16.1.3 -confirm:$false},
    #Configure VMs
    {$webpg = $webls | Get-NsxBackingPortGroup},
    {$apppg = $appls | Get-NsxBackingPortGroup},
    {$dbpg = $dbls | Get-NsxBackingPortGroup},
    {get-vm | where { $_.name -match 'demoweb01'} | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $webpg -Confirm:$false},
    {get-vm | where { $_.name -match 'demoapp01'} | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $apppg -Confirm:$false},
    {get-vm | where { $_.name -match 'demodb01'} | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $dbpg -Confirm:$false}
)

$CleanUp = @(
    {get-vm | where { $_.name -match 'demoweb01'} | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup internal -Confirm:$false},
    {get-vm | where { $_.name -match 'demoapp01'} | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup internal -Confirm:$false},
    {get-vm | where { $_.name -match 'demodb01'} | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup internal -Confirm:$false},
    {Get-NsxEdge edge01 | Remove-NsxEdge -Confirm:$false},
    {Get-NsxLogicalRouter LogicalRouter01 | Remove-NsxLogicalRouter -Confirm:$false},
    {Get-NsxLogicalSwitch webls | Remove-NsxLogicalSwitch -Confirm:$false},
    {Get-NsxLogicalSwitch appls | Remove-NsxLogicalSwitch -Confirm:$false},
    {Get-NsxLogicalSwitch dbls | Remove-NsxLogicalSwitch -Confirm:$false},
    {Get-NsxLogicalSwitch transitls | Remove-NsxLogicalSwitch -Confirm:$false}
)


function DeployTheAwesome { 

    foreach ( $step in $Deploy ) { 

        #Show me first
        write-host -foregroundcolor yellow ">>> $step"

        write-host "Press a key to run the command..."
        #wait for a keypress to continue
        $junk = [console]::ReadKey($true)

        #execute (dot source) me in global scope
        . $step
    }
}

function RushDeployTheAwesome { 

    foreach ( $step in $Deploy ) { 

        #Show me first
        write-host -foregroundcolor yellow ">>> $step"

        #execute (dot source) me in global scope
        . $step
    }
}

function CleanupTheAwesome { 

    foreach ( $step in $CleanUp ) { 

        #Show me first
        write-host -foregroundcolor yellow ">>> $step"

        write-host "Press a key to run the command..."
        #wait for a keypress to continue
        $junk = [console]::ReadKey($true)

        #execute (dot source) me in global scope
        . $step
    }
}

function RushCleanupTheAwesome { 

    foreach ( $step in $CleanUp ) { 

        #Show me first
        write-host -foregroundcolor yellow ">>> $step"

        #execute (dot source) me in global scope
        . $step
    }
}
