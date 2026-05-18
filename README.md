# UMich GSI Posting Watcher CLI

This package contains authoritative command-line versions of the UMich GSI Posting Watcher in both Python and PowerShell.

The scripts monitor two sources:

1. UMich Careers career-interest pages, defaulting to career interest ID `171`
2. UMSI Graduate Student Instructor Google Sites open postings page

The scripts detect newly discovered postings by saving normalized posting keys to a local JSON state file.

## What the scripts do

Each script:

- fetches postings from UMich Careers
- fetches open postings from the UMSI GSI Google Sites page
- extracts job opening IDs when available
- normalizes each posting into a consistent shape
- compares postings against a local state file
- prints only new postings by default
- supports showing all postings
- supports text, JSON, and CSV output

## Limitations

These are CLI scripts, not the full web app.

They do not:

- send email
- run continuously
- expose a web UI
- manage subscribers
- implement scheduled background jobs
- implement daily digest notifications

The scripts rely on the current page structure of UMich Careers and UMSI Google Sites. If either site changes its markup or text layout, the parser may need updates.

## Python CLI

### Requirements

Python 3.11+ is recommended.

Install dependencies:

```bash
pip install requests beautifulsoup4
```

### Usage

Run both sources and show only new postings:

```bash
python umich_gsi_watch.py
```

Show all current postings:

```bash
python umich_gsi_watch.py --show-all
```

Run only UMich Careers:

```bash
python umich_gsi_watch.py --source careers --career-interest-id 171
```

Run only UMSI Google Sites:

```bash
python umich_gsi_watch.py --source umsi
```

Output JSON:

```bash
python umich_gsi_watch.py --show-all --format json
```

Output CSV:

```bash
python umich_gsi_watch.py --show-all --format csv
```

Use a custom state file:

```bash
python umich_gsi_watch.py --state-path ./state/umich-gsi-seen-postings.json
```

Test without updating the state file:

```bash
python umich_gsi_watch.py --no-save-state
```

## PowerShell CLI

### Requirements

PowerShell 7+ is recommended.

The script uses built-in PowerShell cmdlets and .NET classes. No external PowerShell modules are required.

### Usage

Run both sources and show only new postings:

```powershell
.\Watch-UmichGsiPostings.ps1
```

Show all current postings:

```powershell
.\Watch-UmichGsiPostings.ps1 -ShowAll
```

Run only UMich Careers:

```powershell
.\Watch-UmichGsiPostings.ps1 -Source Careers -CareerInterestId 171
```

Run only UMSI Google Sites:

```powershell
.\Watch-UmichGsiPostings.ps1 -Source UMSI
```

Output JSON:

```powershell
.\Watch-UmichGsiPostings.ps1 -ShowAll -OutputFormat Json
```

Output CSV:

```powershell
.\Watch-UmichGsiPostings.ps1 -ShowAll -OutputFormat Csv
```

Use a custom state file:

```powershell
.\Watch-UmichGsiPostings.ps1 -StatePath .\state\umich-gsi-seen-postings.json
```

Test without updating the state file:

```powershell
.\Watch-UmichGsiPostings.ps1 -NoSaveState
```

## State tracking

Both scripts use a JSON state file.

Default state file:

```text
umich-gsi-seen-postings.json
```

The state file stores normalized posting keys. A posting is considered new when its key is not already present in the state file.

Posting key rules:

```text
If job_opening_id exists:
  {source}:job:{job_opening_id}

If job_opening_id is missing:
  {source}:url:{url}
```

First run behavior:

- The first run treats all discovered postings as new.
- After the first run, the state file is saved.
- Future runs only show postings not already in the state file.

Use `--no-save-state` or `-NoSaveState` to test without modifying the state file.

## Output fields

Each normalized posting may include:

```text
source
title
job_opening_id
url
date_posted
department
location
status
course
```

Some fields may be empty depending on the source.

UMich Careers usually provides:

```text
date_posted
title
job_opening_id
department
location
url
```

UMSI Google Sites usually provides:

```text
status
course
title
job_opening_id, when listed on detail page
url
```

## Scheduling examples

### Windows Task Scheduler with PowerShell

Example action:

```powershell
pwsh.exe -File "C:\path\to\Watch-UmichGsiPostings.ps1"
```

### cron with Python

Example hourly run:

```cron
0 * * * * /usr/bin/python3 /path/to/umich_gsi_watch.py >> /path/to/umich-gsi-watch.log 2>&1
```

## Recommended next step

For a full application, use these CLI scripts as the source/parsing layer and move the following concerns into the web app:

- database persistence
- subscriber management
- email notifications
- scheduler management
- frontend polling and settings
- digest notifications
