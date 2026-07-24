#Requires -Version 7.0
<#
Interactive Exchange Online compliance search + purge helper.

Walks through: look for a previous search (created by this script, or any
other unfinished compliance search on request) that was never purged or
cleaned up and offer to resume it, or search for matching messages -> review
what was found (and confirm nothing else matched) -> explicit typed
confirmation -> purge -> offer to remove the compliance search now that it
is logged. No purge happens without that separate confirmation step.

=====================================================================
CHEAT SHEET - PowerShell syntax used in this script, for readers new
to PowerShell. Skip this if you already know PowerShell.
=====================================================================

  $Something             A variable. PowerShell variables are always
                          prefixed with a dollar sign.

  "text $var text"        Double-quoted strings interpolate variables
                          automatically. Single-quoted strings ('...')
                          do NOT interpolate - they are always literal.

  "$($expr)"              Inside a double-quoted string, $(...) runs
                          any PowerShell expression and inlines the
                          result as text. Needed for anything more
                          complex than a bare variable name, e.g.
                          "$($search.Items)" to print a property.

  Verb-Noun                PowerShell commands ("cmdlets") are always
                          named Verb-Noun, e.g. Get-Module, New-Item,
                          Read-Host. This script also defines its own
                          functions the same way (e.g. Ensure-Sessions)
                          so they read the same as built-in cmdlets.

  function Foo { }         Defines a reusable block of code, called
                          later just like a built-in cmdlet.

  param()                  Declares the parameters (arguments) a
                          function or script accepts. [Mandatory]
                          means the caller must supply that value.

  [CmdletBinding()]        Placed above param() to opt a function or
                          script into PowerShell's standard cmdlet
                          behavior (e.g. -Verbose, -ErrorAction).

  |  (pipe)                 Sends the output of one command into the
                          next command, e.g.
                          Get-Module | Sort-Object Version.

  Where-Object { $_.X }    Filters items flowing through the pipeline.
                          $_ means "the current item being looked at."

  @( ... )                 Forces the result to be treated as an array,
                          even if only zero or one items come back.
                          Without it, a single result would not support
                          array operations like .Count reliably.

  -match / -notmatch       Regular-expression comparison. Returns
                          $true/$false depending on whether the text
                          matches the pattern on the right.

  (?i)                     A regex flag meaning "case-insensitive,"
                          used inside -match patterns in this script
                          (e.g. so typing "Other" or "other" both work).

  -like                    Wildcard comparison (simpler than regex).
                          * matches any run of characters, e.g.
                          "EmailPurge_*" matches anything starting
                          with that prefix.

  -notin                   Checks that a value is NOT present in a
                          list/array.

  if (...) { } elseif { } else { }
                          Standard conditional branching. In this
                          script it's sometimes used to compute a
                          value directly, e.g.
                          $x = if (cond) { "a" } else { "b" }

  do { ... } while (cond)  A loop that always runs its body at least
                          once, then repeats while the condition is
                          true. Used here to poll a search/action
                          status every few seconds until it finishes.

  try { } catch { }        Runs the try block; if it throws an error,
                          the catch block runs instead of stopping
                          the script (since $ErrorActionPreference is
                          'Stop', ordinary errors would otherwise halt
                          everything).

  scriptblock / { ... }    Code wrapped in curly braces can be stored
                          in a variable or passed as a parameter and
                          run later. New-ComplianceActionFresh below
                          takes one as its -Create parameter.

  & $scriptblock           The "call operator." Executes a scriptblock
                          (or command name) that's stored in a
                          variable, rather than just printing it.

  `"                       A backtick is PowerShell's escape
                          character. `" inserts a literal double-quote
                          character inside a double-quoted string.

=====================================================================
#>

[CmdletBinding()]
param()

# Stop the whole script on any unhandled error instead of continuing on to
# the next line. This matters a lot here because several steps (like
# purging) should never run if an earlier step silently failed.
$ErrorActionPreference = 'Stop'

# 3.2.0 is the first release built on the REST-based cmdlets (no WinRM/Basic
# Auth), which is what Connect-IPPSSession and the compliance search cmdlets
# used here require now that Basic Auth is retired.
$MinimumModuleVersion = [version]'3.2.0'

# Every search this script creates uses this prefix, so resume-detection can
# tell its own searches apart from ones started manually or by someone else.
$SearchNamePrefix = 'EmailPurge_'

function Ensure-ExchangeOnlineModule {
    # Get-Module -ListAvailable looks at every version of this module that is
    # installed on the machine (not just the one currently loaded). Sorting
    # by Version descending and taking the first result gets us the newest
    # installed copy, if any exist at all.
    $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $installed) {
        # Install-Module downloads and installs a module from the PowerShell
        # Gallery. -Scope CurrentUser avoids needing admin rights. -Force
        # skips the "are you sure" prompt, and -AllowClobber lets it
        # overwrite commands from other modules that happen to share a name.
        Write-Host "ExchangeOnlineManagement module not found. Installing for the current user..." -ForegroundColor Cyan
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion $MinimumModuleVersion -Force -AllowClobber
    } elseif ($installed.Version -lt $MinimumModuleVersion) {
        Write-Host "ExchangeOnlineManagement $($installed.Version) is installed but $MinimumModuleVersion or later is required. Updating..." -ForegroundColor Cyan
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion $MinimumModuleVersion -Force -AllowClobber
    } else {
        Write-Host "ExchangeOnlineManagement $($installed.Version) already installed, skipping install." -ForegroundColor Cyan
    }

    # Import-Module actually loads the module's cmdlets (Connect-ExchangeOnline,
    # New-ComplianceSearch, etc.) into this PowerShell session so they can be
    # called below. Installing a module does not automatically load it.
    Import-Module ExchangeOnlineManagement -MinimumVersion $MinimumModuleVersion -ErrorAction Stop
}

function Ensure-Sessions {
    $connected = $false
    try {
        # Get-OrganizationConfig is a lightweight Exchange Online cmdlet that
        # only succeeds if we already have an active connection. It's used
        # here purely as a connectivity check, and its actual output is
        # discarded with Out-Null since we only care whether it throws.
        Get-OrganizationConfig -ErrorAction Stop | Out-Null
        $connected = $true
    } catch { }
    if (-not $connected) {
        # Connect-ExchangeOnline opens an interactive sign-in (it will pop up
        # a browser/device-code prompt) and establishes the Exchange Online
        # session used for connectivity checks like the one above.
        Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
        Connect-ExchangeOnline
    }

    $ippsConnected = $false
    try {
        # Same idea as above, but Get-ComplianceSearch only succeeds once we
        # have a Security & Compliance PowerShell session, which is the
        # separate connection actually used to create/run/purge searches.
        Get-ComplianceSearch -ErrorAction Stop | Out-Null
        $ippsConnected = $true
    } catch { }
    if (-not $ippsConnected) {
        # Connect-IPPSSession opens the separate sign-in for Security &
        # Compliance PowerShell (IPPS = Information Protection and
        # Compliance). -EnableSearchOnlySession requests a lighter-weight
        # session limited to search-related cmdlets, which is all this
        # script needs.
        Write-Host "Connecting to Security & Compliance PowerShell..." -ForegroundColor Cyan
        Connect-IPPSSession -EnableSearchOnlySession
    }
}

function Read-DateYyMmDd {
    param([string]$Prompt)
    while ($true) {
        # Read-Host prints $Prompt and waits for the user to type a line of
        # input, returning it as a string.
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        try {
            # ParseExact requires the input to match the given format exactly
            # (here, two-digit year/month/day separated by slashes), so we
            # don't silently accept ambiguous formats like mm/dd/yy.
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
        # Compliance search actions (preview/purge) run asynchronously in
        # Exchange Online, so we have to poll their status every few seconds
        # rather than getting a result immediately.
        Start-Sleep -Seconds 5
        # Get-ComplianceSearchAction looks up an in-progress or finished
        # action (like a preview or purge) by its identity/name and reports
        # its current status.
        $action = Get-ComplianceSearchAction -Identity $Identity
        Write-Host "  $Label status: $($action.Status)"
    } while ($action.Status -notin @('Completed', 'Failed'))
    return $action
}

function Get-ResumableSearches {
    # Without -AllSearches, only considers searches this script created (the
    # EmailPurge_ prefix). With -AllSearches, considers every compliance
    # search, including ones started manually or by someone else, so a
    # search that was set up outside this script can still be resumed.
    param([switch]$AllSearches)
    $searches = Get-ComplianceSearch
    if (-not $AllSearches) {
        $searches = $searches | Where-Object { $_.Name -like "$SearchNamePrefix*" }
    }
    # A search counts as "resumable" (not finished) if it has no purge
    # action yet, or its purge action exists but never completed - e.g. the
    # script was interrupted, or the purge failed and was never retried.
    $searches | Where-Object {
        $purgeAction = Get-ComplianceSearchAction -Identity "$($_.Name)_Purge" -ErrorAction SilentlyContinue
        -not $purgeAction -or $purgeAction.Status -ne 'Completed'
    }
}

function Write-ResumableSearchList {
    param([Parameter(Mandatory)][object[]]$Searches)
    # A plain numeric for-loop (rather than foreach) is used here because we
    # need each item's position ($i + 1) to display as a pickable number,
    # matching what Resolve-ResumeChoice expects the user to type back.
    for ($i = 0; $i -lt $Searches.Count; $i++) {
        $r = $Searches[$i]
        Write-Host "  [$($i + 1)] $($r.Name) - Status: $($r.Status), Items: $($r.Items)"
        Write-Host "      Query: $($r.ContentMatchQuery)"
    }
}

function Resolve-ResumeChoice {
    param(
        [Parameter(Mandatory)][object[]]$Searches,
        [Parameter(Mandatory)][string]$Choice
    )
    # Only treat the input as a valid pick if it's purely digits (^\d+$) and
    # falls within the range of numbers actually shown to the user. Anything
    # else (blank, "other", garbage) returns $null so the caller treats it
    # as "no selection."
    if ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $Searches.Count) {
        return $Searches[[int]$Choice - 1]
    }
    return $null
}

function New-ComplianceActionFresh {
    # Removes a leftover action with this identity first, if one exists, so a
    # retried preview/purge does not fail with "an action already exists."
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][scriptblock]$Create
    )
    if (Get-ComplianceSearchAction -Identity $Identity -ErrorAction SilentlyContinue) {
        # Remove-ComplianceSearchAction deletes a previously created
        # preview/purge action record so a new one can be created in its
        # place. -Confirm:$false skips the interactive "are you sure" prompt
        # since this script already gates real deletions behind its own
        # explicit confirmations.
        Remove-ComplianceSearchAction -Identity $Identity -Confirm:$false
    }
    # Runs the scriptblock that was passed in via -Create, i.e. actually
    # creates the new preview or purge action.
    & $Create
}

# Make sure the ExchangeOnlineManagement module is installed/up to date and
# loaded, then make sure we're actually signed in, before doing anything else.
Ensure-ExchangeOnlineModule
Ensure-Sessions

# Build the path to a "logs" folder next to this script, and create it if it
# doesn't exist yet, so every run's transcript has somewhere to go.
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
# One log file per run, timestamped so repeated runs never overwrite each
# other's history.
$logPath = Join-Path $logDir "purge-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
# Start-Transcript records everything printed to the console (and much of
# what's typed) into $logPath for the rest of this script's run, giving a
# durable record of what search/purge actions were taken.
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Host "=== Email Purge Helper ===" -ForegroundColor Cyan
    Write-Host "Searches Exchange Online for messages matching your criteria, lets you review"
    Write-Host "what was found, and only purges after you type an explicit confirmation."
    Write-Host ""

    # These stay $null until either an existing search is resumed or a new
    # one is created below; everything after this point works the same way
    # regardless of which path filled them in.
    $searchName = $null
    $query = $null

    # Look for searches this script created previously that never got
    # purged/cleaned up, so the user can pick up where a previous run left
    # off instead of starting over (and possibly duplicating a search).
    $ownResumable = @(Get-ResumableSearches)
    if ($ownResumable.Count -gt 0) {
        Write-Host "Found $($ownResumable.Count) previous search(es) created by this script that were never purged or cleaned up:" -ForegroundColor Yellow
        Write-ResumableSearchList -Searches $ownResumable
    } else {
        Write-Host "No previous searches created by this script are waiting on a purge." -ForegroundColor Yellow
    }

    $resumeChoice = Read-Host "Enter a number to resume one listed above, 'other' to also check compliance searches not created by this script (e.g. started manually), or press Enter to start a new search"
    $chosen = Resolve-ResumeChoice -Searches $ownResumable -Choice $resumeChoice

    # Only fall back to checking every compliance search in the tenant if the
    # user didn't pick a number above and specifically typed "other" - this
    # keeps the default path from touching searches that aren't ours.
    if (-not $chosen -and $resumeChoice -match '^(?i)other$') {
        $otherResumable = @(Get-ResumableSearches -AllSearches | Where-Object { $_.Name -notin $ownResumable.Name })
        if ($otherResumable.Count -eq 0) {
            Write-Host "No other unfinished compliance searches were found." -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host "Other unfinished compliance search(es), including any started outside this script:" -ForegroundColor Yellow
            Write-ResumableSearchList -Searches $otherResumable
            $otherChoice = Read-Host "Enter a number to resume one listed above, or press Enter to start a new search"
            $chosen = Resolve-ResumeChoice -Searches $otherResumable -Choice $otherChoice
        }
    }

    if ($chosen) {
        $searchName = $chosen.Name
        $query = $chosen.ContentMatchQuery
        Write-Host "Resuming search '$searchName'." -ForegroundColor Cyan
    }
    Write-Host ""

    # Ask up front (whether resuming or starting fresh) how the eventual
    # purge should behave. Defaulting to SoftDelete means messages land in
    # Recoverable Items for ~14 days instead of being gone immediately,
    # which is the safer default for a helper script like this one.
    $purgeTypeInput = Read-Host "Purge type: SoftDelete (recoverable ~14 days, recommended) or HardDelete (permanent) [SoftDelete]"
    $purgeType = if ($purgeTypeInput -match '^(?i)hard') { 'HardDelete' } else { 'SoftDelete' }

    if (-not $searchName) {
        # No existing search was chosen, so gather criteria to build a new one.
        $sender = Read-Host "Sender email address to search for (optional, press Enter to skip)"
        $recipient = Read-Host "Recipient (To) email address to search for (optional, press Enter to skip)"

        $subject = $null
        if ([string]::IsNullOrWhiteSpace($sender) -and [string]::IsNullOrWhiteSpace($recipient)) {
            # If neither sender nor recipient was given, a subject becomes
            # mandatory - otherwise the search query would have no criteria
            # at all and could match every message in the tenant.
            while ([string]::IsNullOrWhiteSpace($subject)) {
                $subject = Read-Host "Subject (required, since no sender or recipient was given)"
            }
        } else {
            $subject = Read-Host "Subject to search for (optional, press Enter to skip)"
        }

        $startDate = Read-DateYyMmDd "Start date (yy/mm/dd, optional; leave blank to search as far back as available)"
        $endDate = Read-DateYyMmDd "End date (yy/mm/dd, optional; leave blank to search through right now)"

        # Build up the KQL (Keyword Query Language) clauses for whichever
        # criteria were actually supplied, then join them with AND. Each
        # value the user typed is wrapped in its own parentheses and double
        # quotes (with `" escaping the quote character) so the compliance
        # search engine treats it as one exact value.
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

        # Just a human-readable summary of the date range for the console -
        # not used in the actual query - so the user can double check what
        # they entered before the search runs.
        $dateRangeDescription =
            if ($startDate -and $endDate) { "$($startDate.ToString('yyyy-MM-dd')) through $($endDate.ToString('yyyy-MM-dd'))" }
            elseif ($startDate) { "$($startDate.ToString('yyyy-MM-dd')) through right now" }
            elseif ($endDate) { "as far back as available through $($endDate.ToString('yyyy-MM-dd'))" }
            else { "no date restriction" }

        # Timestamped name so every search this script creates is unique and
        # identifiable later as "created by this script" via $SearchNamePrefix.
        $searchName = "$SearchNamePrefix$(Get-Date -Format 'yyyyMMdd_HHmmss')"

        Write-Host ""
        Write-Host "Query: $query"
        Write-Host "Date range: $dateRangeDescription"
        Write-Host "Creating compliance search '$searchName'..."
        # New-ComplianceSearch defines the search (name, where to look, and
        # what query to match) but does not run it yet. -ExchangeLocation All
        # means every mailbox in the tenant is in scope.
        New-ComplianceSearch -Name $searchName -ExchangeLocation All -ContentMatchQuery $query | Out-Null
        # Start-ComplianceSearch kicks off the actual search that was just
        # defined above.
        Start-ComplianceSearch -Identity $searchName | Out-Null
    }

    Write-Host "Waiting for search to complete..."
    do {
        Start-Sleep -Seconds 5
        # Get-ComplianceSearch (without -Identity pointing at an action)
        # returns the search's own status/progress, including how many
        # items it has matched so far.
        $search = Get-ComplianceSearch -Identity $searchName
        Write-Host "  Search status: $($search.Status)"
    } while ($search.Status -notin @('Completed', 'Failed', 'PartiallyCompleted'))

    Write-Host ""
    Write-Host "=== Search results ===" -ForegroundColor Cyan
    Write-Host "Items found: $($search.Items)"
    Write-Host "Size: $($search.Size)"

    if ($search.Items -eq 0) {
        Write-Host "No matching items were found. Nothing to purge." -ForegroundColor Yellow
        $cleanupEmpty = Read-Host "Remove this empty compliance search now? (Y/n)"
        if ($cleanupEmpty -notmatch '^(?i)n') {
            # Remove-ComplianceSearch deletes the search definition itself
            # (as opposed to Remove-ComplianceSearchAction, which only
            # removes a preview/purge action record tied to a search).
            Remove-ComplianceSearch -Identity $searchName -Confirm:$false
            Write-Host "Removed compliance search '$searchName'." -ForegroundColor Cyan
        } else {
            Write-Host "Left compliance search '$searchName' in place." -ForegroundColor Yellow
        }
        return
    }

    Write-Host ""
    Write-Host "Generating a preview so you can confirm no unexpected senders/recipients matched..." -ForegroundColor Cyan
    $previewActionName = "${searchName}_Preview"
    New-ComplianceActionFresh -Identity $previewActionName -Create {
        # New-ComplianceSearchAction with -Preview samples matched messages
        # (sender/recipient/subject, etc.) without deleting anything, so the
        # user can sanity-check the results before any purge happens.
        New-ComplianceSearchAction -SearchName $searchName -Preview | Out-Null
    }
    Wait-ComplianceAction -Identity $previewActionName -Label "Preview" | Out-Null

    # -Details asks for the actual preview content (the sampled message
    # list) rather than just the action's status.
    $previewDetails = (Get-ComplianceSearchAction -Identity $previewActionName -Details).Results
    Write-Host ""
    Write-Host "=== Preview details (verify sender/recipient/subject match what you expect) ===" -ForegroundColor Cyan
    Write-Host $previewDetails
    Write-Host ""
    Write-Host "You can also review the full result list in the Purview compliance portal under this search's name." -ForegroundColor Yellow

    Write-Host ""
    Write-Host "Nothing has been deleted yet. Review the results above before continuing." -ForegroundColor Yellow
    # This is the one and only gate before anything is actually deleted: the
    # user must type the literal word DELETE, not just press Enter or type
    # "y" - anything else safely aborts.
    $confirm = Read-Host "Type DELETE to purge these $($search.Items) item(s) using $purgeType, or anything else to abort"
    if ($confirm -ne 'DELETE') {
        Write-Host "Aborted. No messages were purged. Search '$searchName' is still saved if you want to re-review or resume later." -ForegroundColor Yellow
        return
    }

    Write-Host "Purging with $purgeType..."
    $purgeActionName = "${searchName}_Purge"
    New-ComplianceActionFresh -Identity $purgeActionName -Create {
        # This is the step that actually deletes the matched messages.
        # -PurgeType controls whether they go to Recoverable Items
        # (SoftDelete) or are permanently removed (HardDelete).
        # -Confirm:$false skips PowerShell's own "are you sure" prompt,
        # since the DELETE confirmation above already served that purpose.
        New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $purgeType -Confirm:$false | Out-Null
    }
    $purgeAction = Wait-ComplianceAction -Identity $purgeActionName -Label "Purge"

    Write-Host ""
    Write-Host "Purge action finished with status: $($purgeAction.Status)" -ForegroundColor Cyan
    Write-Host "Search name: $searchName"
    Write-Host "Log written to: $logPath"

    if ($purgeAction.Status -eq 'Completed') {
        $cleanup = Read-Host "Purge is complete and logged. Remove this compliance search now? (Y/n)"
        if ($cleanup -notmatch '^(?i)n') {
            Remove-ComplianceSearch -Identity $searchName -Confirm:$false
            Write-Host "Removed compliance search '$searchName'." -ForegroundColor Cyan
        } else {
            Write-Host "Left compliance search '$searchName' in place." -ForegroundColor Yellow
        }
    } else {
        # If the purge itself failed or only partially completed, leave the
        # search in place (rather than cleaning it up) so it still shows up
        # as "resumable" the next time this script runs.
        Write-Host "Purge did not complete successfully, so the search was left in place. Re-run this script and choose to resume '$searchName' to retry." -ForegroundColor Yellow
    }
}
finally {
    # Runs no matter how the try block above exits (normal completion, an
    # early `return`, or an uncaught error), so the transcript is always
    # closed out and the log file is left in a readable, finished state.
    Stop-Transcript | Out-Null
}
