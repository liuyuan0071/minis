# ============================================================================
# CI Test Loop — 阶段3 自动化闭环
#   1. git push 触发 GitHub Actions 构建
#   2. 轮询 gh run 直到完成
#   3. gh run download 下载 APK
#   4. adb install -r 安装到 MuMu (127.0.0.1:16384)
#   5. adb 启动 App
#   6. logcat 冒烟断言（无 FATAL / PRootKernel booted / PTY started）
#   7. 输出 PASS / FAIL（可被外部循环调用，失败时返回退出码 1）
#
# 用法（在仓库根目录）:
#   powershell -File scripts/ci_test_loop.ps1 -Repo liuyuan0071/minis
#   powershell -File scripts/ci_test_loop.ps1 -AdbDevice 127.0.0.1:16384 -SkipPush
#
# 说明:
#   - 不执行任何删除操作（用户环境拦截 Remove-Item，见 trae）
#   - adb 已连接 MuMu；若未连接会自动 connect
#   - 签名稳定后 install -r 可直接覆盖，无需卸载
# ============================================================================
param(
    [string]$Repo = "liuyuan0071/minis",
    [string]$Gh = "C:\Program Files\GitHub CLI\gh.exe",
    [string]$Adb = "C:\tools\android\platform-tools\adb.exe",
    [string]$AdbDevice = "127.0.0.1:16384",
    [string]$OutDir = "raw\ci-download",
    [switch]$SkipPush,
    [int]$PollSeconds = 15,
    [int]$MaxWaitMinutes = 25
)

$ErrorActionPreference = "Stop"
$workspace = (Get-Location).Path

Write-Host "== CI Test Loop: repo=$Repo device=$AdbDevice ==" -ForegroundColor Cyan

# --- 0. 确保 adb 连接 ---
if (-not (Test-Path $Adb)) { Write-Error "adb not found: $Adb"; exit 1 }
$devices = & $Adb devices
if ($devices -notmatch [regex]::Escape($AdbDevice)) {
    Write-Host "Connecting to $AdbDevice ..."
    & $Adb connect $AdbDevice | Out-Host
    Start-Sleep -Seconds 3
}

# --- 1. push（可选跳过） ---
if (-not $SkipPush) {
    Write-Host "`n== Step 1/6: git push ==" -ForegroundColor Green
    git add -A
    $message = if ($env:CI_COMMIT_MESSAGE) { $env:CI_COMMIT_MESSAGE } else { "阶段3: CI 自动构建触发" }
    git commit -m $message 2>$null | Out-Null   # 无改动时 commit 失败可忽略
    git push github master 2>&1 | Out-Host
}

# --- 2. 轮询最新的 push run ---
Write-Host "`n== Step 2/6: 轮询 GitHub Actions run ==" -ForegroundColor Green
$runId = ""
for ($i = 0; $i -lt [math]::Ceiling($MaxWaitMinutes * 60 / $PollSeconds); $i++) {
    $runs = & $Gh run list --repo $Repo --limit 1 --json databaseId,status,conclusion,headSha,event 2>$null | ConvertFrom-Json
    if ($runs -and $runs.Count -gt 0) {
        $runId = $runs[0].databaseId
        $status = $runs[0].status
        $conclusion = $runs[0].conclusion
        $event = $runs[0].event
        Write-Host ("  run #{0} status={1} conclusion={2} event={3}" -f $runId, $status, ($conclusion -join ""), $event)
        if ($status -eq "completed") {
            if ($conclusion -eq "success" -and $event -eq "push") { break }
            if ($event -eq "push") {
                # 最新 push run 失败 → 中止
                Write-Host "  FAIL: 最新 push run #$runId conclusion=$conclusion" -ForegroundColor Red
                exit 1
            }
        }
    } else {
        Write-Host "  (no run yet, waiting...)"
    }
    Start-Sleep -Seconds $PollSeconds
}
if (-not $runId) { Write-Error "Timed out waiting for a run"; exit 1 }
if ((& $Gh run view $runId --repo $Repo --json status --jq '.status' 2>$null) -ne "completed") {
    Write-Host "  FAIL: run #$runId did not complete in $MaxWaitMinutes min" -ForegroundColor Red
    exit 1
}

# --- 3. 下载 APK ---
Write-Host "`n== Step 3/6: 下载 APK (run #$runId) ==" -ForegroundColor Green
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
& $Gh run download $runId --repo $Repo --dir $OutDir 2>&1 | Out-Host
$apk = Get-ChildItem $OutDir -Recurse -Filter *.apk | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apk) { Write-Error "No APK found in $OutDir"; exit 1 }
Write-Host "  APK: $($apk.FullName) ($([math]::Round($apk.Length/1MB,1)) MB)" -ForegroundColor Yellow

# --- 4. 安装到 MuMu（签名稳定 → install -r 覆盖） ---
Write-Host "`n== Step 4/6: adb install -r ==" -ForegroundColor Green
$installOut = & $Adb -s $AdbDevice install -r $apk.FullName 2>&1 | Out-String
Write-Host $installOut
if ($installOut -match "INSTALL_FAILED") {
    # 签名不匹配等：退而求其次卸载重装（MuMu 上无用户数据损失，可接受）
    Write-Host "  install -r failed ($($installOut.Trim())), falling back to uninstall+install" -ForegroundColor Yellow
    & $Adb -s $AdbDevice uninstall com.openminis.app.workhelper | Out-Host
    & $Adb -s $AdbDevice install $apk.FullName 2>&1 | Out-Host
}

# --- 5. 启动 App ---
Write-Host "`n== Step 5/6: 启动 App ==" -ForegroundColor Green
& $Adb -s $AdbDevice logcat -c 2>$null
& $Adb -s $AdbDevice shell am force-stop com.openminis.app.workhelper 2>$null
Start-Sleep -Seconds 2
& $Adb -s $AdbDevice shell am start -n com.openminis.app.workhelper/com.openminis.app.MainActivityIconAuto | Out-Host
Start-Sleep -Seconds 15

# --- 6. 冒烟断言 ---
Write-Host "`n== Step 6/6: logcat 冒烟断言 ==" -ForegroundColor Green
$log = & $Adb -s $AdbDevice logcat -d 2>&1 | Out-String

$fatal = [regex]::Matches($log, "FATAL EXCEPTION|AndroidRuntime.*FATAL|Process: com\.openminis\.app\.workhelper").Count
$prootBoot = [regex]::Matches($log, "PRoot kernel booted").Count
$ptyStart = [regex]::Matches($log, "PTY started|TerminalSession: PTY started").Count
$prootError = [regex]::Matches($log, "proot error|PRoot error|ERROR.*proot").Count
$nativeLibs = [regex]::Matches($log, "library_path=.*lib/x86_64|nativeLibraryDir=.*x86_64").Count

Write-Host "  FATAL crashes : $fatal" -ForegroundColor $(if ($fatal -eq 0) {"Green"} else {"Red"})
Write-Host "  PRoot booted  : $prootBoot" -ForegroundColor $(if ($prootBoot -gt 0) {"Green"} else {"Red"})
Write-Host "  PTY started   : $ptyStart" -ForegroundColor $(if ($ptyStart -gt 0) {"Green"} else {"Yellow"})
Write-Host "  proot errors  : $prootError" -ForegroundColor $(if ($prootError -eq 0) {"Green"} else {"Red"})
Write-Host "  x86_64 native : $nativeLibs" -ForegroundColor $(if ($nativeLibs -gt 0) {"Green"} else {"Yellow"})

if ($fatal -eq 0 -and $prootBoot -gt 0 -and $prootError -eq 0) {
    Write-Host "`n== RESULT: PASS ==" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n== RESULT: FAIL ==" -ForegroundColor Red
    exit 1
}
