param (
    [Parameter(Mandatory = $true)]
    [string]
    $scriptName, # e.g. "db-test-ps1"

    [Parameter(Mandatory = $false)]
    [string]
    $scriptParameters, # e.g. "-Compile 0 -Test 1"

    [Parameter(Mandatory = $true)]
    [string]
    $comment, # e.g. "Compiling and running tests"

    [Parameter(Mandatory = $true)]
    [string]
    $dbtype,

    [Parameter(Mandatory = $true)]
    [string]
    $OutputS3BucketName,

    [Parameter(Mandatory = $true)]
    [string]
    $OutputS3KeyPrefix,

    [Parameter(Mandatory = $true)]
    [string]
    $LansaVersion
)

# Mapping of databases to appropriate path
$DatabaseType_SystemRootPath = @{
    "AZURESQL" = "C:\Program Files (x86)\AZURESQL";
    "MSSQLS" = "C:\Program Files (x86)\LANSA";
    "ORACLE" = "C:\Program Files (x86)\ORACLE";
    "SQLANYWHERE" = "C:\Program Files (x86)\SQLANYWHERE";
    "MYSQL" = "C:\Program Files (x86)\MySQL"
}

$root_directory = $DatabaseType_SystemRootPath[$dbtype]

$instance_id = ((Get-EC2Instance -Filter @( `
                                    @{Name = "tag:LansaVersion"; Values=$LansaVersion}, `
                                    @{Name= "tag:aws:cloudformation:stack-name"; Values="DB-Regression-VM-$LansaVersion"}) `
                                    ).Instances `
                                ).InstanceId `

$localComment = "$comment for $dbtype"
$runPSCommandID = (Send-SSMCommand `
        -DocumentName "AWS-RunPowerShellScript" `
        -Comment $localComment `
        -Parameter @{'commands' = @("& '$root_directory\LANSA\VersionControl\Scripts\$scriptName' $scriptParameters")} `
        -Target @(@{Key="tag:aws:cloudformation:stack-name"; Values = "DB-Regression-VM-$LansaVersion"}, @{Key="tag:LansaVersion"; Values = "$LansaVersion"}) `
        -OutputS3BucketName $OutputS3BucketName `
        -OutputS3KeyPrefix $OutputS3KeyPrefix/$dbtype).CommandId

Write-Host "`nThe CommandID is: $runPSCommandID`n"

# Function to read the logs (from the S3 bucket) generated by running the Send-SSMCommand and printing it out to the Azure DevOps console
function writings3logs {

    # This will download the AWS Systems Manager log file(s) locally at the location specified on the "Folder" flag
    Read-S3Object -BucketName $OutputS3BucketName `
        -KeyPrefix "$OutputS3KeyPrefix/$dbtype/$runPSCommandID/$instance_id/awsrunPowerShellScript/0.awsrunPowerShellScript" `
        -Folder "s3_logs" # This is on the agent, and not the local machine

    # This will get all types of logs (expected types: stderr, for failure and stdout if successful) and print them to the console
    Get-ChildItem "s3_logs" | ForEach-Object {
        $content = Get-Content -Raw $_.FullName
        Write-Host "`n###################### - Displaying logs for: $($_.Name) - ######################`n"
        Write-Host $content
        Write-Host "`n###################### - END - ######################`n"
    }

    Write-Host "`nThe logs can also be found here: $OutputS3BucketName/$OutputS3KeyPrefix/$dbtype/$runPSCommandID/`n"
}

# The retry/timeout logic in case the script doesn't run; it will halt the execution right away if status is "Failed"
$RetryCount = 90
while(((Get-SSMCommand -CommandId $runPSCommandID).Status -ne "Success") -and ($RetryCount -gt 0)) {

    Write-Host "Please wait. $scriptName execution for $dbtype is in progress. The logs will be displayed after the execution.`n"

    Start-Sleep 20 # Checking every 20 seconds

    $RetryCount -= 1

    if(((Get-SSMCommand -CommandId $runPSCommandID).Status).Value -eq "Failed") {
        writings3logs # This is a function
        throw "$scriptName execution for $dbtype has failed!"
    }
}

# The actual timeout/halting of execution when timeout occures
if($RetryCount -le 0) {
    writings3logs # This is a function
    throw "Timeout: 30 minutes expired waiting for the script to start."
}

# And when nothing fails, fetch and write the logs
writings3logs # This is a function
