# SANITISED HISTORICAL DERIVATIVE — reference only; not an operational runbook.
# Synthetic examples; dependencies and credentials intentionally not included.
# Do not run selections or remove this guard. See docs/books.md and docs/books-provenance.json.
throw "REFERENCE ONLY: execution is unconditionally disabled."

# ==============================================================================
# UAR SQL Automation Workbook
# ==============================================================================
# 
# Takes a pre-normalised CSV → `App_<APPCODE>_Temp1` → `App_<APPCODE>_Temp2` 
# in `synthetic-test`.
#
# WORKFLOW:
#   ├─ 0. Setup + preflight (set variables, paths, trace, helpers)
#   │  └─ 0a. Preflight SQL (confirm DB, app, owner, cycle)
#   │
#   ├─ 1. Validate input CSV (check schema, values, RoleGroups)
#   │  └─ 1b. OPTIONAL: RoleGroups + CSV compare (insert confirmed roles, evidence diff)
#   │
#   ├─ 2. Load Temp1 (create/load/check staging input)
#   │  ├─ 2a. Create Temp1 table (create if missing)
#   │  ├─ 2b. Load CSV into Temp1 (generate SQL, insert rows)
#   │  └─ 2c. Verify Temp1 + RoleGroups gate (counts, distributions, zero blockers)
#   │
#   ├─ 3. Transform Temp2 (build reviewed output table)
#   │  ├─ 3a. Run transform (Dynamic backstop, execute template)
#   │  ├─ 3b. Verify Temp2 (row parity, review flags, IDs)
#   │  └─ 3c. Generate review pack (produce IAM decision/routing files)
#   │
#   ├─ 4. Final verification (confirm counts and artefacts)
#   │
#   ├─ NEXT. STAGEBOOK.ps1 (dry-run, routing, staging, review items)
#   └─ PROD. Apply to production (set synthetic-production, rerun 2-4)
#
# NOTE: Test in `synthetic-test` first. When all gates pass, change:
#       $TargetDb = "synthetic-production"
#       and re-run Steps 2–4.
#
# PREREQUISITES:
# - PWSH working, Azure CLI logged in as SA account
# - VPN GlobalProtect connected vpn.reference.invalid
# - PING sql.reference.invalid (192.0.2.10)
# - SQLCMD working from the PowerShell prompt (Azure AD auth, TLS 1.2)
# - Python 3 available as `python3`, `python`, or Windows `py` in PATH
# - A pre-normalised CSV matching the 16-column Temp1 schema
#



# ==============================================================================
# STEP 0 — Setup + preflight
# ==============================================================================
# 
# Copy this entire block into pwsh and execute it.
# It sets up global variables and checks connectivity.
#


& {

    $ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $Root = $ScriptRoot

    Set-Location $Root
    $Server   = "sql.reference.invalid"
    $TargetDb = "synthetic-production"        # dev DB for SyntheticAppA validation
    $ProdDb   = "synthetic-production"        # read-only lookup DB for this run
    $AppCode = "SyntheticAppA"                  # safe table suffix: App_SyntheticAppA_Temp1/Temp2
    $AppSearch = "SyntheticAppA"    # exact application lookup
    $InputCsv = 'examples/input/input.csv'
    $OriginalCsv = 'examples/input/original.csv'
    $PriorYearReviewCsv = "" # optional; set to a local 2025 final-review CSV when prior-year comparison is needed

    $RunId  = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'AUS Eastern Standard Time').ToString('yyyyMMdd-HHmmss') + "-$AppCode".ToLower()
    $RunDir = Join-Path (Join-Path $Root 'runs') $RunId
    New-Item -ItemType Directory -Path $RunDir -Force | Out-Null

    $OpsDir = Join-Path $Root "ops"
    $ValidateCsvPy = Join-Path $OpsDir "WORKBOOK-01-validate-csv.py"
    $CsvComparePy = Join-Path $OpsDir "WORKBOOK-01a-compare-csv-profile.py"
    $LoadCsvPy = Join-Path $OpsDir "WORKBOOK-02-load-csv.py"
    $TransformTemp2Sql = Join-Path $OpsDir "WORKBOOK-03-transform-temp2.sql"
    $ReviewPackPs1 = Join-Path $OpsDir "WORKBOOK-04-review-pack.ps1"

    $sqlcmd = 'tools/synthetic/sqlcmd'
    $VenvPython = Join-Path $Root '.venv/bin/python'
    $Python = if (Test-Path $VenvPython) { $VenvPython } else { 'python3' }
    $ConsoleTracePath = Join-Path $RunDir 'console-trace-workbook.txt'

    function Start-UarConsoleTrace([string]$Path, [string]$Label) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
        Add-Content -Path $Path -Value ""
        Add-Content -Path $Path -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Label trace setup ====="
        Set-Variable -Name UarConsoleTracePath -Value $Path -Scope Global
    }

    function global:Invoke-WorkbookCommand {
        param(
            [Parameter(Mandatory = $true)][string]$Label,
            [Parameter(Mandatory = $true)][scriptblock]$Command,
            [switch]$PassThru,
            [switch]$IgnoreExitCode,
            [switch]$FriendlyStopOnNonZero
        )
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host ""
        Write-Host "======================================================================"
        Write-Host $Label
        Write-Host "Timestamp: $stamp"
        Write-Host "======================================================================"
        if ($ConsoleTracePath) {
            Add-Content -Path $ConsoleTracePath -Value ""
            Add-Content -Path $ConsoleTracePath -Value "===== $stamp $Label ====="
        }
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
        foreach ($line in @($output)) {
            Write-Host $line
            if ($ConsoleTracePath) { Add-Content -Path $ConsoleTracePath -Value ([string]$line) }
        }
        if (-not $IgnoreExitCode -and $exitCode -ne 0) {
            if ($FriendlyStopOnNonZero) {
                Write-Host ""
                Write-Host "STOP  $Label did not pass. Review the report above and fix the input before proceeding."
                Write-Host "      Exit code: $exitCode"
                if ($ConsoleTracePath) {
                    Add-Content -Path $ConsoleTracePath -Value ""
                    Add-Content -Path $ConsoleTracePath -Value "STOP  $Label did not pass. Review the report above and fix the input before proceeding. Exit code: $exitCode"
                }
                Set-Variable -Name WorkbookStop -Value $true -Scope Global
                if ($PassThru) { return $output }
                return
            }
            throw "$Label failed with exit code $exitCode"
        }
        Set-Variable -Name WorkbookStop -Value $false -Scope Global
        if ($PassThru) { return $output }
    }

    Start-UarConsoleTrace -Path $ConsoleTracePath -Label 'WORKBOOK'

    foreach ($v in @('Root','Server','TargetDb','ProdDb','AppCode','AppSearch','InputCsv','OriginalCsv','PriorYearReviewCsv','RunId','RunDir','OpsDir','ValidateCsvPy','CsvComparePy','LoadCsvPy','TransformTemp2Sql','ReviewPackPs1','sqlcmd','Python','ConsoleTracePath')) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "TargetDb"
    Write-Host $TargetDb
    Write-Host ""
    Write-Host "AppCode"
    Write-Host $AppCode
    Write-Host ""
    Write-Host "RunDir"
    Write-Host $RunDir
    Write-Host ""
    Write-Host "ConsoleTracePath"
    Write-Host $ConsoleTracePath
    Write-Host ""
    Write-Host "sqlcmd"
    Write-Host $sqlcmd
    Write-Host ""
    Write-Host "Python"
    Write-Host $Python
    Write-Host ""
    Write-Host "InputCsv"
    Write-Host $InputCsv
    Write-Host ""
    Write-Host "OriginalCsv"
    Write-Host $OriginalCsv
}


# --------------------------------------------------------------------------
# STEP 0a — Preflight SQL (connectivity + app/cycle lookup)
# --------------------------------------------------------------------------
# 
# Runs diagnostic query against $ProdDb. Captures AppId, BusinessOwner/Delegate, ReviewCycleId.
#

@"
SET NOCOUNT ON;

DECLARE @AppId uniqueidentifier;
DECLARE @AppName nvarchar(200);
DECLARE @BO varchar(100);
DECLARE @BOName varchar(200);
DECLARE @Delegate varchar(100);
DECLARE @DelegateName varchar(200);

SELECT
    @AppId = a.Id,
    @AppName = a.ApplicationName,
    @BO = a.BusinessOwnerAccount,
    @BOName = bo.FullName,
    @Delegate = a.DelegateAccount,
    @DelegateName = del.FullName
FROM dbo.Applications a
LEFT JOIN dbo.Employees bo ON bo.AccountName = a.BusinessOwnerAccount
LEFT JOIN dbo.Employees del ON del.AccountName = a.DelegateAccount
WHERE a.ApplicationName LIKE '$AppSearch';

PRINT 'login_name';
PRINT SUSER_SNAME();
PRINT '';
PRINT 'AppId';
PRINT ISNULL(CAST(@AppId AS varchar(36)), 'FILL-ME');
PRINT '';
PRINT 'ApplicationName';
PRINT ISNULL(@AppName, 'FILL-ME');
PRINT '';
PRINT 'BusinessOwner';
PRINT ISNULL(@BO, 'FILL-ME');
PRINT '';
PRINT 'BusinessOwnerName';
PRINT ISNULL(@BOName, 'FILL-ME');
PRINT '';
PRINT 'Delegate';
PRINT ISNULL(@Delegate, '');
PRINT '';
PRINT 'DelegateName';
PRINT ISNULL(@DelegateName, '');

PRINT '';
PRINT 'ReviewCycleId';
DECLARE @rcId varchar(36);
DECLARE @line varchar(max);
DECLARE rc CURSOR LOCAL FOR
    SELECT CONCAT(CAST(Id AS varchar(36)), '  ', Name, '  ', CONVERT(varchar, StartDate, 23), '..', CONVERT(varchar, EndDate, 23))
    FROM dbo.ReviewCycles WHERE Active = 1 ORDER BY StartDate DESC;
OPEN rc; FETCH NEXT FROM rc INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN
    PRINT @line;
    PRINT '';
    FETCH NEXT FROM rc INTO @line;
END;
CLOSE rc; DEALLOCATE rc;
SET @rcId = (SELECT TOP (1) CAST(Id AS varchar(36)) FROM dbo.ReviewCycles WHERE Active = 1 ORDER BY StartDate DESC);
IF @rcId IS NULL PRINT 'FILL-ME';
"@ | Set-Content (Join-Path $RunDir "00_preflight.sql") -Encoding UTF8

Invoke-WorkbookCommand -Label 'STEP 0a preflight SQL' -Command { & $sqlcmd -S $Server -d $ProdDb -G -N true -C -b -i (Join-Path $RunDir "00_preflight.sql") -W }

& {
    $BusinessOwnerName = ''
    $Delegate = ''
    $DelegateName = ''

    $lines = Invoke-WorkbookCommand -Label 'STEP 0b capture preflight output' -Command { & $sqlcmd -S $Server -d $ProdDb -G -N true -C -b -i (Join-Path $RunDir "00_preflight.sql") -W } -PassThru
    $key = $null
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq '' -or $t -eq 'login_name' -or $t -eq 'ApplicationName') { $key = $null; continue }
        if ($t -in @('AppId','BusinessOwner','BusinessOwnerName','Delegate','DelegateName','ReviewCycleId')) { $key = $t; continue }
        if ($key) {
            $v = if ($key -eq 'ReviewCycleId') { ($t -split '\s+')[0] } else { $t }
            # Set both local and global scope. Local is needed for the summary printed inside this & { } block;
            # global is needed for later workbook steps pasted/run interactively.
            Set-Variable -Name $key -Value $v
            Set-Variable -Name $key -Value $v -Scope Global
            $key = $null
        }
    }
    Write-Host "`nAppCode              = $AppCode"
    Write-Host "AppId                = $AppId"
    Write-Host "BusinessOwner account ID    = $BusinessOwner"
    Write-Host "BusinessOwner name   = $BusinessOwnerName"
    Write-Host "Delegate account ID         = $Delegate"
    Write-Host "Delegate name        = $DelegateName"
    Write-Host "ReviewCycleId        = $ReviewCycleId"
    Write-Host "`n>> VERIFY owner/delegate and review cycle. Edit captured values if wrong."
}

# Azure CLI expired auth refresh (synthetic-admin account):
#   az logout; az account clear; az login --tenant 00000000-0000-4000-8000-000000000001 --allow-no-subscriptions


# ============================================================================
# CHECKLIST — STEP 0
# ============================================================================
# 
# [ ] synthetic-production responds
# [ ] ApplicationId, BusinessOwner account ID/name, Delegate account ID/name, ReviewCycleId captured correctly
#
# STOP if: DB unreachable, auth expired, app not found, wrong review cycle.
#

# ==============================================================================
# STEP 1 — Validate input CSV
# ==============================================================================
#
# The CSV must have these 16 columns:
#   AccountId, FirstName, LastName, FullName, Email, Member, AccessType,
#   StaffId, RoleName_ORIGINAL, RoleName, Path, ApplicationAccountStatus,
#   MemberType, HostName, ExtractDate, ApplicationID
#
# ops\WORKBOOK-01-validate-csv.py checks:
#   - header completeness
#   - blank AccountId, spaces in AccountId
#   - account-prefix lowercase
#   - ApplicationAccountStatus (0/1 only)
#   - AccessType values
#   - blank RoleName
#   - blank ApplicationID
#   - ExtractDate format (YYYY-MM-DD)
#   - blank-columns expected for Temp2 enrichment
#   - RoleGroups gate against $TargetDb
#

#  $InputCsv  = 'examples/input/input.csv'
# $InputCsv  = 'examples/input/input.csv'
# $InputCsv  = 'examples/input/input.csv'
# $InputCsv  = 'examples/input/input.csv'
# $InputCsv  = 'examples/input/input.csv'

Invoke-WorkbookCommand -Label 'STEP 1 validate input CSV' -Command { & $Python $ValidateCsvPy $InputCsv --appid $AppId --server $Server --db $TargetDb --sqlcmd $sqlcmd } -FriendlyStopOnNonZero







# --------------------------------------------------------------------------
# STEP 1b — OPTIONAL: insert confirmed missing RoleGroups, then compare CSVs
# --------------------------------------------------------------------------
#
# Use this block after STEP 1 validation prints missing RoleGroups.
#
# Operator flow:
#   1. Paste the validator's BLOCK 1 RoleGroupsToAdd here.
#   2. For validator BLOCK 2, prefer fixing the CSV RoleName to the DB candidate.
#      Only add a BLOCK 2 role here if it is genuinely new.
#   3. Run this block. If RoleGroupsToAdd has rows, it generates and executes
#      01b_insert_rolegroups.sql immediately.
#   4. This block then writes the OriginalCsv/InputCsv comparison evidence.
#   5. Return to STEP 1 and rerun validation. Do not proceed to STEP 2 until
#      STEP 1 passes the RoleGroups exact-match gate.
#
# RoleType affects ReviewType, ReviewerAccount, ShouldReview, ShouldReviewComment.
# Dynamic=1 excludes the role from review.
#

& {
    # Paste the validator's BLOCK 1 `$RoleGroupsToAdd = @(... )` output here.
    # For BLOCK 2 roles, prefer fixing CSV RoleName to the suggested DB candidate;
    # only add them here if you confirm they are genuinely new RoleGroups.
    $RoleGroupsToAdd = @(
        # [pscustomobject]@{ RoleName = 'SyntheticRole01'; Description = 'SyntheticRole01'; RoleType = 'Elevated'; DataSource = "$AppCode BO"; Dynamic = 0 } # synthetic_row_1
        # [pscustomobject]@{ RoleName = 'SyntheticRole02'; Description = 'SyntheticRole02'; RoleType = 'Elevated'; DataSource = "$AppCode BO"; Dynamic = 0 } # synthetic_row_2
        # [pscustomobject]@{ RoleName = 'SyntheticRole03'; Description = 'SyntheticRole03'; RoleType = 'Elevated'; DataSource = "$AppCode BO"; Dynamic = 0 } # synthetic_row_3


        # [pscustomobject]@{ RoleName = 'SyntheticRole04'; Description = 'SyntheticRole04'; RoleType = 'Privileged'; DataSource = "$AppCode BO"; Dynamic = 0 } # synthetic_row_4
        # [pscustomobject]@{ RoleName = 'SyntheticRole05'; Description = 'SyntheticRole05'; RoleType = 'Privileged'; DataSource = "$AppCode BO"; Dynamic = 0 } # synthetic_row_5
        # [pscustomobject]@{ RoleName = 'SyntheticRole06'; Description = 'SyntheticRole06'; RoleType = 'Privileged'; DataSource = "$AppCode BO"; Dynamic = 0 } # synthetic_row_6




    )


    Set-Variable -Name RoleGroupsToAdd -Value $RoleGroupsToAdd -Scope Global

    function SqlText($s) {
        if ($null -eq $s -or [string]::IsNullOrWhiteSpace([string]$s)) { return 'NULL' }
        return "N'" + ([string]$s).Replace("'", "''") + "'"
    }

    if ($RoleGroupsToAdd -and $RoleGroupsToAdd.Count -gt 0) {
        $reviewRoleTypeRows = @()
        foreach ($r in $RoleGroupsToAdd) {
            foreach ($required in @('RoleName','Description','RoleType','DataSource')) {
                if ($null -eq $r.$required -or [string]::IsNullOrWhiteSpace([string]$r.$required) -or $r.$required -eq 'FILL-ME') {
                    throw "RoleGroupsToAdd row has missing $required. Row: $($r | ConvertTo-Json -Compress)"
                }
            }
            if ([string]$r.RoleType -eq 'REVIEW') { $reviewRoleTypeRows += $r }
            if ([int]$r.Dynamic -notin @(0,1)) {
                throw "Dynamic must be 0 or 1. Row: $($r | ConvertTo-Json -Compress)"
            }
        }

        if ($reviewRoleTypeRows.Count -gt 0) {
            $names = ($reviewRoleTypeRows | ForEach-Object { $_.RoleName }) -join ', '
            throw "RoleType=REVIEW remains for: $names. Decide the correct RoleType before inserting RoleGroups."
        }

        if ($TargetDb -eq 'synthetic-production') {
            Write-Warning 'TargetDb is synthetic-production. This block will execute RoleGroups inserts because RoleGroupsToAdd has rows.'
        }

        $insertSql = Join-Path $RunDir '01b_insert_rolegroups.sql'
        $sql = New-Object System.Collections.Generic.List[string]
        $sql.Add('SET XACT_ABORT ON;')
        $sql.Add('SET NOCOUNT ON;')
        $sql.Add("DECLARE @ApplicationId uniqueidentifier = '$AppId';")
        $sql.Add('')

        foreach ($r in $RoleGroupsToAdd) {
            $roleName = SqlText $r.RoleName
            $desc = SqlText $r.Description
            $roleType = SqlText $r.RoleType
            $dataSource = SqlText $r.DataSource
            $dynamic = [int]$r.Dynamic

            $sql.Add("IF NOT EXISTS (SELECT 1 FROM dbo.RoleGroups WHERE ApplicationID = @ApplicationId AND RoleName = $roleName)")
            $sql.Add('BEGIN')
            $sql.Add('    INSERT INTO dbo.RoleGroups (Id, ApplicationID, RoleName, Description, RoleType, DataSource, Dynamic)')
            $sql.Add("    VALUES (NEWID(), @ApplicationId, $roleName, $desc, $roleType, $dataSource, $dynamic);")
            $sql.Add("    PRINT 'Inserted RoleGroup: ' + CONVERT(varchar(300), $roleName);")
            $sql.Add('END')
            $sql.Add('ELSE')
            $sql.Add('BEGIN')
            $sql.Add("    PRINT 'Already exists, skipped: ' + CONVERT(varchar(300), $roleName);")
            $sql.Add('END;')
            $sql.Add('')
        }

        $sql.Add('SELECT RoleName, RoleType, DataSource, Dynamic')
        $sql.Add('FROM dbo.RoleGroups')
        $sql.Add('WHERE ApplicationID = @ApplicationId')
        $sql.Add('ORDER BY RoleName;')

        $sql -join "`r`n" | Set-Content $insertSql -Encoding UTF8
        Set-Variable -Name RoleGroupsInsertSql -Value $insertSql -Scope Global

        Write-Host 'Generated and executing RoleGroups insert SQL:'
        Write-Host $RoleGroupsInsertSql
        Invoke-WorkbookCommand -Label 'STEP 1b execute RoleGroups inserts' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $RoleGroupsInsertSql -W -s '|' }
    } else {
        Write-Host 'No RoleGroupsToAdd configured. Skipping RoleGroups insert and continuing to CSV comparison.'
    }

    # Same-row/order CSV profile for audit evidence of workbook pre-normalisation.
    $CsvDiffSummaryPath = Join-Path $RunDir '01_csv_diff_summary.csv'
    $CsvDiffDetailPath = Join-Path $RunDir '01_csv_cell_diff.csv'
    $CsvDiffTextPath = Join-Path $RunDir '01_csv_diff_summary.txt'

    Set-Variable -Name CsvDiffSummaryPath -Value $CsvDiffSummaryPath -Scope Global
    Set-Variable -Name CsvDiffDetailPath -Value $CsvDiffDetailPath -Scope Global
    Set-Variable -Name CsvDiffTextPath -Value $CsvDiffTextPath -Scope Global

    if ([string]::IsNullOrWhiteSpace($OriginalCsv) -or -not (Test-Path $OriginalCsv)) {
        Write-Warning "OriginalCsv not found or not set; skipping CSV diff profile: $OriginalCsv"
        "Column,ColumnStatus,OldRows,NewRows,Identical,Modified,BlankToPopulated,PopulatedToBlank,BothBlank,OldPopulated,NewPopulated,Note`r`n<file>,OriginalCsvNotFound,0,0,0,0,0,0,0,0,0,""$OriginalCsv""" |
            Set-Content -Path $CsvDiffSummaryPath -Encoding UTF8
        "RowNumber,Column,ChangeType,OldValue,NewValue" | Set-Content -Path $CsvDiffDetailPath -Encoding UTF8
        'OriginalCsv not found or not set; CSV diff profile skipped.' | Set-Content -Path $CsvDiffTextPath -Encoding UTF8
    } else {
        if (-not (Test-Path $InputCsv)) { throw "InputCsv not found: $InputCsv" }
        if (-not (Test-Path $CsvComparePy)) { throw "CSV comparison helper not found: $CsvComparePy" }

        Invoke-WorkbookCommand -Label 'STEP 1b compare OriginalCsv to InputCsv' -Command { & $Python $CsvComparePy $OriginalCsv $InputCsv `
            --summary-csv $CsvDiffSummaryPath `
            --detail-csv $CsvDiffDetailPath `
            --summary-txt $CsvDiffTextPath }
        if ($LASTEXITCODE -ne 0) { throw "CSV diff profile failed. If pandas is missing, run: & `$Python -m pip install pandas" }
    }

    Write-Host ''
    Write-Warning 'Return to STEP 1 and rerun CSV validation now. Do not proceed to STEP 2 until STEP 1 passes, especially the RoleGroups exact-match gate.'
}


# Recheck the CSV validation after any RoleGroups inserts or CSV fixes. The RoleGroups gate must return zero blocker rows before proceeding to STEP 2.

Invoke-WorkbookCommand -Label 'STEP 1 validate input CSV' -Command { & $Python $ValidateCsvPy $InputCsv --appid $AppId --server $Server --db $TargetDb --sqlcmd $sqlcmd } -FriendlyStopOnNonZero


# ============================================================================
# CHECKLIST — STEP 1
# ============================================================================
#
# [ ] All 16 columns present
# [ ] No blank AccountId (review spaces if SyntheticAppD legacy)
# [ ] ApplicationAccountStatus is 0/1 only
# [ ] No blank RoleName
# [ ] ApplicationID populated in all rows
# [ ] ExtractDate populated
# [ ] Row count matches expectations
# [ ] RoleGroups exact-match check shows Missing exact matches = 0
# [ ] RoleGroups duplicate/conflicting RoleType checks show zero issues
#
# STOP if: any FAIL. Fix the CSV / RoleGroups and re-run.
#

# ==============================================================================
# STEP 2 — Load Temp1
# ==============================================================================
#
# MUTATING — truncates and re-inserts `dbo.App_<CODE>_Temp1`.
#

# --------------------------------------------------------------------------
# STEP 2a — Create table (if not exists)
# --------------------------------------------------------------------------
#
# Creates dbo.App_<CODE>_Temp1 using the inline schema definition.
# No clone table or external SQL template dependency.
#

& {
    $tableName = "App_${AppCode}_Temp1"
    $createSql = Join-Path $RunDir "02_create_temp1.sql"

    $create = @"
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID('dbo.$tableName', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[$tableName](
        [AccountId] [nvarchar](100) NOT NULL,
        [FirstName] [nvarchar](1) NULL,
        [LastName] [nvarchar](1) NULL,
        [FullName] [nvarchar](100) NOT NULL,
        [Email] [nvarchar](1) NULL,
        [Member] [nvarchar](200) NOT NULL,
        [AccessType] [nvarchar](50) NULL,
        [StaffId] [nvarchar](1) NULL,
        [RoleName_ORIGINAL] [nvarchar](100) NOT NULL,
        [RoleName] [nvarchar](100) NOT NULL,
        [Path] [nvarchar](150) NOT NULL,
        [ApplicationAccountStatus] [nvarchar](1) NULL,
        [MemberType] [nvarchar](50) NOT NULL,
        [HostName] [nvarchar](1) NULL,
        [ExtractDate] [date] NOT NULL,
        [ApplicationID] [nvarchar](50) NOT NULL
    ) ON [PRIMARY];

    PRINT 'Created table: dbo.$tableName';
END
ELSE
BEGIN
    PRINT 'Table exists: dbo.$tableName';
END;
"@

    $create | Set-Content $createSql -Encoding UTF8
    Invoke-WorkbookCommand -Label 'STEP 2a create Temp1 table' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $createSql -W }
}

# --------------------------------------------------------------------------
# STEP 2b — Load CSV into Temp1
# --------------------------------------------------------------------------
#
# Generates INSERT statements from CSV and loads into table.
# For large datasets: use SqlBulkCopy or bcp instead.
#

& {
    $loadSql = Join-Path $RunDir "02_load_temp1.sql"
    Invoke-WorkbookCommand -Label 'STEP 2b generate Temp1 load SQL' -Command { & $Python $LoadCsvPy $InputCsv --appcode $AppCode --server $Server --database $TargetDb --sqlcmd $sqlcmd --out $loadSql }
    Invoke-WorkbookCommand -Label 'STEP 2b load CSV into Temp1' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $loadSql -W -s "|" }
}

# --------------------------------------------------------------------------
# STEP 2c — Verify Temp1 and RoleGroups gate
# --------------------------------------------------------------------------
#
# Shows row count, distributions by ApplicationID, ApplicationAccountStatus, 
# AccessType, and all RoleName values.
#

& {
    $verify = @"
SET NOCOUNT ON;
SELECT 'Temp1' AS stage, COUNT_BIG(*) AS rows FROM [dbo].[App_${AppCode}_Temp1];
SELECT ApplicationID, COUNT_BIG(*) AS n FROM [dbo].[App_${AppCode}_Temp1] GROUP BY ApplicationID;
SELECT ApplicationAccountStatus, COUNT_BIG(*) AS n FROM [dbo].[App_${AppCode}_Temp1] GROUP BY ApplicationAccountStatus;
SELECT AccessType, COUNT_BIG(*) AS n FROM [dbo].[App_${AppCode}_Temp1] GROUP BY AccessType;
SELECT DISTINCT RoleName FROM [dbo].[App_${AppCode}_Temp1] ORDER BY RoleName;
"@
    $verify | Set-Content (Join-Path $RunDir "02_verify_temp1.sql") -Encoding UTF8
    Invoke-WorkbookCommand -Label 'STEP 2c verify Temp1' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i (Join-Path $RunDir "02_verify_temp1.sql") -W -s "|" }
}

# ==========================================================================
# ⚠️  CRITICAL — RoleGroups gate — DO NOT SKIP [MUST return ZERO rows !!!]
# ==========================================================================
#
# This is the most dangerous step in the entire workbook.
#
# Every `RoleName` in your Temp1 **must** have exactly one matching entry in
# `dbo.RoleGroups` for the current $TargetDb/ApplicationId, and that match must
# have one unambiguous RoleType. If a role is missing, duplicated, or has
# conflicting RoleType values:
#
#   - Temp2 transforms INNER JOIN on RoleGroups returns zero, duplicate, or
#     ambiguous rows for that access
#   - RoleType, Dynamic, DataSource, ShouldReview, and reviewer routing can be
#     silently wrong
#   - Temp2 can load without obvious operator errors, but the data is WRONG
#
# CONSEQUENCE if unchecked:
#   Hundreds of review items could be published with wrong ShouldReview
#   flags and wrong reviewer assignments. UAR sign-off would be based on
#   bad data.
#
# --------------------------------------------------------------------------
# Check for missing, duplicate, RoleType-conflicting, or Dynamic=1 RoleGroups entries
# --------------------------------------------------------------------------
#

& {
    $check = @"
-- !!! ANY BLOCKER ROW RETURNED HERE MUST BE FIXED BEFORE TEMP2 !!!
-- This checks Temp1 RoleName values against dbo.RoleGroups for the current ApplicationId.
-- It blocks: missing RoleGroups rows, duplicate RoleGroups rows, conflicting RoleType values, and Dynamic=1 rows.
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#RoleGroupGate') IS NOT NULL DROP TABLE #RoleGroupGate;

WITH InputRoles AS (
    SELECT DISTINCT LTRIM(RTRIM(RoleName)) AS RoleName
    FROM [dbo].[App_${AppCode}_Temp1]
    WHERE NULLIF(LTRIM(RTRIM(RoleName)), '') IS NOT NULL
), RoleGate AS (
    SELECT
        i.RoleName,
        ISNULL(g.RoleGroupMatches, 0) AS RoleGroupMatches,
        ISNULL(g.DistinctRoleTypes, 0) AS DistinctRoleTypes,
        ISNULL(g.DynamicOneMatches, 0) AS DynamicOneMatches,
        ISNULL(g.DistinctDynamicValues, 0) AS DistinctDynamicValues,
        g.MatchingRoleGroups
    FROM InputRoles i
    OUTER APPLY (
        SELECT
            COUNT(*) AS RoleGroupMatches,
            COUNT(DISTINCT ISNULL(rg.RoleType, '<NULL>')) AS DistinctRoleTypes,
            SUM(CASE WHEN ISNULL(CONVERT(int, rg.Dynamic), 0) = 1 THEN 1 ELSE 0 END) AS DynamicOneMatches,
            COUNT(DISTINCT ISNULL(CONVERT(varchar(5), rg.Dynamic), '<NULL>')) AS DistinctDynamicValues,
            STRING_AGG(
                CONVERT(nvarchar(max), CONCAT(
                    CONVERT(varchar(36), rg.Id),
                    ':RoleType=', ISNULL(rg.RoleType, '<NULL>'),
                    ':Dynamic=', ISNULL(CONVERT(varchar(5), rg.Dynamic), '<NULL>'),
                    ':DataSource=', ISNULL(rg.DataSource, '<NULL>')
                )),
                '; '
            ) AS MatchingRoleGroups
        FROM dbo.RoleGroups rg
        WHERE rg.ApplicationId = '$AppId'
          AND LTRIM(RTRIM(rg.RoleName)) = i.RoleName
    ) g
)
SELECT
    RoleName,
    RoleGroupMatches,
    DistinctRoleTypes,
    DynamicOneMatches,
    DistinctDynamicValues,
    CONCAT(
        CASE WHEN RoleGroupMatches = 0 THEN 'Missing RoleGroups row; ' ELSE '' END,
        CASE WHEN RoleGroupMatches > 1 THEN 'Duplicate RoleGroups rows; ' ELSE '' END,
        CASE WHEN DistinctRoleTypes > 1 THEN 'Conflicting RoleType values; ' ELSE '' END,
        CASE WHEN DynamicOneMatches > 0 THEN 'Dynamic=1 RoleGroups row used by current Temp1; ' ELSE '' END
    ) AS IssueFlags,
    CASE
        WHEN RoleGroupMatches = 0 THEN 'Missing RoleGroups row'
        WHEN RoleGroupMatches > 1 AND DistinctRoleTypes > 1 THEN 'Duplicate RoleGroups rows with conflicting RoleType'
        WHEN RoleGroupMatches > 1 THEN 'Duplicate RoleGroups rows'
        WHEN DistinctRoleTypes > 1 THEN 'Conflicting RoleType values'
        WHEN DynamicOneMatches > 0 THEN 'Dynamic=1 RoleGroups row used by current Temp1'
        ELSE 'OK'
    END AS GateStatus,
    MatchingRoleGroups
INTO #RoleGroupGate
FROM RoleGate;

PRINT '';
PRINT '======================================================================';
PRINT 'RoleGroups critical gate';
PRINT 'Database      : $TargetDb';
PRINT 'ApplicationId : $AppId';
PRINT 'Temp1 table   : dbo.App_${AppCode}_Temp1';
PRINT 'Required      : ZERO blocker rows';
PRINT '======================================================================';

SELECT 'Distinct Temp1 RoleName values' AS CheckMetric, COUNT_BIG(*) AS CheckValue FROM #RoleGroupGate
UNION ALL SELECT 'Roles passing all RoleGroups checks', COUNT_BIG(*) FROM #RoleGroupGate WHERE GateStatus = 'OK'
UNION ALL SELECT 'BLOCKER roles total', COUNT_BIG(*) FROM #RoleGroupGate WHERE GateStatus <> 'OK'
UNION ALL SELECT 'Missing RoleGroups rows', COUNT_BIG(*) FROM #RoleGroupGate WHERE RoleGroupMatches = 0
UNION ALL SELECT 'Duplicate RoleGroups rows', COUNT_BIG(*) FROM #RoleGroupGate WHERE RoleGroupMatches > 1
UNION ALL SELECT 'Conflicting RoleType values', COUNT_BIG(*) FROM #RoleGroupGate WHERE DistinctRoleTypes > 1
UNION ALL SELECT 'Roles with Dynamic=1', COUNT_BIG(*) FROM #RoleGroupGate WHERE DynamicOneMatches > 0
UNION ALL SELECT 'Dynamic=1 RoleGroups rows', ISNULL(SUM(CONVERT(bigint, DynamicOneMatches)), 0) FROM #RoleGroupGate;

IF EXISTS (SELECT 1 FROM #RoleGroupGate WHERE GateStatus <> 'OK')
BEGIN
    PRINT '';
    PRINT 'FAIL: RoleGroups gate returned blocker rows. Fix every row listed below before Temp2 transform.';
    PRINT '';

    SELECT
        RoleName,
        GateStatus,
        IssueFlags,
        RoleGroupMatches,
        DistinctRoleTypes,
        DynamicOneMatches,
        DistinctDynamicValues,
        MatchingRoleGroups
    FROM #RoleGroupGate
    WHERE GateStatus <> 'OK'
    ORDER BY RoleName;

    THROW 51020, 'RoleGroups gate failed: missing, duplicate, conflicting RoleType, or Dynamic=1 rows. Fix dbo.RoleGroups before Temp2 transform.', 1;
END
ELSE
BEGIN
    PRINT '';
    PRINT 'PASS: RoleGroups gate returned ZERO blocker rows. Safe to continue to Temp2 RoleGroups join.';
    PRINT '';

    SELECT
        'PASS' AS RoleGroupsGate,
        'ZERO blocker rows: no missing roles, no duplicate RoleGroups rows, no conflicting RoleType values, no Dynamic=1 roles used by current Temp1.' AS Result;
END;
"@
    $check | Set-Content (Join-Path $RunDir "02_role_check.sql") -Encoding UTF8
    Invoke-WorkbookCommand -Label 'STEP 2c RoleGroups gate' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i (Join-Path $RunDir "02_role_check.sql") -W -s "|" }
}

# ============================================================================
# CHECKLIST — STEP 2
# ============================================================================
#
# [ ] Loaded rows = CSV rows
# [ ] ApplicationID single-0valued
# [ ] ExtractDate single-valued
# [ ] **RoleGroups gate returned ZERO rows and no THROW** ← CRITICAL BLOCKER
#     Covers missing rows, duplicate RoleName rows, same RoleName with different
#     RoleType, and Dynamic=1 values used by current Temp1.
#
# STOP if: row mismatch, ANY row returned from RoleGroups gate, or sqlcmd throws.
#
# If the gate returns rows: find those roles in dbo.RoleGroups on the
# current $TargetDb. If testing in synthetic-test, replicate/fix RoleGroups there
# before transforming; if applying to production, fix synthetic-production with verified
# RoleType/Dynamic/DataSource values from the app owner.
#

# ==============================================================================
# STEP 3 — Transform to Temp2
# ==============================================================================
#
# MUTATING — truncates and re-inserts `dbo.App_<CODE>_Temp2`.
#
# Uses ops\WORKBOOK-03-transform-temp2.sql — the production transform extracted
# from `1-00.DataTransformation_App_Name_Temp2.sql` with hardcoded values
# replaced by PowerShell variables.
#

# --------------------------------------------------------------------------
# STEP 3a — Run transform
# --------------------------------------------------------------------------
#
# Backstop only: before transforming, checks whether any RoleGroups used by the current Temp1 have Dynamic=1.
# The critical RoleGroups gate above should already block Dynamic=1 rows. If this
# backstop still finds any, Dynamic=1 rows are excluded from review, so the operator
# must choose whether to update those Temp1-present RoleGroups to Dynamic=0 or leave
# them unchanged before Temp2 is created. RoleGroups not present in the current Temp1 are ignored.
# Then expands the template with current variable values and executes it.
# The SQL creates the table if missing, then truncates and transforms.
# All original IIF logic preserved. No fixture dependency.
#

& {
    $dynamicDetailsSql = @"
SET NOCOUNT ON;

WITH Temp1RoleCounts AS (
    SELECT
        LTRIM(RTRIM(RoleName)) AS RoleName,
        COUNT_BIG(*) AS Temp1Rows
    FROM [dbo].[App_${AppCode}_Temp1]
    WHERE NULLIF(LTRIM(RTRIM(RoleName)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(RoleName))
)
SELECT
    CONVERT(varchar(36), rg.Id) AS RoleGroupId,
    rg.RoleName,
    rg.RoleType,
    rg.DataSource,
    CONVERT(int, rg.Dynamic) AS Dynamic,
    trc.Temp1Rows,
    rg.Description
FROM Temp1RoleCounts trc
INNER JOIN dbo.RoleGroups rg
    ON rg.ApplicationId = '$AppId'
   AND LTRIM(RTRIM(rg.RoleName)) = trc.RoleName
WHERE ISNULL(rg.Dynamic, 0) = 1
ORDER BY rg.RoleName;
"@
    $dynamicDetailsPath = Join-Path $RunDir "03_dynamic_rolegroups_check.sql"
    $dynamicDetailsSql | Set-Content $dynamicDetailsPath -Encoding UTF8

    $dynamicCountSql = @"
SET NOCOUNT ON;

WITH InputRoles AS (
    SELECT DISTINCT LTRIM(RTRIM(RoleName)) AS RoleName
    FROM [dbo].[App_${AppCode}_Temp1]
    WHERE NULLIF(LTRIM(RTRIM(RoleName)), '') IS NOT NULL
)
SELECT COUNT_BIG(*)
FROM InputRoles i
INNER JOIN dbo.RoleGroups rg
    ON rg.ApplicationId = '$AppId'
   AND LTRIM(RTRIM(rg.RoleName)) = i.RoleName
WHERE ISNULL(rg.Dynamic, 0) = 1;
"@
    $dynamicCountPath = Join-Path $RunDir "03_dynamic_rolegroups_count.sql"
    $dynamicCountSql | Set-Content $dynamicCountPath -Encoding UTF8

    $dynamicCountOutput = Invoke-WorkbookCommand -Label 'STEP 3a dynamic RoleGroups count' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $dynamicCountPath -h -1 -W } -PassThru
    $dynamicCountLine = $dynamicCountOutput | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
    $dynamicCount = if ($dynamicCountLine) { [int64]$dynamicCountLine } else { 0 }

    if ($dynamicCount -gt 0) {
        Write-Warning "Found $dynamicCount RoleGroups row(s) used by current Temp1 with Dynamic=1. These rows would become ShouldReview=0 with comment 'Dynamic Role'."
        Write-Host "Dynamic RoleGroups details:"
        Invoke-WorkbookCommand -Label 'STEP 3a dynamic RoleGroups details' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $dynamicDetailsPath -W -s "|" }
        Write-Host ""

        do {
            $dynamicChoice = (Read-Host "Modify these Temp1-present RoleGroups to Dynamic=0 before Temp2 transform? Type M to modify, L to leave unchanged, or A to abort").Trim().ToUpperInvariant()
        } until ($dynamicChoice -in @('M','L','A'))

        if ($dynamicChoice -eq 'A') {
            throw 'Temp2 transform aborted by operator after Dynamic=1 RoleGroups check.'
        }

        if ($dynamicChoice -eq 'M') {
            $dynamicUpdateSql = @"
SET NOCOUNT ON;

WITH InputRoles AS (
    SELECT DISTINCT LTRIM(RTRIM(RoleName)) AS RoleName
    FROM [dbo].[App_${AppCode}_Temp1]
    WHERE NULLIF(LTRIM(RTRIM(RoleName)), '') IS NOT NULL
)
UPDATE rg
SET Dynamic = 0
FROM dbo.RoleGroups rg
INNER JOIN InputRoles i
    ON LTRIM(RTRIM(rg.RoleName)) = i.RoleName
WHERE rg.ApplicationId = '$AppId'
  AND ISNULL(rg.Dynamic, 0) = 1;

SELECT @@ROWCOUNT AS RoleGroupsUpdatedToDynamic0;
"@
            $dynamicUpdatePath = Join-Path $RunDir "03_dynamic_rolegroups_update_to_0.sql"
            $dynamicUpdateSql | Set-Content $dynamicUpdatePath -Encoding UTF8

            Write-Host "Updating Temp1-present Dynamic RoleGroups to 0..."
            Invoke-WorkbookCommand -Label 'STEP 3a dynamic RoleGroups update' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $dynamicUpdatePath -W -s "|" }
        }
        else {
            Write-Warning "Leaving Temp1-present Dynamic=1 RoleGroups unchanged. Matching Temp2 rows will not be reviewed."
        }
    }
    else {
        Write-Host "Dynamic RoleGroups check passed: no RoleGroups used by current Temp1 have Dynamic=1."
    }

    # Expand WORKBOOK-03-transform-temp2.sql with current variable values
    $tmpl = Get-Content $TransformTemp2Sql -Raw
    $tmpl = $tmpl -replace '\$\{AppCode\}', $AppCode
    $tmpl = $tmpl -replace '\$\{AppId\}', $AppId
    $tmpl = $tmpl -replace '\$\{RCId\}', $ReviewCycleId
    $tmpl = $tmpl -replace '\$\{BO\}', $BusinessOwner
    $tmpl | Set-Content (Join-Path $RunDir "03_transform_temp2.sql") -Encoding UTF8

    Invoke-WorkbookCommand -Label 'STEP 3a transform Temp2' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i (Join-Path $RunDir "03_transform_temp2.sql") -W -s "|" }
}

# --------------------------------------------------------------------------
# STEP 3b — Verify Temp2
# --------------------------------------------------------------------------
#
# Shows row count, ShouldReview distribution, ShouldReviewComment counts,
# AccountType distribution, FullName blanks, and distinctness of ApplicationId/ReviewCycleId.
#

& {
    $verify = @"
SET NOCOUNT ON;
SELECT 'Temp1' AS stage, COUNT_BIG(*) AS rows FROM [dbo].[App_${AppCode}_Temp1]
UNION ALL SELECT 'Temp2', COUNT_BIG(*) FROM [dbo].[App_${AppCode}_Temp2];

SELECT ReviewType, ShouldReview, COUNT_BIG(*) AS n
FROM [dbo].[App_${AppCode}_Temp2] GROUP BY ReviewType, ShouldReview ORDER BY 1,2;

SELECT ShouldReviewComment, COUNT_BIG(*) AS n

        FROM [dbo].[App_${AppCode}_Temp2] GROUP BY ShouldReviewComment ORDER BY n DESC;

SELECT AccountType, COUNT_BIG(*) AS n
FROM [dbo].[App_${AppCode}_Temp2] GROUP BY AccountType ORDER BY n DESC;

SELECT COUNT_BIG(*) AS blank_fullname
FROM [dbo].[App_${AppCode}_Temp2] WHERE FullName IS NULL OR LEN(FullName)=0;

SELECT COUNT(DISTINCT ApplicationId) AS apps, COUNT(DISTINCT ReviewCycleId) AS cycles
FROM [dbo].[App_${AppCode}_Temp2];
"@
    $verify | Set-Content (Join-Path $RunDir "03_verify_temp2.sql") -Encoding UTF8
    Invoke-WorkbookCommand -Label 'STEP 3b verify Temp2' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i (Join-Path $RunDir "03_verify_temp2.sql") -W -s "|" }
}

# --------------------------------------------------------------------------
# STEP 3c — Generate Temp2 review pack
# --------------------------------------------------------------------------
#
# Produces plain-text/HTML review pack, summary CSV, IAM decision CSV, and
# machine-safe approval CSV in $RunDir.
#
# Human-facing file:
#   04_review_pack_iam_decision_rows.csv
#
# IAM-editable machine input for STAGEBOOK.ps1:
#   05_reviewer_routing_approval.csv
#
# Re-runnable without reloading Temp1 or rebuilding Temp2.
#

& $ReviewPackPs1 `
    -Server $Server `
    -Database $TargetDb `
    -AppCode $AppCode `
    -AppId $AppId `
    -ReviewCycleId $ReviewCycleId `
    -RunDir $RunDir `
    -SqlCmd $sqlcmd `
    -PriorYearReviewCsv $PriorYearReviewCsv `
    -InputCsv $InputCsv `
    -OriginalCsv $OriginalCsv `
    -CsvDiffSummaryPath $CsvDiffSummaryPath `
    -CsvDiffDetailPath $CsvDiffDetailPath `
    -CsvDiffTextPath $CsvDiffTextPath

# ============================================================================
# CHECKLIST — STEP 3
# ============================================================================
#
# [ ] Temp2 rows = Temp1 rows
# [ ] FullName blanks = 0
# [ ] ApplicationId and ReviewCycleId single-valued
# [ ] ShouldReview distribution reviewed
# [ ] AccountType distribution makes sense
#
# STOP if: row diff, blank FullName, missing role mapping.
#

# ==============================================================================
# STEP 4 — Final verification
# ==============================================================================
#
# Summary query showing Temp1, Temp2, and ShouldReview=1 counts.
#

& {
    $final = "SELECT 'Temp1' AS stage, COUNT_BIG(*) AS rows FROM [dbo].[App_${AppCode}_Temp1] UNION ALL SELECT 'Temp2', COUNT_BIG(*) FROM [dbo].[App_${AppCode}_Temp2] UNION ALL SELECT 'ShouldReview=1', COUNT_BIG(*) FROM [dbo].[App_${AppCode}_Temp2] WHERE ShouldReview=1;"
    Invoke-WorkbookCommand -Label 'STEP 4 final verification' -Command { & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -Q "$final" -W -s "|" }
}

# ============================================================================
# CHECKLIST — STEP 4
# ============================================================================
#
# [ ] Temp1 rows = input CSV rows
# [ ] Temp2 rows = Temp1 rows
# [ ] ShouldReview=1 count reviewed and signed off
# [ ] Run artefacts saved in $RunDir
# [ ] IAM completes 05_reviewer_routing_approval.csv before STAGEBOOK.ps1
#
#
# ==============================================================================
# APPLYING TO PRODUCTION
# ==============================================================================
#
# When all gates pass against `synthetic-test`:
#
#   $TargetDb = "synthetic-production"
#
# Re-run Steps 2–4. Every sqlcmd invocation inherits $TargetDb.
#
# ⚠️  Requires an approved UAR change.
#

# ==============================================================================
# TROUBLESHOOTING
# ==============================================================================
#
# Azure CLI expired:
#   az logout; az account clear; az login --tenant 00000000-0000-4000-8000-000000000001 --allow-no-subscriptions
#   az logout; az account clear; az login --tenant 00000000-0000-4000-8000-000000000001 --allow-no-subscriptions --scope "https://database.reference.invalid//.default"
#
# Firewall blocked:
#   Confirm VPN, re-run Step 0.
#
# RoleGroups gaps:
#   Add missing entries to dbo.RoleGroups before Step 3.
#
# CSV too large for INSERT:
#   Use SqlBulkCopy or bcp.
#
