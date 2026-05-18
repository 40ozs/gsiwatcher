<#
.SYNOPSIS
    Watches UMich Careers and UMSI GSI postings from the command line.
    
    I was tired of opening the URLs so I made this super stupid script. 
    I want my education funded so I made thischeck for postings.
    
    This can run from the task manager. There's a python verion.
    The GSI link is fairly specific, so changing that may not work
    but, T H E O R E T I C A L L Y, it could work with other links.
    I'm not going to test or try that becuase those are going to pay
    for my edu.

.DESCRIPTION
    This script checks:
    1. UMich Careers career-interest pages
    2. UMSI Graduate Student Instructor Google Sites open postings page

    It detects new postings by comparing normalized posting keys against a
    local JSON state file.

.EXAMPLE
    .\Watch-UmichGsiPostings.ps1 -ShowAll

.EXAMPLE
    .\Watch-UmichGsiPostings.ps1 -Source Careers -CareerInterestId 171

.EXAMPLE
    .\Watch-UmichGsiPostings.ps1 -Source UMSI

.EXAMPLE
    .\Watch-UmichGsiPostings.ps1 -OutputFormat Json


.EXAMPLE
    .\Watch-UmichGsiPostings.ps1 -ShowAll

    --------------------------------------------------------------------------------
    GRAD STU INSTR - FA26
    Posted:     4/22/2026
    Job ID:     276671
    Department: LSA Complex Systems
    Location:   Ann Arbor Campus
    Source:     umich_careers:171
    URL:        https://careers.umich.edu/job_detail/276671
    --------------------------------------------------------------------------------
    HMP 600 - The Health Services System I
    Status:     OPEN
    Job ID:     276872
    Department: UMSI
    Course:     HMP 600 - The Health Services System I
    Source:     umsi_google_sites
    URL:        https://sites.google.com/a/umich.edu/umsi-graduate-student-instructors/courses/residential-courses/HMP600
    --------------------------------------------------------------------------------
    
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Careers', 'UMSI')]
    [string]$Source = 'All',

    [int]$CareerInterestId = 171,

    [string]$StatePath = (Join-Path $PSScriptRoot 'umich-gsi-seen-postings.json'),

    [ValidateSet('Text', 'Json', 'Csv')]
    [string]$OutputFormat = 'Text',

    [switch]$ShowAll,

    [switch]$NoSaveState,

    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseUrl = 'https://careers.umich.edu'
$UmsiGsiCoursesUrl = 'https://sites.google.com/a/umich.edu/umsi-graduate-student-instructors/courses?authuser=0'

$KnownLocations = @(
    'Ann Arbor Campus',
    'Dearborn Campus',
    'Flint Campus',
    'Multiple Locations',
    'Other MI Location',
    'Outside Michigan'
)

function ConvertTo-NormalizedWhitespace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return (($Value -replace '\s+', ' ').Trim())
}

function Get-PlainTextFromHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $withoutScript = [regex]::Replace(
        $Html,
        '<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>',
        ' ',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $withoutStyle = [regex]::Replace(
        $withoutScript,
        '<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>',
        ' ',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $withSpaces = [regex]::Replace($withoutStyle, '<[^>]+>', ' ')
    $decoded = [System.Net.WebUtility]::HtmlDecode($withSpaces)

    return ConvertTo-NormalizedWhitespace -Value $decoded
}

function Invoke-PostingWebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$TimeoutSeconds = 30
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -TimeoutSec $TimeoutSeconds `
            -Headers @{ 'User-Agent' = 'UMichGsiWatcherPowerShell/1.0' } `
            -UseBasicParsing

        return [string]$response.Content
    }
    catch {
        throw "Failed to fetch page: $Uri. $($_.Exception.Message)"
    }
}

function New-UnifiedPosting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Title,

        [AllowNull()]
        [string]$JobOpeningId,

        [Parameter(Mandatory)]
        [string]$Url,

        [AllowNull()]
        [string]$DatePosted,

        [AllowNull()]
        [string]$Department,

        [AllowNull()]
        [string]$Location,

        [AllowNull()]
        [string]$Status,

        [AllowNull()]
        [string]$Course
    )

    [pscustomobject]@{
        source         = $Source
        title          = $Title
        job_opening_id = $JobOpeningId
        url            = $Url
        date_posted    = $DatePosted
        department     = $Department
        location       = $Location
        status         = $Status
        course         = $Course
    }
}

function Get-PostingKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Posting
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Posting.job_opening_id)) {
        return "$($Posting.source):job:$($Posting.job_opening_id)"
    }

    return "$($Posting.source):url:$($Posting.url)"
}

function Select-UniquePosting {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Posting = @()
    )

    begin {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $items = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in @($Posting)) {
            if ($null -eq $item) {
                continue
            }

            $key = Get-PostingKey -Posting $item

            if ($seen.Add($key)) {
                $items.Add($item)
            }
        }
    }

    end {
        return @($items)
    }
}

function Get-UmichCareerInterestPosting {
    [CmdletBinding()]
    param(
        [int]$CareerInterestId = 171,

        [int]$TimeoutSeconds = 30
    )

    $url = "$BaseUrl/browse-jobs/career_interests/$CareerInterestId"
    $html = Invoke-PostingWebRequest -Uri $url -TimeoutSeconds $TimeoutSeconds
    $text = Get-PlainTextFromHtml -Html $html

    $locationPattern = ($KnownLocations | ForEach-Object { [regex]::Escape($_) }) -join '|'

    $pattern = "(?<date>\d{1,2}/\d{1,2}/\d{4})\s+(?<title>.+?)\s+(?<id>\d{6})\s+(?<department>.+?)\s+(?<location>$locationPattern)"

    $careerMatches = [regex]::Matches(
        $text,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $postings = foreach ($match in $careerMatches) {
        $jobId = ConvertTo-NormalizedWhitespace -Value $match.Groups['id'].Value

        New-UnifiedPosting `
            -Source "umich_careers:$CareerInterestId" `
            -Title (ConvertTo-NormalizedWhitespace -Value $match.Groups['title'].Value) `
            -JobOpeningId $jobId `
            -Url "$BaseUrl/job_detail/$jobId" `
            -DatePosted (ConvertTo-NormalizedWhitespace -Value $match.Groups['date'].Value) `
            -Department (ConvertTo-NormalizedWhitespace -Value $match.Groups['department'].Value) `
            -Location (ConvertTo-NormalizedWhitespace -Value $match.Groups['location'].Value) `
            -Status $null `
            -Course $null
    }

    return @($postings | Select-UniquePosting)
}

function Get-HtmlAnchor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $anchorPattern = '<a\b[^>]*href=["''](?<href>[^"'']+)["''][^>]*>(?<text>.*?)<\/a>'

    $careerMatches = [regex]::Matches(
        $Html,
        $anchorPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    foreach ($match in $careerMatches) {
        $href = [System.Net.WebUtility]::HtmlDecode($match.Groups['href'].Value)
        $text = Get-PlainTextFromHtml -Html $match.Groups['text'].Value

        [pscustomobject]@{
            href = $href
            text = $text
        }
    }
}

function Resolve-AbsoluteUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUri,

        [Parameter(Mandatory)]
        [string]$Href
    )

    $base = [System.Uri]::new($BaseUri)
    $resolved = [System.Uri]::new($base, $Href)

    return $resolved.AbsoluteUri
}

function Get-UmsiOpenCourseLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html,

        [Parameter(Mandatory)]
        [string]$BaseUri
    )

    $htmlWithLineBreaks = [regex]::Replace(
        $Html,
        '<br\s*/?>|</p>|</div>|</li>|</h\d>',
        "`n",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $textWithLines = [System.Net.WebUtility]::HtmlDecode(
        ([regex]::Replace($htmlWithLineBreaks, '<[^>]+>', "`n"))
    )

    if ($textWithLines -notmatch 'OPEN POSTINGS:') {
        return @()
    }

    $openSection = ($textWithLines -split 'OPEN POSTINGS:', 2)[1]

    if ($openSection -match 'CLOSED POSTINGS:') {
        $openSection = ($openSection -split 'CLOSED POSTINGS:', 2)[0]
    }

    $openCourseNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($line in ($openSection -split "(`r`n|`n|`r)")) {
        $candidate = ConvertTo-NormalizedWhitespace -Value $line

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if ($candidate -in @('Courses:', 'Courses')) {
            continue
        }

        [void]$openCourseNames.Add($candidate)
    }

    $links = @(Get-HtmlAnchor -Html $Html)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($link in $links) {
        if ($openCourseNames.Contains($link.text)) {
            $absoluteUrl = Resolve-AbsoluteUrl -BaseUri $BaseUri -Href $link.href
            $key = "$($link.text)|$absoluteUrl"

            if ($seen.Add($key)) {
                $results.Add(
                    [pscustomobject]@{
                        title = $link.text
                        url   = $absoluteUrl
                    }
                )
            }
        }
    }

    return @($results)
}

function Get-JobOpeningIdFromHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $text = Get-PlainTextFromHtml -Html $Html

    $patterns = @(
        'Job Opening ID\s*#?\s*(\d{6})',
        'Job Opening ID\s+(\d{6})',
        'Enter the Job Opening ID\s*#?\s*(\d{6})'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match(
            $text,
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return $null
}

function Get-UmsiOpenGsiPosting {
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 30
    )

    $coursesHtml = Invoke-PostingWebRequest -Uri $UmsiGsiCoursesUrl -TimeoutSeconds $TimeoutSeconds
    $openCourses = @(Get-UmsiOpenCourseLink -Html $coursesHtml -BaseUri $UmsiGsiCoursesUrl)

    $postings = foreach ($course in $openCourses) {
        $detailHtml = Invoke-PostingWebRequest -Uri $course.url -TimeoutSeconds $TimeoutSeconds
        $jobId = Get-JobOpeningIdFromHtml -Html $detailHtml

        New-UnifiedPosting `
            -Source 'umsi_google_sites' `
            -Title $course.title `
            -JobOpeningId $jobId `
            -Url $course.url `
            -DatePosted $null `
            -Department 'UMSI' `
            -Location $null `
            -Status 'OPEN' `
            -Course $course.title
    }

    return @($postings | Select-UniquePosting)
}

function Get-WatchState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            updated_at_utc    = (Get-Date).ToUniversalTime().ToString('o')
            seen_posting_keys = @()
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

        if ($raw -is [array]) {
            return [pscustomobject]@{
                updated_at_utc    = (Get-Date).ToUniversalTime().ToString('o')
                seen_posting_keys = @($raw | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            }
        }

        if ($null -eq $raw.seen_posting_keys) {
            throw "State file is missing seen_posting_keys."
        }

        return [pscustomobject]@{
            updated_at_utc    = [string]$raw.updated_at_utc
            seen_posting_keys = @($raw.seen_posting_keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        }
    }
    catch {
        throw "Failed to read state file: $Path. $($_.Exception.Message)"
    }
}

function Save-WatchState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Postings = @()
    )

    $Postings = @($Postings)
    $keys = @($Postings | ForEach-Object { Get-PostingKey -Posting $_ } | Sort-Object -Unique)

    $state = [pscustomobject]@{
        updated_at_utc    = (Get-Date).ToUniversalTime().ToString('o')
        seen_posting_keys = $keys
    }

    $parent = Split-Path -Parent $Path

    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tempPath = "$Path.tmp"

    $state |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $tempPath -Encoding UTF8

    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-NewPosting {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Postings = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SeenPostingKeys = @()
    )

    $Postings = @($Postings)
    $SeenPostingKeys = @($SeenPostingKeys)

    $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]$SeenPostingKeys)

    foreach ($posting in $Postings) {
        if ($null -eq $posting) {
            continue
        }

        $key = Get-PostingKey -Posting $posting

        if (-not $seen.Contains($key)) {
            $posting
        }
    }
}

function Write-PostingText {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Postings = @(),

        [Parameter(Mandatory)]
        [string]$Heading
    )

    $Postings = @($Postings)

    if ($Postings.Count -eq 0) {
        Write-Output 'No postings to display.'
        return
    }

    Write-Output $Heading
    Write-Output ''

    foreach ($posting in $Postings) {
        Write-Output $posting.title

        if ($posting.status) {
            Write-Output ("Status:     {0}" -f $posting.status)
        }

        if ($posting.date_posted) {
            Write-Output ("Posted:     {0}" -f $posting.date_posted)
        }

        if ($posting.job_opening_id) {
            Write-Output ("Job ID:     {0}" -f $posting.job_opening_id)
        }

        if ($posting.department) {
            Write-Output ("Department: {0}" -f $posting.department)
        }

        if ($posting.location) {
            Write-Output ("Location:   {0}" -f $posting.location)
        }

        if ($posting.course) {
            Write-Output ("Course:     {0}" -f $posting.course)
        }

        Write-Output ("Source:     {0}" -f $posting.source)
        Write-Output ("URL:        {0}" -f $posting.url)
        Write-Output ('-' * 80)
    }
}

try {
    $state = Get-WatchState -Path $StatePath

    $postings = @()

    if ($Source -in @('All', 'Careers')) {
        $postings += @(Get-UmichCareerInterestPosting `
            -CareerInterestId $CareerInterestId `
            -TimeoutSeconds $TimeoutSeconds)
    }

    if ($Source -in @('All', 'UMSI')) {
        $postings += @(Get-UmsiOpenGsiPosting -TimeoutSeconds $TimeoutSeconds)
    }

    $postings = @($postings | Select-UniquePosting)
    $newPostings = @(Get-NewPosting -Postings $postings -SeenPostingKeys @($state.seen_posting_keys))

    $postingsToDisplay = @(
        if ($ShowAll) {
            $postings
        }
        else {
            $newPostings
        }
    )

    switch ($OutputFormat) {
        'Text' {
            if ($postingsToDisplay.Count -eq 0) {
                if ($ShowAll) {
                    Write-Output 'No postings found.'
                }
                else {
                    Write-Output 'No new postings found.'
                }
            }
            else {
                $heading = if ($ShowAll) { 'All current postings:' } else { 'New postings:' }
                Write-PostingText -Postings $postingsToDisplay -Heading $heading
            }
        }

        'Json' {
            @($postingsToDisplay) | ConvertTo-Json -Depth 6
        }

        'Csv' {
            @($postingsToDisplay) | ConvertTo-Csv -NoTypeInformation
        }
    }

    if (-not $NoSaveState) {
        Save-WatchState -Path $StatePath -Postings $postings
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}