# email-purge-helper

Used to manage compliance searches in Exchange Online and purge messages, useful for malware and sensitive email recall.

## Requirements

- PowerShell 7 or later
- An account with permission to run Content Search / eDiscovery actions in Microsoft Purview

The `ExchangeOnlineManagement` module (3.2.0 or later) is installed automatically the first time you run the script if it is missing, and upgraded automatically if an older version is found. Nothing is reinstalled if a compatible version is already present.

## Usage

Run the interactive script from a PowerShell 7 prompt:

```powershell
./scripts/Invoke-EmailPurge.ps1
```

It will:

1. Install or update the `ExchangeOnlineManagement` module if needed, then connect to Exchange Online and Security & Compliance PowerShell if you are not already connected.
2. Ask for a sender, an optional recipient, and (if neither sender nor recipient is given) a required subject, plus an optional start/end date in `yy/mm/dd` format.
3. Create and run a compliance search, then show the item count and a preview of the matched messages so you can confirm nothing outside the intended sender/recipient/subject matched.
4. Ask you to type `DELETE` to confirm before purging. Anything else aborts without deleting anything.
5. Purge using either `SoftDelete` (recoverable for about 14 days, the default) or `HardDelete` (permanent), based on your choice.

Every run writes a timestamped transcript to `scripts/logs/` recording the search name, query, item counts, and purge result.

## Testing

Since this script drives live Exchange Online compliance actions, test it against a mailbox and message you control:

1. Send yourself a test message with a distinctive subject.
2. Run the script, searching by that subject (or your own address as sender), and confirm the preview only shows that one message.
3. Abort at the confirmation prompt first to confirm nothing is deleted when you don't type `DELETE`.
4. Re-run and confirm with `DELETE` using `SoftDelete`, then verify the message is recoverable from the mailbox's Recoverable Items if needed.
