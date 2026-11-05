# SANITISED HISTORICAL DERIVATIVE — reference only; not an operational runbook.
# Synthetic examples; dependencies and credentials intentionally not included.
# Do not run selections or remove this guard. See docs/books.md and docs/books-provenance.json.
throw "REFERENCE ONLY: execution is unconditionally disabled."

# ==============================================================================
# UAR SyntheticReview Smoke Test Workbook
# ==============================================================================
#
# Creates clearly tagged dummy ReviewItems rows so an IAM operator can sign in to
# SyntheticReview and verify the reviewer experience for their own account, normally in
# synthetic-test/test first.
#
# This is NOT part of normal campaign staging. It is an operator smoke-test tool:
#   - creates BO and/or LineManager dummy rows assigned to $TestReviewerAccount;
#   - can optionally create one clearly tagged Reviewer EmailQueue smoke-test row;
#   - follows the real timeline: create row -> queue/send email -> test SyntheticReview -> verify -> cleanup;
#   - keeps rows tagged with $TestTag and DataSource='SYNTHETICREVIEW_SMOKETEST';
#   - provides explicit cleanup steps for tagged ReviewItems and EmailQueue rows.
#
# ============================================================================== 

# ==============================================================================
# REQUIRED INPUTS + EXECUTE SWITCHES — edit these values first
# ============================================================================== 
# Leave execute switches false for DRY-RUN. Prefer TargetDb='synthetic-test'.
# If you intentionally smoke-test production SyntheticReview, set AllowProductionSmokeTest
# to $true and keep the test rows clearly tagged/cleaned up.

& {
    $Server = "sql.reference.invalid"
    $TargetDb = "synthetic-test"          # preferred for smoke test; use production only with explicit allow below
    $AllowProductionSmokeTest = $false  # must be true if TargetDb = synthetic-production

    $AppSearch = "%SyntheticAppC%"       # must uniquely match one dbo.Applications.ApplicationName
    $ReviewCycleName = "DEMO"           # preferred for synthetic-test smoke tests; leave blank if using ReviewCycleId
    $ReviewCycleId = "00000000-0000-4000-8000-000000000002"                 # optional exact cycle id; wins over ReviewCycleName when set
    $TestReviewerAccount = "synthetic-reviewer-01"   # yourself / IAM tester
    $TestSubjectAccount = "syntheticreview-smoketest" # dummy reviewed subject/account prefix
    $TestTag = "SYNTHETICREVIEW_SMOKETEST_synthetic-reviewer-01"  # stable tag used for create/verify/cleanup
    $SyntheticReviewUrl = ""                      # optional: paste app URL for operator output

    $CreateBusinessOwnerItem = $false
    $CreateLineManagerItem = $false

    $ExecuteCreateSmokeTestRows = $false
    $ExecuteCleanupSmokeTestRows = $false

    # Optional notification pre-flight smoke test. DelegatedShared uses your
    # interactive Graph sign-in plus Send As permission on the shared mailbox.
    $EmailSmokeActionName = "Reviewer"
    $MailAuthMode = "DelegatedShared"   # TESTBOOK: DelegatedShared; MAILBOOK/prod: AppOnly
    $EmailSender = "review-notices@example.invalid"
    $ExecuteCreateEmailQueueSmokeTestRow = $false
    $ExecuteSendSmokeTestEmail = $false
    $ExecuteCleanupEmailQueueSmokeTestRows = $false

    foreach ($v in @(
        'Server','TargetDb','AllowProductionSmokeTest','AppSearch','ReviewCycleName','ReviewCycleId','TestReviewerAccount',
        'TestSubjectAccount','TestTag','SyntheticReviewUrl','CreateBusinessOwnerItem',
        'CreateLineManagerItem','ExecuteCreateSmokeTestRows','ExecuteCleanupSmokeTestRows',
        'EmailSmokeActionName','MailAuthMode','EmailSender','ExecuteCreateEmailQueueSmokeTestRow','ExecuteSendSmokeTestEmail','ExecuteCleanupEmailQueueSmokeTestRows'
    )) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "Server                      = $Server"
    Write-Host "TargetDb                    = $TargetDb"
    Write-Host "AllowProductionSmokeTest    = $AllowProductionSmokeTest"
    Write-Host "AppSearch                   = $AppSearch"
    Write-Host "ReviewCycleName             = $ReviewCycleName"
    Write-Host "ReviewCycleId               = $ReviewCycleId"
    Write-Host "TestReviewerAccount         = $TestReviewerAccount"
    Write-Host "TestSubjectAccount          = $TestSubjectAccount"
    Write-Host "TestTag                     = $TestTag"
    Write-Host "CreateBusinessOwnerItem     = $CreateBusinessOwnerItem"
    Write-Host "CreateLineManagerItem       = $CreateLineManagerItem"
    Write-Host "ExecuteCreateSmokeTestRows        = $ExecuteCreateSmokeTestRows"
    Write-Host "ExecuteCleanupSmokeTestRows       = $ExecuteCleanupSmokeTestRows"
    Write-Host "EmailSmokeActionName              = $EmailSmokeActionName"
    Write-Host "MailAuthMode                      = $MailAuthMode"
    Write-Host "EmailSender                       = $EmailSender"
    Write-Host "ExecuteCreateEmailQueueSmokeTestRow = $ExecuteCreateEmailQueueSmokeTestRow"
    Write-Host "ExecuteSendSmokeTestEmail         = $ExecuteSendSmokeTestEmail"
    Write-Host "ExecuteCleanupEmailQueueSmokeTestRows = $ExecuteCleanupEmailQueueSmokeTestRows"
}

# ==============================================================================
# STEP 0 — Setup helpers + run folder
# ============================================================================== 

# macOS-only workbook root. Run these scripts from the historical-books repo root.
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Root = $ScriptRoot
& {
    Set-Location $Root

    function global:Sql-StringLiteral([string]$Value) {
        if ($null -eq $Value) { return "NULL" }
        return "N'" + $Value.Replace("'", "''") + "'"
    }

    function Start-UarConsoleTrace([string]$Path, [string]$Label) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
        Add-Content -Path $Path -Value ""
        Add-Content -Path $Path -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Label trace setup ====="
        Set-Variable -Name UarConsoleTracePath -Value $Path -Scope Global
    }

    function global:Invoke-TestSqlFile {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Label,
            [switch]$PassThru
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
        $output | Add-Content -Path $ConsoleTracePath
        $output | ForEach-Object { Write-Host $_ }
        if ($exitCode -ne 0) { throw "sqlcmd failed for $Label with exit code $exitCode" }
        if ($PassThru) { return $output }
    }

    if ([string]::IsNullOrWhiteSpace($TestTag) -or $TestTag -eq 'FILL-ME') { throw 'TestTag is required.' }
    if ([string]::IsNullOrWhiteSpace($TestReviewerAccount) -or $TestReviewerAccount -eq 'FILL-ME') { throw 'TestReviewerAccount is required.' }
    if ([string]::IsNullOrWhiteSpace($AppSearch) -or $AppSearch -eq 'FILL-ME') { throw 'AppSearch is required and must match one application.' }
    if ($TargetDb -eq 'synthetic-production' -and -not $AllowProductionSmokeTest) {
        throw 'TargetDb is synthetic-production. Set $AllowProductionSmokeTest = $false in the first block only if this production smoke test is intentional.'
    }

    $RunId = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'AUS Eastern Standard Time').ToString('yyyyMMdd-HHmmss') + "-testbook-$($TestReviewerAccount)".ToLower()
    $RunDir = Join-Path (Join-Path $Root 'runs') $RunId
    New-Item -ItemType Directory -Path $RunDir -Force | Out-Null

    $sqlcmd = 'tools/synthetic/sqlcmd'
    $Pwsh = 'pwsh'
    $ConsoleTracePath = Join-Path $RunDir 'console-trace-testbook.txt'
    Start-UarConsoleTrace -Path $ConsoleTracePath -Label 'TESTBOOK'

    foreach ($v in @('Root','RunId','RunDir','sqlcmd','Pwsh','ConsoleTracePath')) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "RunDir           = $RunDir"
    Write-Host "ConsoleTracePath = $ConsoleTracePath"
    Write-Host "sqlcmd           = $sqlcmd"
    Write-Host "pwsh             = $Pwsh"
    Write-Host ""
    Write-Host "Next: run STEP 1 preflight."
}

# ==============================================================================
# STEP 1 — Preflight: app/cycle/reviewer/test-row state
# ============================================================================== 
#
# Read-only. Confirms app match, active cycle, reviewer employee record, and any
# existing smoke-test rows with this TestTag.
#

& {
    $preflightSqlPath = Join-Path $RunDir '00_testbook_preflight.sql'
    $preflightSql = @"
SET NOCOUNT ON;

DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleName nvarchar(200) = $(Sql-StringLiteral $ReviewCycleName);
DECLARE @ReviewCycleIdInput varchar(36) = $(Sql-StringLiteral $ReviewCycleId);
DECLARE @ReviewerAccount varchar(100) = $(Sql-StringLiteral $TestReviewerAccount);
DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);

SELECT 'Target database' AS [Check], DB_NAME() AS [Value];

SELECT 'Application matches' AS [Check], COUNT_BIG(*) AS [Value]
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch;

SELECT TOP (20)
    Id AS ApplicationId,
    ApplicationName,
    BusinessOwnerAccount,
    BusinessOwnerName,
    DelegateAccount,
    DelegateName,
    ITOwnerAccount,
    ITOwnerName
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch
ORDER BY ApplicationName;

SELECT TOP (20)
    Id AS ReviewCycleId,
    Name,
    StartDate,
    EndDate,
    Active,
    CASE
      WHEN @ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput) THEN 'SELECTED_BY_ID'
      WHEN @ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName THEN 'SELECTED_BY_NAME'
      WHEN @ReviewCycleIdInput = '' AND @ReviewCycleName = '' AND Active = 1 THEN 'ACTIVE_CANDIDATE'
      ELSE ''
    END AS SelectionHint
FROM dbo.ReviewCycles
WHERE Active = 1
   OR (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
ORDER BY SelectionHint DESC, StartDate DESC, Name;

SELECT TOP (5)
    AccountName,
    FullName,
    DisplayName,
    EmailAddress,
    UserPrincipalName,
    AccountStatus,
    AccountType,
    ManagerAccountName
FROM dbo.Employees
WHERE AccountName = @ReviewerAccount;

SELECT 'Existing smoke-test ReviewItems for TestTag' AS [Check], COUNT_BIG(*) AS [Value]
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%';

SELECT TOP (50)
    Id, AccountName, FullName, RoleName, ReviewType, ReviewerAccount,
    Response, CompletedDate, CompletedBy, IssuedDate, DueDate
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
ORDER BY ModifiedDate DESC, RoleName;
"@
    $preflightSql | Set-Content -Path $preflightSqlPath -Encoding UTF8
    Invoke-TestSqlFile -Path $preflightSqlPath -Label 'STEP 1 preflight smoke-test context (read-only)'
}

# ==============================================================================
# STEP 2 — Create SyntheticReview smoke-test ReviewItems
# ============================================================================== 
#
# Dry-run by default: writes SQL but does not insert. Set
# $ExecuteCreateSmokeTestRows = $false in the first block, rerun that block, then
# rerun STEP 2 to insert dummy rows.
#
# The rows are tagged by:
#   DataSource = 'SYNTHETICREVIEW_SMOKETEST'
#   RoleName contains $TestTag
#

& {
    $createSqlPath = Join-Path $RunDir '01_create_myuas_smoketest_reviewitems.sql'
    $createSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleName nvarchar(200) = $(Sql-StringLiteral $ReviewCycleName);
DECLARE @ReviewCycleIdInput varchar(36) = $(Sql-StringLiteral $ReviewCycleId);
DECLARE @ReviewerAccount varchar(100) = $(Sql-StringLiteral $TestReviewerAccount);
DECLARE @SubjectPrefix varchar(100) = $(Sql-StringLiteral $TestSubjectAccount);
DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);
DECLARE @CreateBusinessOwnerItem bit = $(if ($CreateBusinessOwnerItem) { '1' } else { '0' });
DECLARE @CreateLineManagerItem bit = $(if ($CreateLineManagerItem) { '1' } else { '0' });

DECLARE @AppCount bigint;
DECLARE @AppId uniqueidentifier;
DECLARE @AppName varchar(200);
DECLARE @ReviewCycleId uniqueidentifier;
DECLARE @CycleCount bigint;
DECLARE @ReviewerName varchar(200);
DECLARE @ReviewerEmail varchar(200);
DECLARE @ExistingTaggedRows bigint;

SELECT @AppCount = COUNT_BIG(*)
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch;

IF @AppCount <> 1
BEGIN
    SELECT Id, ApplicationName, BusinessOwnerAccount, DelegateAccount
    FROM dbo.Applications
    WHERE ApplicationName LIKE @AppSearch
    ORDER BY ApplicationName;
    THROW 56000, 'AppSearch must match exactly one application before creating smoke-test rows.', 1;
END;

SELECT TOP (1)
    @AppId = Id,
    @AppName = ApplicationName
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch
ORDER BY ApplicationName;

SELECT @CycleCount = COUNT_BIG(*)
FROM dbo.ReviewCycles
WHERE (
    (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
    OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
    OR (@ReviewCycleIdInput = '' AND @ReviewCycleName = '' AND Active = 1)
);

IF @CycleCount <> 1
BEGIN
    SELECT Id AS ReviewCycleId, Name, StartDate, EndDate, Active
    FROM dbo.ReviewCycles
    WHERE Active = 1
       OR (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
       OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
    ORDER BY Active DESC, StartDate DESC, Name;
    THROW 56001, 'Review cycle selector must match exactly one cycle. Set ReviewCycleId or ReviewCycleName in TESTBOOK first block.', 1;
END;

SELECT TOP (1) @ReviewCycleId = Id
FROM dbo.ReviewCycles
WHERE (
    (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
    OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
    OR (@ReviewCycleIdInput = '' AND @ReviewCycleName = '' AND Active = 1)
);

SELECT TOP (1)
    @ReviewerName = COALESCE(NULLIF(FullName, ''), NULLIF(DisplayName, ''), @ReviewerAccount),
    @ReviewerEmail = COALESCE(NULLIF(EmailAddress, ''), NULLIF(UserPrincipalName, ''))
FROM dbo.Employees
WHERE AccountName = @ReviewerAccount;

IF @ReviewerName IS NULL
    THROW 56002, 'TestReviewerAccount not found in dbo.Employees.', 1;

IF @ReviewerEmail IS NULL
    PRINT 'WARNING: Test reviewer has no EmailAddress/UserPrincipalName in Employees. Web login may still work, but email smoke-test would not.';

SELECT @ExistingTaggedRows = COUNT_BIG(*)
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%';

IF @ExistingTaggedRows > 0
BEGIN
    SELECT TOP (50)
        Id, AccountName, FullName, RoleName, ReviewType, ReviewerAccount,
        Response, CompletedDate, CompletedBy, IssuedDate, DueDate
    FROM dbo.ReviewItems
    WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
      AND RoleName LIKE '%' + @TestTag + '%'
    ORDER BY ModifiedDate DESC, RoleName;

    THROW 56003, 'Smoke-test rows already exist for this TestTag. Run cleanup first or choose a different TestTag.', 1;
END;

IF @CreateBusinessOwnerItem = 1
BEGIN
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
    VALUES (
        NEWID(), @SubjectPrefix + '-bo', 'SYNTHETICREVIEW Smoke Test - Business Owner', NULL, NULL, NULL, 'Local Account',
        NULL, NULL, NULL, @SubjectPrefix + '-bo', NULL,
        NULL, @TestTag + ' - BusinessOwner', 'SYNTHETICREVIEW smoke-test row. Safe to delete via TESTBOOK cleanup. Tag=' + @TestTag,
        'Privileged', @AppName, 'SYNTHETICREVIEW_SMOKETEST', CONVERT(bit, 1),
        CONVERT(bit, 1), 'BusinessOwner', NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL,
        NULL, CONVERT(date, GETDATE()), GETDATE(), NULL,
        @AppId, @ReviewCycleId, NULL, @ReviewerAccount,
        @ReviewerAccount, @ReviewerName, NULL
    );
END;

IF @CreateLineManagerItem = 1
BEGIN
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
    VALUES (
        NEWID(), @SubjectPrefix + '-lm', 'SYNTHETICREVIEW Smoke Test - Line Manager', NULL, NULL, NULL, 'Human Account',
        @ReviewerAccount, @ReviewerName, NULL, NULL, NULL,
        NULL, @TestTag + ' - LineManager', 'SYNTHETICREVIEW smoke-test row. Safe to delete via TESTBOOK cleanup. Tag=' + @TestTag,
        'Standard', @AppName, 'SYNTHETICREVIEW_SMOKETEST', CONVERT(bit, 1),
        CONVERT(bit, 1), 'LineManager', NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL,
        NULL, CONVERT(date, GETDATE()), GETDATE(), NULL,
        @AppId, @ReviewCycleId, NULL, @ReviewerAccount,
        @ReviewerAccount, @ReviewerName, NULL
    );
END;

SELECT 'Smoke-test ReviewItems inserted' AS Metric, @@ROWCOUNT AS LastInsertRowCount
UNION ALL SELECT 'Smoke-test ReviewItems now present', COUNT_BIG(*)
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%';

SELECT Id, AccountName, FullName, RoleName, ReviewType, ReviewerAccount, ReviewerName,
       Response, CompletedDate, IssuedDate, DueDate, ApplicationId, ReviewCycleId
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
ORDER BY ReviewType, RoleName;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $createSql | Set-Content -Path $createSqlPath -Encoding UTF8

    if ($ExecuteCreateSmokeTestRows) {
        Invoke-TestSqlFile -Path $createSqlPath -Label 'STEP 2 create SyntheticReview smoke-test ReviewItems (MUTATING)'
        Write-Host ""
        Write-Host "Next: sign in to SyntheticReview as $TestReviewerAccount and check the Business Owner / Line Manager tabs."
        if ($SyntheticReviewUrl) { Write-Host "SyntheticReview URL: $SyntheticReviewUrl" }
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote smoke-test create SQL but did not execute:"
        Write-Host $createSqlPath
        Write-Host "Set `$ExecuteCreateSmokeTestRows = `$true in the first block, rerun that block, then rerun STEP 2 to insert dummy rows."
    }
}

# ==============================================================================
# STEP 3 — Email notification pre-flight smoke test (read-only)
# ============================================================================== 
#
# Validates the operational/data/artifact prerequisites for testing the mail
# workflow before MAILBOOK is allowed to send anything:
#   - tagged pending ReviewItems exist for this tester;
#   - the tester has EmailAddress/UserPrincipalName in Employees;
#   - tagged EmailQueue rows are visible and isolated;
#   - due active rows outside this test tag are surfaced as a sender-scope risk.
#

& {
    $emailPreflightSqlPath = Join-Path $RunDir '04_email_smoketest_preflight.sql'
    $emailPreflightSql = @"
SET NOCOUNT ON;

DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleName nvarchar(200) = $(Sql-StringLiteral $ReviewCycleName);
DECLARE @ReviewCycleIdInput varchar(36) = $(Sql-StringLiteral $ReviewCycleId);
DECLARE @ReviewerAccount varchar(100) = $(Sql-StringLiteral $TestReviewerAccount);
DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);
DECLARE @EmailActionName varchar(100) = $(Sql-StringLiteral $EmailSmokeActionName);
DECLARE @EmailQueueComment varchar(100) = LEFT(@TestTag + ' EMAIL_SMOKETEST ' + @EmailActionName, 100);

DECLARE @AppId uniqueidentifier;
DECLARE @ReviewCycleId uniqueidentifier;

SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch
ORDER BY ApplicationName;

SELECT TOP (1) @ReviewCycleId = Id
FROM dbo.ReviewCycles
WHERE (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName = '' AND Active = 1)
ORDER BY Active DESC, StartDate DESC, Name;

SELECT 'Target database' AS [Check], DB_NAME() AS [Value]
UNION ALL SELECT 'ApplicationId', CONVERT(varchar(36), @AppId)
UNION ALL SELECT 'ReviewCycleId', CONVERT(varchar(36), @ReviewCycleId)
UNION ALL SELECT 'EmailActionName', @EmailActionName
UNION ALL SELECT 'EmailQueueComment', @EmailQueueComment;

SELECT 'Tagged pending ReviewItems for tester' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
  AND ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ReviewerAccount = @ReviewerAccount
  AND Response IS NULL
UNION ALL SELECT 'Tester Employees rows', COUNT_BIG(*) FROM dbo.Employees WHERE AccountName = @ReviewerAccount
UNION ALL SELECT 'Tester Employees rows with email/UPN', COUNT_BIG(*) FROM dbo.Employees WHERE AccountName = @ReviewerAccount AND COALESCE(NULLIF(EmailAddress, ''), NULLIF(UserPrincipalName, '')) IS NOT NULL
UNION ALL SELECT 'Tagged EmailQueue rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment
UNION ALL SELECT 'Tagged due active EmailQueue rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
UNION ALL SELECT 'Other due active rows for this action', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @EmailActionName AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE()) AND ISNULL(Comment, '') <> @EmailQueueComment;

SELECT TOP (20)
    ri.Id, ri.AccountName, ri.FullName, ri.RoleName, ri.ReviewType, ri.ReviewerAccount,
    ri.Response, ri.CompletedDate, ri.IssuedDate, ri.DueDate
FROM dbo.ReviewItems ri
WHERE ri.DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND ri.RoleName LIKE '%' + @TestTag + '%'
ORDER BY ri.ReviewType, ri.RoleName;

SELECT TOP (20)
    e.AccountName, e.DisplayName, e.EmailAddress, e.UserPrincipalName, e.AccountStatus, e.AccountType
FROM dbo.Employees e
WHERE e.AccountName = @ReviewerAccount;

SELECT TOP (50)
    q.Id, q.FromAccount, q.ToAccount, q.ActionName, q.Comment, q.Active, q.CreatedOn, q.ExecuteOn, q.CompletedOn, q.ErrorMessage
FROM dbo.EmailQueue q
WHERE q.Comment = @EmailQueueComment
   OR (q.ActionName = @EmailActionName AND q.Active = 1 AND CONVERT(date, ISNULL(q.ExecuteOn, q.CreatedOn)) <= CONVERT(date, GETDATE()))
ORDER BY CASE WHEN q.Comment = @EmailQueueComment THEN 0 ELSE 1 END, q.CreatedOn DESC;
"@
    $emailPreflightSql | Set-Content -Path $emailPreflightSqlPath -Encoding UTF8
    Invoke-TestSqlFile -Path $emailPreflightSqlPath -Label 'STEP 3 email notification pre-flight smoke test (read-only)'
}

# ==============================================================================
# STEP 4 — Create tagged EmailQueue smoke-test row
# ============================================================================== 
#
# Dry-run by default. This queues exactly one tagged Reviewer notification for the
# tester, based on the tagged TESTBOOK ReviewItems. It does not send email; use
# MAILBOOK for sender preflight/send verification after reviewing the queue row.
#

& {
    $emailQueueCreateSqlPath = Join-Path $RunDir '05_create_emailqueue_smoketest.sql'
    $emailQueueCreateSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleName nvarchar(200) = $(Sql-StringLiteral $ReviewCycleName);
DECLARE @ReviewCycleIdInput varchar(36) = $(Sql-StringLiteral $ReviewCycleId);
DECLARE @ReviewerAccount varchar(100) = $(Sql-StringLiteral $TestReviewerAccount);
DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);
DECLARE @EmailActionName varchar(100) = $(Sql-StringLiteral $EmailSmokeActionName);
DECLARE @EmailQueueComment varchar(100) = LEFT(@TestTag + ' EMAIL_SMOKETEST ' + @EmailActionName, 100);

DECLARE @AppId uniqueidentifier;
DECLARE @ReviewCycleId uniqueidentifier;
DECLARE @PendingTaggedRows bigint;
DECLARE @ReviewerEmail varchar(200);

IF @EmailActionName <> 'Reviewer'
    THROW 56100, 'TESTBOOK EmailQueue smoke test is intentionally limited to Reviewer action.', 1;

SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch
ORDER BY ApplicationName;

SELECT TOP (1) @ReviewCycleId = Id
FROM dbo.ReviewCycles
WHERE (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName = '' AND Active = 1)
ORDER BY Active DESC, StartDate DESC, Name;

SELECT @ReviewerEmail = COALESCE(NULLIF(EmailAddress, ''), NULLIF(UserPrincipalName, ''))
FROM dbo.Employees
WHERE AccountName = @ReviewerAccount;

IF @ReviewerEmail IS NULL
    THROW 56101, 'Test reviewer has no EmailAddress/UserPrincipalName; do not queue email smoke test.', 1;

SELECT @PendingTaggedRows = COUNT_BIG(*)
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
  AND ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND ReviewerAccount = @ReviewerAccount
  AND Response IS NULL;

IF @PendingTaggedRows = 0
    THROW 56102, 'No tagged pending ReviewItems exist for this tester/app/cycle; create or reset smoke-test ReviewItems first.', 1;

IF EXISTS (SELECT 1 FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND Active = 1)
    THROW 56103, 'An active tagged EmailQueue smoke-test row already exists. Cleanup first or use the existing row.', 1;

INSERT INTO dbo.EmailQueue (Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, CompletedOn, ExecuteOn, ErrorMessage)
VALUES (NEWID(), NULL, @ReviewerAccount, @EmailActionName, @EmailQueueComment, CONVERT(bit, 1), GETDATE(), NULL, GETDATE(), NULL);

SELECT 'Tagged EmailQueue smoke-test rows inserted' AS Metric, @@ROWCOUNT AS Value
UNION ALL SELECT 'Tagged pending ReviewItems backing the queue row', @PendingTaggedRows;

SELECT Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
ORDER BY CreatedOn DESC;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $emailQueueCreateSql | Set-Content -Path $emailQueueCreateSqlPath -Encoding UTF8

    if ($ExecuteCreateEmailQueueSmokeTestRow) {
        Invoke-TestSqlFile -Path $emailQueueCreateSqlPath -Label 'STEP 4 create tagged EmailQueue smoke-test row (MUTATING)'
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote EmailQueue smoke-test create SQL but did not execute:"
        Write-Host $emailQueueCreateSqlPath
        Write-Host "Set `$ExecuteCreateEmailQueueSmokeTestRow = `$true in the first block, rerun that block, then rerun STEP 4 to queue the test notification."
    }
}

# ==============================================================================
# STEP 5 — Send tagged smoke-test email directly, then test SyntheticReview
# ============================================================================== 
#
# Runs the copied UAR sender directly after a hard gate proves this tagged
# smoke-test row is ready. The sender is scoped by QueueComment in UAR.psd1, so
# other due active EmailQueue rows for the same ActionName are surfaced but do
# not block this tagged smoke test.
#

& {
    $emailSendGateSqlPath = Join-Path $RunDir '07_send_email_smoketest_gate.sql'
    $emailSendPostcheckSqlPath = Join-Path $RunDir '08_send_email_smoketest_postcheck.sql'
    $emailQueueComment = "$TestTag EMAIL_SMOKETEST $EmailSmokeActionName"

    $emailSendGateSql = @"
SET NOCOUNT ON;

DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleName nvarchar(200) = $(Sql-StringLiteral $ReviewCycleName);
DECLARE @ReviewCycleIdInput varchar(36) = $(Sql-StringLiteral $ReviewCycleId);
DECLARE @ReviewerAccount varchar(100) = $(Sql-StringLiteral $TestReviewerAccount);
DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);
DECLARE @EmailActionName varchar(100) = $(Sql-StringLiteral $EmailSmokeActionName);
DECLARE @EmailQueueComment varchar(100) = LEFT(@TestTag + ' EMAIL_SMOKETEST ' + @EmailActionName, 100);

DECLARE @AppId uniqueidentifier;
DECLARE @ResolvedReviewCycleId uniqueidentifier;
DECLARE @TaggedPendingRows bigint;
DECLARE @TaggedDueRows bigint;
DECLARE @OtherDueRows bigint;
DECLARE @RecipientEmail varchar(300);

SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE ApplicationName LIKE @AppSearch
ORDER BY ApplicationName;

SELECT TOP (1) @ResolvedReviewCycleId = Id
FROM dbo.ReviewCycles
WHERE (@ReviewCycleIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @ReviewCycleIdInput))
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName <> '' AND Name = @ReviewCycleName)
   OR (@ReviewCycleIdInput = '' AND @ReviewCycleName = '' AND Active = 1)
ORDER BY Active DESC, StartDate DESC, Name;

SELECT @TaggedPendingRows = COUNT_BIG(*)
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
  AND ApplicationId = @AppId
  AND ReviewCycleId = @ResolvedReviewCycleId
  AND ReviewerAccount = @ReviewerAccount
  AND Response IS NULL;

SELECT @TaggedDueRows = COUNT_BIG(*)
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
  AND ActionName = @EmailActionName
  AND ToAccount = @ReviewerAccount
  AND Active = 1
  AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE());

SELECT @OtherDueRows = COUNT_BIG(*)
FROM dbo.EmailQueue
WHERE ActionName = @EmailActionName
  AND Active = 1
  AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
  AND ISNULL(Comment, '') <> @EmailQueueComment;

SELECT @RecipientEmail = COALESCE(NULLIF(EmailAddress, ''), NULLIF(UserPrincipalName, ''))
FROM dbo.Employees
WHERE AccountName = @ReviewerAccount;

SELECT 'ResolvedReviewCycleId' AS Metric, CONVERT(varchar(36), @ResolvedReviewCycleId) AS Value
UNION ALL SELECT 'Tagged pending ReviewItems', CONVERT(varchar(36), @TaggedPendingRows)
UNION ALL SELECT 'Tagged due active EmailQueue rows', CONVERT(varchar(36), @TaggedDueRows)
UNION ALL SELECT 'Other due active rows for same ActionName', CONVERT(varchar(36), @OtherDueRows)
UNION ALL SELECT 'Recipient email/UPN', COALESCE(@RecipientEmail, '');

SELECT Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
   OR (ActionName = @EmailActionName AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE()))
ORDER BY CASE WHEN Comment = @EmailQueueComment THEN 0 ELSE 1 END, CreatedOn DESC;

IF @EmailActionName <> 'Reviewer'
    THROW 56200, 'TESTBOOK direct send is intentionally limited to Reviewer action. Use MAILBOOK for other actions.', 1;
IF @AppId IS NULL
    THROW 56201, 'Could not resolve AppSearch to an application.', 1;
IF @ResolvedReviewCycleId IS NULL
    THROW 56202, 'Could not resolve ReviewCycleId/ReviewCycleName.', 1;
IF @TaggedPendingRows = 0
    THROW 56203, 'No tagged pending ReviewItems exist for this tester/app/cycle; create or reset smoke-test ReviewItems first.', 1;
IF @RecipientEmail IS NULL
    THROW 56204, 'Test reviewer has no EmailAddress/UserPrincipalName; direct email send blocked.', 1;
IF @TaggedDueRows <> 1
    THROW 56205, 'Expected exactly one tagged due active EmailQueue smoke-test row before send.', 1;
IF @OtherDueRows <> 0
    PRINT 'WARNING: Other due active EmailQueue rows exist for this ActionName. Current sender is QueueComment-scoped, so this tagged smoke test can continue.';

PRINT 'ResolvedReviewCycleId=' + CONVERT(varchar(36), @ResolvedReviewCycleId);
"@
    $emailSendGateSql | Set-Content -Path $emailSendGateSqlPath -Encoding UTF8
    $gateOutput = Invoke-TestSqlFile -Path $emailSendGateSqlPath -Label 'STEP 5 pre-send gate for direct smoke-test email (read-only)' -PassThru
    $gateText = ($gateOutput -join "`n")
    if ($gateText -notmatch 'ResolvedReviewCycleId=(?<id>[0-9a-fA-F-]{36})') {
        throw 'Could not parse resolved ReviewCycleId from STEP 5 gate output.'
    }
    $ResolvedSmokeReviewCycleId = $Matches['id']
    Write-Host "Pre-send gate passed. ResolvedSmokeReviewCycleId = $ResolvedSmokeReviewCycleId"

    $MailDir = Join-Path (Join-Path $Root 'ops') 'mail'
    $UarPsd1TemplatePath = Join-Path $MailDir 'UAR.psd1.template'
    $UarPsd1Path = Join-Path $MailDir 'UAR.psd1'
    $SenderScript = Join-Path $MailDir 'ActionQuery_Email_ToOnly.ps1'
    $requiredMailFiles = @(
        (Join-Path $MailDir 'UAR.psm1'),
        $UarPsd1TemplatePath,
        $SenderScript,
        (Join-Path (Join-Path $MailDir 'templates') 'template.Reviewer.html')
    )
    foreach ($file in $requiredMailFiles) {
        if (-not (Test-Path $file -PathType Leaf)) { throw "Required mail sender file missing: $file" }
    }

    if (@('AppOnly','DelegatedShared') -notcontains $MailAuthMode) { throw "Invalid MailAuthMode '$MailAuthMode'. Use AppOnly or DelegatedShared." }
    function ConvertTo-Psd1SingleQuotedValue([string]$Value) { return $Value.Replace("'", "''") }
    $configText = Get-Content -Path $UarPsd1TemplatePath -Raw
    $configText = $configText.Replace('{{DBServer}}', (ConvertTo-Psd1SingleQuotedValue $Server)).Replace('{{Database}}', (ConvertTo-Psd1SingleQuotedValue $TargetDb)).Replace('{{ReviewCycleId}}', (ConvertTo-Psd1SingleQuotedValue $ResolvedSmokeReviewCycleId)).Replace('{{QueueComment}}', (ConvertTo-Psd1SingleQuotedValue $emailQueueComment)).Replace('{{EmailSender}}', (ConvertTo-Psd1SingleQuotedValue $EmailSender)).Replace('{{MailAuthMode}}', (ConvertTo-Psd1SingleQuotedValue $MailAuthMode))
    $configText | Set-Content -Path $UarPsd1Path -Encoding UTF8
    Write-Host "Generated runtime mail config: $UarPsd1Path"

    foreach ($moduleName in @('EPS','Microsoft.Graph.Authentication','Microsoft.Graph.Users.Actions')) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            if ($ExecuteSendSmokeTestEmail) { throw "Required PowerShell module missing for direct send: $moduleName. Install it before sending." }
            Write-Warning "PowerShell module missing for direct send: $moduleName"
        }
    }

    $credentialPaths = @((Join-Path $MailDir 'synthetic-db.cred'))
    if ($MailAuthMode -ieq 'AppOnly') { $credentialPaths += (Join-Path $MailDir 'synthetic-app.cred') }
    foreach ($credentialPath in $credentialPaths) {
        if (-not (Test-Path $credentialPath -PathType Leaf)) {
            if ($ExecuteSendSmokeTestEmail) { throw "Required credential file missing for direct send: $credentialPath" }
            Write-Warning "Credential file missing for direct send: $credentialPath"
        } else {
            try {
                Get-Content $credentialPath | ConvertTo-SecureString -ErrorAction Stop | Out-Null
            } catch {
                if ($ExecuteSendSmokeTestEmail) { throw "Credential file exists but cannot be decrypted by this Windows user/session: $credentialPath. Recreate it locally with ConvertFrom-SecureString." }
                Write-Warning "Credential file exists but cannot be decrypted by this Windows user/session: $credentialPath"
            }
        }
    }
    if ($MailAuthMode -ieq 'DelegatedShared') {
        Write-Host "MailAuthMode DelegatedShared: Graph will prompt/sign in interactively with Mail.Send.Shared and use Send As on $EmailSender."
    }

    Write-Host ""
    Write-Host "Direct sender command: `"$Pwsh`" -NoProfile -File `"$SenderScript`" -ActionName $EmailSmokeActionName"
    if (-not $ExecuteSendSmokeTestEmail) {
        Write-Host "Dry-run: direct smoke-test email was not sent. Set `$ExecuteSendSmokeTestEmail = `$true, rerun first block, then rerun STEP 5."
        return
    }
    if ($TargetDb -eq 'synthetic-production' -and -not $AllowProductionSmokeTest) {
        throw 'Production direct email send blocked. Set $AllowProductionSmokeTest = $false only for an intentional production smoke test.'
    }

    Write-Host "Executing direct smoke-test sender now..."
    Add-Content -Path $ConsoleTracePath -Value ""
    Add-Content -Path $ConsoleTracePath -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) STEP 5 direct sender $EmailSmokeActionName ====="
    Push-Location $MailDir
    try {
        $senderOutput = & $Pwsh -NoProfile -File $SenderScript -ActionName $EmailSmokeActionName 2>&1
        $senderOutput | Tee-Object -FilePath $ConsoleTracePath -Append
        if ($LASTEXITCODE -ne 0) { throw "Direct smoke-test sender exited with code $LASTEXITCODE" }
        $senderText = ($senderOutput -join "`n")
        if ($senderText -notmatch '1 email\(s\) sent successfully; 0 failure\(s\) observed') {
            throw 'Direct smoke-test sender did not report exactly 1 successful email and 0 failures. Review console trace before continuing.'
        }
    }
    finally {
        Pop-Location
    }

    $emailSendPostcheckSql = @"
SET NOCOUNT ON;

DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);
DECLARE @EmailActionName varchar(100) = $(Sql-StringLiteral $EmailSmokeActionName);
DECLARE @EmailQueueComment varchar(100) = LEFT(@TestTag + ' EMAIL_SMOKETEST ' + @EmailActionName, 100);

SELECT 'Tagged EmailQueue rows after direct send' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
UNION ALL SELECT 'Tagged active rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND Active = 1
UNION ALL SELECT 'Tagged completed rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND CompletedOn IS NOT NULL
UNION ALL SELECT 'Tagged error rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND ErrorMessage IS NOT NULL;

SELECT Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
ORDER BY CreatedOn DESC;

IF EXISTS (SELECT 1 FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND Active = 1)
    THROW 56220, 'Tagged EmailQueue row is still active after sender run; email did not complete successfully.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND Active = 0 AND CompletedOn IS NOT NULL)
    THROW 56221, 'Tagged EmailQueue row was not marked completed after sender run.', 1;
"@
    $emailSendPostcheckSql | Set-Content -Path $emailSendPostcheckSqlPath -Encoding UTF8
    Invoke-TestSqlFile -Path $emailSendPostcheckSqlPath -Label 'STEP 5 post-send EmailQueue verification (read-only)' | Out-Null

    Write-Host ""
    Write-Host "Test email send completed successfully. Sign in to SyntheticReview as $TestReviewerAccount and test the BO/LM tabs."
    if ($SyntheticReviewUrl) { Write-Host "SyntheticReview URL: $SyntheticReviewUrl" }
    Write-Host "Then run STEP 6 to verify ReviewItems changes before cleanup."
}

# ==============================================================================
# STEP 6 — Verify SyntheticReview smoke-test rows after email/web test
# ============================================================================== 
#
# Read-only. Run before and after testing in SyntheticReview to see whether Response,
# CompletedDate, CompletedBy, IssuedDate, or DueDate changed.
#

& {
    $verifySqlPath = Join-Path $RunDir '02_verify_myuas_smoketest_reviewitems.sql'
    $verifySql = @"
SET NOCOUNT ON;

DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);

SELECT 'Smoke-test ReviewItems for TestTag' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
UNION ALL SELECT 'Pending rows', COUNT_BIG(*) FROM dbo.ReviewItems WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST' AND RoleName LIKE '%' + @TestTag + '%' AND Response IS NULL
UNION ALL SELECT 'Responded rows', COUNT_BIG(*) FROM dbo.ReviewItems WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST' AND RoleName LIKE '%' + @TestTag + '%' AND Response IS NOT NULL
UNION ALL SELECT 'Issued/due rows', COUNT_BIG(*) FROM dbo.ReviewItems WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST' AND RoleName LIKE '%' + @TestTag + '%' AND (IssuedDate IS NOT NULL OR DueDate IS NOT NULL);

SELECT Id, AccountName, FullName, RoleName, ReviewType, ReviewerAccount, ReviewerName,
       Response, Comment, CompletedDate, CompletedBy, IssuedDate, DueDate,
       ApplicationId, ReviewCycleId
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
ORDER BY ReviewType, RoleName;
"@
    $verifySql | Set-Content -Path $verifySqlPath -Encoding UTF8
    Invoke-TestSqlFile -Path $verifySqlPath -Label 'STEP 6 verify SyntheticReview smoke-test rows (read-only)'
}

# ==============================================================================
# STEP 7 — Cleanup tagged EmailQueue smoke-test rows
# ============================================================================== 

& {
    $emailQueueCleanupSqlPath = Join-Path $RunDir '06_cleanup_emailqueue_smoketest.sql'
    $emailQueueCleanupSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);
DECLARE @EmailActionName varchar(100) = $(Sql-StringLiteral $EmailSmokeActionName);
DECLARE @EmailQueueComment varchar(100) = LEFT(@TestTag + ' EMAIL_SMOKETEST ' + @EmailActionName, 100);

SELECT 'Tagged EmailQueue rows before cleanup' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
UNION ALL SELECT 'Tagged active rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND Active = 1
UNION ALL SELECT 'Tagged completed rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND CompletedOn IS NOT NULL
UNION ALL SELECT 'Tagged error rows', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Comment = @EmailQueueComment AND ErrorMessage IS NOT NULL;

SELECT Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment
ORDER BY CreatedOn DESC;

DELETE FROM dbo.EmailQueue
WHERE Comment = @EmailQueueComment;

SELECT 'Tagged EmailQueue rows deleted' AS Metric, @@ROWCOUNT AS Value;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $emailQueueCleanupSql | Set-Content -Path $emailQueueCleanupSqlPath -Encoding UTF8

    if ($ExecuteCleanupEmailQueueSmokeTestRows) {
        Invoke-TestSqlFile -Path $emailQueueCleanupSqlPath -Label 'STEP 7 cleanup tagged EmailQueue smoke-test rows (MUTATING)'
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote EmailQueue smoke-test cleanup SQL but did not execute:"
        Write-Host $emailQueueCleanupSqlPath
        Write-Host "Set `$ExecuteCleanupEmailQueueSmokeTestRows = `$true in the first block, rerun that block, then rerun STEP 7 after mail testing."
    }

}

# ==============================================================================
# STEP 8 — Cleanup SyntheticReview smoke-test rows
# ============================================================================== 
#
# Dry-run by default: writes SQL but does not delete. Set
# $ExecuteCleanupSmokeTestRows = $false in the first block, rerun that block, then
# rerun STEP 8 to remove tagged dummy rows.
#

& {
    $cleanupSqlPath = Join-Path $RunDir '03_cleanup_myuas_smoketest_reviewitems.sql'
    $cleanupSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @TestTag varchar(100) = $(Sql-StringLiteral $TestTag);

SELECT 'Smoke-test ReviewItems before cleanup' AS Metric, COUNT_BIG(*) AS Value
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
UNION ALL SELECT 'Responded rows before cleanup', COUNT_BIG(*) FROM dbo.ReviewItems WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST' AND RoleName LIKE '%' + @TestTag + '%' AND Response IS NOT NULL
UNION ALL SELECT 'Issued/due rows before cleanup', COUNT_BIG(*) FROM dbo.ReviewItems WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST' AND RoleName LIKE '%' + @TestTag + '%' AND (IssuedDate IS NOT NULL OR DueDate IS NOT NULL);

SELECT Id, AccountName, FullName, RoleName, ReviewType, ReviewerAccount,
       Response, CompletedDate, CompletedBy, IssuedDate, DueDate
FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%'
ORDER BY ReviewType, RoleName;

DELETE FROM dbo.ReviewItems
WHERE DataSource = 'SYNTHETICREVIEW_SMOKETEST'
  AND RoleName LIKE '%' + @TestTag + '%';

SELECT 'Smoke-test ReviewItems deleted' AS Metric, @@ROWCOUNT AS Value;

COMMIT TRAN;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRAN;
  THROW;
END CATCH;
"@
    $cleanupSql | Set-Content -Path $cleanupSqlPath -Encoding UTF8

    if ($ExecuteCleanupSmokeTestRows) {
        Invoke-TestSqlFile -Path $cleanupSqlPath -Label 'STEP 8 cleanup SyntheticReview smoke-test ReviewItems (MUTATING)'
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote smoke-test cleanup SQL but did not execute:"
        Write-Host $cleanupSqlPath
        Write-Host "Set `$ExecuteCleanupSmokeTestRows = `$true in the first block, rerun that block, then rerun STEP 8 to delete tagged dummy rows."
    }
}

# ==============================================================================
# STEP 9 — Final summary
# ============================================================================== 

& {
    Write-Host ""
    Write-Host "TESTBOOK completed."
    Write-Host "RunDir: $RunDir"
    Write-Host "Console trace: $ConsoleTracePath"
    Write-Host "Generated SQL files:"
    Get-ChildItem -Path $RunDir -Filter '*smoketest*.sql' -File | Sort-Object Name | ForEach-Object {
        Write-Host "  $($_.FullName)"
    }
    Write-Host ""
    Write-Host "Real timeline: create tagged ReviewItems, run email preflight, create tagged EmailQueue, send directly from TESTBOOK, test SyntheticReview, verify rows, cleanup EmailQueue, then cleanup ReviewItems."
}
