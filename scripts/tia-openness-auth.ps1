<#
.SYNOPSIS
  TIA Portal Openness 授权管理：预授权 exe、清理失效条目、关闭/开启安全确认弹窗。

.DESCRIPTION
  Siemens Openness 每次连接 TIA Portal 时校验调用方 exe 的 SHA256 是否在
  HKLM\SOFTWARE\Siemens\Automation\Openness\AllowList\<exe>\Entry (N) 中。
  重新编译 exe -> 哈希变化 -> 弹窗要求重新授权，旧条目成为死条目。

  Action:
    status   报告授权状态、弹窗开关、死条目数量
    grant    预授权一个 exe（按当前哈希写入 AllowList）
    prune    删除指向不存在文件或旧哈希的死条目
    insecure 设置 NonSecureOpennessAccess（-Popup off 关闭弹窗 / -Popup on 恢复弹窗）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tia-openness-auth.ps1 -Action status

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tia-openness-auth.ps1 -Action grant -ExePath "D:\build\MyApp.exe"
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("status", "grant", "prune", "insecure")]
    [string] $Action,

    [string] $ExePath,

    [ValidateSet("off", "on")]
    [string] $Popup = "off",

    [string] $Version,

    [switch] $DryRun
)

$ErrorActionPreference = "Stop"

$OPENNESS_ROOT = "HKLM:\SOFTWARE\Siemens\Automation\Openness"
$ALLOWLIST = Join-Path $OPENNESS_ROOT "AllowList"

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExeFingerprint {
    param([string] $Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $fi = Get-Item -LiteralPath $full
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($full)
    try { $hash = [Convert]::ToBase64String($sha.ComputeHash($fs)) }
    finally { $fs.Close(); $sha.Dispose() }
    [pscustomobject]@{
        Path = $full
        Name = $fi.Name
        Hash = $hash
        DateModified = $fi.LastWriteTimeUtc.ToString(
            "yyyy/M/d HH:mm:ss.fff", [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-AllowListEntries {
    if (-not (Test-Path -LiteralPath $ALLOWLIST)) { return @() }
    $out = @()
    foreach ($exeKey in Get-ChildItem -LiteralPath $ALLOWLIST -ErrorAction SilentlyContinue) {
        foreach ($entryKey in Get-ChildItem -LiteralPath $exeKey.PSPath -ErrorAction SilentlyContinue) {
            $v = Get-ItemProperty -LiteralPath $entryKey.PSPath -ErrorAction SilentlyContinue
            $path = $v.Path
            $state = "missing"
            if ($path -and (Test-Path -LiteralPath $path)) {
                try {
                    $cur = Get-ExeFingerprint -Path $path
                    $state = if ($cur.Hash -eq $v.FileHash) { "valid" } else { "stale" }
                } catch { $state = "unreadable" }
            }
            $out += [pscustomobject]@{
                ExeKey       = $exeKey.PSChildName
                EntryKey     = $entryKey.PSChildName
                Path         = $path
                FileHash     = $v.FileHash
                DateModified = $v.DateModified
                State        = $state
            }
        }
    }
    return $out
}
function Get-OpennessVersions {
    if (-not (Test-Path -LiteralPath $OPENNESS_ROOT)) { return @() }
    Get-ChildItem -LiteralPath $OPENNESS_ROOT -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d+\.\d+$' } |
        Select-Object -ExpandProperty PSChildName |
        Sort-Object { [version]$_ } -Descending
}

function Get-InsecureState {
    param([string] $Ver)
    $key = Join-Path $OPENNESS_ROOT $Ver
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $v = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).NonSecureOpennessAccess
    if ($null -eq $v) { return $null }
    return [int]$v
}

function Invoke-Status {
    Write-Output "=== TIA Portal Openness 授权状态 ==="
    Write-Output ("管理员权限 : " + (Test-IsAdmin))
    Write-Output ""
    Write-Output "--- 各版本 NonSecureOpennessAccess（1 = 不弹安全确认）---"
    $versions = @(Get-OpennessVersions)
    if ($versions.Count -eq 0) {
        Write-Output "  未发现 Openness 版本注册表项"
    } else {
        foreach ($v in $versions) {
            $state = Get-InsecureState -Ver $v
            $label = switch ($state) {
                1 { "1  (已关闭弹窗)" }
                0 { "0  (弹窗开启)" }
                default { "(未设置 -> 弹窗开启)" }
            }
            Write-Output ("  {0,-6} {1}" -f $v, $label)
        }
    }
    Write-Output ""
    Write-Output "--- AllowList 条目 ---"
    $entries = @(Get-AllowListEntries)
    if ($entries.Count -eq 0) {
        Write-Output "  (空)"
    } else {
        foreach ($g in ($entries | Group-Object ExeKey | Sort-Object Name)) {
            $valid = @($g.Group | Where-Object State -eq "valid").Count
            $stale = @($g.Group | Where-Object State -eq "stale").Count
            $missing = @($g.Group | Where-Object State -eq "missing").Count
            Write-Output ("  {0}: 共 {1} 条 | 有效 {2} | 旧哈希 {3} | 文件已删 {4}" -f $g.Name, $g.Count, $valid, $stale, $missing)
        }
        $dead = @($entries | Where-Object { $_.State -ne "valid" }).Count
        Write-Output ""
        Write-Output "  合计 $($entries.Count) 条，可清理 $dead 条"
    }
}

function Invoke-Grant {
    if (-not $ExePath) { throw "grant 需要 -ExePath" }
    if (-not (Test-IsAdmin)) { throw "写 HKLM 需要管理员权限，请以管理员身份打开 PowerShell 后重跑。" }
    $fp = Get-ExeFingerprint -Path $ExePath
    Write-Output "目标 exe : $($fp.Path)"
    Write-Output "SHA256   : $($fp.Hash)"
    Write-Output "修改时间 : $($fp.DateModified) (UTC)"
    Write-Output ""
    $exeKey = Join-Path $ALLOWLIST $fp.Name
    if (-not (Test-Path -LiteralPath $exeKey)) {
        if ($DryRun) { Write-Output "[DryRun] 将创建键 $exeKey"; return }
        New-Item -Path $exeKey -Force | Out-Null
    }
    $same = @(Get-ChildItem -LiteralPath $exeKey -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty $_.PSPath).FileHash -eq $fp.Hash })
    if ($same.Count -gt 0) {
        Write-Output "已存在相同哈希条目: $($same[0].PSChildName)，无需重复写入"
        return
    }
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $exeKey ("Entry (" + $n + ")"))) { $n++ }
    $name = "Entry ($n)"
    if ($DryRun) { Write-Output "[DryRun] 将写入 $exeKey\$name"; return }
    $target = Join-Path $exeKey $name
    New-Item -Path $target -Force | Out-Null
    New-ItemProperty -LiteralPath $target -Name "Path" -Value $fp.Path -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $target -Name "DateModified" -Value $fp.DateModified -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $target -Name "FileHash" -Value $fp.Hash -PropertyType String -Force | Out-Null
    $rb = Get-ItemProperty -LiteralPath $target
    $ok = ($rb.Path -eq $fp.Path -and $rb.FileHash -eq $fp.Hash -and $rb.DateModified -eq $fp.DateModified)
    Write-Output "已写入 $target"
    Write-Output "回读校验: $(if ($ok) { 'PASS' } else { 'FAIL' })"
    if (-not $ok) { throw "回读校验失败" }
}
function Invoke-Prune {
    if (-not (Test-IsAdmin)) { throw "写 HKLM 需要管理员权限，请以管理员身份打开 PowerShell 后重跑。" }
    $entries = @(Get-AllowListEntries)
    $dead = @($entries | Where-Object { $_.State -ne "valid" })
    Write-Output "总条目 $($entries.Count)，可清理 $($dead.Count)"
    if ($dead.Count -eq 0) { Write-Output "无需清理"; return }
    if ($DryRun) {
        foreach ($d in $dead) { Write-Output ("[DryRun] 删除 " + $d.ExeKey + "\" + $d.EntryKey + "  (" + $d.State + ")") }
        return
    }
    $removed = 0
    foreach ($d in $dead) {
        $key = Join-Path (Join-Path $ALLOWLIST $d.ExeKey) $d.EntryKey
        Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $key)) { $removed++ }
    }
    Write-Output "已删除 $removed 条"
    foreach ($exeKey in Get-ChildItem -LiteralPath $ALLOWLIST -ErrorAction SilentlyContinue) {
        if (@(Get-ChildItem $exeKey.PSPath -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $exeKey.PSPath -Force -ErrorAction SilentlyContinue
            Write-Output "已删除空键 $($exeKey.PSChildName)"
        }
    }
}

function Invoke-Insecure {
    if (-not (Test-IsAdmin)) { throw "写 HKLM 需要管理员权限，请以管理员身份打开 PowerShell 后重跑。" }
    $ver = $Version
    if (-not $ver) {
        $versions = @(Get-OpennessVersions)
        if ($versions.Count -eq 0) { throw "未发现任何 Openness 版本注册表项" }
        $ver = $versions[0]
        Write-Output "未指定 -Version，自动选择最高版本: $ver"
    }
    $key = Join-Path $OPENNESS_ROOT $ver
    if (-not (Test-Path -LiteralPath $key)) { throw "版本键不存在: $key" }
    $value = if ($Popup -eq "off") { 1 } else { 0 }
    if ($DryRun) { Write-Output "[DryRun] 将设置 $key\NonSecureOpennessAccess = $value"; return }
    New-ItemProperty -LiteralPath $key -Name "NonSecureOpennessAccess" -Value $value -PropertyType DWord -Force | Out-Null
    $rb = (Get-ItemProperty -LiteralPath $key).NonSecureOpennessAccess
    Write-Output "已设置 $key\NonSecureOpennessAccess = $rb"
    if ($Popup -eq "off") {
        Write-Output "注意：此后 TIA Portal 对所有 Openness 客户端都不再弹安全确认，"
        Write-Output "      仅在你信任本机全部 Openness 调用方时使用。恢复用 -Enable:$false"
    } else {
        Write-Output "已恢复安全确认弹窗。"
    }
}

switch ($Action) {
    "status"   { Invoke-Status }
    "grant"    { Invoke-Grant }
    "prune"    { Invoke-Prune }
    "insecure" { Invoke-Insecure }
}