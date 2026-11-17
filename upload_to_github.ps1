$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$gh = "C:\Program Files\GitHub CLI\gh.exe"
if (-not (Test-Path $gh)) {
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghCmd) { $gh = $ghCmd.Source } else { throw "GitHub CLI (gh) not found." }
}

$token = (& $gh auth token).Trim()
$headers = @{
    "Authorization"        = "Bearer $token"
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "Antigravity-eBiz-DataLab"
}

$Owner = "kcar-ebiz"
$Repo  = "kcar-ebiz.github.io"
$LabFolderName = "eBiz 연구실 (케이카닷컴)"
$WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
$TodayDate = ([DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9))).ToString("yyyy-MM-dd")

function Invoke-GhJsonPost {
    param([string]$Uri, [string]$Method = "Post", [object]$BodyObj)
    $json = $BodyObj | ConvertTo-Json -Depth 10 -Compress
    $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $Uri -Headers $headers -Method $Method -ContentType "application/json; charset=utf-8" -Body $utf8Bytes
}

# 0. Update eBiz 연구실 (케이카닷컴)/manifest.json automatically
$labDir = Join-Path $WorkDir $LabFolderName
if (-not (Test-Path -LiteralPath $labDir)) {
    New-Item -ItemType Directory -Force -Path $labDir | Out-Null
}
$hiddenLab = @("index.html", "manifest.json", ".gitkeep", "README_사용안내.md")
$labFiles = @()
Get-ChildItem -LiteralPath $labDir -File -Force | Sort-Object Name | ForEach-Object {
    if ($hiddenLab -notcontains $_.Name) {
        $labFiles += [ordered]@{
            name      = $_.Name
            size      = $_.Length
            updatedAt = $_.LastWriteTime.ToString("yyyy-MM-dd")
        }
    }
}
$manifestObj = [ordered]@{
    updatedAt = $TodayDate
    files     = $labFiles
}
$manifestJson = $manifestObj | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $labDir "manifest.json"), $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[1/4] Updated $LabFolderName/manifest.json ($($labFiles.Count) lab files detected)." -ForegroundColor Cyan

# 1. Ensure repository exists under Organization kcar-ebiz
$repoExists = $false
try {
    $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo" -Headers $headers -Method Get
    $repoExists = $true
} catch {
    $repoExists = $false
}

if (-not $repoExists) {
    Write-Host "[2/4] Creating GitHub Organization repository $Owner/$Repo ..." -ForegroundColor Yellow
    $createBody = [ordered]@{
        name        = $Repo
        description = "K Car e-biz실 데이터랩 (Mobility Intelligence & Strategy Main Portal)"
        homepage    = "https://kcar-ebiz.github.io/"
        private     = $false
        auto_init   = $true
    }
    $null = Invoke-GhJsonPost -Uri "https://api.github.com/orgs/$Owner/repos" -Method "Post" -BodyObj $createBody
    Start-Sleep -Seconds 2
} else {
    Write-Host "[2/4] Repository $Owner/$Repo verified." -ForegroundColor Cyan
}

# 2. Mirror local SUMMARY directory cleanly to GitHub tree
$refInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/git/ref/heads/main" -Headers $headers -Method Get
$baseCommitSha = $refInfo.object.sha
$commitInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/git/commits/$baseCommitSha" -Headers $headers -Method Get
$baseTreeSha = $commitInfo.tree.sha

$allFiles = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($WorkDir.Length).TrimStart('\', '/') -replace '\\', '/'
    ($rel -notlike ".git/*")
}

Write-Host "[3/4] Uploading $($allFiles.Count) portal files to GitHub ($Owner/$Repo) ..." -ForegroundColor Cyan
$treeItems = New-Object System.Collections.Generic.List[object]
foreach ($file in $allFiles) {
    $relPath = $file.FullName.Substring($WorkDir.Length).TrimStart('\', '/') -replace '\\', '/'
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $b64 = [Convert]::ToBase64String($bytes)
    $blobRes = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/blobs" -Method "Post" -BodyObj @{
        content  = $b64
        encoding = "base64"
    }
    $treeItems.Add([ordered]@{
        path = $relPath
        mode = "100644"
        type = "blob"
        sha  = $blobRes.sha
    })
}

$newTree = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/trees" -Method "Post" -BodyObj @{
    tree = $treeItems
}

if ($newTree.sha -ne $baseTreeSha) {
    $newCommit = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/commits" -Method "Post" -BodyObj @{
        message = "feat(portal): deploy e-biz실 데이터랩 to https://kcar-ebiz.github.io/ ($TodayDate)"
        tree    = $newTree.sha
        parents = @($baseCommitSha)
    }
    $null = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/main" -Method "Patch" -BodyObj @{
        sha   = $newCommit.sha
        force = $false
    }
    Write-Host "  -> Committed portal files ($($newCommit.sha.Substring(0,7)))." -ForegroundColor Green
} else {
    Write-Host "  -> Portal tree is already up to date ($($baseCommitSha.Substring(0,7)))." -ForegroundColor Green
}

# 3. Verify & Trigger GitHub Pages deployment
Write-Host "[4/4] Verifying GitHub Pages deployment (https://kcar-ebiz.github.io/) ..." -ForegroundColor Cyan
$pagesEnabled = $false
try {
    $pagesInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/pages" -Headers $headers -Method Get
    $pagesEnabled = $true
} catch {
    $pagesEnabled = $false
}

if (-not $pagesEnabled) {
    try {
        $pagesInfo = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/pages" -Method "Post" -BodyObj @{
            source = @{
                branch = "main"
                path   = "/"
            }
        }
        Write-Host "  -> Enabled GitHub Pages!" -ForegroundColor Green
    } catch {
        Write-Host "  -> GitHub Pages auto-enabled for root repo." -ForegroundColor Cyan
    }
}

try {
    $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/pages/builds" -Headers $headers -Method Post
    Write-Host "  -> Triggered GitHub Pages cloud rebuild!" -ForegroundColor Green
} catch {}

$encodedLab = [Uri]::EscapeDataString($LabFolderName)
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " e-biz실 데이터랩 공식 단축 도메인 배포 완료!" -ForegroundColor Green
Write-Host " 메인 포털 URL   : https://kcar-ebiz.github.io/" -ForegroundColor Yellow
Write-Host " 보증 개선 URL   : https://kcar-ebiz.github.io/warranty/" -ForegroundColor Yellow
Write-Host " eBiz 연구실 URL : https://kcar-ebiz.github.io/$encodedLab/" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green
