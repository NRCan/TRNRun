# Print a Markdown summary of the JUnit (*.xml) and TRX (*.trx) results under a directory, such as:
# Write-TestSummary.ps1 TestResults >> $env:GITHUB_STEP_SUMMARY
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'

# One row per test file or class, like the MATLAB summary.
$rows = [ordered]@{}
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Result([string]$Group, [string]$Name, [string]$Outcome, [double]$Seconds, [string]$Message) {
    if (-not $rows.Contains($Group)) {
        $rows[$Group] = [pscustomobject]@{ Passed = 0; Failed = 0; Skipped = 0; Seconds = 0.0 }
    }
    $rows[$Group].$Outcome++
    $rows[$Group].Seconds += $Seconds
    if ($Outcome -eq 'Failed') {
        $firstLine = "$Message".Trim() -split '\r?\n' | Select-Object -First 1
        $failures.Add("- **$Group** › $Name" + $(if ($firstLine) { ": $firstLine" } else { '' }))
    }
}

function Format-Seconds([double]$Seconds) {
    $Seconds.ToString('0.00', [cultureinfo]::InvariantCulture)
}

# JUnit from Nim (TestResults/nim/<component>-<test>.xml) and pytest.
foreach ($file in Get-ChildItem $Path -Recurse -Filter *.xml | Sort-Object FullName) {
    $xml = [xml](Get-Content $file.FullName -Raw)
    foreach ($case in $xml.SelectNodes('//testcase')) {
        $group = if ($file.Directory.Name -eq 'nim') { $file.BaseName -replace '-', ' / ' } else { "python / $($case.classname)" }
        $problem = $case.SelectSingleNode('failure|error')
        $outcome = if ($problem) { 'Failed' } elseif ($case.SelectSingleNode('skipped')) { 'Skipped' } else { 'Passed' }
        $message = if ($problem) { $problem.GetAttribute('message') } else { '' }
        Add-Result $group $case.name $outcome ([double]$case.time) $message
    }
}

# TRX from dotnet test.
foreach ($file in Get-ChildItem $Path -Recurse -Filter *.trx | Sort-Object FullName) {
    $trx = [xml](Get-Content $file.FullName -Raw)
    $classes = @{}
    foreach ($test in $trx.TestRun.TestDefinitions.UnitTest) {
        $classes[$test.id] = $test.TestMethod.className -replace '^.*\.', ''
    }
    foreach ($result in $trx.TestRun.Results.UnitTestResult) {
        $outcome = switch ($result.outcome) { 'Passed' { 'Passed' } 'Failed' { 'Failed' } default { 'Skipped' } }
        $seconds = if ($result.duration) { [timespan]::Parse($result.duration).TotalSeconds } else { 0 }
        Add-Result ".NET / $($classes[$result.testId])" $result.testName $outcome $seconds $result.Output.ErrorInfo.Message
    }
}

if ($rows.Count -eq 0) {
    '## Test results'
    ''
    "No test results found in $Path."
    return
}

$all = $rows.Values
$passed = ($all | Measure-Object Passed -Sum).Sum
$failed = ($all | Measure-Object Failed -Sum).Sum
$skipped = ($all | Measure-Object Skipped -Sum).Sum
$seconds = ($all | Measure-Object Seconds -Sum).Sum

'## Test results'
''
'| Total tests | Passed ✅ | Failed ❌ | Skipped 🚫 | Duration (s) |'
'|---:|---:|---:|---:|---:|'
"| $($passed + $failed + $skipped) | $passed | $failed | $skipped | $(Format-Seconds $seconds) |"
''
'| Test file | Passed | Failed | Skipped | Duration (s) |'
'|---|---:|---:|---:|---:|'
foreach ($group in $rows.Keys) {
    $row = $rows[$group]
    $icon = if ($row.Failed) { '❌' } else { '✅' }
    "| $icon $group | $($row.Passed) | $($row.Failed) | $($row.Skipped) | $(Format-Seconds $row.Seconds) |"
}

if ($failures.Count) {
    ''
    '### Failures'
    ''
    $failures
}
