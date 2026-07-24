# email-purge-helper

Used to manage compliance searches in Exchange Online and purge messages, useful for malware and sensitive email recall.

## Requirements

- PowerShell 7 or later
- An account with permission to run Content Search / eDiscovery actions in Microsoft Purview

The `ExchangeOnlineManagement` module (3.2.0 or later) is installed automatically the first time you run the script if it is missing, and upgraded automatically if an older version is found. Nothing is reinstalled if a compatible version is already present.

## Usage

### Run directly from GitHub

You can run the script straight from this repo without cloning it first:

```powershell
irm https://raw.githubusercontent.com/Kinsman4249/email-purge-helper/main/scripts/Invoke-EmailPurge.ps1 | iex
```

This does not require changing your PowerShell execution policy or unblocking anything. Execution policy (and the "this file is unsigned" prompt) only applies when PowerShell runs a `.ps1` *file* from disk. `irm | iex` downloads the script text and runs it with `Invoke-Expression` in your current session, which is a different code path that the file-based execution policy does not gate.

One side effect: because there is no script file on disk in this mode, the script cannot find its own folder, so the run log is written to `.\logs` under your current working directory instead of next to the script. Everything else behaves the same.

If you'd rather download and run it as a file (for example, to keep a local copy or review it first), you'll hit the execution-policy check, since a downloaded `.ps1` is flagged unsigned:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/Kinsman4249/email-purge-helper/main/scripts/Invoke-EmailPurge.ps1 -OutFile Invoke-EmailPurge.ps1
Unblock-File .\Invoke-EmailPurge.ps1
powershell -ExecutionPolicy Bypass -File .\Invoke-EmailPurge.ps1
```

`-ExecutionPolicy Bypass` on the invocation only affects that one process, not your machine's default policy. Alternatively, set your session/user policy once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` and then run the script normally with `Unblock-File` first.

### Run from a local clone

```powershell
./scripts/Invoke-EmailPurge.ps1
```

It will:

1. Install or update the `ExchangeOnlineManagement` module if needed, then connect to Exchange Online and Security & Compliance PowerShell if you are not already connected.
2. Look for previous searches this script created (named `EmailPurge_*`) that were never purged or cleaned up, and offer to resume one instead of starting over.
3. If you don't resume one, ask for a sender, an optional recipient, and (if neither sender nor recipient is given) a required subject, plus an optional start/end date in `yy/mm/dd` format.
4. Create and run a compliance search, then show the item count and a preview of the matched messages so you can confirm nothing outside the intended sender/recipient/subject matched.
5. Ask you to type `DELETE` to confirm before purging. Anything else aborts without deleting anything, leaving the search in place so it shows up as resumable next time.
6. Purge using either `SoftDelete` (recoverable for about 14 days, the default) or `HardDelete` (permanent), based on your choice.
7. Once the purge is complete and logged, offer to remove the compliance search. Declining leaves it in place; if the purge itself didn't complete successfully, the search is always left in place so you can resume and retry it next run.

Every run writes a timestamped transcript to `scripts/logs/` recording the search name, query, item counts, and purge result.

## Testing

Since this script drives live Exchange Online compliance actions, test it against a mailbox and message you control:

1. Send yourself a test message with a distinctive subject.
2. Run the script, searching by that subject (or your own address as sender), and confirm the preview only shows that one message.
3. Abort at the confirmation prompt first to confirm nothing is deleted when you don't type `DELETE`.
4. Re-run and confirm with `DELETE` using `SoftDelete`, then verify the message is recoverable from the mailbox's Recoverable Items if needed.
