# Offline inspection only: never dot-sources, imports or evaluates a book.
param([string]$SourceDirectory = '')
$ErrorActionPreference = 'Stop'

function Assert-Static([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Read-BookAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Static ($errors.Count -eq 0) "Parse errors in $([IO.Path]::GetFileName($Path)): $($errors.Count)"
    return @{ Ast = $ast; Tokens = $tokens; Text = [IO.File]::ReadAllText($Path) }
}
function Get-Functions($Book) {
    @($Book.Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true) | ForEach-Object {
        $f = $_
        $parameters = @($f.FindAll({param($n) $n -is [System.Management.Automation.Language.ParameterAst]}, $true) | ForEach-Object { $_.Extent.Text })
        $f.Name + ':' + ($parameters -join '|')
    })
}
function Get-Steps($Book) {
    @($Book.Tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match '^# STEP\s' } | ForEach-Object { [regex]::Match($_.Text, '^# STEP\s+([0-9]+[A-Za-z]?)\b').Groups[1].Value })
}
function Get-SqlShapes($Book) {
    @($Book.Ast.FindAll({param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Value -match '(?is)^\s*(SET\s+(NOCOUNT|XACT_ABORT)|SELECT\s|DECLARE\s|INSERT\s|UPDATE\s|DELETE\s|FROM\s|WHERE\s|ORDER\s|IF\s+NOT\s+EXISTS|VALUES\s)'
    }, $true) | ForEach-Object {
        # Mask SQL literal payloads only; retain keywords, identifiers, columns,
        # operators, interpolation syntax, statement order and punctuation.
        $shape = [regex]::Replace($_.Value, "N?'(?:''|[^'])*'", "'<literal>'")
        $shape = [regex]::Replace($shape, '(?m)--[^\r\n]*', '')
        [regex]::Replace($shape, '\s+', ' ').Trim()
    })
}

$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $Root 'docs/books-provenance.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.books) {
    $book = Read-BookAst (Join-Path $Root $entry.derivative)
    $first = $book.Ast.EndBlock.Statements[0]
    Assert-Static ($first -is [System.Management.Automation.Language.ThrowStatementAst] -and $first.Extent.Text -eq 'throw "REFERENCE ONLY: execution is unconditionally disabled."') 'Missing unconditional initial guard'
    Assert-Static ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Root $entry.derivative)).Hash.ToLowerInvariant() -eq $entry.derivativeSha256) 'Derivative hash mismatch'
    foreach ($assignment in $book.Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]}, $true)) {
        if ($assignment.Left.Extent.Text -match '^\$(Execute\w+|Allow\w+|ReplaceExistingReviewItems|CreateBusinessOwnerItem|CreateLineManagerItem)$' -and $assignment.Right.Extent.Text -match '^\$(true|false)$') {
            Assert-Static ($assignment.Right.Extent.Text -eq '$false') 'Enabled mutation opt-in'
        }
    }
    Assert-Static ($book.Text -notmatch '(?i)/Users/|[A-Z]:\\|\b[a-z]\d{7}\b|\b(?:\d{1,3}\.){3}\d{1,3}\b(?<!192\.0\.2\.10)') 'Unexpected local path/account/IP'
    foreach ($hostMatch in [regex]::Matches($book.Text, '(?i)(?:https?://|[\w.+-]+@)([a-z0-9.-]+)')) {
        Assert-Static ($hostMatch.Groups[1].Value.EndsWith('.invalid')) 'Non-invalid endpoint/address'
    }
    if ($SourceDirectory) {
        $sourcePath = Join-Path $SourceDirectory $entry.source
        Assert-Static ((Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant() -eq $entry.sourceSha256) 'Source hash mismatch'
        $source = Read-BookAst $sourcePath
        Assert-Static ((Get-Functions $source | ConvertTo-Json -Compress) -ceq (Get-Functions $book | ConvertTo-Json -Compress)) 'Function/parameter mismatch'
        Assert-Static ((Get-Steps $source | ConvertTo-Json -Compress) -ceq (Get-Steps $book | ConvertTo-Json -Compress)) 'Ordered step mismatch'
        Assert-Static ((Get-SqlShapes $source | ConvertTo-Json -Compress) -ceq (Get-SqlShapes $book | ConvertTo-Json -Compress)) 'SQL shape mismatch'
        $sourceTypes = @($source.Ast.FindAll({param($n) $true}, $true) | Select-Object -Skip 1 | ForEach-Object { $_.GetType().Name })
        $bookTypes = @($book.Ast.FindAll({param($n) $true}, $true) | Select-Object -Skip 1 | Where-Object { -not ($_.Extent.StartOffset -ge $first.Extent.StartOffset -and $_.Extent.EndOffset -le $first.Extent.EndOffset) } | ForEach-Object { $_.GetType().Name })
        Assert-Static (($sourceTypes -join ',') -ceq ($bookTypes -join ',')) 'AST structure mismatch beyond initial guard'
    }
    $functions = @(Get-Functions $book).Count
    $steps = @(Get-Steps $book).Count
    $sql = @(Get-SqlShapes $book).Count
    Assert-Static ($functions -eq $entry.functionCount -and $steps -eq $entry.stepCount -and $sql -eq $entry.sqlShapeCount) 'Manifest count mismatch'
    Write-Output "$($entry.derivative): parse=0 errors; functions=$functions; steps=$steps; SQL shapes=$sql; checks passed"
}
