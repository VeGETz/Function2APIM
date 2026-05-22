#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectPath = ".",
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$Prune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiVersion = '2022-08-01'
$ConfigFile = Join-Path $PSScriptRoot 'apim-sync.config.json'

# --- Config ------------------------------------------------------------------

function Get-Config {
    $config = @{}

    if (Test-Path $ConfigFile) {
        $raw = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $raw.PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value }
    }

    $fields = @('subscriptionId', 'resourceGroup', 'apimInstance', 'apiId', 'backendId')
    $changed = $false

    foreach ($field in $fields) {
        if (-not $config.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($config[$field])) {
            $value = Read-Host "Enter $field"
            $config[$field] = $value.Trim()
            $changed = $true
        }
    }

    if ($changed) {
        $save = Read-Host "Save config to apim-sync.config.json? (y/n)"
        if ($save -ieq 'y') {
            $config | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
            Write-Host "Config saved to $ConfigFile" -ForegroundColor Green
        }
    }

    return $config
}

# --- Auth ---------------------------------------------------------------------

function Get-AzToken {
    $result = az account get-access-token --resource https://management.azure.com/ --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to get Azure token. Run 'az login' first." -ForegroundColor Red
        Write-Host $result -ForegroundColor Red
        exit 1
    }
    return ($result | ConvertFrom-Json).accessToken
}

# --- Function Discovery -------------------------------------------------------

function Get-HttpMethods {
    param([string]$Content)
    $all = @('get', 'post', 'put', 'delete', 'patch', 'head', 'options')
    return @($all | Where-Object { $Content -match """$_""" })
}

function Get-RouteTemplate {
    param([string]$TriggerContent, [string]$FunctionName)
    if ($TriggerContent -match 'Route\s*=\s*"([^"]*)"') {
        $route = $Matches[1].Trim().TrimStart('/')
        if ($route -ne '') {
            # Strip route constraints: {id:guid} -> {id}
            $route = [regex]::Replace($route, '\{(\w+):[^}]+\}', '{$1}')
            return $route
        }
    }
    return $FunctionName.ToLower()
}

function Get-FunctionsFromProject {
    param([string]$Path)

    $discovered = [System.Collections.Generic.List[hashtable]]::new()
    $skipped    = [System.Collections.Generic.List[string]]::new()

    $fnAttrPattern  = [regex]'\[Function\("([^"]+)"\)\]'
    $httpTriggerPat = [regex]'(?s)\[HttpTrigger\(([^)]+)\)\]'

    foreach ($file in @(Get-ChildItem -Path $Path -Filter '*.cs' -Recurse)) {
        $content = Get-Content $file.FullName -Raw

        foreach ($match in $fnAttrPattern.Matches($content)) {
            $functionName = $match.Groups[1].Value
            $windowStart  = $match.Index + $match.Length
            $windowLen    = [Math]::Min(900, $content.Length - $windowStart)
            $window       = $content.Substring($windowStart, $windowLen)

            $htMatch = $httpTriggerPat.Match($window)

            if (-not $htMatch.Success) {
                $skipped.Add("$functionName - no HttpTrigger (non-HTTP trigger, skipped)")
                continue
            }

            $triggerContent = $htMatch.Groups[1].Value
            $methods = @(Get-HttpMethods -Content $triggerContent)

            if ($methods.Count -eq 0) {
                $skipped.Add("$functionName - HttpTrigger found but no HTTP methods, skipped")
                continue
            }

            $route = Get-RouteTemplate -TriggerContent $triggerContent -FunctionName $functionName

            foreach ($method in $methods) {
                $discovered.Add(@{
                    FunctionName = $functionName
                    Method       = $method.ToUpper()
                    Route        = $route
                    OperationId  = "$($method.ToLower())-$($functionName.ToLower())"
                    DisplayName  = $functionName
                })
            }
        }
    }

    if ($skipped.Count -gt 0) {
        Write-Host "`n[SKIPPED] Non-HTTP functions:" -ForegroundColor Yellow
        $skipped | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
    }

    return $discovered
}

# --- APIM REST Helpers --------------------------------------------------------

function Invoke-ApimRest {
    param(
        [string]$Method,
        [string]$Url,
        [string]$Token,
        [hashtable]$Body = $null,
        [string]$ContentType = 'application/json'
    )

    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = $ContentType }
    $params  = @{ Method = $Method; Uri = $Url; Headers = $headers }

    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host "  APIM API error [$Method $Url]: HTTP $code - $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Invoke-ApimRestXml {
    param([string]$Method, [string]$Url, [string]$Token, [string]$Body)
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/vnd.ms-azure-apim.policy+xml' }
    try {
        Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $Body | Out-Null
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host "  Policy apply error: HTTP $code - $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Get-ApimOperations {
    param([string]$BaseUrl, [string]$Token)
    $all = [System.Collections.Generic.List[object]]::new()
    $url = "${BaseUrl}/operations?api-version=${ApiVersion}&`$top=250"

    do {
        $result = Invoke-ApimRest -Method GET -Url $url -Token $Token
        foreach ($op in $result.value) { $all.Add($op) }
        $url = if ($result.PSObject.Properties['nextLink']) { $result.nextLink } else { $null }
    } while ($url)

    return @($all)
}

function Get-TemplateParameters {
    param([string]$UrlTemplate)
    $params = @()
    [regex]::Matches($UrlTemplate, '\{(\w+)\}') | ForEach-Object {
        $params += @{ name = $_.Groups[1].Value; required = $true; values = @(); type = 'string' }
    }
    return $params
}

function Set-ApimOperation {
    param([string]$BaseUrl, [string]$Token, [hashtable]$Fn)
    $url         = "${BaseUrl}/operations/$($Fn.OperationId)?api-version=${ApiVersion}"
    $urlTemplate = '/' + $Fn.Route.TrimStart('/')
    $body = @{
        properties = @{
            displayName        = $Fn.DisplayName
            method             = $Fn.Method
            urlTemplate        = $urlTemplate
            templateParameters = @(Get-TemplateParameters -UrlTemplate $urlTemplate)
        }
    }
    Invoke-ApimRest -Method PUT -Url $url -Token $Token -Body $body | Out-Null
}

function Remove-ApimOperation {
    param([string]$BaseUrl, [string]$Token, [string]$OperationId)
    $url = "${BaseUrl}/operations/${OperationId}?api-version=${ApiVersion}"
    Invoke-ApimRest -Method DELETE -Url $url -Token $Token | Out-Null
}

function Set-OperationPolicy {
    param([string]$BaseUrl, [string]$Token, [string]$OperationId, [string]$BackendId)
    $url = "${BaseUrl}/operations/${OperationId}/policies/policy?api-version=${ApiVersion}"
    $xml = @"
<policies>
    <inbound>
        <base />
        <set-backend-service id="apim-generated-policy" backend-id="$BackendId" />
    </inbound>
    <backend>
        <base />
    </backend>
    <outbound>
        <base />
    </outbound>
    <on-error>
        <base />
    </on-error>
</policies>
"@
    Invoke-ApimRestXml -Method PUT -Url $url -Token $Token -Body $xml
}

# --- Diff ---------------------------------------------------------------------

function Get-Diff {
    param([array]$Local, [array]$Remote)

    $localMap  = @{}; foreach ($fn in $Local)  { $localMap[$fn.OperationId]  = $fn }
    $remoteMap = @{}; foreach ($op in $Remote) { $remoteMap[$op.name]         = $op }

    $create    = @()
    $update    = @()
    $delete    = @()
    $unchanged = @()

    foreach ($id in $localMap.Keys) {
        $fn = $localMap[$id]
        if (-not $remoteMap.ContainsKey($id)) {
            $create += $fn
        }
        else {
            $remote    = $remoteMap[$id]
            $localUrl  = '/' + $fn.Route.TrimStart('/')
            $remoteUrl = $remote.properties.urlTemplate
            $remoteMethod = $remote.properties.method

            if ($localUrl -ne $remoteUrl -or $fn.Method -ne $remoteMethod) {
                $update += $fn
            }
            else {
                $unchanged += $fn
            }
        }
    }

    foreach ($id in $remoteMap.Keys) {
        if (-not $localMap.ContainsKey($id)) { $delete += $remoteMap[$id] }
    }

    return @{ Create = $create; Update = $update; Delete = $delete; Unchanged = $unchanged }
}

# --- Main ---------------------------------------------------------------------

if (-not $DryRun -and -not $Apply) {
    Write-Host @"

Sync-FunctionToApim.ps1

  USAGE:
    .\Sync-FunctionToApim.ps1 -DryRun   [-ProjectPath <path>]
    .\Sync-FunctionToApim.ps1 -Apply    [-ProjectPath <path>] [-Prune]

  FLAGS:
    -DryRun        Show diff, make no changes
    -Apply         Apply creates and updates
    -Prune         (with -Apply) also delete stale APIM operations
    -ProjectPath   Path to Function App project (default: current directory)

"@
    exit 0
}

Write-Host "`n=== Function App -> APIM Sync ===" -ForegroundColor Cyan

$config  = Get-Config
$baseUrl = "https://management.azure.com/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)/providers/Microsoft.ApiManagement/service/$($config.apimInstance)/apis/$($config.apiId)"

Write-Host "`nAcquiring Azure token..." -ForegroundColor Gray
$token = Get-AzToken
Write-Host "Token OK" -ForegroundColor Green

$resolvedPath = Resolve-Path $ProjectPath
Write-Host "Scanning: $resolvedPath" -ForegroundColor Gray
$localFns = @(Get-FunctionsFromProject -Path $resolvedPath)
Write-Host "Found $($localFns.Count) HTTP operation(s) in source" -ForegroundColor Green

Write-Host "Fetching operations from APIM..." -ForegroundColor Gray
$remoteOps = @(Get-ApimOperations -BaseUrl $baseUrl -Token $token)
Write-Host "Found $($remoteOps.Count) operation(s) in APIM" -ForegroundColor Green

$diff = Get-Diff -Local $localFns -Remote $remoteOps

Write-Host "`n--- DIFF -----------------------------------------" -ForegroundColor Cyan

if (@($diff.Create).Count -gt 0) {
    Write-Host "`n[+] CREATE ($($diff.Create.Count)):" -ForegroundColor Green
    $diff.Create | ForEach-Object {
        Write-Host "    $($_.Method) /$($_.Route)  ->  $($_.OperationId)" -ForegroundColor Green
    }
}

if (@($diff.Update).Count -gt 0) {
    Write-Host "`n[~] UPDATE ($($diff.Update.Count)):" -ForegroundColor Yellow
    $diff.Update | ForEach-Object {
        Write-Host "    $($_.Method) /$($_.Route)  ->  $($_.OperationId)" -ForegroundColor Yellow
    }
}

if (@($diff.Delete).Count -gt 0) {
    $pruneLabel = if ($Prune -and $Apply) { 'WILL DELETE' } else { 'stale - use -Apply -Prune to remove' }
    Write-Host "`n[-] STALE ($($diff.Delete.Count)):" -ForegroundColor Red
    $diff.Delete | ForEach-Object {
        Write-Host "    $($_.name)  -  $pruneLabel" -ForegroundColor Red
    }
}

if (@($diff.Unchanged).Count -gt 0) {
    Write-Host "`n[=] UNCHANGED ($($diff.Unchanged.Count)):" -ForegroundColor DarkGray
    $diff.Unchanged | ForEach-Object {
        Write-Host "    $($_.OperationId)" -ForegroundColor DarkGray
    }
}

if ($DryRun) {
    Write-Host "`nDry run complete. No changes made.`n" -ForegroundColor Cyan
    exit 0
}

# --- Apply --------------------------------------------------------------------

Write-Host "`n--- APPLYING --------------------------------------" -ForegroundColor Cyan

foreach ($fn in $diff.Create) {
    Write-Host "  [+] Creating $($fn.OperationId) ..." -ForegroundColor Green -NoNewline
    Set-ApimOperation   -BaseUrl $baseUrl -Token $token -Fn $fn
    Set-OperationPolicy -BaseUrl $baseUrl -Token $token -OperationId $fn.OperationId -BackendId $config.backendId
    Write-Host " done" -ForegroundColor Green
}

foreach ($fn in $diff.Update) {
    Write-Host "  [~] Updating $($fn.OperationId) ..." -ForegroundColor Yellow -NoNewline
    Set-ApimOperation -BaseUrl $baseUrl -Token $token -Fn $fn
    Write-Host " done" -ForegroundColor Yellow
}

if ($Prune) {
    foreach ($op in $diff.Delete) {
        Write-Host "  [-] Deleting $($op.name) ..." -ForegroundColor Red -NoNewline
        Remove-ApimOperation -BaseUrl $baseUrl -Token $token -OperationId $op.name
        Write-Host " done" -ForegroundColor Red
    }
}

Write-Host "`nSync complete.`n" -ForegroundColor Cyan
