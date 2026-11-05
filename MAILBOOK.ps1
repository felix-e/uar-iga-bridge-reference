# SANITISED HISTORICAL DERIVATIVE — reference only; not an operational runbook.
# Synthetic examples; dependencies and credentials intentionally not included.
# Do not run selections or remove this guard. See docs/books.md and docs/books-provenance.json.
throw "REFERENCE ONLY: execution is unconditionally disabled."

# ==============================================================================
# UAR Email Notification Workbook
# ==============================================================================
#
# Previews, queues, sends, and verifies SyntheticReview notification emails through the
# original EmailQueue + PowerShell sender workflow, but with safer workbook gates.
#
# Normal production sequence:
#   1. Run WORKBOOK.ps1 and STAGEBOOK.ps1 for the application/cycle.
#   2. Point $RunDir at that run folder.
#   3. Run each MAILBOOK step in order, reviewing generated SQL and outputs.
#   4. Keep execute switches false until the operator intentionally opts in.
#
# Source behaviour adapted from historical-reference\ps and historical-reference\email\2023.template.
# Runtime config is generated as ops\mail\UAR.psd1 from ops\mail\UAR.psd1.template.
# Credential files remain local only:
#   ops\mail\synthetic-db.cred
#   ops\mail\synthetic-app.cred
#
# ==============================================================================

# ==============================================================================
# REQUIRED INPUTS + EXECUTE SWITCHES — edit these values first
# ==============================================================================
# Leave execute switches false for DRY-RUN. For production EmailQueue insert/send,
# set AllowProductionEmailSideEffects deliberately and only after preflight gates pass.

& {
    $AppCode = "SyntheticAppC"       # display/search name used when AppId is not derived from RunDir
    $AppSearch = "%SyntheticAppC%"   # must match one dbo.Applications row when AppId is blank
    $RunDir  = ""                    # existing run folder; relative paths resolve under this repo

    $Server = ""                    # derived from run artefacts when blank
    $TargetDb = ""                  # derived from run artefacts when blank
    $AppId = ""                     # derived from run artefacts when blank
    $ReviewCycleId = ""             # derived from run artefacts when blank

    $ActionName = "Reviewer"        # Reviewer/Reissue/Reminder/FinalReminder/NoLM_delegated/NoLM_BO/Delegate/MoR
    $ExecuteOn = (Get-Date).Date     # queue due date; sender processes active rows due today or earlier
    $QueueComment = ""              # default generated as UAR2026 <AppCode> <RunDirLeaf> <ActionName>
    $MailAuthMode = "AppOnly"        # AppOnly for production parity; DelegatedShared for interactive shared-mailbox testing
    $EmailSender = "review-notices@example.invalid"

    $ExecuteInsertEmailQueue = $false
    $ExecuteResetFailedQueueRows = $false
    $ExecuteSendEmail = $false

    $AllowProductionEmailSideEffects = $false
    $AllowUnscopedActiveDueQueueRows = $false # sender processes all due active rows for ActionName unless this gate is clean

    foreach ($v in @(
        'AppCode','AppSearch','RunDir','Server','TargetDb','AppId','ReviewCycleId','ActionName','ExecuteOn','QueueComment','MailAuthMode','EmailSender',
        'ExecuteInsertEmailQueue','ExecuteResetFailedQueueRows','ExecuteSendEmail','AllowProductionEmailSideEffects',
        'AllowUnscopedActiveDueQueueRows'
    )) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "AppCode                         = $AppCode"
    Write-Host "AppSearch                       = $AppSearch"
    Write-Host "RunDir                          = $RunDir"
    Write-Host "Server                          = $Server"
    Write-Host "TargetDb                        = $TargetDb"
    Write-Host "AppId                           = $AppId"
    Write-Host "ReviewCycleId                   = $ReviewCycleId"
    Write-Host "ActionName                      = $ActionName"
    Write-Host "ExecuteOn                       = $ExecuteOn"
    Write-Host "MailAuthMode                    = $MailAuthMode"
    Write-Host "EmailSender                     = $EmailSender"
    Write-Host "ExecuteInsertEmailQueue         = $ExecuteInsertEmailQueue"
    Write-Host "ExecuteResetFailedQueueRows     = $ExecuteResetFailedQueueRows"
    Write-Host "ExecuteSendEmail                = $ExecuteSendEmail"
    Write-Host "AllowProductionEmailSideEffects = $AllowProductionEmailSideEffects"
    Write-Host "AllowUnscopedActiveDueQueueRows = $AllowUnscopedActiveDueQueueRows"
}

# ==============================================================================
# STEP 0 — Setup + derive context + generate runtime mail config
# ==============================================================================

# macOS-only workbook root. Run these scripts from the historical-books repo root.
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Root = $ScriptRoot
& {
    Set-Location $Root

    function Is-FillMe([string]$Value) {
        return [string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'FILL-ME'
    }

    function Resolve-BookPath([string]$Path, [string]$BaseRoot) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
        if ([System.IO.Path]::IsPathRooted($expanded)) { return [System.IO.Path]::GetFullPath($expanded) }
        return [System.IO.Path]::GetFullPath((Join-Path $BaseRoot $expanded))
    }

    function global:Sql-StringLiteral([string]$Value) {
        if ($null -eq $Value) { return "NULL" }
        return "N'" + $Value.Replace("'", "''") + "'"
    }

    function Get-MailPackMetadataValue([string]$Path, [string]$Name) {
        if (-not (Test-Path $Path -PathType Leaf)) { return '' }
        $text = Get-Content -Path $Path -Raw
        $pattern = '""Name"":""' + [regex]::Escape($Name) + '"",""Value"":""(?<value>[^""]*)""'
        $match = [regex]::Match($text, $pattern)
        if ($match.Success) { return $match.Groups['value'].Value }
        return ''
    }

    function Resolve-MailRunDir([string]$Value, [string]$BaseRoot) {
        if (Is-FillMe $Value) {
            $stamp = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'AUS Eastern Standard Time').ToString('yyyyMMdd-HHmmss')
            return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $BaseRoot 'runs') "$stamp-mailbook-$($ActionName.ToLower())"))
        }
        return Resolve-BookPath -Path $Value -BaseRoot $BaseRoot
    }

    function Start-UarConsoleTrace([string]$Path, [string]$Label) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
        Add-Content -Path $Path -Value ""
        Add-Content -Path $Path -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Label trace setup ====="
        Set-Variable -Name UarConsoleTracePath -Value $Path -Scope Global
    }

    function global:Invoke-MailSqlFile {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Label,
            [string]$OutputPath = ''
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
        if ($OutputPath) { $output | Set-Content -Path $OutputPath -Encoding UTF8 }
        if ($exitCode -ne 0) { throw "sqlcmd failed for $Label with exit code $exitCode" }
        return $output
    }

    $validToOnly = @('Reviewer','Reissue','Reminder','NoLM_delegated','NoLM_BO','FinalReminder')
    $validToAndFrom = @('Delegate','MoR')
    $validActions = @($validToOnly + $validToAndFrom)
    if ($validActions -notcontains $ActionName) { throw "Invalid ActionName '$ActionName'. Valid values: $($validActions -join ', ')" }

    $RunDir = Resolve-MailRunDir -Value $RunDir -BaseRoot $Root
    New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
    $RunDirLeaf = Split-Path -Path $RunDir -Leaf

    $StageSummaryPath = Join-Path $RunDir '08_stage_pack_summary.csv'
    $ReviewSummaryPath = Join-Path $RunDir '04_review_pack_summary.csv'

    foreach ($candidate in @($StageSummaryPath, $ReviewSummaryPath)) {
        if (-not $Server) { $Server = Get-MailPackMetadataValue -Path $candidate -Name 'Server' }
        if (-not $TargetDb) { $TargetDb = Get-MailPackMetadataValue -Path $candidate -Name 'Database' }
        if (-not $AppId) { $AppId = Get-MailPackMetadataValue -Path $candidate -Name 'AppId' }
        if (-not $ReviewCycleId) { $ReviewCycleId = Get-MailPackMetadataValue -Path $candidate -Name 'ReviewCycleId' }
        if (-not $AppCode) { $AppCode = Get-MailPackMetadataValue -Path $candidate -Name 'AppCode' }
    }

    if (-not $Server) { $Server = 'sql.reference.invalid' }
    if (Is-FillMe $TargetDb) { throw 'TargetDb could not be derived. Set $TargetDb in the first block or point $RunDir at a completed WORKBOOK/STAGEBOOK run.' }
    if (Is-FillMe $ReviewCycleId) { throw 'ReviewCycleId could not be derived. Set $ReviewCycleId in the first block or point $RunDir at a completed STAGEBOOK run.' }
    if (Is-FillMe $AppId -and Is-FillMe $AppSearch) { throw 'Set $AppId or an $AppSearch that matches exactly one dbo.Applications row.' }
    if (Is-FillMe $QueueComment) { $QueueComment = "UAR2026 $AppCode $RunDirLeaf $ActionName" }

    if ($TargetDb -eq 'synthetic-production' -and ($ExecuteInsertEmailQueue -or $ExecuteResetFailedQueueRows -or $ExecuteSendEmail) -and -not $AllowProductionEmailSideEffects) {
        throw 'Production EmailQueue/email side effects requested. Set $AllowProductionEmailSideEffects = $false only after preflight approval.'
    }

    $OpsDir = Join-Path $Root 'ops'
    $MailDir = Join-Path $OpsDir 'mail'
    $TemplateDir = Join-Path $MailDir 'templates'
    $UarPsd1TemplatePath = Join-Path $MailDir 'UAR.psd1.template'
    $UarPsd1Path = Join-Path $MailDir 'UAR.psd1'
    $ToOnlyRunner = Join-Path $MailDir 'ActionQuery_Email_ToOnly.ps1'
    $ToAndFromRunner = Join-Path $MailDir 'ActionQuery_Email_ToAndFrom.ps1'

    $requiredFiles = @(
        Join-Path $MailDir 'UAR.psm1',
        $UarPsd1TemplatePath,
        $ToOnlyRunner,
        $ToAndFromRunner,
        Join-Path $TemplateDir 'template.Reviewer.html',
        Join-Path $TemplateDir 'template.Reminder.html',
        Join-Path $TemplateDir 'template.delegated.html',
        Join-Path $TemplateDir 'template.escalated_MoR.html',
        Join-Path $TemplateDir 'template.NoLM_BO.html',
        Join-Path $TemplateDir 'template.NoLM_delegated.html'
    )
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path $file -PathType Leaf)) { throw "Required mail file missing: $file" }
    }

    if (@('AppOnly','DelegatedShared') -notcontains $MailAuthMode) { throw "Invalid MailAuthMode '$MailAuthMode'. Use AppOnly or DelegatedShared." }
    if (Is-FillMe $QueueComment) { throw 'QueueComment is required. Sender is scoped by QueueComment to prevent ActionName-only blasts.' }
    function ConvertTo-Psd1SingleQuotedValue([string]$Value) { return $Value.Replace("'", "''") }
    $configText = Get-Content -Path $UarPsd1TemplatePath -Raw
    $configText = $configText.Replace('{{DBServer}}', (ConvertTo-Psd1SingleQuotedValue $Server)).Replace('{{Database}}', (ConvertTo-Psd1SingleQuotedValue $TargetDb)).Replace('{{ReviewCycleId}}', (ConvertTo-Psd1SingleQuotedValue $ReviewCycleId)).Replace('{{QueueComment}}', (ConvertTo-Psd1SingleQuotedValue $QueueComment)).Replace('{{EmailSender}}', (ConvertTo-Psd1SingleQuotedValue $EmailSender)).Replace('{{MailAuthMode}}', (ConvertTo-Psd1SingleQuotedValue $MailAuthMode))
    $configText | Set-Content -Path $UarPsd1Path -Encoding UTF8

    $requiredModules = @('EPS','Microsoft.Graph.Authentication','Microsoft.Graph.Users.Actions')
    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            $message = "PowerShell module missing for sender: $moduleName"
            if ($ExecuteSendEmail) { throw $message }
            Write-Warning $message
        }
    }
    $DbCredPath = Join-Path $MailDir 'synthetic-db.cred'
    $GraphCredPath = Join-Path $MailDir 'synthetic-app.cred'
    $credentialPaths = @($DbCredPath)
    if ($MailAuthMode -ieq 'AppOnly') { $credentialPaths += $GraphCredPath }
    foreach ($credentialPath in $credentialPaths) {
        if (-not (Test-Path $credentialPath -PathType Leaf)) {
            $message = "Credential file missing for sender: $credentialPath"
            if ($ExecuteSendEmail) { throw $message }
            Write-Warning $message
            continue
        }
        try { Get-Content $credentialPath | ConvertTo-SecureString -ErrorAction Stop | Out-Null }
        catch {
            $message = "Credential file exists but cannot be decrypted in this session: $credentialPath"
            if ($ExecuteSendEmail) { throw $message }
            Write-Warning $message
        }
    }

    $sqlcmd = 'tools/synthetic/sqlcmd'
    $Pwsh = 'pwsh'
    $ConsoleTracePath = Join-Path $RunDir 'console-trace-mailbook.txt'
    Start-UarConsoleTrace -Path $ConsoleTracePath -Label 'MAILBOOK'

    foreach ($v in @(
        'Root','RunDir','RunDirLeaf','Server','TargetDb','AppId','ReviewCycleId','QueueComment','MailAuthMode','EmailSender','OpsDir','MailDir','TemplateDir',
        'UarPsd1Path','ToOnlyRunner','ToAndFromRunner','sqlcmd','Pwsh','ConsoleTracePath','validToOnly','validToAndFrom'
    )) {
        Set-Variable -Name $v -Value (Get-Variable $v).Value -Scope Global
    }

    Write-Host "RunDir           = $RunDir"
    Write-Host "ConsoleTracePath = $ConsoleTracePath"
    Write-Host "MailDir          = $MailDir"
    Write-Host "Runtime config   = $UarPsd1Path"
    Write-Host "Server           = $Server"
    Write-Host "TargetDb         = $TargetDb"
    Write-Host "AppId            = $AppId"
    Write-Host "ReviewCycleId    = $ReviewCycleId"
    Write-Host "QueueComment     = $QueueComment"
    Write-Host "MailAuthMode     = $MailAuthMode"
    Write-Host "EmailSender      = $EmailSender"
    Write-Host "sqlcmd           = $sqlcmd"
    Write-Host "pwsh             = $Pwsh"
    Write-Host ""
    Write-Host "Next: run STEP 1 preflight."
}

# ==============================================================================
# STEP 1 — Preflight ReviewItems, Employees, EmailQueue, and mail config
# ==============================================================================

& {
    $preflightSqlPath = Join-Path $RunDir '09_mail_preflight.sql'
    $allowUnscoped = if ($AllowUnscopedActiveDueQueueRows) { '1' } else { '0' }
    $preflightSql = @"
SET NOCOUNT ON;

DECLARE @AppIdInput varchar(36) = $(Sql-StringLiteral $AppId);
DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleId uniqueidentifier = TRY_CONVERT(uniqueidentifier, $(Sql-StringLiteral $ReviewCycleId));
DECLARE @ActionName varchar(100) = $(Sql-StringLiteral $ActionName);
DECLARE @QueueComment varchar(100) = LEFT($(Sql-StringLiteral $QueueComment), 100);
DECLARE @AllowUnscoped bit = $allowUnscoped;

DECLARE @AppId uniqueidentifier;
DECLARE @AppCount bigint;

SELECT @AppCount = COUNT_BIG(*)
FROM dbo.Applications
WHERE (@AppIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @AppIdInput))
   OR (@AppIdInput = '' AND ApplicationName LIKE @AppSearch);

IF @AppCount <> 1
BEGIN
    SELECT TOP (50) Id AS ApplicationId, ApplicationName, BusinessOwnerAccount, DelegateAccount
    FROM dbo.Applications
    WHERE (@AppIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @AppIdInput))
       OR (@AppIdInput = '' AND ApplicationName LIKE @AppSearch)
    ORDER BY ApplicationName;
    THROW 57000, 'App selector must match exactly one application for MAILBOOK.', 1;
END;

SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE (@AppIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @AppIdInput))
   OR (@AppIdInput = '' AND ApplicationName LIKE @AppSearch)
ORDER BY ApplicationName;

IF @ReviewCycleId IS NULL THROW 57001, 'ReviewCycleId is not a valid uniqueidentifier.', 1;

SELECT 'Target database' AS [Check], DB_NAME() AS [Value]
UNION ALL SELECT 'ApplicationId', CONVERT(varchar(36), @AppId)
UNION ALL SELECT 'ReviewCycleId', CONVERT(varchar(36), @ReviewCycleId)
UNION ALL SELECT 'ActionName', @ActionName
UNION ALL SELECT 'QueueComment', @QueueComment;

SELECT Id AS ApplicationId, ApplicationName, BusinessOwnerAccount, BusinessOwnerName, DelegateAccount, DelegateName
FROM dbo.Applications
WHERE Id = @AppId;

SELECT Id AS ReviewCycleId, Name, StartDate, EndDate, Active
FROM dbo.ReviewCycles
WHERE Id = @ReviewCycleId;

SELECT 'ReviewItems rows for app/cycle' AS Metric, COUNT_BIG(*) AS Value FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId
UNION ALL SELECT 'Pending ReviewItems', COUNT_BIG(*) FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND Response IS NULL
UNION ALL SELECT 'Touched/issued/completed ReviewItems', COUNT_BIG(*) FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND (Response IS NOT NULL OR CompletedDate IS NOT NULL OR IssuedDate IS NOT NULL OR DueDate IS NOT NULL);

;WITH Pending AS (
    SELECT *
    FROM dbo.ReviewItems
    WHERE ApplicationId = @AppId
      AND ReviewCycleId = @ReviewCycleId
      AND Response IS NULL
), Candidate AS (
    SELECT ReviewerAccount AS ToAccount, CAST(NULL AS varchar(50)) AS FromAccount, COUNT_BIG(*) AS PendingRows
    FROM Pending
    WHERE @ActionName IN ('Reviewer','Reissue','Reminder','FinalReminder') AND NULLIF(ReviewerAccount, '') IS NOT NULL
    GROUP BY ReviewerAccount
    UNION ALL
    SELECT DelegateAccount AS ToAccount, CAST(NULL AS varchar(50)) AS FromAccount, COUNT_BIG(*) AS PendingRows
    FROM Pending
    WHERE @ActionName = 'NoLM_delegated' AND NULLIF(DelegateAccount, '') IS NOT NULL
    GROUP BY DelegateAccount
    UNION ALL
    SELECT BusinessOwnerAccount AS ToAccount, CAST(NULL AS varchar(50)) AS FromAccount, COUNT_BIG(*) AS PendingRows
    FROM Pending
    WHERE @ActionName = 'NoLM_BO' AND NULLIF(BusinessOwnerAccount, '') IS NOT NULL
    GROUP BY BusinessOwnerAccount
    UNION ALL
    SELECT DelegateAccount AS ToAccount, ReviewerAccount AS FromAccount, COUNT_BIG(*) AS PendingRows
    FROM Pending
    WHERE @ActionName = 'Delegate' AND NULLIF(DelegateAccount, '') IS NOT NULL
    GROUP BY DelegateAccount, ReviewerAccount
    UNION ALL
    SELECT MORAccount AS ToAccount, ReviewerAccount AS FromAccount, COUNT_BIG(*) AS PendingRows
    FROM Pending
    WHERE @ActionName = 'MoR' AND NULLIF(MORAccount, '') IS NOT NULL AND DATEDIFF(DAY, MoREscalationStartDate, GETDATE()) >= 0
    GROUP BY MORAccount, ReviewerAccount
), Preview AS (
    SELECT c.ToAccount, c.FromAccount, c.PendingRows,
           COALESCE(NULLIF(e.EmailAddress, ''), NULLIF(e.UserPrincipalName, '')) AS ToEmail,
           COALESCE(NULLIF(e.FirstName, ''), NULLIF(e.DisplayName, ''), c.ToAccount) AS ToName
    FROM Candidate c
    LEFT JOIN dbo.Employees e ON e.AccountName = c.ToAccount
)
SELECT 'Candidate recipients' AS Metric, COUNT_BIG(*) AS Value FROM Preview
UNION ALL SELECT 'Candidate recipients missing email/UPN', COUNT_BIG(*) FROM Preview WHERE ToEmail IS NULL
UNION ALL SELECT 'Active due EmailQueue rows for action', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
UNION ALL SELECT 'Active due rows with this QueueComment', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE()) AND Comment = @QueueComment
UNION ALL SELECT 'Active due rows outside this QueueComment', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE()) AND ISNULL(Comment, '') <> ISNULL(@QueueComment, '');

SELECT TOP (100) ToAccount, FromAccount, PendingRows, ToEmail, ToName
FROM Preview
ORDER BY ToAccount, FromAccount;

SELECT TOP (100) Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE ActionName = @ActionName
  AND Active = 1
  AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
ORDER BY CASE WHEN Comment = @QueueComment THEN 0 ELSE 1 END, CreatedOn DESC, ToAccount, FromAccount;

IF @AllowUnscoped = 0 AND EXISTS (
    SELECT 1 FROM dbo.EmailQueue
    WHERE ActionName = @ActionName
      AND Active = 1
      AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
      AND ISNULL(Comment, '') <> ISNULL(@QueueComment, '')
)
    PRINT 'WARNING: due active EmailQueue rows exist outside this QueueComment. Sender will process all due active rows for this ActionName.';
"@
    $preflightSql | Set-Content -Path $preflightSqlPath -Encoding UTF8
    Invoke-MailSqlFile -Path $preflightSqlPath -Label 'STEP 1 mail preflight (read-only)' | Out-Null
}

# ==============================================================================
# STEP 2 — Preview EmailQueue recipient candidates and write CSV artefact
# ==============================================================================

& {
    $previewSqlPath = Join-Path $RunDir "09_mailqueue_preview_$ActionName.sql"
    $previewCsvPath = Join-Path $RunDir "09_mailqueue_preview_$ActionName.csv"
    $previewSql = @"
SET NOCOUNT ON;

DECLARE @AppIdInput varchar(36) = $(Sql-StringLiteral $AppId);
DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleId uniqueidentifier = TRY_CONVERT(uniqueidentifier, $(Sql-StringLiteral $ReviewCycleId));
DECLARE @ActionName varchar(100) = $(Sql-StringLiteral $ActionName);
DECLARE @QueueComment varchar(100) = LEFT($(Sql-StringLiteral $QueueComment), 100);

DECLARE @AppId uniqueidentifier;
SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE (@AppIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @AppIdInput))
   OR (@AppIdInput = '' AND ApplicationName LIKE @AppSearch)
ORDER BY ApplicationName;

;WITH Pending AS (
    SELECT * FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND Response IS NULL
), Candidate AS (
    SELECT ReviewerAccount AS ToAccount, CAST(NULL AS varchar(50)) AS FromAccount, COUNT_BIG(*) AS PendingRows FROM Pending WHERE @ActionName IN ('Reviewer','Reissue','Reminder','FinalReminder') AND NULLIF(ReviewerAccount, '') IS NOT NULL GROUP BY ReviewerAccount
    UNION ALL SELECT DelegateAccount, CAST(NULL AS varchar(50)), COUNT_BIG(*) FROM Pending WHERE @ActionName = 'NoLM_delegated' AND NULLIF(DelegateAccount, '') IS NOT NULL GROUP BY DelegateAccount
    UNION ALL SELECT BusinessOwnerAccount, CAST(NULL AS varchar(50)), COUNT_BIG(*) FROM Pending WHERE @ActionName = 'NoLM_BO' AND NULLIF(BusinessOwnerAccount, '') IS NOT NULL GROUP BY BusinessOwnerAccount
    UNION ALL SELECT DelegateAccount, ReviewerAccount, COUNT_BIG(*) FROM Pending WHERE @ActionName = 'Delegate' AND NULLIF(DelegateAccount, '') IS NOT NULL GROUP BY DelegateAccount, ReviewerAccount
    UNION ALL SELECT MORAccount, ReviewerAccount, COUNT_BIG(*) FROM Pending WHERE @ActionName = 'MoR' AND NULLIF(MORAccount, '') IS NOT NULL AND DATEDIFF(DAY, MoREscalationStartDate, GETDATE()) >= 0 GROUP BY MORAccount, ReviewerAccount
), Preview AS (
    SELECT @ActionName AS ActionName, c.ToAccount, c.FromAccount, c.PendingRows,
           COALESCE(NULLIF(e.EmailAddress, ''), NULLIF(e.UserPrincipalName, '')) AS ToEmail,
           COALESCE(NULLIF(e.FirstName, ''), NULLIF(e.DisplayName, ''), c.ToAccount) AS ToName,
           CASE WHEN q.Id IS NULL THEN 0 ELSE 1 END AS ActiveQueueAlreadyExists,
           @QueueComment AS QueueComment
    FROM Candidate c
    LEFT JOIN dbo.Employees e ON e.AccountName = c.ToAccount
    OUTER APPLY (
        SELECT TOP (1) Id
        FROM dbo.EmailQueue q
        WHERE q.Active = 1
          AND q.ActionName = @ActionName
          AND ISNULL(q.ToAccount, '') = ISNULL(c.ToAccount, '')
          AND ISNULL(q.FromAccount, '') = ISNULL(c.FromAccount, '')
          AND ISNULL(q.Comment, '') = ISNULL(@QueueComment, '')
        ORDER BY CreatedOn DESC
    ) q
)
SELECT CsvLine
FROM (
    SELECT 0 AS SortOrder, 'ActionName,ToAccount,FromAccount,PendingRows,ToEmail,ToName,ActiveQueueAlreadyExists,QueueComment' AS CsvLine
    UNION ALL
    SELECT 1 AS SortOrder, CONCAT(
        '"', REPLACE(ISNULL(ActionName,''), '"', '""'), '",',
        '"', REPLACE(ISNULL(ToAccount,''), '"', '""'), '",',
        '"', REPLACE(ISNULL(FromAccount,''), '"', '""'), '",',
        PendingRows, ',',
        '"', REPLACE(ISNULL(ToEmail,''), '"', '""'), '",',
        '"', REPLACE(ISNULL(ToName,''), '"', '""'), '",',
        ActiveQueueAlreadyExists, ',',
        '"', REPLACE(ISNULL(QueueComment,''), '"', '""'), '"'
    ) AS CsvLine
    FROM Preview
) csv
ORDER BY SortOrder, CsvLine;
"@
    $previewSql | Set-Content -Path $previewSqlPath -Encoding UTF8
    $csvLines = Invoke-MailSqlFile -Path $previewSqlPath -Label 'STEP 2 mail recipient preview (read-only CSV extract)'
    $csvLines |
        Where-Object { $_ -and ($_ -notmatch '^-+$') -and ($_ -notmatch '^\(\d+ rows affected\)$') } |
        Set-Content -Path $previewCsvPath -Encoding UTF8
    Write-Host "Preview CSV: $previewCsvPath"
}

# ==============================================================================
# STEP 3 — Insert EmailQueue rows (mutating, explicit switch)
# ==============================================================================

& {
    $insertSqlPath = Join-Path $RunDir "10_insert_emailqueue_$ActionName.sql"
    $insertSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @AppIdInput varchar(36) = $(Sql-StringLiteral $AppId);
DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleId uniqueidentifier = TRY_CONVERT(uniqueidentifier, $(Sql-StringLiteral $ReviewCycleId));
DECLARE @ActionName varchar(100) = $(Sql-StringLiteral $ActionName);
DECLARE @QueueComment varchar(100) = LEFT($(Sql-StringLiteral $QueueComment), 100);
DECLARE @ExecuteOn datetime = TRY_CONVERT(datetime, $(Sql-StringLiteral ([datetime]$ExecuteOn).ToString('yyyy-MM-dd HH:mm:ss')));

DECLARE @AppId uniqueidentifier;
SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE (@AppIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @AppIdInput))
   OR (@AppIdInput = '' AND ApplicationName LIKE @AppSearch)
ORDER BY ApplicationName;

IF @AppId IS NULL THROW 57100, 'Could not resolve application for EmailQueue insert.', 1;
IF @ReviewCycleId IS NULL THROW 57101, 'ReviewCycleId is invalid for EmailQueue insert.', 1;

;WITH Pending AS (
    SELECT * FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND Response IS NULL
), Candidate AS (
    SELECT ReviewerAccount AS ToAccount, CAST(NULL AS varchar(50)) AS FromAccount, COUNT_BIG(*) AS PendingRows FROM Pending WHERE @ActionName IN ('Reviewer','Reissue','Reminder','FinalReminder') AND NULLIF(ReviewerAccount, '') IS NOT NULL GROUP BY ReviewerAccount
    UNION ALL SELECT DelegateAccount, CAST(NULL AS varchar(50)), COUNT_BIG(*) FROM Pending WHERE @ActionName = 'NoLM_delegated' AND NULLIF(DelegateAccount, '') IS NOT NULL GROUP BY DelegateAccount
    UNION ALL SELECT BusinessOwnerAccount, CAST(NULL AS varchar(50)), COUNT_BIG(*) FROM Pending WHERE @ActionName = 'NoLM_BO' AND NULLIF(BusinessOwnerAccount, '') IS NOT NULL GROUP BY BusinessOwnerAccount
    UNION ALL SELECT DelegateAccount, ReviewerAccount, COUNT_BIG(*) FROM Pending WHERE @ActionName = 'Delegate' AND NULLIF(DelegateAccount, '') IS NOT NULL GROUP BY DelegateAccount, ReviewerAccount
    UNION ALL SELECT MORAccount, ReviewerAccount, COUNT_BIG(*) FROM Pending WHERE @ActionName = 'MoR' AND NULLIF(MORAccount, '') IS NOT NULL AND DATEDIFF(DAY, MoREscalationStartDate, GETDATE()) >= 0 GROUP BY MORAccount, ReviewerAccount
), CandidateWithEmail AS (
    SELECT c.*, COALESCE(NULLIF(e.EmailAddress, ''), NULLIF(e.UserPrincipalName, '')) AS ToEmail
    FROM Candidate c
    LEFT JOIN dbo.Employees e ON e.AccountName = c.ToAccount
)
SELECT * INTO #CandidateWithEmail FROM CandidateWithEmail;

IF NOT EXISTS (SELECT 1 FROM #CandidateWithEmail)
    THROW 57102, 'No candidate recipients found; EmailQueue insert blocked.', 1;

IF EXISTS (SELECT 1 FROM #CandidateWithEmail WHERE ToEmail IS NULL)
BEGIN
    SELECT * FROM #CandidateWithEmail WHERE ToEmail IS NULL ORDER BY ToAccount, FromAccount;
    THROW 57103, 'One or more candidate recipients have no EmailAddress/UserPrincipalName; EmailQueue insert blocked.', 1;
END;

INSERT INTO dbo.EmailQueue (Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, CompletedOn, ExecuteOn, ErrorMessage)
SELECT NEWID(), FromAccount, ToAccount, @ActionName, @QueueComment, CONVERT(bit, 1), GETDATE(), NULL, @ExecuteOn, NULL
FROM #CandidateWithEmail c
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.EmailQueue q
    WHERE q.Active = 1
      AND q.ActionName = @ActionName
      AND ISNULL(q.ToAccount, '') = ISNULL(c.ToAccount, '')
      AND ISNULL(q.FromAccount, '') = ISNULL(c.FromAccount, '')
      AND ISNULL(q.Comment, '') = ISNULL(@QueueComment, '')
);

SELECT 'EmailQueue rows inserted' AS Metric, @@ROWCOUNT AS Value
UNION ALL SELECT 'Candidate recipients', COUNT_BIG(*) FROM #CandidateWithEmail
UNION ALL SELECT 'Active rows for this QueueComment', COUNT_BIG(*) FROM dbo.EmailQueue WHERE Active = 1 AND ActionName = @ActionName AND Comment = @QueueComment;

SELECT Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE ActionName = @ActionName AND Comment = @QueueComment
ORDER BY CreatedOn DESC, ToAccount, FromAccount;

COMMIT TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    THROW;
END CATCH;
"@
    $insertSql | Set-Content -Path $insertSqlPath -Encoding UTF8
    if ($ExecuteInsertEmailQueue) {
        Invoke-MailSqlFile -Path $insertSqlPath -Label 'STEP 3 insert EmailQueue rows (MUTATING)' | Out-Null
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote EmailQueue insert SQL but did not execute:"
        Write-Host $insertSqlPath
        Write-Host "Set `$ExecuteInsertEmailQueue = `$true in the first block, rerun that block, then rerun STEP 3 to insert queue rows."
    }
}

# ==============================================================================
# STEP 3B — Reset failed rows for this action/comment (mutating, explicit switch)
# ==============================================================================

& {
    $resetSqlPath = Join-Path $RunDir "10b_reset_failed_emailqueue_$ActionName.sql"
    $resetSql = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @ActionName varchar(100) = $(Sql-StringLiteral $ActionName);
DECLARE @QueueComment varchar(100) = LEFT($(Sql-StringLiteral $QueueComment), 100);
DECLARE @ExecuteOn datetime = TRY_CONVERT(datetime, $(Sql-StringLiteral ([datetime]$ExecuteOn).ToString('yyyy-MM-dd HH:mm:ss')));

SELECT Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE ActionName = @ActionName
  AND Comment = @QueueComment
  AND ErrorMessage IS NOT NULL
ORDER BY CreatedOn DESC;

UPDATE dbo.EmailQueue
SET Active = 1,
    CompletedOn = NULL,
    ExecuteOn = COALESCE(@ExecuteOn, ExecuteOn, GETDATE()),
    ErrorMessage = NULL
WHERE ActionName = @ActionName
  AND Comment = @QueueComment
  AND ErrorMessage IS NOT NULL;

SELECT 'Failed EmailQueue rows reset' AS Metric, @@ROWCOUNT AS Value;

COMMIT TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    THROW;
END CATCH;
"@
    $resetSql | Set-Content -Path $resetSqlPath -Encoding UTF8
    if ($ExecuteResetFailedQueueRows) {
        Invoke-MailSqlFile -Path $resetSqlPath -Label 'STEP 3B reset failed EmailQueue rows (MUTATING)' | Out-Null
    } else {
        Write-Host ""
        Write-Host "Dry-run: wrote failed-row reset SQL but did not execute:"
        Write-Host $resetSqlPath
    }
}

# ==============================================================================
# STEP 4 — Verify EmailQueue before send
# ==============================================================================

& {
    $verifySqlPath = Join-Path $RunDir "11_verify_emailqueue_before_send_$ActionName.sql"
    $allowUnscoped = if ($AllowUnscopedActiveDueQueueRows) { '1' } else { '0' }
    $verifySql = @"
SET NOCOUNT ON;

DECLARE @ReviewCycleId uniqueidentifier = TRY_CONVERT(uniqueidentifier, $(Sql-StringLiteral $ReviewCycleId));
DECLARE @ActionName varchar(100) = $(Sql-StringLiteral $ActionName);
DECLARE @QueueComment varchar(100) = LEFT($(Sql-StringLiteral $QueueComment), 100);
DECLARE @AllowUnscoped bit = $allowUnscoped;

;WITH DueQueue AS (
    SELECT q.*
    FROM dbo.EmailQueue q
    WHERE q.ActionName = @ActionName
      AND q.Active = 1
      AND CONVERT(date, ISNULL(q.ExecuteOn, q.CreatedOn)) <= CONVERT(date, GETDATE())
), PendingCounts AS (
    SELECT q.Id,
           (SELECT COUNT_BIG(*) FROM dbo.ReviewItems ri WHERE ri.ReviewerAccount = q.ToAccount AND ri.ReviewType = 'LineManager' AND ri.Response IS NULL AND ri.ReviewCycleId = @ReviewCycleId) AS ManagerCount,
           (SELECT COUNT_BIG(*) FROM dbo.ReviewItems ri WHERE ri.ReviewerAccount = q.ToAccount AND ri.ReviewType = 'BusinessOwner' AND ri.Response IS NULL AND ri.ReviewCycleId = @ReviewCycleId) AS BusinessOwnerCount,
           (SELECT COUNT_BIG(*) FROM dbo.ReviewItems ri WHERE ri.DelegateAccount = q.ToAccount AND ri.Response IS NULL AND ri.ReviewCycleId = @ReviewCycleId) AS DelegatedCount,
           (SELECT COUNT_BIG(*) FROM dbo.ReviewItems ri WHERE ri.MORAccount = q.ToAccount AND DATEDIFF(DAY, ri.MoREscalationStartDate, GETDATE()) >= 0 AND ri.Response IS NULL AND ri.ReviewCycleId = @ReviewCycleId) AS EscalatedCount
    FROM DueQueue q
), QueueStatus AS (
    SELECT q.Id, q.FromAccount, q.ToAccount, q.ActionName, q.Comment, q.CreatedOn, q.ExecuteOn, q.ErrorMessage,
           COALESCE(NULLIF(e.EmailAddress, ''), NULLIF(e.UserPrincipalName, '')) AS ToEmail,
           pc.ManagerCount, pc.BusinessOwnerCount, pc.DelegatedCount, pc.EscalatedCount,
           CASE WHEN @ActionName = 'MoR' THEN pc.EscalatedCount ELSE pc.ManagerCount + pc.BusinessOwnerCount + pc.DelegatedCount + pc.EscalatedCount END AS SenderPendingCount
    FROM DueQueue q
    LEFT JOIN dbo.Employees e ON e.AccountName = q.ToAccount
    LEFT JOIN PendingCounts pc ON pc.Id = q.Id
)
SELECT 'Due active rows for action' AS Metric, COUNT_BIG(*) AS Value FROM QueueStatus
UNION ALL SELECT 'Due active rows with this QueueComment', COUNT_BIG(*) FROM QueueStatus WHERE Comment = @QueueComment
UNION ALL SELECT 'Due active rows outside this QueueComment', COUNT_BIG(*) FROM QueueStatus WHERE ISNULL(Comment, '') <> ISNULL(@QueueComment, '')
UNION ALL SELECT 'Due rows missing email/UPN', COUNT_BIG(*) FROM QueueStatus WHERE ToEmail IS NULL
UNION ALL SELECT 'Due rows with zero sender pending count', COUNT_BIG(*) FROM QueueStatus WHERE SenderPendingCount = 0;

SELECT TOP (200) *
FROM QueueStatus
ORDER BY CASE WHEN Comment = @QueueComment THEN 0 ELSE 1 END, ToAccount, FromAccount, CreatedOn;

SELECT ActionName, ToAccount, FromAccount, Comment, COUNT_BIG(*) AS ActiveDueDuplicates
FROM QueueStatus
GROUP BY ActionName, ToAccount, FromAccount, Comment
HAVING COUNT_BIG(*) > 1
ORDER BY ActiveDueDuplicates DESC, ToAccount, FromAccount;

IF EXISTS (SELECT 1 FROM QueueStatus WHERE ToEmail IS NULL)
    THROW 57200, 'One or more due queue rows have no recipient email/UPN. Resolve before send.', 1;

IF EXISTS (SELECT 1 FROM QueueStatus WHERE SenderPendingCount = 0)
    THROW 57201, 'One or more due queue rows have zero pending items by sender logic. Resolve before send.', 1;

IF @AllowUnscoped = 0 AND EXISTS (SELECT 1 FROM QueueStatus WHERE ISNULL(Comment, '') <> ISNULL(@QueueComment, ''))
    THROW 57202, 'Due active rows outside this QueueComment exist. Sender would process them too. Clear them or set AllowUnscopedActiveDueQueueRows intentionally.', 1;
"@
    $verifySql | Set-Content -Path $verifySqlPath -Encoding UTF8
    Invoke-MailSqlFile -Path $verifySqlPath -Label 'STEP 4 verify EmailQueue before send (read-only gate)' | Out-Null
}

# ==============================================================================
# STEP 5 — Run notification sender (external email side effect, explicit switch)
# ==============================================================================

& {
    $runner = if ($validToOnly -contains $ActionName) { $ToOnlyRunner } else { $ToAndFromRunner }
    Write-Host ""
    Write-Host "Selected runner: $runner"
    Write-Host "Sender command : `"$Pwsh`" -NoProfile -File `"$runner`" -ActionName $ActionName"

    if (-not $ExecuteSendEmail) {
        Write-Host "Dry-run: sender was not executed. Set `$ExecuteSendEmail = `$true only after STEP 4 passes and approvals are complete."
        return
    }

    if ($TargetDb -eq 'synthetic-production' -and -not $AllowProductionEmailSideEffects) {
        throw 'Production send blocked. Set $AllowProductionEmailSideEffects = $false only after approval.'
    }
    $credentialPaths = @((Join-Path $MailDir 'synthetic-db.cred'))
    if ($MailAuthMode -ieq 'AppOnly') { $credentialPaths += (Join-Path $MailDir 'synthetic-app.cred') }
    foreach ($credentialPath in $credentialPaths) {
        if (-not (Test-Path $credentialPath -PathType Leaf)) { throw "Required credential file missing for send: $credentialPath" }
        try { Get-Content $credentialPath | ConvertTo-SecureString -ErrorAction Stop | Out-Null }
        catch { throw "Credential file exists but cannot be decrypted in this session: $credentialPath" }
    }
    if ($MailAuthMode -ieq 'DelegatedShared') {
        Write-Host "MailAuthMode DelegatedShared: Graph will prompt/sign in interactively with Mail.Send.Shared and use Send As on $EmailSender."
    }

    Add-Content -Path $ConsoleTracePath -Value ""
    Add-Content -Path $ConsoleTracePath -Value "===== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) STEP 5 run sender $ActionName ====="
    Push-Location $MailDir
    try {
        $senderOutput = & $Pwsh -NoProfile -File $runner -ActionName $ActionName 2>&1
        $senderOutput | Add-Content -Path $ConsoleTracePath
        $senderOutput | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "Sender process exited with code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
    Write-Host "Sender completed. Review console trace: $ConsoleTracePath"
}

# ==============================================================================
# STEP 6 — Post-send verification pack
# ==============================================================================

& {
    $packSqlPath = Join-Path $RunDir "12_mail_pack_$ActionName.sql"
    $packTxtPath = Join-Path $RunDir "12_mail_pack_$ActionName.txt"
    $packHtmlPath = Join-Path $RunDir "12_mail_pack_$ActionName.html"
    $packSummaryCsvPath = Join-Path $RunDir "12_mail_pack_summary_$ActionName.csv"
    $packSql = @"
SET NOCOUNT ON;

DECLARE @AppIdInput varchar(36) = $(Sql-StringLiteral $AppId);
DECLARE @AppSearch nvarchar(200) = $(Sql-StringLiteral $AppSearch);
DECLARE @ReviewCycleId uniqueidentifier = TRY_CONVERT(uniqueidentifier, $(Sql-StringLiteral $ReviewCycleId));
DECLARE @ActionName varchar(100) = $(Sql-StringLiteral $ActionName);
DECLARE @QueueComment varchar(100) = LEFT($(Sql-StringLiteral $QueueComment), 100);
DECLARE @AppId uniqueidentifier;

SELECT TOP (1) @AppId = Id
FROM dbo.Applications
WHERE (@AppIdInput <> '' AND Id = TRY_CONVERT(uniqueidentifier, @AppIdInput))
   OR (@AppIdInput = '' AND ApplicationName LIKE @AppSearch)
ORDER BY ApplicationName;

SELECT 'Metadata' AS Section, 'GeneratedAt' AS Name, CONVERT(varchar(19), GETDATE(), 120) AS Value
UNION ALL SELECT 'Metadata', 'Database', DB_NAME()
UNION ALL SELECT 'Metadata', 'ApplicationId', CONVERT(varchar(36), @AppId)
UNION ALL SELECT 'Metadata', 'ReviewCycleId', CONVERT(varchar(36), @ReviewCycleId)
UNION ALL SELECT 'Metadata', 'ActionName', @ActionName
UNION ALL SELECT 'Metadata', 'QueueComment', @QueueComment;

SELECT 'EmailQueue summary' AS Section, 'Active due for action' AS Metric, COUNT_BIG(*) AS Value FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
UNION ALL SELECT 'EmailQueue summary', 'Active due for this QueueComment', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Comment = @QueueComment AND Active = 1 AND CONVERT(date, ISNULL(ExecuteOn, CreatedOn)) <= CONVERT(date, GETDATE())
UNION ALL SELECT 'EmailQueue summary', 'Completed for this QueueComment', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Comment = @QueueComment AND Active = 0 AND CompletedOn IS NOT NULL
UNION ALL SELECT 'EmailQueue summary', 'Errors for this QueueComment', COUNT_BIG(*) FROM dbo.EmailQueue WHERE ActionName = @ActionName AND Comment = @QueueComment AND ErrorMessage IS NOT NULL
UNION ALL SELECT 'ReviewItems summary', 'Pending ReviewItems for app/cycle', COUNT_BIG(*) FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND Response IS NULL
UNION ALL SELECT 'ReviewItems summary', 'Completed ReviewItems for app/cycle', COUNT_BIG(*) FROM dbo.ReviewItems WHERE ApplicationId = @AppId AND ReviewCycleId = @ReviewCycleId AND Response IS NOT NULL;

SELECT TOP (200) Id, FromAccount, ToAccount, ActionName, Comment, Active, CreatedOn, ExecuteOn, CompletedOn, ErrorMessage
FROM dbo.EmailQueue
WHERE ActionName = @ActionName
  AND (Comment = @QueueComment OR ErrorMessage IS NOT NULL OR CompletedOn >= DATEADD(day, -2, GETDATE()))
ORDER BY COALESCE(CompletedOn, CreatedOn) DESC, ToAccount, FromAccount;

SELECT ReviewType, ReviewerAccount, DelegateAccount, MORAccount, COUNT_BIG(*) AS PendingRows
FROM dbo.ReviewItems
WHERE ApplicationId = @AppId
  AND ReviewCycleId = @ReviewCycleId
  AND Response IS NULL
GROUP BY ReviewType, ReviewerAccount, DelegateAccount, MORAccount
ORDER BY PendingRows DESC, ReviewType, ReviewerAccount, DelegateAccount, MORAccount;
"@
    $packSql | Set-Content -Path $packSqlPath -Encoding UTF8
    $packOutput = Invoke-MailSqlFile -Path $packSqlPath -Label 'STEP 6 post-send mail verification pack (read-only)'
    $packOutput | Set-Content -Path $packTxtPath -Encoding UTF8
    $html = @(
        '<!doctype html><html><head><meta charset="utf-8"><title>UAR mail pack</title></head><body>',
        "<h1>UAR mail pack - $ActionName</h1>",
        "<p><strong>Generated:</strong> $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))</p>",
        "<p><strong>Database:</strong> $TargetDb<br><strong>ReviewCycleId:</strong> $ReviewCycleId<br><strong>QueueComment:</strong> $QueueComment</p>",
        '<pre>',
        [System.Net.WebUtility]::HtmlEncode(($packOutput -join "`r`n")),
        '</pre></body></html>'
    )
    $html | Set-Content -Path $packHtmlPath -Encoding UTF8

    @(
        'Name,Value',
        'ActionName,' + $ActionName,
        'TargetDb,' + $TargetDb,
        'ReviewCycleId,' + $ReviewCycleId,
        'QueueComment,"' + ($QueueComment.Replace('"','""')) + '"',
        'PackText,' + $packTxtPath,
        'PackHtml,' + $packHtmlPath
    ) | Set-Content -Path $packSummaryCsvPath -Encoding UTF8

    Write-Host "Mail pack text : $packTxtPath"
    Write-Host "Mail pack HTML : $packHtmlPath"
    Write-Host "Mail summary   : $packSummaryCsvPath"
}

# ==============================================================================
# STEP 7 — Operator testing sequence summary
# ==============================================================================

& {
    Write-Host ""
    Write-Host "MAILBOOK test/operation sequence:"
    Write-Host "  1. STEP 0: generate ops\mail\UAR.psd1 and verify templates/runners/credentials."
    Write-Host "  2. STEP 1: confirm app/cycle, pending ReviewItems, Employees email coverage, and no unexpected due active queue rows."
    Write-Host "  3. STEP 2: review $ActionName recipient CSV before inserting anything."
    Write-Host "  4. STEP 3: insert EmailQueue only after preview is approved."
    Write-Host "  5. STEP 4: hard gate before send; resolves missing email, zero pending, duplicates, and unscoped queue rows."
    Write-Host "  6. STEP 5: run sender only with explicit switch and production approval."
    Write-Host "  7. STEP 6: keep txt/html/csv evidence pack with EmailQueue and ReviewItems state."
    Write-Host ""
    Write-Host "For a contained pre-flight workflow, use TESTBOOK.ps1 to create tagged dummy ReviewItems and a tagged Reviewer EmailQueue row in synthetic-test, then run MAILBOOK against that test run before touching production."
}
