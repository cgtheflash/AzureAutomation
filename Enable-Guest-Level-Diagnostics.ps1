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

      # Gather some information and set some names
      $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ResourceName
      $OSType = $VM.storageprofile.osdisk.ostype
      $Region = $VM.Location
      $SubAbbrv = $SubId.Substring($SubId.Length - 4)
      $StorageAccountName = "vmdiag$($Region)$($SubAbbrv)"
      $DiagRGName = "RG-GuestDiagnostics"
      # $StorageAccount = Get-AzStorageAccount -ResourceGroupName $DiagRGName -Name $StorageAccountName -InformationAction Ignore -ErrorAction SilentlyContinue
      $StorageAccounts = Get-AzStorageAccount
      $ResourceGroups = Get-AzResourceGroup
                
      # If Resource Group for Storage Account doesn't exist yet then create it
      If ($ResourceGroups.ResourceGroupName -notcontains $DiagRGName) {
        New-AzResourceGroup -Name $DiagRGName -Location $Region
      }

      # If Storage Account for this subscription and region doesn't exist yet then create it
      If ($StorageAccounts.StorageAccountName -notcontains $StorageAccountName) {
        New-AzStorageAccount -ResourceGroupName $DiagRGName -AccountName $StorageAccountName -SkuName Standard_LRS -Location $Region
      }

      # Enable System Assigned Managed Identity
      $UpdateVM = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $VM -IdentityType SystemAssigned -InformationAction Ignore -ErrorAction SilentlyContinue

      If ($OSType -eq 'Linux') {

        # Check if extension already exists
        $Extension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName
        If ($($Extension.name) -notcontains 'LinuxDiagnostic') {

          # Performance Diagnostics JSON Config for Linux
          $JSONConfig = @"
          {
            "sinksConfig": {
              "sink": [
                {
                  "name": "AzMonSink",
                  "type": "AzMonSink",
                  "AzureMonitor": {}
                }
              ]
            },
            "StorageAccount": "$($StorageAccountName)",
            "ladCfg": {
              "diagnosticMonitorConfiguration": {
                "eventVolume": "Medium",         
                "metrics": {
                  "metricAggregation": [
                    {
                      "scheduledTransferPeriod": "PT1H"
                    },
                    {
                      "scheduledTransferPeriod": "PT1M"
                    }
                  ],
                  "resourceId": "$($VM.Id)"
                },
                "performanceCounters": {
                  "performanceCounterConfiguration": [
                    {
                      "annotation": [
                        {
                          "displayName": "Disk read guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "readbytespersecond",
                      "counterSpecifier": "/builtin/disk/readbytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk writes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "writespersecond",
                      "counterSpecifier": "/builtin/disk/writespersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk transfer time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagetransfertime",
                      "counterSpecifier": "/builtin/disk/averagetransfertime",
                      "type": "builtin",
                      "unit": "Seconds"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk transfers",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "transferspersecond",
                      "counterSpecifier": "/builtin/disk/transferspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk write guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE", 
                      "counter": "writebytespersecond",
                      "counterSpecifier": "/builtin/disk/writebytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk read time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagereadtime",
                      "counterSpecifier": "/builtin/disk/averagereadtime",
                      "type": "builtin",
                      "unit": "Seconds"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk write time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagewritetime",
                      "counterSpecifier": "/builtin/disk/averagewritetime", 
                      "type": "builtin",
                      "unit": "Seconds"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk total bytes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "bytespersecond",
                      "counterSpecifier": "/builtin/disk/bytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk reads",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE", 
                      "counter": "readspersecond",
                      "counterSpecifier": "/builtin/disk/readspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk queue length",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagediskqueuelength",
                      "counterSpecifier": "/builtin/disk/averagediskqueuelength",
                      "type": "builtin",
                      "unit": "Count"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network in guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "bytesreceived",
                      "counterSpecifier": "/builtin/network/bytesreceived",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network total bytes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "bytestotal",
                      "counterSpecifier": "/builtin/network/bytestotal",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network out guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "bytestransmitted",
                      "counterSpecifier": "/builtin/network/bytestransmitted",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network collisions",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "totalcollisions",
                      "counterSpecifier": "/builtin/network/totalcollisions",
                      "type": "builtin",
                      "unit": "Count"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets received errors",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "totalrxerrors",
                      "counterSpecifier": "/builtin/network/totalrxerrors",
                      "type": "builtin", 
                      "unit": "Count"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets sent",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "packetstransmitted", 
                      "counterSpecifier": "/builtin/network/packetstransmitted",
                      "type": "builtin",
                      "unit": "Count"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets received",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "packetsreceived",
                      "counterSpecifier": "/builtin/network/packetsreceived",
                      "type": "builtin",
                      "unit": "Count"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets sent errors",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "totaltxerrors",
                      "counterSpecifier": "/builtin/network/totaltxerrors",
                      "type": "builtin",
                      "unit": "Count"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem transfers/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "transferspersecond",
                      "counterSpecifier": "/builtin/filesystem/transferspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % free space", 
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentfreespace",
                      "counterSpecifier": "/builtin/filesystem/percentfreespace",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % used space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentusedspace",
                      "counterSpecifier": "/builtin/filesystem/percentusedspace",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem used space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "usedspace",
                      "counterSpecifier": "/builtin/filesystem/usedspace",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem read bytes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "bytesreadpersecond",
                      "counterSpecifier": "/builtin/filesystem/bytesreadpersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem free space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "freespace",
                      "counterSpecifier": "/builtin/filesystem/freespace",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % free inodes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentfreeinodes",
                      "counterSpecifier": "/builtin/filesystem/percentfreeinodes",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem bytes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem", 
                      "condition": "IsAggregate=TRUE",
                      "counter": "bytespersecond",
                      "counterSpecifier": "/builtin/filesystem/bytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem reads/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "readspersecond",
                      "counterSpecifier": "/builtin/filesystem/readspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem write bytes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "byteswrittenpersecond",
                      "counterSpecifier": "/builtin/filesystem/byteswrittenpersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem writes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "writespersecond",
                      "counterSpecifier": "/builtin/filesystem/writespersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % used inodes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentusedinodes",
                      "counterSpecifier": "/builtin/filesystem/percentusedinodes",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU IO wait time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentiowaittime",
                      "counterSpecifier": "/builtin/processor/percentiowaittime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU user time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentusertime",
                      "counterSpecifier": "/builtin/processor/percentusertime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU nice time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentnicetime",
                      "counterSpecifier": "/builtin/processor/percentnicetime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU percentage guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentprocessortime",
                      "counterSpecifier": "/builtin/processor/percentprocessortime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU interrupt time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor", 
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentinterrupttime",
                      "counterSpecifier": "/builtin/processor/percentinterrupttime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU idle time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentidletime",
                      "counterSpecifier": "/builtin/processor/percentidletime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU privileged time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentprivilegedtime",
                      "counterSpecifier": "/builtin/processor/percentprivilegedtime",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Memory available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "availablememory",
                      "counterSpecifier": "/builtin/memory/availablememory",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap percent used",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentusedswap",
                      "counterSpecifier": "/builtin/memory/percentusedswap",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Memory used",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "usedmemory",
                      "counterSpecifier": "/builtin/memory/usedmemory",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Page reads",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "pagesreadpersec",
                      "counterSpecifier": "/builtin/memory/pagesreadpersec",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "availableswap",
                      "counterSpecifier": "/builtin/memory/availableswap",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap percent available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentavailableswap",
                      "counterSpecifier": "/builtin/memory/percentavailableswap",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Mem. percent available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentavailablememory",
                      "counterSpecifier": "/builtin/memory/percentavailablememory",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Pages",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "pagespersec",
                      "counterSpecifier": "/builtin/memory/pagespersec",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap used",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "usedswap",
                      "counterSpecifier": "/builtin/memory/usedswap",
                      "type": "builtin",
                      "unit": "Bytes"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Memory percentage",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentusedmemory",
                      "counterSpecifier": "/builtin/memory/percentusedmemory",
                      "type": "builtin",
                      "unit": "Percent"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Page writes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "pageswrittenpersec",
                      "counterSpecifier": "/builtin/memory/pageswrittenpersec",
                      "type": "builtin",
                      "unit": "CountPerSecond"
                    }
                  ]
                },
                "syslogEvents": {
                  "syslogEventConfiguration": {
                    "LOG_AUTH": "LOG_DEBUG",
                    "LOG_AUTHPRIV": "LOG_DEBUG",
                    "LOG_CRON": "LOG_DEBUG",
                    "LOG_DAEMON": "LOG_DEBUG",
                    "LOG_FTP": "LOG_DEBUG",
                    "LOG_KERN": "LOG_DEBUG",
                    "LOG_LOCAL0": "LOG_DEBUG",
                    "LOG_LOCAL1": "LOG_DEBUG",
                    "LOG_LOCAL2": "LOG_DEBUG",
                    "LOG_LOCAL3": "LOG_DEBUG",
                    "LOG_LOCAL4": "LOG_DEBUG",
                    "LOG_LOCAL5": "LOG_DEBUG",
                    "LOG_LOCAL6": "LOG_DEBUG",
                    "LOG_LOCAL7": "LOG_DEBUG",
                    "LOG_LPR": "LOG_DEBUG",
                    "LOG_MAIL": "LOG_DEBUG",
                    "LOG_NEWS": "LOG_DEBUG",
                    "LOG_SYSLOG": "LOG_DEBUG",
                    "LOG_USER": "LOG_DEBUG",
                    "LOG_UUCP": "LOG_DEBUG"
                  }
                }
              },
              "sampleRateInSeconds": 15
            }
          }
"@

          # Generate a SAS token for the agent to use to authenticate with the storage account
          $sasToken = New-AzStorageAccountSASToken -Service Blob, Table -ResourceType Service, Container, Object -Permission "racwdlup" -Context (Get-AzStorageAccount -ResourceGroupName $DiagRGName -AccountName $storageAccountName).Context -ExpiryTime $([System.DateTime]::Now.AddYears(10))

          # Build the protected settings (storage account SAS token)
          $protectedSettings = "{'storageAccountName': '$storageAccountName', 'storageAccountSasToken': '$sasToken'}"

          # Install the extension with the settings built above
          Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName -Location $VM.Location -ExtensionType LinuxDiagnostic -Publisher Microsoft.Azure.Diagnostics -Name LinuxDiagnostic -SettingString $JSONConfig -ProtectedSettingString $protectedSettings -TypeHandlerVersion 4.0 
          
          #Verify successful installation of extension
          $Extension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName
          $DiagExtension = $Extension | Where-Object { $_.name -contains 'LinuxDiagnostic' }
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
            Write-Error "LinuxDiagnostic extension was not found on resource: $ResourceName"
          }
          $Extension = $null # Clear variable
        }
        Else {
          Write-Error "LinuxDiagnostic extension is already installed on: $ResourceName"
        }
      }
      Elseif ($OSType -eq 'Windows') {

        # Check if extension already exists
        $Extension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $ResourceName
        If ($($Extension.name) -notcontains 'Microsoft.Insights.VMDiagnosticsSettings') {

          # JSON Config for Performance Diagnostics
          $JSONConfig = 
          @"
          {
            "StorageAccount": "$($StorageAccountName)",
            "ladCfg": {
              "diagnosticMonitorConfiguration": {
                "eventVolume": "Medium",
                "metrics": {
                  "metricAggregation": [
                    {
                      "scheduledTransferPeriod": "PT1M"
                    },
                    {
                      "scheduledTransferPeriod": "PT1H"
                    }
                  ],
                  "resourceId": "$($Vm.Id)" 
                },
                "syslogEvents": {
                  "syslogEventConfiguration": {
                    "LOG_AUTH": "LOG_DEBUG",
                    "LOG_AUTHPRIV": "LOG_DEBUG",
                    "LOG_CRON": "LOG_DEBUG",
                    "LOG_DAEMON": "LOG_DEBUG",
                    "LOG_FTP": "LOG_DEBUG",
                    "LOG_KERN": "LOG_DEBUG",
                    "LOG_LOCAL0": "LOG_DEBUG",
                    "LOG_LOCAL1": "LOG_DEBUG",
                    "LOG_LOCAL2": "LOG_DEBUG",
                    "LOG_LOCAL3": "LOG_DEBUG",
                    "LOG_LOCAL4": "LOG_DEBUG",
                    "LOG_LOCAL5": "LOG_DEBUG",
                    "LOG_LOCAL6": "LOG_DEBUG",
                    "LOG_LOCAL7": "LOG_DEBUG",
                    "LOG_LPR": "LOG_DEBUG",
                    "LOG_MAIL": "LOG_DEBUG",
                    "LOG_NEWS": "LOG_DEBUG",
                    "LOG_SYSLOG": "LOG_DEBUG",
                    "LOG_USER": "LOG_DEBUG",
                    "LOG_UUCP": "LOG_DEBUG"
                  }
                },
                "performanceCounters": {
                  "performanceCounterConfiguration": [
                    {
                      "annotation": [
                        {
                          "displayName": "CPU IO wait time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentiowaittime",
                      "counterSpecifier": "/builtin/processor/percentiowaittime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU user time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentusertime",
                      "counterSpecifier": "/builtin/processor/percentusertime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU nice time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentnicetime",
                      "counterSpecifier": "/builtin/processor/percentnicetime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU percentage guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentprocessortime",
                      "counterSpecifier": "/builtin/processor/percentprocessortime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU interrupt time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentinterrupttime",
                      "counterSpecifier": "/builtin/processor/percentinterrupttime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU idle time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentidletime",
                      "counterSpecifier": "/builtin/processor/percentidletime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "CPU privileged time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "processor",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentprivilegedtime",
                      "counterSpecifier": "/builtin/processor/percentprivilegedtime",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Memory available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "availablememory",
                      "counterSpecifier": "/builtin/memory/availablememory",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap percent used",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentusedswap",
                      "counterSpecifier": "/builtin/memory/percentusedswap",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Memory used",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "usedmemory",
                      "counterSpecifier": "/builtin/memory/usedmemory",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Page reads",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "pagesreadpersec",
                      "counterSpecifier": "/builtin/memory/pagesreadpersec",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "availableswap",
                      "counterSpecifier": "/builtin/memory/availableswap",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap percent available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentavailableswap",
                      "counterSpecifier": "/builtin/memory/percentavailableswap",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Mem. percent available",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentavailablememory",
                      "counterSpecifier": "/builtin/memory/percentavailablememory",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Pages",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "pagespersec",
                      "counterSpecifier": "/builtin/memory/pagespersec",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Swap used",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "usedswap",
                      "counterSpecifier": "/builtin/memory/usedswap",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Memory percentage",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "percentusedmemory",
                      "counterSpecifier": "/builtin/memory/percentusedmemory",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Page writes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "memory",
                      "counter": "pageswrittenpersec",
                      "counterSpecifier": "/builtin/memory/pageswrittenpersec",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network in guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "bytesreceived",
                      "counterSpecifier": "/builtin/network/bytesreceived",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network total bytes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "bytestotal",
                      "counterSpecifier": "/builtin/network/bytestotal",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network out guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "bytestransmitted",
                      "counterSpecifier": "/builtin/network/bytestransmitted",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Network collisions",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "totalcollisions",
                      "counterSpecifier": "/builtin/network/totalcollisions",
                      "type": "builtin",
                      "unit": "Count",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets received errors",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "totalrxerrors",
                      "counterSpecifier": "/builtin/network/totalrxerrors",
                      "type": "builtin",
                      "unit": "Count",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets sent",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "packetstransmitted",
                      "counterSpecifier": "/builtin/network/packetstransmitted",
                      "type": "builtin",
                      "unit": "Count",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets received",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "packetsreceived",
                      "counterSpecifier": "/builtin/network/packetsreceived",
                      "type": "builtin",
                      "unit": "Count",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Packets sent errors",
                          "locale": "en-us"
                        }
                      ],
                      "class": "network",
                      "counter": "totaltxerrors",
                      "counterSpecifier": "/builtin/network/totaltxerrors",
                      "type": "builtin",
                      "unit": "Count",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem transfers/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "transferspersecond",
                      "counterSpecifier": "/builtin/filesystem/transferspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % free space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentfreespace",
                      "counterSpecifier": "/builtin/filesystem/percentfreespace",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % used space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentusedspace",
                      "counterSpecifier": "/builtin/filesystem/percentusedspace",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem used space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "usedspace",
                      "counterSpecifier": "/builtin/filesystem/usedspace",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem read bytes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "bytesreadpersecond",
                      "counterSpecifier": "/builtin/filesystem/bytesreadpersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem free space",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "freespace",
                      "counterSpecifier": "/builtin/filesystem/freespace",
                      "type": "builtin",
                      "unit": "Bytes",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % free inodes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentfreeinodes",
                      "counterSpecifier": "/builtin/filesystem/percentfreeinodes",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem bytes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "bytespersecond",
                      "counterSpecifier": "/builtin/filesystem/bytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem reads/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "readspersecond",
                      "counterSpecifier": "/builtin/filesystem/readspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem write bytes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "byteswrittenpersecond",
                      "counterSpecifier": "/builtin/filesystem/byteswrittenpersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem writes/sec",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "writespersecond",
                      "counterSpecifier": "/builtin/filesystem/writespersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Filesystem % used inodes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "filesystem",
                      "condition": "IsAggregate=TRUE",
                      "counter": "percentusedinodes",
                      "counterSpecifier": "/builtin/filesystem/percentusedinodes",
                      "type": "builtin",
                      "unit": "Percent",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk read guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "readbytespersecond",
                      "counterSpecifier": "/builtin/disk/readbytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk writes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "writespersecond",
                      "counterSpecifier": "/builtin/disk/writespersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk transfer time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagetransfertime",
                      "counterSpecifier": "/builtin/disk/averagetransfertime",
                      "type": "builtin",
                      "unit": "Seconds",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk transfers",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "transferspersecond",
                      "counterSpecifier": "/builtin/disk/transferspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk write guest OS",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "writebytespersecond",
                      "counterSpecifier": "/builtin/disk/writebytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk read time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagereadtime",
                      "counterSpecifier": "/builtin/disk/averagereadtime",
                      "type": "builtin",
                      "unit": "Seconds",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk write time",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagewritetime",
                      "counterSpecifier": "/builtin/disk/averagewritetime",
                      "type": "builtin",
                      "unit": "Seconds",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk total bytes",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "bytespersecond",
                      "counterSpecifier": "/builtin/disk/bytespersecond",
                      "type": "builtin",
                      "unit": "BytesPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk reads",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "readspersecond",
                      "counterSpecifier": "/builtin/disk/readspersecond",
                      "type": "builtin",
                      "unit": "CountPerSecond",
                      "sampleRate": "PT15S"
                    },
                    {
                      "annotation": [
                        {
                          "displayName": "Disk queue length",
                          "locale": "en-us"
                        }
                      ],
                      "class": "disk",
                      "condition": "IsAggregate=TRUE",
                      "counter": "averagediskqueuelength",
                      "counterSpecifier": "/builtin/disk/averagediskqueuelength",
                      "type": "builtin",
                      "unit": "Count",
                      "sampleRate": "PT15S"
                    }
                  ]
                }
              },
              "sampleRateInSeconds": 15
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
        Else {
          Write-Error "OSType: $($OSType) not supported."
        }

      }
      else {
        # Extension is already install on VM
        Write-Error "Microsoft.Insights.VMDiagnosticsSettings extension is already installed on resource: $ResourceName."
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
