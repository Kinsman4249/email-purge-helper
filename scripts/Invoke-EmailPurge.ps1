#Requires -Version 7.0
<#
Interactive Exchange Online compliance search + purge helper.

Walks through: search for matching messages -> review what was found (and
confirm nothing else matched) -> explicit typed confirmation -> purge.
No purge happens without that separate confirmation step.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 3.2.0 is the first release built on the REST-based cmdlets (no WinRM/Basic
# Auth), which is what Connect-IPPSSession and the compliance search cmdlets
# used here require now that Basic Auth is retired.
$MinimumModuleVersion = [version]'3.2.0'

function Ensure-ExchangeOnlineModule {
    $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $installed) {
        Write-Host "ExchangeOnlineManagement module not found. Installing for the current user..." -ForegroundColor Cyan
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion $MinimumModuleVersion -Force -AllowClobber
    } elseif ($installed.Version -lt $MinimumModuleVersion) {
        Write-Host "ExchangeOnlineManagement $($installed.Version) is installed but $MinimumModuleVersion or later is required. Updating..." -ForegroundColor Cyan
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion $MinimumModuleVersion -Force -AllowClobber
    } else {
        Write-Host "ExchangeOnlineManagement $($installed.Version) already installed, skipping install." -ForegroundColor Cyan
    }

    Import-Module ExchangeOnlineManagement -MinimumVersion $MinimumModuleVersion -ErrorAction Stop
}

function Ensure-Sessions {
    $connected = $false
    try {
        Get-OrganizationConfig -ErrorAction Stop | Out-Null
        $connected = $true
    } catch { }
    if (-not $connected) {
        Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
        Connect-ExchangeOnline
    }

    $ippsConnected = $false
    try {
        Get-ComplianceSearch -ErrorAction Stop | Out-Null
        $ippsConnected = $true
    } catch { }
    if (-not $ippsConnected) {
        Write-Host "Connecting to Security & Compliance PowerShell..." -ForegroundColor Cyan
        Connect-IPPSSession -EnableSearchOnlySession
    }
}

function Read-DateYyMmDd {
    param([string]$Prompt)
    while ($true) {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        try {
            return [datetime]::ParseExact($raw.Trim(), 'yy/MM/dd', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            Write-Host "Could not parse '$raw' as yy/mm/dd. Example: 24/01/15. Leave blank to skip." -ForegroundColor Yellow
        }
    }
}

function Wait-ComplianceAction {
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Label
    )
    do {
        Start-Sleep -Seconds 5
        $action = Get-ComplianceSearchAction -Identity $Identity
        Write-Host "  $Label status: $($action.Status)"
    } while ($action.Status -notin @('Completed', 'Failed'))
    return $action
}

Ensure-ExchangeOnlineModule
Ensure-Sessions

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logPath = Join-Path $logDir "purge-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Host "=== Email Purge Helper ===" -ForegroundColor Cyan
    Write-Host "Searches Exchange Online for messages matching your criteria, lets you review"
    Write-Host "what was found, and only purges after you type an explicit confirmation."
    Write-Host ""

    $sender = Read-Host "Sender email address to search for (optional, press Enter to skip)"
    $recipient = Read-Host "Recipient (To) email address to search for (optional, press Enter to skip)"

    $subject = $null
    if ([string]::IsNullOrWhiteSpace($sender) -and [string]::IsNullOrWhiteSpace($recipient)) {
        while ([string]::IsNullOrWhiteSpace($subject)) {
            $subject = Read-Host "Subject (required, since no sender or recipient was given)"
        }
    } else {
        $subject = Read-Host "Subject to search for (optional, press Enter to skip)"
    }

    $startDate = Read-DateYyMmDd "Start date (yy/mm/dd, optional; leave blank to search as far back as available)"
    $endDate = Read-DateYyMmDd "End date (yy/mm/dd, optional; leave blank to search through right now)"

    $purgeTypeInput = Read-Host "Purge type: SoftDelete (recoverable ~14 days, recommended) or HardDelete (permanent) [SoftDelete]"
    $purgeType = if ($purgeTypeInput -match '^(?i)hard') { 'HardDelete' } else { 'SoftDelete' }

    $clauses = @()
    if ($sender)    { $clauses += "(from:`"$sender`")" }
    if ($recipient) { $clauses += "(to:`"$recipient`")" }
    if ($subject)   { $clauses += "(subject:`"$subject`")" }
    # Only add a bound when its date was actually given. Omitting the lower
    # bound with only an end date means the search reaches as far back as
    # indexed mail exists; omitting the upper bound with only a start date
    # means it naturally extends through the moment the search runs.
    if ($startDate) { $clauses += "(received>=$($startDate.ToString('yyyy-MM-dd')))" }
    if ($endDate)   { $clauses += "(received<=$($endDate.ToString('yyyy-MM-dd')))" }
    $query = $clauses -join ' AND '

    $dateRangeDescription =
        if ($startDate -and $endDate) { "$($startDate.ToString('yyyy-MM-dd')) through $($endDate.ToString('yyyy-MM-dd'))" }
        elseif ($startDate) { "$($startDate.ToString('yyyy-MM-dd')) through right now" }
        elseif ($endDate) { "as far back as available through $($endDate.ToString('yyyy-MM-dd'))" }
        else { "no date restriction" }

    $searchName = "EmailPurge_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    Write-Host ""
    Write-Host "Query: $query"
    Write-Host "Date range: $dateRangeDescription"
    Write-Host "Creating compliance search '$searchName'..."
    New-ComplianceSearch -Name $searchName -ExchangeLocation All -ContentMatchQuery $query | Out-Null
    Start-ComplianceSearch -Identity $searchName | Out-Null

    Write-Host "Waiting for search to complete..."
    do {
        Start-Sleep -Seconds 5
        $search = Get-ComplianceSearch -Identity $searchName
        Write-Host "  Search status: $($search.Status)"
    } while ($search.Status -notin @('Completed', 'Failed', 'PartiallyCompleted'))

    Write-Host ""
    Write-Host "=== Search results ===" -ForegroundColor Cyan
    Write-Host "Items found: $($search.Items)"
    Write-Host "Size: $($search.Size)"

    if ($search.Items -eq 0) {
        Write-Host "No matching items were found. Nothing to purge. Search '$searchName' is left in place for reference." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Generating a preview so you can confirm no unexpected senders/recipients matched..." -ForegroundColor Cyan
    $previewActionName = "${searchName}_Preview"
    New-ComplianceSearchAction -SearchName $searchName -Preview | Out-Null
    Wait-ComplianceAction -Identity $previewActionName -Label "Preview" | Out-Null

    $previewDetails = (Get-ComplianceSearchAction -Identity $previewActionName -Details).Results
    Write-Host ""
    Write-Host "=== Preview details (verify sender/recipient/subject match what you expect) ===" -ForegroundColor Cyan
    Write-Host $previewDetails
    Write-Host ""
    Write-Host "You can also review the full result list in the Purview compliance portal under this search's name." -ForegroundColor Yellow

    Write-Host ""
    Write-Host "Nothing has been deleted yet. Review the results above before continuing." -ForegroundColor Yellow
    $confirm = Read-Host "Type DELETE to purge these $($search.Items) item(s) using $purgeType, or anything else to abort"
    if ($confirm -ne 'DELETE') {
        Write-Host "Aborted. No messages were purged. Search '$searchName' is still saved if you want to re-review or resume later." -ForegroundColor Yellow
        return
    }

    Write-Host "Purging with $purgeType..."
    New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $purgeType -Confirm:$false | Out-Null
    $purgeAction = Wait-ComplianceAction -Identity "${searchName}_Purge" -Label "Purge"

    Write-Host ""
    Write-Host "Purge action finished with status: $($purgeAction.Status)" -ForegroundColor Cyan
    Write-Host "Search name: $searchName"
    Write-Host "Log written to: $logPath"
}
finally {
    Stop-Transcript | Out-Null
}
