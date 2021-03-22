[OutputType("PSAzureOperationResponse")]
param
(
    [Parameter (Mandatory = $False)]
    [object] $WebhookData
)
#$ErrorActionPreference = "stop"

if ($WebhookData) {
    # Get the data object from WebhookData
    $WebhookBody = (ConvertFrom-Json -InputObject $WebhookData.RequestBody)

    # Get the info needed to identify the VM (depends on the payload schema)
    $schemaId = $WebhookBody.schemaId
    Write-Verbose "schemaId: $schemaId" -Verbose
    if ($schemaId -eq "Microsoft.Insights/activityLogs") {
        # This is the Activity Log Alert schema
        $AlertContext = [object] (($WebhookBody.data).context).activityLog
        $SubId = $AlertContext.subscriptionId
        $ResourceGroupName = $AlertContext.resourceGroupName
        $ResourceType = $AlertContext.resourceType
        $ResourceName = (($AlertContext.resourceId).Split("/"))[-1]
        $status = ($WebhookBody.data).status
    }
    else {
        # Schema not supported
        Write-Error "The alert data schema - $schemaId - is not supported."
    }
    
    Write-Verbose "status: $status" -Verbose
    if (($status -eq "Activated") -or ($status -eq "Fired")) {
        Write-Verbose "resourceType: $ResourceType" -Verbose
        Write-Verbose "resourceName: $ResourceName" -Verbose
        Write-Verbose "resourceGroupName: $ResourceGroupName" -Verbose
        Write-Verbose "subscriptionId: $SubId" -Verbose

        # Determine code path depending on the resourceType
        if ($ResourceType -eq "Microsoft.Compute/virtualMachines") {
            # Authenticate to Azure with service principal and certificate and set subscription
            Write-Verbose "Authenticating to Azure with service principal and certificate" -Verbose
            $ConnectionAssetName = "AzureRunAsConnection"
            Write-Verbose "Get connection asset: $ConnectionAssetName" -Verbose
            $Conn = Get-AutomationConnection -Name $ConnectionAssetName
            Write-Verbose "Authenticating to Azure with service principal." -Verbose
            Connect-AzAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint | Write-Verbose
            Write-Verbose "Setting subscription to work against: $SubId" -Verbose
            Set-AzContext -SubscriptionId $SubId -ErrorAction Stop | Write-Verbose

            if (!($Conn)) {
                throw "Could not retrieve connection asset: $ConnectionAssetName. Check that this asset exists in the Automation account."
            }

            $Extension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName
            If ($($Extension.name) -notcontains 'Microsoft.Insights.VMDiagnosticsSettings') {
                
                # Gather some information and set some names
                $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ResourceName
                $Region = $VM.Location
                $SubAbbrv = $SubId.Substring($SubId.Length - 4)
                $StorageAccountName = "vmdiag$($Region)$($SubAbbrv)"
                $StorageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -InformationAction Ignore -ErrorAction SilentlyContinue
                $DiagRGName = "RG-GuestDiagnostics"
                $DiagRG = Get-AzResourceGroup -Name $DiagRGName -InformationAction Ignore -ErrorAction SilentlyContinue
                
                # If Resource Group for Storage Account doesn't exist yet then create it
                If (!($DiagRG)) {
                    New-AzResourceGroup -Name $DiagRGName -Location $Region
                }

                # If Storage Account for this subscription and region doesn't exist yet then create it
                If (!($StorageAccount)) {
                    New-AzStorageAccount -ResourceGroupName $ResourceGroupName -AccountName $StorageAccountName -SkuName Standard_LRS -Location $Region
                }

                # Enable System Assigned Managed Identity
                $UpdateVM = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $VM -IdentityType SystemAssigned -InformationAction Ignore -ErrorAction SilentlyContinue

                # Turn on Guest-Level Diagnostics
                $JSONConfig = 
                @"
                {
                    "StorageAccount": "$($StorageAccountName)",
                    "WadCfg": {
                      "DiagnosticMonitorConfiguration": {
                        "overallQuotaInMB": 5120,
                        "Metrics": {
                          "resourceId": "$($VM.Id)",
                          "MetricAggregation": [
                            {
                              "scheduledTransferPeriod": "PT1H"
                            },
                            {
                              "scheduledTransferPeriod": "PT1M"
                            }
                          ]
                        },
                        "DiagnosticInfrastructureLogs": {
                          "scheduledTransferLogLevelFilter": "Error",
                          "scheduledTransferPeriod": "PT1M"
                        },
                        "PerformanceCounters": {
                          "scheduledTransferPeriod": "PT1M",
                          "PerformanceCounterConfiguration": [
                            {
                              "counterSpecifier": "\\Processor Information(_Total)\\% Processor Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Processor Information(_Total)\\% Privileged Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Processor Information(_Total)\\% User Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Processor Information(_Total)\\Processor Frequency",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\System\\Processes",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Process(_Total)\\Thread Count",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Process(_Total)\\Handle Count",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\System\\System Up Time",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\System\\Context Switches/sec",
                              "unit": "CountPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\System\\Processor Queue Length",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\% Committed Bytes In Use",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Available Bytes",
                              "unit": "Bytes",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Committed Bytes",
                              "unit": "Bytes",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Cache Bytes",
                              "unit": "Bytes",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Pool Paged Bytes",
                              "unit": "Bytes",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Pool Nonpaged Bytes",
                              "unit": "Bytes",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Pages/sec",
                              "unit": "CountPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Memory\\Page Faults/sec",
                              "unit": "CountPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Process(_Total)\\Working Set",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Process(_Total)\\Working Set - Private",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\% Disk Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\% Disk Read Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\% Disk Write Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\% Idle Time",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Disk Bytes/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Disk Read Bytes/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Disk Write Bytes/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Disk Transfers/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Disk Reads/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Disk Writes/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Avg. Disk sec/Transfer",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Avg. Disk sec/Read",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Avg. Disk sec/Write",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Avg. Disk Queue Length",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Avg. Disk Read Queue Length",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Avg. Disk Write Queue Length",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\% Free Space",
                              "unit": "Percent",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\LogicalDisk(_Total)\\Free Megabytes",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Bytes Total/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Bytes Sent/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Bytes Received/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Packets/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Packets Sent/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Packets Received/sec",
                              "unit": "BytesPerSecond",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Packets Outbound Errors",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            },
                            {
                              "counterSpecifier": "\\Network Interface(*)\\Packets Received Errors",
                              "unit": "Count",
                              "sampleRate": "PT60S"
                            }
                          ],
                          "sinks": "AzureMonitor"
                        },
                        "WindowsEventLog": {
                          "scheduledTransferPeriod": "PT1M",
                          "DataSource": [
                            {
                              "name": "Application!*[System[(Level=1 or Level=2 or Level=3)]]"
                            },
                            {
                              "name": "System!*[System[(Level=1 or Level=2 or Level=3)]]"
                            },
                            {
                              "name": "Security!*[System[(band(Keywords,4503599627370496))]]"
                            }
                          ]
                        },
                        "Directories": {
                          "scheduledTransferPeriod": "PT1M"
                        }
                      },
                      "SinksConfig": {
                        "Sink": [
                          {
                            "AzureMonitor": {},
                            "name": "AzureMonitor"
                          }
                        ]
                      }
                    }
                  }
"@
                # Write JSON to file
                $JSONConfig | out-file -FilePath 'C:\Temp\JSONConfig.json'
                
                # Install Diagnostics Extension and Configure
                Write-Verbose "Adding the Guest-Level Diagnostics Extension to the VM - $ResourceName - in resource group - $ResourceGroupName" -Verbose
                $JSONConfigPath = "C:\Temp\JSONConfig.json"
                Set-AzVMDiagnosticsExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName -DiagnosticsConfigurationPath $JSONConfigPath -StorageAccountName $StorageAccountName
                    
                #Verify successful installation of extension
                $Extension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName
                $DiagExtension = $Extension | Where-Object { $_.name -contains 'Microsoft.Insights.VMDiagnosticsSettings' }
                If ($DiagExtension) {
                    If ($DiagExtension.ProvisioningState -eq "Succeeded") {
                        Write-output "$($DiagExtension.name) - $($DiagExtension.ProvisioningState)"
                    }
                    Else {
                        Write-output "$($DiagExtension.name) - $($DiagExtension.ProvisioningState)"
                        Write-Error "Aborting Runbook"
                        Return
                    }
                }
                Else {
                    Write-Error "Microsoft.Insights.VMDiagnosticsSettings extension was not found on resource: $ResourceName"
                }

            }
            else {
                # Extension is already install on VM
                Write-Error "$ResourceName already has Microsoft.Insights.VMDiagnosticsSettings extension."
            }
        }
        else {
            # ResourceType not supported
            Write-Error "$ResourceType is not a supported resource type for this runbook. Only Virtual Machines are supported."
        }
    }
    else {
        # The alert status was not 'Activated' or 'Fired' so no action taken
        Write-Verbose ("No action taken. Alert status: " + $status) -Verbose
    }
}
else {
    # Error
    Write-Error "This runbook is meant to be started from an Azure alert webhook only."
}
