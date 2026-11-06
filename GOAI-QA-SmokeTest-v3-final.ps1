#requires -Version 5.1
<#
.SYNOPSIS
    Go/AI QA post-deployment infrastructure and HTTP smoke-test POC.
.DESCRIPTION
    Read-only Kubernetes checks using the local kubectl identity, followed by
    HTTP availability checks. Records PASS/FAIL/WARNING/ERROR and saves CSV/JSON.
    This is NOT a functional feature test or an Azure DevOps pipeline task.
.NOTES
    Jira: IAIAIFC-1925 | Environment: QA (epic-qa) only
    Prerequisites: kubectl, approved kubeconfig/RBAC, QA network/DNS/TLS access.
    Contains no passwords, tokens, or embedded Kubernetes credentials.
    Exit codes: 0 = PASS (possibly with warnings), 1 = FAIL, 2 = ERROR.
.EXAMPLE
    .\GOAI-QA-SmokeTest-v3-reviewed.ps1
.EXAMPLE
    .\GOAI-QA-SmokeTest-v3-reviewed.ps1 -TestFailureHandling
    Adds a synthetic FAIL without changing cluster/application resources.
#>
[CmdletBinding()]
param(
    [switch]$TestFailureHandling
)

$ErrorActionPreference = 'Stop'

# QA-only settings. PROD requires separate configuration and approval.
$namespace = 'epic-qa'
$expectedContext = 'ucp_mke.abbvienet.com:6443_svc-msrepic'
$backendService = 'abbvie-intelligence-backend'
$backendPort = 8011
$reportDir = Join-Path $env:USERPROFILE 'GoAI-SmokeTests'
$baselinePath = Join-Path $reportDir 'qa-restart-baseline.json'
$results = [System.Collections.Generic.List[object]]::new()
$startedAt = Get-Date
$runId = $startedAt.ToString('yyyyMMdd-HHmmss')
$reportCsv = Join-Path $reportDir "GoAI-QA-v3-$runId.csv"
$reportJson = Join-Path $reportDir "GoAI-QA-v3-$runId.json"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

# Consistent results are used in the console and exported evidence.
function Add-Result {
    param(
        [string]$Check,
        [ValidateSet('PASS', 'FAIL', 'WARNING', 'ERROR')][string]$Status,
        [string]$Details,
        [object]$DurationMs = $null
    )
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

# kubectl inherits credentials from the executing session's kubeconfig.
# A nonzero kubectl status or invalid JSON is an ERROR, not app FAIL.
function Get-KubeJson {
    param([string[]]$KubeArgs)
    $output = & kubectl @KubeArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }
    try { return (($output | Out-String) | ConvertFrom-Json) }
    catch { throw "kubectl returned invalid JSON: $($_.Exception.Message)" }
}

# Checks HTTPS URLs independently of MKE. Retries transient failures;
# only HTTP 200 is considered an availability PASS for this POC.
function Test-Http {
    param([string]$Name, [string]$Url)
    $lastMessage = 'No response'
    $lastType = 'ERROR'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing `
                -TimeoutSec 10 -MaximumRedirection 5 -ErrorAction Stop
            $watch.Stop()
            $status = [int]$response.StatusCode
            if ($status -eq 200) {
                Add-Result $Name 'PASS' "HTTP 200; attempt $attempt" $watch.ElapsedMilliseconds
                return
            }
            $lastType = 'FAIL'
            $lastMessage = "HTTP $status; attempt $attempt"
        }
        catch {
            $watch.Stop()
            if ($null -ne $_.Exception.Response) {
                $lastType = 'FAIL'
                $lastMessage = "HTTP $([int]$_.Exception.Response.StatusCode); attempt $attempt"
            }
            else {
                $lastType = 'ERROR'
                $lastMessage = "Connectivity/TLS/request error; attempt $attempt`: $($_.Exception.Message)"
            }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    Add-Result $Name $lastType $lastMessage
}

# Safety guard: do not query the namespace with an unexpected cluster context.
try {
    $context = (& kubectl config current-context 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $context -ne $expectedContext) {
        throw "Unexpected or unavailable Kubernetes context: $context"
    }
    Add-Result 'Kubernetes Context' 'PASS' 'Expected MKE context verified'
}
catch { Add-Result 'Kubernetes Context' 'ERROR' $_.Exception.Message }

if ($results[0].Status -eq 'PASS') {
    # A rollout is ready only when desired == updated == ready == available
    # and Kubernetes has observed the current deployment generation.
    $deployments = [ordered]@{
        'Backend'  = 'abbvie-intelligence-backend'
        'Frontend' = 'abbvie-intelligence-frontend'
        'Worker'   = 'abbvie-intelligence-backend-worker'
    }
    $backendDesiredReplicas = $null
    foreach ($name in $deployments.Keys) {
        try {
            $d = Get-KubeJson -KubeArgs @('get', 'deployment', $deployments[$name], '-n', $namespace, '-o', 'json')
            $desired = [int]$d.spec.replicas
            $ready = [int]$d.status.readyReplicas
            $updated = [int]$d.status.updatedReplicas
            $available = [int]$d.status.availableReplicas
            $observed = [long]$d.status.observedGeneration
            $generation = [long]$d.metadata.generation
            if ($name -eq 'Backend') { $backendDesiredReplicas = $desired }
            $complete = ($desired -gt 0 -and $ready -eq $desired -and
                         $updated -eq $desired -and $available -eq $desired -and
                         $observed -ge $generation)
            if ($complete) {
                Add-Result $name 'PASS' "$ready/$desired ready, updated, available; rollout observed"
            }
            else {
                Add-Result $name 'FAIL' "Desired=$desired Ready=$ready Updated=$updated Available=$available Generation=$observed/$generation"
            }
        }
        catch { Add-Result $name 'ERROR' $_.Exception.Message }
    }

    # Kubernetes v1 Endpoints is deprecated. Query EndpointSlice objects
    # owned by the backend Service; count unique ready, nonterminating IPs
    # that advertise the application's TCP port.
    try {
        if ($null -eq $backendDesiredReplicas -or $backendDesiredReplicas -le 0) {
            throw 'Cannot determine expected endpoints because backend replica count is unavailable'
        }
        $ep = Get-KubeJson -KubeArgs @(
            'get', 'endpointslices', '-n', $namespace,
            '-l', "kubernetes.io/service-name=$backendService", '-o', 'json'
        )
        $addresses = @(
            foreach ($slice in @($ep.items)) {
                $matchingPorts = @($slice.ports | Where-Object {
                    [int]$_.port -eq $backendPort -and $_.protocol -eq 'TCP'
                })
                if ($matchingPorts.Count -eq 0) { continue }
                foreach ($endpoint in @($slice.endpoints)) {
                    if ($endpoint.conditions.ready -eq $true -and
                        $endpoint.conditions.terminating -ne $true) {
                        foreach ($address in @($endpoint.addresses)) {
                            if ($address) { $address }
                        }
                    }
                }
            }
        )
        $actual = @($addresses | Sort-Object -Unique).Count
        $expected = $backendDesiredReplicas
        if ($actual -eq $expected) {
            Add-Result 'Backend Endpoints' 'PASS' "$actual/$expected ready EndpointSlice addresses on TCP $backendPort"
        }
        else {
            Add-Result 'Backend Endpoints' 'FAIL' "$actual/$expected ready EndpointSlice addresses on TCP $backendPort"
        }
    }
    catch { Add-Result 'Backend Endpoints' 'ERROR' $_.Exception.Message }

    # Compare container restarts against the previous successful snapshot.
    # Pod UID + container name prevents treating replacement pods as the
    # same container. First execution creates a baseline (WARNING).
    try {
        $pods = Get-KubeJson -KubeArgs @('get', 'pods', '-n', $namespace, '-o', 'json')
        $counts = @{}
        foreach ($pod in @($pods.items)) {
            $podName = [string]$pod.metadata.name
            if ($podName -notlike 'abbvie-intelligence-*') { continue }
            foreach ($cs in @($pod.status.containerStatuses)) {
                if (-not $cs.name) { continue }
                $key = "$($pod.metadata.uid)/$($cs.name)"
                $counts[$key] = [int]$cs.restartCount
            }
        }
        if ($counts.Count -eq 0) { throw 'No Go/AI container statuses returned' }
        $total = ($counts.Values | Measure-Object -Sum).Sum
        if (Test-Path $baselinePath) {
            $prior = Get-Content $baselinePath -Raw | ConvertFrom-Json
            if ($prior.namespace -ne $namespace) { throw 'Restart baseline namespace mismatch' }
            $priorMap = @{}
            foreach ($item in @($prior.containers)) { $priorMap[[string]$item.key] = [int]$item.count }
            $increases = 0
            foreach ($key in $counts.Keys) {
                if ($priorMap.ContainsKey($key) -and $counts[$key] -gt $priorMap[$key]) {
                    $increases += ($counts[$key] - $priorMap[$key])
                }
            }
            if ($increases -eq 0) {
                Add-Result 'Pod Restarts' 'PASS' "No increases on surviving containers; cumulative=$total"
            }
            else {
                Add-Result 'Pod Restarts' 'WARNING' "$increases new restarts on surviving containers; cumulative=$total"
            }
        }
        else {
            Add-Result 'Pod Restarts' 'WARNING' "Initial baseline only; cumulative=$total; no comparison yet"
        }
        # Update baseline only after reading and comparing pod statuses.
        $snapshot = [PSCustomObject]@{
            recordedAt = (Get-Date).ToString('o')
            namespace = $namespace
            containers = @(
                foreach ($key in $counts.Keys) {
                    [PSCustomObject]@{ key = $key; count = $counts[$key] }
                }
            )
        }
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $baselinePath -Encoding UTF8
    }
    catch { Add-Result 'Pod Restarts' 'ERROR' $_.Exception.Message }

    # Existing QA ingress routes; no port forwarding needed.
    Test-Http -Name 'Backend HTTP' -Url 'https://ai-q-backend.k8s.abbvienet.com/healthcheck'
    Test-Http -Name 'Frontend HTTP' -Url 'https://ai-q.abbvienet.com'
}

# Negative test for exit-code/reporting behavior; never changes QA resources.
if ($TestFailureHandling) {
    Add-Result 'Simulated Failure (test only)' 'FAIL' 'Synthetic failure verifies nonzero exit behavior'
}

# Export evidence, then return a code suitable for future pipeline handling.
# ERROR takes precedence over FAIL; warnings are non-blocking in this POC.
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
    durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 2)
    overall = $overall
    exitCode = $exitCode
    failures = $failures
    errors = $errors
    warnings = $warnings
    checks = @($results.ToArray())
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $reportJson -Encoding UTF8
$results | Format-Table Check, Status, Details, DurationMs -AutoSize
Write-Host "CSV: $reportCsv"
Write-Host "JSON: $reportJson"
Write-Host "OVERALL: $overall (exit code $exitCode)"
exit $exitCode
