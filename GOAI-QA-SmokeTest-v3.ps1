# Go/AI QA Smoke Testing POC - Version 3
# Jira: IAIAIFC-1925
# Read-only Kubernetes and HTTPS checks. PowerShell 5.1+.
[CmdletBinding()]
param(
    [switch]$TestFailureHandling
)

$ErrorActionPreference = 'Stop'
$namespace = 'epic-qa'
$expectedContext = 'ucp_mke.abbvienet.com:6443_svc-msrepic'
$reportDir = Join-Path $env:USERPROFILE 'GoAI-SmokeTests'
$baselinePath = Join-Path $reportDir 'qa-restart-baseline.json'
$results = [System.Collections.Generic.List[object]]::new()
$startedAt = Get-Date
$runId = $startedAt.ToString('yyyyMMdd-HHmmss')
$reportCsv = Join-Path $reportDir "GoAI-QA-v3-$runId.csv"
$reportJson = Join-Path $reportDir "GoAI-QA-v3-$runId.json"

New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Details, [object]$DurationMs = $null)
    $script:results.Add([PSCustomObject]@{
        Timestamp   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Environment = 'QA'
        Check       = $Check
        Status      = $Status
        Details     = $Details
        DurationMs  = $DurationMs
    })
    Write-Host "$Check : $Status - $Details"
}

function Get-KubeJson {
    param([string[]]$KubeArgs)
    $output = & kubectl @KubeArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | Out-String).Trim()) }
    try { return (($output | Out-String) | ConvertFrom-Json) }
    catch { throw "kubectl output was not valid JSON: $($_.Exception.Message)" }
}

function Test-Http {
    param([string]$Name, [string]$Url, [bool]$ExpectFailure = $false)
    $lastMessage = 'No response'
    $lastType = 'ERROR'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 5 -ErrorAction Stop
            $watch.Stop()
            $status = [int]$response.StatusCode
            if ($status -eq 200) {
                if ($ExpectFailure) { Add-Result $Name 'FAIL' "Unexpected HTTP 200; attempt $attempt" $watch.ElapsedMilliseconds }
                else { Add-Result $Name 'PASS' "HTTP 200; attempt $attempt" $watch.ElapsedMilliseconds }
                return
            }
            $lastType = 'FAIL'
            $lastMessage = "HTTP $status; attempt $attempt"
        }
        catch {
            $watch.Stop()
            $httpResponse = $_.Exception.Response
            if ($null -ne $httpResponse) {
                $lastType = 'FAIL'
                $code = [int]$httpResponse.StatusCode
                $lastMessage = "HTTP $code; attempt $attempt"
            }
            else {
                $lastType = 'ERROR'
                $lastMessage = "Connectivity/TLS/request error; attempt $attempt`: $($_.Exception.Message)"
            }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    if ($ExpectFailure) {
        Add-Result $Name 'PASS' "Controlled negative test produced $lastType ($lastMessage)"
    }
    else {
        Add-Result $Name $lastType $lastMessage
    }
}

try {
    $context = (& kubectl config current-context 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $context -ne $expectedContext) {
        throw "Context mismatch or unavailable: $context"
    }
    Add-Result 'Kubernetes Context' 'PASS' 'Expected MKE context verified'
}
catch {
    Add-Result 'Kubernetes Context' 'ERROR' $_.Exception.Message
}

if ($results[0].Status -eq 'PASS') {
    $deployments = [ordered]@{
        'Backend'  = 'abbvie-intelligence-backend'
        'Frontend' = 'abbvie-intelligence-frontend'
        'Worker'   = 'abbvie-intelligence-backend-worker'
    }
    foreach ($name in $deployments.Keys) {
        try {
            $d = Get-KubeJson -KubeArgs @('get','deployment',$deployments[$name],'-n',$namespace,'-o','json')
            $desired = [int]$d.spec.replicas
            $ready = [int]$d.status.readyReplicas
            $updated = [int]$d.status.updatedReplicas
            $available = [int]$d.status.availableReplicas
            $observed = [long]$d.status.observedGeneration
            $generation = [long]$d.metadata.generation
            $complete = ($desired -gt 0 -and $desired -eq $ready -and $desired -eq $updated -and $desired -eq $available -and $observed -ge $generation)
            if ($complete) { Add-Result $name 'PASS' "$ready/$desired ready, updated, available; rollout observed" }
            else { Add-Result $name 'FAIL' "Desired=$desired Ready=$ready Updated=$updated Available=$available Generation=$observed/$generation" }
        }
        catch { Add-Result $name 'ERROR' $_.Exception.Message }
    }

    try {
        $ep = Get-KubeJson -KubeArgs @('get','endpoints','abbvie-intelligence-backend','-n',$namespace,'-o','json')
        $addresses = @(
            foreach ($subset in @($ep.subsets)) {
                foreach ($address in @($subset.addresses)) { if ($address.ip) { $address.ip } }
            }
        )
        if ($addresses.Count -eq 4) { Add-Result 'Backend Endpoints' 'PASS' '4 ready endpoints (expected 4)' }
        else { Add-Result 'Backend Endpoints' 'FAIL' "$($addresses.Count) ready endpoints; expected 4" }
    }
    catch { Add-Result 'Backend Endpoints' 'ERROR' $_.Exception.Message }

    try {
        $pods = Get-KubeJson -KubeArgs @('get','pods','-n',$namespace,'-o','json')
        $counts = @{}
        foreach ($pod in @($pods.items)) {
            $podName = [string]$pod.metadata.name
            if ($podName -notlike 'abbvie-intelligence-*') { continue }
            foreach ($cs in @($pod.status.containerStatuses)) {
                if (-not $cs.name) { continue }
                # UID + container name means replaced pods don't inherit old baselines.
                $key = "$($pod.metadata.uid)/$($cs.name)"
                $counts[$key] = [int]$cs.restartCount
            }
        }
        if ($counts.Count -eq 0) { throw 'No matching container statuses were returned' }
        $total = ($counts.Values | Measure-Object -Sum).Sum
        if (Test-Path $baselinePath) {
            $prior = Get-Content $baselinePath -Raw | ConvertFrom-Json
            $priorMap = @{}
            foreach ($item in @($prior.containers)) { $priorMap[[string]$item.key] = [int]$item.count }
            $increases = 0
            foreach ($key in $counts.Keys) {
                if ($priorMap.ContainsKey($key) -and $counts[$key] -gt $priorMap[$key]) {
                    $increases += ($counts[$key] - $priorMap[$key])
                }
            }
            if ($increases -eq 0) { Add-Result 'Pod Restarts' 'PASS' "No increases on surviving containers; cumulative=$total" }
            else { Add-Result 'Pod Restarts' 'WARNING' "$increases additional restarts on surviving containers; cumulative=$total" }
        }
        else { Add-Result 'Pod Restarts' 'WARNING' "Initial baseline only; cumulative=$total; no comparison yet" }
        # Persist the current baseline only after successful read.
        $snapshot = [PSCustomObject]@{
            recordedAt = (Get-Date).ToString('o')
            namespace = $namespace
            containers = @(
                foreach ($key in $counts.Keys) { [PSCustomObject]@{ key=$key; count=$counts[$key] } }
            )
        }
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $baselinePath -Encoding UTF8
    }
    catch { Add-Result 'Pod Restarts' 'ERROR' $_.Exception.Message }

    Test-Http -Name 'Backend HTTP' -Url 'https://ai-q-backend.k8s.abbvienet.com/healthcheck'
    Test-Http -Name 'Frontend HTTP' -Url 'https://ai-q.abbvienet.com'
}

# Safe failure-handling test: synthetic result, no network or cluster mutation.
if ($TestFailureHandling) {
    Add-Result 'Simulated Failure (test only)' 'FAIL' 'Intentional synthetic failure confirms nonzero exit behavior'
}

$finishedAt = Get-Date
$errors = @($results | Where-Object Status -eq 'ERROR').Count
$failures = @($results | Where-Object Status -eq 'FAIL').Count
$warnings = @($results | Where-Object Status -eq 'WARNING').Count
$exitCode = if ($errors -gt 0) { 2 } elseif ($failures -gt 0) { 1 } else { 0 }
$overall = if ($errors -gt 0) { 'ERROR' } elseif ($failures -gt 0) { 'FAIL' } elseif ($warnings -gt 0) { 'PASS WITH WARNINGS' } else { 'PASS' }
$results | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8
$summary = [ordered]@{
    runId = $runId
    environment = 'QA'
    namespace = $namespace
    startedAt = $startedAt.ToString('o')
    finishedAt = $finishedAt.ToString('o')
    durationSeconds = [math]::Round(($finishedAt-$startedAt).TotalSeconds,2)
    overall = $overall
    exitCode = $exitCode
    failures = $failures
    errors = $errors
    warnings = $warnings
    checks = @($results.ToArray())
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $reportJson -Encoding UTF8
$results | Format-Table Check,Status,Details,DurationMs -AutoSize
Write-Host "CSV: $reportCsv"
Write-Host "JSON: $reportJson"
Write-Host "OVERALL: $overall (exit code $exitCode)"
exit $exitCode
