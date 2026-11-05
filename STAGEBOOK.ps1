# SANITISED HISTORICAL DERIVATIVE — reference only; not an operational runbook.
# Synthetic examples; dependencies and credentials intentionally not included.
# Do not run selections or remove this guard. See docs/books.md and docs/books-provenance.json.
throw "REFERENCE ONLY: execution is unconditionally disabled."

# ==============================================================================
# UAR ReviewItems Staging Workbook
# ==============================================================================
#
# Takes the post-WORKBOOK App_<APPCODE>_Temp2 table through the original
# sql/reviewitems processing boundary:
#
#   App_<APPCODE>_Temp2
#       -> dbo.ReviewItemsStaging
#       -> dbo.ReviewItems
#
# This file intentionally follows the interactive style of WORKBOOK.ps1:
# paste/run one step at a time, review generated SQL in $RunDir, then opt in to
# mutating steps by setting the execute switches below.
#
# Source mapping from original historical-reference/sql/reviewitems:
#   01.Copy_Temp2-to-ReviewItemsStaging.sql
#   00.DataTransformation_ReviewItemsStaging.sql
#   02.Update-ReviewItemsStaging.sql
#   03.Insert-ReviewItemsStaging-to-ReviewItems.sql
#
# Important 2026 workbook boundary:
#   WORKBOOK.ps1 should already have completed the original sql/dataAnalysis
#   phase and produced a final App_<APPCODE>_Temp2 table. If IAM/BP reviewer
#   approvals are required, apply them to Temp2 before running this stagebook.
#
# ============================================================================== 

# ==============================================================================
# REQUIRED INPUTS + EXECUTE SWITCHES — edit these values first
# ============================================================================== 
# Use the existing WORKBOOK.ps1 run folder that produced App_<APPCODE>_Temp2.
# STAGEBOOK derives Server/TargetDb where recorded, AppId, ReviewCycleId, and
# exact Temp2 table name from the run artifacts, then verifies them before writing
# or executing stage SQL.
#
# Leave execute switches false for DRY-RUN. Set one switch true only after
# reviewing that step's generated SQL/output and intentionally opting in.

& {
    $AppCode = "SyntheticAppA"  # e.g. "SyntheticAppB"
    $RunDir = "runs/20000101-000000-syntheticappa" # existing WORKBOOK run folder; relative paths resolve under repo root
    # e.g. $RunDir = "runs/yyyymmdd-hhmmss-appcode"


    $ExecuteCopyToStaging = $false      # STEP 2: Temp2 -> ReviewItemsStaging
    $ExecuteStagingTransforms = $false  # STEP 3: transform/clean ReviewItemsStaging
    $ExecuteReviewItems = $false        # STEP 5: ReviewItemsStaging -> ReviewItems
    $ReplaceExistingReviewItems = $false # STEP 5 rerun safety: delete/reinsert only if existing rows are untouched/pre-launch

    foreach ($v in @('AppCode','RunDir','ExecuteCopyToStaging','ExecuteStagingTransforms','ExecuteReviewItems','ReplaceExistingReviewItems')) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "AppCode                  = $AppCode"
    Write-Host "RunDir                   = $RunDir"
    Write-Host "ExecuteCopyToStaging     = $ExecuteCopyToStaging"
    Write-Host "ExecuteStagingTransforms = $ExecuteStagingTransforms"
    Write-Host "ExecuteReviewItems       = $ExecuteReviewItems"
    Write-Host "ReplaceExistingReviewItems = $ReplaceExistingReviewItems"
}

# ==============================================================================
# STEP 0 — Setup + safety switches
# ============================================================================== 
#
# Run WORKBOOK.ps1 first. The only intended operator inputs above are $AppCode
# and $RunDir. This block refuses to create a new run folder: it must be pointed
# at an existing WORKBOOK run containing 03_transform_temp2.sql and
# 03_verify_temp2.sql.
#
# By default this stagebook is DRY-RUN: it writes SQL files but does not mutate DB.
# Change the relevant Execute* switch in the first block to $true only after
# reviewing the SQL.
#

# macOS-only workbook root. Run these scripts from the historical-books repo root.
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Root = $ScriptRoot
& {
    Set-Location $Root

    function Normalize-StageKey([string]$Value) {
        if ($null -eq $Value) { return '' }
        return ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]', ''))
    }

    function Is-FillMe([string]$Value) {
        return [string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'FILL-ME'
    }

    function Resolve-BookPath([string]$Path, [string]$BaseRoot) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
        if ([System.IO.Path]::IsPathRooted($expanded)) { return [System.IO.Path]::GetFullPath($expanded) }
        return [System.IO.Path]::GetFullPath((Join-Path $BaseRoot $expanded))
    }

    function Resolve-StageRunDir([string]$Value, [string]$BaseRoot) {
        if (Is-FillMe $Value) { throw 'RunDir is required. Set $RunDir to an existing WORKBOOK run folder under runs/yyyymmdd-hhmmss-appcode.' }
        return Resolve-BookPath -Path $Value -BaseRoot $BaseRoot
    }

    function Quote-SqlName([string]$Name) {
        if ([string]::IsNullOrWhiteSpace($Name)) { throw 'SQL identifier cannot be blank.' }
        return '[' + $Name.Replace(']', ']]') + ']'
    }

    function Get-SingleStageValue([object[]]$Values, [string]$Label, [string]$Path) {
        $unique = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($unique.Count -eq 0) { throw "Could not derive $Label from $Path." }
        if ($unique.Count -gt 1) { throw "Ambiguous $Label values in ${Path}: $($unique -join ', ')" }
        return [string]$unique[0]
    }

    function Get-ReviewPackMetadataValue([string]$Path, [string]$Name) {
        if (-not (Test-Path $Path -PathType Leaf)) { return '' }
        $text = Get-Content -Path $Path -Raw
        $pattern = '""Name"":""' + [regex]::Escape($Name) + '"",""Value"":""(?<value>[^""]*)""'
        $match = [regex]::Match($text, $pattern)
        if ($match.Success) { return $match.Groups['value'].Value }
        return ''
    }

    function global:Sql-StringLiteral([string]$Value) {
        if ($null -eq $Value) { return "NULL" }
        return "N'" + $Value.Replace("'", "''") + "'"
    }

    function global:Invoke-StageSqlFile {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Label
        )
        Write-Host ""
        Write-Host "======================================================================"
        Write-Host $Label
        Write-Host "Timestamp: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Host "Database : $TargetDb"
        Write-Host "SQL      : $Path"
        Write-Host "======================================================================"
        Add-Content -Path $ConsoleTracePath -Value ""
        Add-Content -Path $ConsoleTracePath -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Label ====="
        $output = & $sqlcmd -S $Server -d $TargetDb -G -N true -C -b -i $Path -W -w 65535 2>&1
        $exitCode = $LASTEXITCODE
        $output | Tee-Object -FilePath $ConsoleTracePath -Append
        if ($exitCode -ne 0) { throw "sqlcmd failed for $Label with exit code $exitCode" }
    }

    function Start-UarConsoleTrace([string]$Path, [string]$Label) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
        Add-Content -Path $Path -Value ""
        Add-Content -Path $Path -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Label trace setup ====="
        Set-Variable -Name UarConsoleTracePath -Value $Path -Scope Global
    }

    $ServerWasProvided = [bool](Get-Variable -Name Server -Scope Global -ErrorAction SilentlyContinue)
    $TargetDbWasProvided = [bool](Get-Variable -Name TargetDb -Scope Global -ErrorAction SilentlyContinue)
    $Server = if ($ServerWasProvided -and $Server) { $Server } else { '' }
    $TargetDb = if ($TargetDbWasProvided -and $TargetDb) { $TargetDb } else { '' }
    $AppCode = if ($AppCode) { $AppCode } else { "FILL-ME" }
    $PriorYearReviewCsv = if ($PriorYearReviewCsv) { Resolve-BookPath -Path $PriorYearReviewCsv -BaseRoot $Root } else { '' }

    if (Is-FillMe $AppCode) { throw 'AppCode is required. Set $AppCode at the top of STAGEBOOK.ps1.' }
    $RunDir = Resolve-StageRunDir -Value $RunDir -BaseRoot $Root
    if (Test-Path $RunDir -PathType Leaf) { throw "RunDir points to a file, expected folder: $RunDir" }
    if (-not (Test-Path $RunDir -PathType Container)) { throw "RunDir does not exist. Run WORKBOOK.ps1 first and point `$RunDir to that existing run folder: $RunDir" }

    $RunDirLeaf = Split-Path -Path $RunDir -Leaf
    $RunDirAppCode = ''
    if ($RunDirLeaf -match '^\d{8}-\d{4,6}-(?<code>.+)$') {
        $RunDirAppCode = $Matches['code']
        if ((Normalize-StageKey $RunDirAppCode) -ne (Normalize-StageKey $AppCode)) {
            throw "RunDir/AppCode mismatch. AppCode='$AppCode' but run folder suffix is '$RunDirAppCode'."
        }
    } else {
        Write-Warning "RunDir name does not match expected runs\yyyymmdd-hhmmss-appcode shape: $RunDirLeaf"
    }

    $OpsDir = Join-Path $Root "ops"
    $ReviewPackPs1 = if ($ReviewPackPs1) { $ReviewPackPs1 } else { Join-Path $OpsDir "WORKBOOK-04-review-pack.ps1" }
    $StagePackPs1 = if ($StagePackPs1) { $StagePackPs1 } else { Join-Path $OpsDir "STAGEBOOK-08-stage-pack.ps1" }
    $sqlcmd = 'tools/synthetic/sqlcmd'

    $TransformSqlPath = Join-Path $RunDir '03_transform_temp2.sql'
    $VerifyTemp2SqlPath = Join-Path $RunDir '03_verify_temp2.sql'
    $RoleCheckSqlPath = Join-Path $RunDir '02_role_check.sql'
    $ReviewPackSummaryPath = Join-Path $RunDir '04_review_pack_summary.csv'
    $ConsoleTracePath = Join-Path $RunDir 'console-trace-stagebook.txt'
    Start-UarConsoleTrace -Path $ConsoleTracePath -Label 'STAGEBOOK'
    if (-not (Test-Path $TransformSqlPath -PathType Leaf)) { throw "Required WORKBOOK artifact missing: $TransformSqlPath" }
    if (-not (Test-Path $VerifyTemp2SqlPath -PathType Leaf)) { throw "Required WORKBOOK artifact missing: $VerifyTemp2SqlPath" }

    $ParsedServer = Get-ReviewPackMetadataValue -Path $ReviewPackSummaryPath -Name 'Server'
    $ParsedTargetDb = Get-ReviewPackMetadataValue -Path $ReviewPackSummaryPath -Name 'Database'
    if (-not $ParsedTargetDb -and (Test-Path $RoleCheckSqlPath -PathType Leaf)) {
        $roleCheckText = Get-Content -Path $RoleCheckSqlPath -Raw
        if ($roleCheckText -match "(?im)PRINT\s+'Database\s*:\s*(?<db>[^']+)'") { $ParsedTargetDb = $Matches['db'] }
    }

    if ($ParsedServer) {
        if ($Server -and $Server -ne $ParsedServer) { throw "RunDir/Server mismatch. Server='$Server' but run artifact contains '$ParsedServer'." }
        $Server = $ParsedServer
    }
    if ($ParsedTargetDb) {
        if ($TargetDb -and $TargetDb -ne $ParsedTargetDb) { throw "RunDir/TargetDb mismatch. TargetDb='$TargetDb' but run artifact contains '$ParsedTargetDb'." }
        $TargetDb = $ParsedTargetDb
    }
    if (-not $Server) { $Server = "sql.reference.invalid" }
    if (-not $TargetDb) {
        throw "Could not derive TargetDb from run artifacts. Expected Database metadata in $ReviewPackSummaryPath or $RoleCheckSqlPath; rerun/complete WORKBOOK.ps1 or explicitly set `$TargetDb before this setup block."
    }

    $ReviewPackAppCode = Get-ReviewPackMetadataValue -Path $ReviewPackSummaryPath -Name 'AppCode'
    $ReviewPackAppId = Get-ReviewPackMetadataValue -Path $ReviewPackSummaryPath -Name 'AppId'
    $ReviewPackReviewCycleId = Get-ReviewPackMetadataValue -Path $ReviewPackSummaryPath -Name 'ReviewCycleId'
    $ReviewPackTemp2 = Get-ReviewPackMetadataValue -Path $ReviewPackSummaryPath -Name 'Temp2'

    $transformText = Get-Content -Path $TransformSqlPath -Raw

    $Temp2CodeMatches = [regex]::Matches(
        $transformText,
        '(?im)\b(?:CREATE\s+TABLE|INSERT\s+INTO|TRUNCATE\s+TABLE)\s+(?:\[dbo\]\.|dbo\.)(?:\[App_(?<bracket>[^\]]+)_Temp2\]|App_(?<bare>[A-Za-z0-9_]+)_Temp2\b)'
    )
    $ParsedAppCode = Get-SingleStageValue -Values @($Temp2CodeMatches | ForEach-Object { if ($_.Groups['bracket'].Success) { $_.Groups['bracket'].Value } else { $_.Groups['bare'].Value } }) -Label 'AppCode/Temp2 table' -Path $TransformSqlPath

    $verifyTemp2Text = Get-Content -Path $VerifyTemp2SqlPath -Raw
    $VerifyTemp2CodeMatches = [regex]::Matches(
        $verifyTemp2Text,
        '(?im)(?:\[dbo\]\.|dbo\.)(?:\[App_(?<bracket>[^\]]+)_Temp2\]|App_(?<bare>[A-Za-z0-9_]+)_Temp2\b)'
    )
    $VerifyTemp2AppCode = Get-SingleStageValue -Values @($VerifyTemp2CodeMatches | ForEach-Object { if ($_.Groups['bracket'].Success) { $_.Groups['bracket'].Value } else { $_.Groups['bare'].Value } }) -Label 'Temp2 table in 03_verify_temp2.sql' -Path $VerifyTemp2SqlPath

    if ((Normalize-StageKey $AppCode) -ne (Normalize-StageKey $ParsedAppCode)) {
        throw "RunDir/AppCode mismatch. AppCode='$AppCode' but $TransformSqlPath contains App_$($ParsedAppCode)_Temp2."
    }

    if ($RunDirAppCode -and (Normalize-StageKey $RunDirAppCode) -ne (Normalize-StageKey $ParsedAppCode)) {
        throw "RunDir/artifact mismatch. Run folder suffix is '$RunDirAppCode' but $TransformSqlPath contains App_$($ParsedAppCode)_Temp2."
    }

    if ((Normalize-StageKey $VerifyTemp2AppCode) -ne (Normalize-StageKey $ParsedAppCode)) {
        throw "RunDir artifact mismatch. $VerifyTemp2SqlPath contains App_$($VerifyTemp2AppCode)_Temp2 but $TransformSqlPath contains App_$($ParsedAppCode)_Temp2."
    }
    if ($ReviewPackAppCode -and (Normalize-StageKey $ReviewPackAppCode) -ne (Normalize-StageKey $ParsedAppCode)) {
        throw "RunDir artifact mismatch. Review pack AppCode='$ReviewPackAppCode' but $TransformSqlPath contains '$ParsedAppCode'."
    }
    if ($ReviewPackTemp2 -and (Normalize-StageKey $ReviewPackTemp2) -ne (Normalize-StageKey "dbo.App_$($ParsedAppCode)_Temp2")) {
        throw "RunDir artifact mismatch. Review pack Temp2='$ReviewPackTemp2' but expected dbo.App_$($ParsedAppCode)_Temp2."
    }

    $AppIdMatches = [regex]::Matches($transformText, "(?im)\bAND\s+ua\.Id\s*=\s*'(?<id>[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})'")
    $ReviewCycleIdMatches = [regex]::Matches($transformText, "(?im)'(?<id>[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})'\s+AS\s+ReviewCycleId")
    $ParsedAppId = (Get-SingleStageValue -Values @($AppIdMatches | ForEach-Object { $_.Groups['id'].Value.ToUpperInvariant() }) -Label 'ApplicationId' -Path $TransformSqlPath).ToUpperInvariant()
    $ParsedReviewCycleId = (Get-SingleStageValue -Values @($ReviewCycleIdMatches | ForEach-Object { $_.Groups['id'].Value.ToUpperInvariant() }) -Label 'ReviewCycleId' -Path $TransformSqlPath).ToUpperInvariant()

    if ($ReviewPackAppId -and $ReviewPackAppId.ToUpperInvariant() -ne $ParsedAppId) {
        throw "RunDir artifact mismatch. Review pack AppId='$ReviewPackAppId' but $TransformSqlPath contains '$ParsedAppId'."
    }
    if ($ReviewPackReviewCycleId -and $ReviewPackReviewCycleId.ToUpperInvariant() -ne $ParsedReviewCycleId) {
        throw "RunDir artifact mismatch. Review pack ReviewCycleId='$ReviewPackReviewCycleId' but $TransformSqlPath contains '$ParsedReviewCycleId'."
    }

    # The transform artifact is authoritative for exact casing/punctuation and IDs.
    $AppCode = $ParsedAppCode
    $AppId = $ParsedAppId
    $ReviewCycleId = $ParsedReviewCycleId
    $Temp2Name = "App_${AppCode}_Temp2"
    $Temp2 = (Quote-SqlName 'dbo') + '.' + (Quote-SqlName $Temp2Name)

    # Mutating step switches. Leave false to only write files. Preserve any value already set before rerunning a single step.
    $ExecuteCopyToStaging = if (Get-Variable -Name ExecuteCopyToStaging -Scope Global -ErrorAction SilentlyContinue) { [bool]$ExecuteCopyToStaging } else { $false }
    $ExecuteStagingTransforms = if (Get-Variable -Name ExecuteStagingTransforms -Scope Global -ErrorAction SilentlyContinue) { [bool]$ExecuteStagingTransforms } else { $false }
    $ExecuteReviewItems = if (Get-Variable -Name ExecuteReviewItems -Scope Global -ErrorAction SilentlyContinue) { [bool]$ExecuteReviewItems } else { $false }
    $ReplaceExistingReviewItems = if (Get-Variable -Name ReplaceExistingReviewItems -Scope Global -ErrorAction SilentlyContinue) { [bool]$ReplaceExistingReviewItems } else { $false }

    foreach ($v in @('Root','Server','TargetDb','AppCode','AppId','ReviewCycleId','PriorYearReviewCsv','RunDir','RunDirAppCode','OpsDir','ReviewPackPs1','StagePackPs1','sqlcmd','Temp2Name','Temp2','TransformSqlPath','VerifyTemp2SqlPath','RoleCheckSqlPath','ReviewPackSummaryPath','ConsoleTracePath','ParsedServer','ParsedTargetDb','ParsedAppCode','ParsedAppId','ParsedReviewCycleId','VerifyTemp2AppCode','ReviewPackAppCode','ReviewPackAppId','ReviewPackReviewCycleId','ReviewPackTemp2','ExecuteCopyToStaging','ExecuteStagingTransforms','ExecuteReviewItems','ReplaceExistingReviewItems')) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "Server                = $Server"
    Write-Host "TargetDb              = $TargetDb"
    Write-Host "AppCode               = $AppCode"
    Write-Host "AppId                 = $AppId"
    Write-Host "ReviewCycleId         = $ReviewCycleId"
    Write-Host "Temp2                 = $Temp2"
    Write-Host "RunDir                = $RunDir"
    Write-Host "TransformSqlPath      = $TransformSqlPath"
    Write-Host "VerifyTemp2SqlPath    = $VerifyTemp2SqlPath"
    Write-Host "RoleCheckSqlPath      = $RoleCheckSqlPath"
    Write-Host "ReviewPackSummaryPath = $ReviewPackSummaryPath"
    Write-Host "ConsoleTracePath      = $ConsoleTracePath"
    Write-Host "StagePackPs1          = $StagePackPs1"
    Write-Host "RunDirAppCode         = $RunDirAppCode"
    Write-Host ""
    Write-Host "ParsedServer          = $ParsedServer"
    Write-Host "ParsedTargetDb        = $ParsedTargetDb"
    Write-Host "VerifyTemp2AppCode    = $VerifyTemp2AppCode"
    Write-Host "ReviewPackAppCode     = $ReviewPackAppCode"
    Write-Host "ReviewPackAppId       = $ReviewPackAppId"
    Write-Host "ReviewPackCycleId     = $ReviewPackReviewCycleId"
    Write-Host "ReviewPackTemp2       = $ReviewPackTemp2"
    Write-Host "ParsedAppCode         = $ParsedAppCode"
    Write-Host "ParsedAppId           = $ParsedAppId"
    Write-Host "ParsedReviewCycleId   = $ParsedReviewCycleId"
    Write-Host ""
    Write-Host "ExecuteCopyToStaging      = $ExecuteCopyToStaging"
    Write-Host "ExecuteStagingTransforms  = $ExecuteStagingTransforms"
    Write-Host "ExecuteReviewItems        = $ExecuteReviewItems"
    Write-Host "ReplaceExistingReviewItems = $ReplaceExistingReviewItems"
}

# ==============================================================================
# STEP 1 — Preflight: verify Temp2 and existing ReviewItems/Staging state
# ============================================================================== 
#
# Read-only. Confirms WORKBOOK has produced Temp2 and checks blockers before copy.
#

& {
    $preflightSqlPath = Join-Path $RunDir '06_stage_preflight.sql'
    $preflightSql = @"
SET NOCOUNT ON;

DECLARE @AppId uniqueidentifier = '$AppId';
DECLARE @ReviewCycleId uniqueidentifier = '$ReviewCycleId';

PRINT 'Stagebook preflight';
PRINT 'AppId';
PRINT CONVERT(varchar(36), @AppId);
PRINT 'ReviewCycleId';
PRINT CONVERT(varchar(36), @ReviewCycleId);
PRINT 'Temp2';
PRINT '$Temp2Name';
PRINT '';

IF OBJECT_ID(N'dbo.$Temp2Name', 'U') IS NULL
    THROW 54000, 'Temp2 table does not exist. Run WORKBOOK Temp2 transform first.', 1;

SELECT 'Temp2 rows for app/cycle' AS Metric, COUNT_BIG(*) AS Value
FROM $Temp2
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
UNION ALL SELECT 'Temp2 ShouldReview=1', COUNT_BIG(*) FROM $Temp2 WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND ShouldReview = 1
UNION ALL SELECT 'Temp2 blank FullName', COUNT_BIG(*) FROM $Temp2 WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND (FullName IS NULL OR LEN(FullName) = 0)
UNION ALL SELECT 'Temp2 blank ReviewerAccount where ShouldReview=1', COUNT_BIG(*) FROM $Temp2 WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND ShouldReview = 1 AND (ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0)
UNION ALL SELECT 'Existing ReviewItemsStaging rows for app/cycle', COUNT_BIG(*) FROM dbo.ReviewItemsStaging WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
UNION ALL SELECT 'Existing ReviewItems rows for app/cycle', COUNT_BIG(*) FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;

SELECT ReviewType, ShouldReview, COUNT_BIG(*) AS [RowCount]
FROM $Temp2
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ReviewType, ShouldReview
ORDER BY ReviewType, ShouldReview;

SELECT ShouldReviewComment, COUNT_BIG(*) AS [RowCount]
FROM $Temp2
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ShouldReviewComment
ORDER BY [RowCount] DESC, ShouldReviewComment;

SELECT TOP (50)
    Id, AccountName, FullName, RoleName, RoleType, ReviewType,
    ManagerAccount, BusinessOwnerAccount, ReviewerAccount, DelegateAccount,
    ShouldReview, ShouldReviewComment
FROM $Temp2
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
  AND (
      FullName IS NULL OR LEN(FullName) = 0
      OR (ShouldReview = 1 AND (ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0))
  )
ORDER BY RoleName, AccountName;
"@
    $preflightSql | Set-Content -Path $preflightSqlPath -Encoding UTF8
    Invoke-StageSqlFile -Path $preflightSqlPath -Label 'STEP 1 preflight Temp2/staging state (read-only)'
}

# ==============================================================================
# STEP 2 — Copy Temp2 to ReviewItemsStaging
# ============================================================================== 
#
# Equivalent of original 01.Copy_Temp2-to-ReviewItemsStaging.sql, but scoped to
# one ApplicationId + ReviewCycleId and safe to rerun for staging.
#
# It performs the original FullName fallback in Temp2, then copies the rowset
# column-for-column into ReviewItemsStaging.
#

& {
    $copyStagingSqlPath = Join-Path $RunDir '07_copy_temp2_to_reviewitemsstaging.sql'
    $copyStagingSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @AppId uniqueidentifier = '$AppId';
DECLARE @ReviewCycleId uniqueidentifier = '$ReviewCycleId';

IF OBJECT_ID(N'dbo.$Temp2Name', 'U') IS NULL
    THROW 54100, 'Temp2 table does not exist. Run WORKBOOK Temp2 transform first.', 1;

IF NOT EXISTS (SELECT 1 FROM $Temp2 WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId)
    THROW 54101, 'No Temp2 rows found for this App/ReviewCycle.', 1;

-- Original reviewitems/01 step: repair blank FullName before staging insert.
UPDATE $Temp2
SET FullName = COALESCE(NULLIF(AccountName, ''), NULLIF(SVCAccountName, ''), NULLIF(LocalAccountName, ''), FullName)
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND (FullName IS NULL OR LEN(FullName) = 0)
  AND COALESCE(NULLIF(AccountName, ''), NULLIF(SVCAccountName, ''), NULLIF(LocalAccountName, '')) IS NOT NULL;

IF EXISTS (
    SELECT 1 FROM $Temp2
    WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
      AND (FullName IS NULL OR LEN(FullName) = 0)
)
    THROW 54102, 'Cannot copy to staging: blank FullName remains in Temp2.', 1;

IF EXISTS (
    SELECT 1 FROM $Temp2
    WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
      AND ShouldReview = 1 AND (ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0)
)
    THROW 54103, 'Cannot copy to staging: blank ReviewerAccount where ShouldReview=1.', 1;

DELETE FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;

INSERT INTO dbo.ReviewItemsStaging (
    Id, AccountName, FullName, StaffId, EmailAddress, Title, AccountType,
    ManagerAccount, ManagerName, SVCAccountName, LocalAccountName, Department,
    Vendor, RoleName, RoleType, Path, Description, DataSource, ADStatus,
    ApplicationAccountStatus, ReviewType, DelegateAccount, Hostname, ExtractDate,
    ModifiedDate, ApplicationId, ReviewCycleId, MORAccount, BusinessOwnerAccount,
    ReviewerAccount, ShouldReview, ShouldReviewComment
)
SELECT
    Id, AccountName, FullName, StaffId, EmailAddress, Title, AccountType,
    ManagerAccount, ManagerName, SVCAccountName, LocalAccountName, Department,
    Vendor, RoleName, RoleType, Path, Description, DataSource, ADStatus,
    ApplicationAccountStatus, ReviewType, DelegateAccount, Hostname, ExtractDate,
    ModifiedDate, ApplicationId, ReviewCycleId, MORAccount, BusinessOwnerAccount,
    ReviewerAccount, ShouldReview, ShouldReviewComment
FROM $Temp2
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;

SELECT 'ReviewItemsStaging rows for app/cycle' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
UNION ALL SELECT 'ReviewItemsStaging ShouldReview=1', COUNT_BIG(*) FROM dbo.ReviewItemsStaging WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND ShouldReview = 1;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $copyStagingSql | Set-Content -Path $copyStagingSqlPath -Encoding UTF8

    if ($ExecuteCopyToStaging) {
        Invoke-StageSqlFile -Path $copyStagingSqlPath -Label 'STEP 2 copy Temp2 to ReviewItemsStaging (MUTATING)'
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote staging copy SQL but did not execute:"
        Write-Host $copyStagingSqlPath
        Write-Host "Set `$ExecuteCopyToStaging = `$true in the first block, rerun that block, then rerun STEP 2 to execute."
    }
}

# ==============================================================================
# STEP 3 — Apply ReviewItemsStaging transformations / cleanup
# ============================================================================== 
#
# Scoped implementation of original:
#   00.DataTransformation_ReviewItemsStaging.sql
#   02.Update-ReviewItemsStaging.sql
#
# The old scripts were global and contained dated one-off campaign fixes. This
# step ports the durable generic processing only, scoped to the current app/cycle:
#   - refresh employee-derived fields from dbo.Employees
#   - normalise blank optional values to NULL
#   - re-apply not-reviewable gates for inactive/app-disabled/base/group rows
#   - repair missing reviewer routing only where blank
#   - clear MORAccount on BusinessOwner reviews
#   - fail if ShouldReview=1 rows still have blank critical fields
#
# It intentionally does NOT overwrite IAM-approved reviewer routing already
# applied to Temp2 before staging.
#

& {
    $transformStagingSqlPath = Join-Path $RunDir '07b_transform_reviewitemsstaging.sql'
    $transformStagingSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @AppId uniqueidentifier = '$AppId';
DECLARE @ReviewCycleId uniqueidentifier = '$ReviewCycleId';

IF NOT EXISTS (SELECT 1 FROM dbo.ReviewItemsStaging WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId)
    THROW 54200, 'No ReviewItemsStaging rows found for this App/ReviewCycle. Run STEP 2 first.', 1;

PRINT 'Before staging transformations';
SELECT ReviewType, ShouldReview, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ReviewType, ShouldReview
ORDER BY ReviewType, ShouldReview;

-- Refresh employee-derived fields from dbo.Employees, scoped to this app/cycle.
UPDATE stg
SET
    ManagerAccount = NULLIF(ue.ManagerAccountName, ''),
    ManagerName = NULLIF(ub.FullName, ''),
    Title = NULLIF(ue.Title, ''),
    Department = NULLIF(ue.Department, ''),
    MORAccount = NULLIF(ub.ManagerAccountName, ''),
    ADStatus = CASE
        WHEN ue.AccountName IS NULL THEN stg.ADStatus
        WHEN ue.OwnerAccount IS NULL THEN
            CASE
                WHEN stg.AccountName LIKE 'z[0-9]%[0-9]' THEN CONVERT(bit, 0)
                WHEN stg.AccountName LIKE '%_sa' THEN CONVERT(bit, 0)
                ELSE NULL
            ENDp
        WHEN stg.AccountName IN ('root', 'administrator') THEN NULL
        ELSE ue.AccountStatus
    END
FROM dbo.ReviewItemsStaging stg
LEFT JOIN dbo.Employees ue ON ue.AccountName = stg.AccountName
LEFT JOIN dbo.Employees ub ON ub.AccountName = ue.ManagerAccountName
WHERE stg.ApplicationId = @AppId
  AND stg.ReviewCycleId = @ReviewCycleId
  AND stg.AccountName IS NOT NULL;

PRINT CONCAT('Employee refresh rows touched: ', @@ROWCOUNT);

-- Normalise blank optional values to NULL, matching original ReviewItems cleanup style.
UPDATE dbo.ReviewItemsStaging
SET
    StaffId = NULLIF(StaffId, ''),
    EmailAddress = NULLIF(EmailAddress, ''),
    Title = NULLIF(Title, ''),
    ManagerAccount = NULLIF(ManagerAccount, ''),
    ManagerName = NULLIF(ManagerName, ''),
    SVCAccountName = NULLIF(SVCAccountName, ''),
    LocalAccountName = NULLIF(LocalAccountName, ''),
    Department = NULLIF(Department, ''),
    Vendor = NULLIF(Vendor, ''),
    DelegateAccount = NULLIF(DelegateAccount, ''),
    Hostname = NULLIF(Hostname, ''),
    MORAccount = NULLIF(MORAccount, ''),
    ReviewerAccount = NULLIF(ReviewerAccount, ''),
    ShouldReviewComment = NULLIF(ShouldReviewComment, '')
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;

PRINT CONCAT('Blank-to-NULL normalisation rows touched: ', @@ROWCOUNT);

-- Generic not-reviewable gates from original staging transformation scripts.
UPDATE dbo.ReviewItemsStaging
SET ShouldReview = 0,
    ShouldReviewComment = 'Base Role'
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND RoleType = 'Base'
  AND (ShouldReview <> 0 OR ISNULL(ShouldReviewComment, '') <> 'Base Role');
PRINT CONCAT('Base role exclusions: ', @@ROWCOUNT);

UPDATE dbo.ReviewItemsStaging
SET ShouldReview = 0,
    ShouldReviewComment = 'Inactive in application'
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ShouldReview = 1
  AND ISNULL(ApplicationAccountStatus, 0) = 0;
PRINT CONCAT('Inactive application exclusions: ', @@ROWCOUNT);

UPDATE dbo.ReviewItemsStaging
SET ShouldReview = 0,
    ShouldReviewComment = 'Dormant Account - App team to review'
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ShouldReview = 1
  AND ISNULL(ADStatus, 1) = 0
  AND ISNULL(ApplicationAccountStatus, 1) = 1;
PRINT CONCAT('Dormant/disabled AD exclusions: ', @@ROWCOUNT);

UPDATE dbo.ReviewItemsStaging
SET ShouldReview = 0,
    ShouldReviewComment = 'Group review item'
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ShouldReview = 1
  AND AccountType IN ('Group', 'ServicePrincipalName');
PRINT CONCAT('Group/SPN exclusions: ', @@ROWCOUNT);

-- Repair only blank reviewer routing. Do not overwrite IAM-approved Temp2 routing.
UPDATE dbo.ReviewItemsStaging
SET ReviewType = 'LineManager',
    ReviewerAccount = ManagerAccount
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ShouldReview = 1
  AND RoleType IN ('Standard', 'Elevated')
  AND ManagerAccount IS NOT NULL
  AND (ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0);
PRINT CONCAT('Blank reviewer repaired to LineManager: ', @@ROWCOUNT);

UPDATE dbo.ReviewItemsStaging
SET ReviewType = 'BusinessOwner',
    ReviewerAccount = BusinessOwnerAccount
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ShouldReview = 1
  AND (ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0)
  AND BusinessOwnerAccount IS NOT NULL;
PRINT CONCAT('Blank reviewer repaired to BusinessOwner: ', @@ROWCOUNT);

-- Original staging rule: MORAccount not needed for BO routed reviews.
UPDATE dbo.ReviewItemsStaging
SET MORAccount = NULL
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ReviewType = 'BusinessOwner'
  AND MORAccount IS NOT NULL;
PRINT CONCAT('MORAccount cleared for BusinessOwner reviews: ', @@ROWCOUNT);

-- Final blockers before ReviewItems insert.
IF EXISTS (
    SELECT 1
    FROM dbo.ReviewItemsStaging
    WHERE ApplicationId = @AppId
      AND ReviewCycleId = @ReviewCycleId
      AND ShouldReview = 1
      AND (
          FullName IS NULL OR LEN(FullName) = 0
          OR RoleName IS NULL OR LEN(RoleName) = 0
          OR RoleType IS NULL OR LEN(RoleType) = 0
          OR ReviewType IS NULL OR LEN(ReviewType) = 0
          OR ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0
          OR BusinessOwnerAccount IS NULL OR LEN(BusinessOwnerAccount) = 0
      )
)
BEGIN
    SELECT TOP (100)
        Id, AccountName, FullName, RoleName, RoleType, ReviewType,
        ManagerAccount, BusinessOwnerAccount, ReviewerAccount, DelegateAccount,
        ShouldReview, ShouldReviewComment
    FROM dbo.ReviewItemsStaging
    WHERE ApplicationId = @AppId
      AND ReviewCycleId = @ReviewCycleId
      AND ShouldReview = 1
      AND (
          FullName IS NULL OR LEN(FullName) = 0
          OR RoleName IS NULL OR LEN(RoleName) = 0
          OR RoleType IS NULL OR LEN(RoleType) = 0
          OR ReviewType IS NULL OR LEN(ReviewType) = 0
          OR ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0
          OR BusinessOwnerAccount IS NULL OR LEN(BusinessOwnerAccount) = 0
      )
    ORDER BY RoleName, AccountName;

    THROW 54201, 'ReviewItemsStaging blockers remain. Fix before inserting ReviewItems.', 1;
END;

PRINT 'After staging transformations';
SELECT ReviewType, ShouldReview, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ReviewType, ShouldReview
ORDER BY ReviewType, ShouldReview;

SELECT ShouldReviewComment, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ShouldReviewComment
ORDER BY [RowCount] DESC, ShouldReviewComment;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $transformStagingSql | Set-Content -Path $transformStagingSqlPath -Encoding UTF8

    if ($ExecuteStagingTransforms) {
        Invoke-StageSqlFile -Path $transformStagingSqlPath -Label 'STEP 3 transform ReviewItemsStaging (MUTATING)'
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote staging transformation SQL but did not execute:"
        Write-Host $transformStagingSqlPath
        Write-Host "Set `$ExecuteStagingTransforms = `$true in the first block, rerun that block, then rerun STEP 3 to execute."
    }
}

# ==============================================================================
# STEP 4 — Verify ReviewItemsStaging after transformation
# ============================================================================== 
#
# Read-only gate before ReviewItems insert.
#

& {
    $verifyStagingSqlPath = Join-Path $RunDir '07c_verify_reviewitemsstaging.sql'
    $verifyStagingSql = @"
SET NOCOUNT ON;

DECLARE @AppId uniqueidentifier = '$AppId';
DECLARE @ReviewCycleId uniqueidentifier = '$ReviewCycleId';

SELECT 'ReviewItemsStaging rows for app/cycle' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
UNION ALL SELECT 'ReviewItemsStaging ShouldReview=1', COUNT_BIG(*) FROM dbo.ReviewItemsStaging WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND ShouldReview = 1
UNION ALL SELECT 'Blank critical fields where ShouldReview=1', COUNT_BIG(*) FROM dbo.ReviewItemsStaging WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND ShouldReview = 1 AND (
    FullName IS NULL OR LEN(FullName) = 0
    OR RoleName IS NULL OR LEN(RoleName) = 0
    OR RoleType IS NULL OR LEN(RoleType) = 0
    OR ReviewType IS NULL OR LEN(ReviewType) = 0
    OR ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0
    OR BusinessOwnerAccount IS NULL OR LEN(BusinessOwnerAccount) = 0
)
UNION ALL SELECT 'Existing ReviewItems rows for app/cycle', COUNT_BIG(*) FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;

SELECT ReviewType, ShouldReview, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ReviewType, ShouldReview
ORDER BY ReviewType, ShouldReview;

SELECT RoleType, ShouldReview, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY RoleType, ShouldReview
ORDER BY RoleType, ShouldReview;

SELECT ShouldReviewComment, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ShouldReviewComment
ORDER BY [RowCount] DESC, ShouldReviewComment;

SELECT TOP (100)
    Id, AccountName, FullName, RoleName, RoleType, ReviewType,
    ManagerAccount, BusinessOwnerAccount, ReviewerAccount, DelegateAccount,
    ShouldReview, ShouldReviewComment
FROM dbo.ReviewItemsStaging
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ShouldReview = 1
  AND (
      FullName IS NULL OR LEN(FullName) = 0
      OR RoleName IS NULL OR LEN(RoleName) = 0
      OR RoleType IS NULL OR LEN(RoleType) = 0
      OR ReviewType IS NULL OR LEN(ReviewType) = 0
      OR ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0
      OR BusinessOwnerAccount IS NULL OR LEN(BusinessOwnerAccount) = 0
  )
ORDER BY RoleName, AccountName;
"@
    $verifyStagingSql | Set-Content -Path $verifyStagingSqlPath -Encoding UTF8
    Invoke-StageSqlFile -Path $verifyStagingSqlPath -Label 'STEP 4 verify ReviewItemsStaging (read-only)'
}

# ==============================================================================
# STEP 5 — Insert ReviewItems from staging
# ============================================================================== 
#
# Equivalent of original 03.Insert-ReviewItemsStaging-to-ReviewItems.sql, scoped
# to one ApplicationId + ReviewCycleId.
#
# Rerun safety:
#   - default blocks when ReviewItems already exist, with an operator-readable state summary;
#   - $ReplaceExistingReviewItems = $false allows delete/reinsert only when existing rows
#     still look pre-launch/untouched (no responses, completion, issued/due/escalation, etc.).
#

& {
    $insertReviewItemsSqlPath = Join-Path $RunDir '08_insert_reviewitems.sql'
    $insertReviewItemsSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @AppId uniqueidentifier = '$AppId';
DECLARE @ReviewCycleId uniqueidentifier = '$ReviewCycleId';
DECLARE @ReplaceExistingReviewItems bit = $(if ($ReplaceExistingReviewItems) { '1' } else { '0' });
DECLARE @ExistingReviewItems bigint;
DECLARE @ExistingTouchedReviewItems bigint;
DECLARE @DeletedReviewItems bigint = 0;

SELECT @ExistingReviewItems = COUNT_BIG(*)
FROM dbo.ReviewItems
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;

SELECT @ExistingTouchedReviewItems = COUNT_BIG(*)
FROM dbo.ReviewItems
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND (
      Response IS NOT NULL
      OR CompletedDate IS NOT NULL
      OR CompletedBy IS NOT NULL
      OR (Comment IS NOT NULL AND LEN(Comment) > 0)
      OR IssuedDate IS NOT NULL
      OR DueDate IS NOT NULL
      OR MoREscalationStartDate IS NOT NULL
      OR MoREscalationDueDate IS NOT NULL
      OR BOEscalationStartDate IS NOT NULL
      OR BOEscalationDueDate IS NOT NULL
      OR RevocationTicketNumber IS NOT NULL
      OR BatchNumber IS NOT NULL
      OR Cycle IS NOT NULL
      OR Phase IS NOT NULL
  );

IF @ExistingReviewItems > 0
BEGIN
    SELECT 'Existing ReviewItems rows for app/cycle' AS Metric, @ExistingReviewItems AS Value
    UNION ALL SELECT 'Existing ReviewItems touched/issued/completed rows', @ExistingTouchedReviewItems
    UNION ALL SELECT 'ReplaceExistingReviewItems switch', CONVERT(bigint, @ReplaceExistingReviewItems);

    SELECT ReviewType,
           COUNT_BIG(*) AS [Rows],
           SUM(CASE WHEN Response IS NULL THEN 1 ELSE 0 END) AS PendingRows,
           SUM(CASE WHEN Response IS NOT NULL THEN 1 ELSE 0 END) AS RespondedRows,
           SUM(CASE WHEN IssuedDate IS NOT NULL OR DueDate IS NOT NULL THEN 1 ELSE 0 END) AS IssuedOrDueRows,
           SUM(CASE WHEN CompletedDate IS NOT NULL OR CompletedBy IS NOT NULL THEN 1 ELSE 0 END) AS CompletedRows
    FROM dbo.ReviewItems
    WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
    GROUP BY ReviewType
    ORDER BY ReviewType;

    IF @ReplaceExistingReviewItems = 0
        THROW 54300, 'ReviewItems already exist for this App/ReviewCycle. Default is no replace. Review the summary above; set ReplaceExistingReviewItems true only for pre-launch rerun replacement.', 1;

    IF @ExistingTouchedReviewItems > 0
    BEGIN
        SELECT TOP (50)
            Id, AccountName, FullName, RoleName, ReviewType, ReviewerAccount,
            Response, Comment, CompletedDate, CompletedBy, IssuedDate, DueDate,
            MoREscalationStartDate, BOEscalationStartDate, RevocationTicketNumber,
            BatchNumber, Cycle, Phase
        FROM dbo.ReviewItems
        WHERE ApplicationId = @AppId
          AND ReviewCycleId = @ReviewCycleId
          AND (
              Response IS NOT NULL
              OR CompletedDate IS NOT NULL
              OR CompletedBy IS NOT NULL
              OR (Comment IS NOT NULL AND LEN(Comment) > 0)
              OR IssuedDate IS NOT NULL
              OR DueDate IS NOT NULL
              OR MoREscalationStartDate IS NOT NULL
              OR MoREscalationDueDate IS NOT NULL
              OR BOEscalationStartDate IS NOT NULL
              OR BOEscalationDueDate IS NOT NULL
              OR RevocationTicketNumber IS NOT NULL
              OR BatchNumber IS NOT NULL
              OR Cycle IS NOT NULL
              OR Phase IS NOT NULL
          )
        ORDER BY CompletedDate DESC, IssuedDate DESC, RoleName, AccountName;

        THROW 54304, 'ReplaceExistingReviewItems requested, but existing ReviewItems appear issued/touched/completed. Stop to preserve review/audit state; use a controlled correction path instead.', 1;
    END;

    DELETE FROM dbo.ReviewItems
    WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId;
    SET @DeletedReviewItems = @@ROWCOUNT;

    SELECT 'Pre-launch ReviewItems deleted before replace' AS Metric, @DeletedReviewItems AS Value;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.ReviewItemsStaging WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId)
    THROW 54301, 'No ReviewItemsStaging rows found for this App/ReviewCycle.', 1;

IF EXISTS (
    SELECT 1
    FROM dbo.ReviewItemsStaging
    WHERE ApplicationId = @AppId
      AND ReviewCycleId = @ReviewCycleId
      AND ShouldReview = 1
      AND (
          FullName IS NULL OR LEN(FullName) = 0
          OR RoleName IS NULL OR LEN(RoleName) = 0
          OR RoleType IS NULL OR LEN(RoleType) = 0
          OR ReviewType IS NULL OR LEN(ReviewType) = 0
          OR ReviewerAccount IS NULL OR LEN(ReviewerAccount) = 0
          OR BusinessOwnerAccount IS NULL OR LEN(BusinessOwnerAccount) = 0
      )
)
    THROW 54302, 'Cannot insert ReviewItems: staging blockers remain.', 1;

INSERT INTO dbo.ReviewItems (
    Id, AccountName, FullName, StaffId, EmailAddress, Title, AccountType,
    ManagerAccount, ManagerName, SVCAccountName, LocalAccountName, Department,
    Vendor, RoleName, Description, RoleType, Path, DataSource, ADStatus,
    ApplicationAccountStatus, ReviewType, BatchNumber, DelegateAccount, Response,
    Hostname, Cycle, Phase, Comment, CompletedDate, DueDate, IssuedDate,
    MoREscalationStartDate, MoREscalationDueDate, BOEscalationStartDate,
    BOEscalationDueDate, ExtractDate, ModifiedDate, RevocationTicketNumber,
    ApplicationId, ReviewCycleId, MORAccount, BusinessOwnerAccount,
    ReviewerAccount, ReviewerName, CompletedBy
)
SELECT
    stg.Id, stg.AccountName, stg.FullName, stg.StaffId, stg.EmailAddress, stg.Title, stg.AccountType,
    stg.ManagerAccount, stg.ManagerName, stg.SVCAccountName, stg.LocalAccountName, stg.Department,
    stg.Vendor, stg.RoleName, stg.Description, stg.RoleType, stg.Path, stg.DataSource, stg.ADStatus,
    stg.ApplicationAccountStatus, stg.ReviewType, NULL, stg.DelegateAccount, NULL,
    stg.Hostname, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, stg.ExtractDate, GETDATE(), NULL,
    stg.ApplicationId, stg.ReviewCycleId, stg.MORAccount, stg.BusinessOwnerAccount,
    stg.ReviewerAccount, COALESCE(ue.FullName, ue.DisplayName, stg.ReviewerAccount), NULL
FROM dbo.ReviewItemsStaging stg
LEFT JOIN dbo.Employees ue ON ue.AccountName = stg.ReviewerAccount
WHERE stg.ApplicationId = @AppId
  AND stg.ReviewCycleId = @ReviewCycleId
  AND stg.ShouldReview = 1;

SELECT 'ReviewItems inserted/current for app/cycle' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.ReviewItems
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
UNION ALL SELECT 'ReviewItems deleted before replace', @DeletedReviewItems
UNION ALL SELECT 'ReplaceExistingReviewItems switch', CONVERT(bigint, @ReplaceExistingReviewItems);

SELECT ReviewType, COUNT_BIG(*) AS [RowCount]
FROM dbo.ReviewItems
WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
GROUP BY ReviewType
ORDER BY ReviewType;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $insertReviewItemsSql | Set-Content -Path $insertReviewItemsSqlPath -Encoding UTF8

    if ($ExecuteReviewItems) {
        Invoke-StageSqlFile -Path $insertReviewItemsSqlPath -Label 'STEP 5 insert ReviewItems (MUTATING)'
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote ReviewItems insert SQL but did not execute:"
        Write-Host $insertReviewItemsSqlPath
        Write-Host "Set `$ExecuteReviewItems = `$true in the first block, rerun that block, then rerun STEP 5 to execute."
    }
}

# ==============================================================================
# STEP 6 — Generate stage pack + final summary
# ============================================================================== 

#
# Produces 08_stage_pack.txt/html plus summary CSVs in $RunDir.
# Read-only. Safe to rerun after any stagebook step.
#

& {
    if (-not (Test-Path $StagePackPs1 -PathType Leaf)) { throw "Stage pack script not found: $StagePackPs1" }

    & $StagePackPs1 `
        -Server $Server `
        -Database $TargetDb `
        -AppCode $AppCode `
        -AppId $AppId `
        -ReviewCycleId $ReviewCycleId `
        -RunDir $RunDir `
        -SqlCmd $sqlcmd `
        -ExecuteCopyToStaging $ExecuteCopyToStaging `
        -ExecuteStagingTransforms $ExecuteStagingTransforms `
        -ExecuteReviewItems $ExecuteReviewItems `
        -ReplaceExistingReviewItems $ReplaceExistingReviewItems

    Write-Host ""
    Write-Host "STAGEBOOK completed."
    Write-Host "Generated SQL files are in: $RunDir"
    Write-Host "Console trace: $ConsoleTracePath"
    Write-Host "Stage pack:"
    Write-Host "  $(Join-Path $RunDir '08_stage_pack.txt')"
    Write-Host "  $(Join-Path $RunDir '08_stage_pack.html')"
    if (-not ($ExecuteCopyToStaging -or $ExecuteStagingTransforms -or $ExecuteReviewItems)) {
        Write-Host "No mutating switches were true; database was not changed by STAGEBOOK."
    }
}
