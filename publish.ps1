# Publishes the haveno-dart package to GitHub so it can be linked in the
# Haveno "port haveno-ts to Dart" bounty claim
# (https://bounties.monero.social/posts/166).
#
# One-time prerequisites:
#   1. git installed        (https://git-scm.com)
#   2. GitHub CLI installed (https://cli.github.com)
#   3. gh auth login        (interactive, ~2 minutes)
#
# Then from this folder:
#   powershell -File publish.ps1                 # public repo "haveno-dart"
#   powershell -File publish.ps1 -Private        # private repo
#   powershell -File publish.ps1 -RepoName other # different name

param(
    [string]$RepoName = "haveno-dart",
    [switch]$Private
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is not installed - https://git-scm.com" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) is not installed - https://cli.github.com" }

gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI not logged in. Run: gh auth login" }

if (-not (Test-Path ".git")) {
    git init | Out-Null
    git branch -M main
}

git add -A
git -c user.name="haveno-dart" -c user.email="haveno-dart@users.noreply.github.com" commit -m "haveno-dart 0.1.0: Dart port of haveno-ts" 2>$null
Write-Host "Commit step finished (a 'nothing to commit' result is fine)."

$vis = if ($Private) { "--private" } else { "--public" }
if (-not (gh repo view $RepoName 2>$null)) {
    gh repo create $RepoName $vis --source . --push
} else {
    git push -u origin main
}

Write-Host ""
Write-Host "Done. Public repo URL (use this in the bounty claim):"
gh repo view $RepoName --json url -q .url
