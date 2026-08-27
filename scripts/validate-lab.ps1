param([string]$ResourceGroup="rg-aumlab", [string]$SubscriptionId)

function Get-PatchAssessmentResult {
    param([string]$ResourceGroupName, [string]$VMName)

    $json = az vm get-instance-view `
        --resource-group $ResourceGroupName `
        --name $VMName `
        --subscription $SubscriptionId `
        --query "instanceView.patchStatus.availablePatchSummary" `
        --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json) -or $json -eq "null") {
        return $null
    }

    $summary = $json | ConvertFrom-Json
    if ($null -eq $summary) {
        return $null
    }

    return [PSCustomObject]@{
        Status                        = $summary.status
        CriticalAndSecurityPatchCount = $summary.criticalAndSecurityPatchCount
        OtherPatchCount               = $summary.otherPatchCount
        StartDateTime                 = $summary.startTime
    }
}

Write-Host "`n=== Azure Update Manager Compliance Validation ===" -ForegroundColor Cyan

$vms     = @("DC01","WS01","WS02")
$results = @()
$allPass = $true

foreach ($vm in $vms) {
    $assessment = Get-PatchAssessmentResult -ResourceGroupName $ResourceGroup -VMName $vm

    $compliant = $assessment.Status -eq "Succeeded" -and $assessment.CriticalAndSecurityPatchCount -eq 0
    $status    = if ($compliant) { "PASS" } else { "FAIL" }
    if (-not $compliant) { $allPass = $false }

    Write-Host "[$status] $vm -- Critical missing: $($assessment.CriticalAndSecurityPatchCount) | Status: $($assessment.Status)"

    $results += [PSCustomObject]@{
        VMName                   = $vm
        AssessmentStatus         = $assessment.Status
        CriticalAndSecurityCount = $assessment.CriticalAndSecurityPatchCount
        OtherPatchCount          = $assessment.OtherPatchCount
        LastAssessmentTime       = $assessment.StartDateTime
        Compliant                = $compliant
        Result                   = $status
    }
}

Write-Host ""
Write-Host "Overall: $(if ($allPass){"ALL PASS"}else{"FAILURES DETECTED"})" `
    -ForegroundColor $(if ($allPass){"Green"}else{"Red"})

$report = @{
    GeneratedAt   = (Get-Date -Format "o")
    ResourceGroup = $ResourceGroup
    VMs           = $results
}
$report | ConvertTo-Json -Depth 5 | Out-File "./aum-compliance-report.json" -Encoding UTF8
Write-Host "Report exported: aum-compliance-report.json" -ForegroundColor Cyan