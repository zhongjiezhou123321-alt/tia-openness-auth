<#
.SYNOPSIS
  TIA Portal Openness 授权弹窗自动点击器。

.DESCRIPTION
  监听 Openness 授权对话框，自动点击「是」（仅授权本次，不写白名单，
  不累积 AllowList 历史记录 —— 调试期 exe 每次重编译哈希都会变）。

  实现要点：
    1. Win32 EnumWindows 找到标题含 Openness 的可见顶层窗口；
    2. UI Automation 的 AutomationElement.FromHandle(hwnd) 直接取元素树
       （模态子窗口不在 RootElement 子树里，必须用 FromHandle）；
    3. 优先点「是/Yes」（仅本次授权）；不点「全部确定」（避免堆积过期白名单）；
    4. InvokePattern 触发；失败退回 Win32 BM_CLICK；
    5. UIA 拿不到按钮时按几何位置兜底。

  动作：list 列出弹窗与按钮 / once 处理一次 / watch 持续监听

.EXAMPLE
  pwsh -File tia-openness-autoclick.ps1 -Action watch -Minutes 480
#>
param(
    [ValidateSet("list", "once", "watch", "prune")]
    [string] $Action = "watch",
    [int] $IntervalMs = 400,
    [int] $Minutes = 0,
    [switch] $DryRun,
    [switch] $NoGeometricFallback,
    [switch] $PruneOnExit,
    [string] $LogPath
)

$ErrorActionPreference = "Continue"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not $LogPath) { $LogPath = Join-Path $env:TEMP "tia-openness-autoclick.log" }

function Write-Log {
    param([string] $Msg)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Msg
    try { Write-Host $line } catch { }
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs, [System.Text.UTF8Encoding]::new($false))
        $sw.WriteLine($line)
        $sw.Flush(); $sw.Close(); $fs.Close()
    } catch { }
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class TiaWin {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public class WinInfo {
        public IntPtr Handle;
        public uint Pid;
        public string Title = "";
        public string ClassName = "";
        public int Left, Top, Right, Bottom;
    }

    static string TextOf(IntPtr h) {
        var sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, 1024);
        return sb.ToString();
    }

    public static List<WinInfo> FindOpennessDialogs() {
        var res = new List<WinInfo>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            string title = TextOf(h);
            if (title.IndexOf("Openness", StringComparison.OrdinalIgnoreCase) < 0) return true;
            var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            RECT r; GetWindowRect(h, out r);
            res.Add(new WinInfo {
                Handle = h, Pid = pid, Title = title, ClassName = cn.ToString(),
                Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom
            });
            return true;
        }, IntPtr.Zero);
        return res;
    }

    public static List<WinInfo> ChildButtons(IntPtr parent) {
        var res = new List<WinInfo>();
        EnumChildWindows(parent, (h, l) => {
            var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
            if (cn.ToString().IndexOf("BUTTON", StringComparison.OrdinalIgnoreCase) < 0) return true;
            if (!IsWindowVisible(h)) return true;
            RECT r; GetWindowRect(h, out r);
            res.Add(new WinInfo {
                Handle = h, ClassName = cn.ToString(), Title = TextOf(h),
                Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom
            });
            return true;
        }, IntPtr.Zero);
        return res;
    }

    public static bool ClickWin32(IntPtr h) {
        try { SendMessageW(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); return true; }
        catch { return false; }
    }
}
'@ -ErrorAction SilentlyContinue

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

# 从 hwnd 直接取元素树，并遍历收集所有 Button
function Get-UiaButtons {
    param([IntPtr] $Hwnd)
    $out = @()
    try {
        $win = $AE::FromHandle($Hwnd)
    } catch {
        Write-Log ("  FromHandle 失败: " + $_.Exception.Message)
        return $out
    }
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        $found = $win.FindAll($TS::Descendants, $cond)
        foreach ($b in $found) {
            try {
                $r = $b.Current.BoundingRectangle
                $out += [pscustomobject]@{
                    Element = $b
                    Name = $b.Current.Name
                    AutomationId = $b.Current.AutomationId
                    Enabled = $b.Current.IsEnabled
                    X = [int]$r.X
                    Y = [int]$r.Y
                    W = [int]$r.Width
                    H = [int]$r.Height
                }
            } catch { }
        }
    } catch { }
    return $out
}

function Select-TargetButton {
    param($Buttons)
    if (-not $Buttons -or $Buttons.Count -eq 0) { return $null }
    foreach ($b in $Buttons) { if ($b.Name -match "全部|Always|所有") { return $b } }
    foreach ($b in $Buttons) { if ($b.Name -match "^是$|^Yes$|^允许$|^Allow$") { return $b } }
    foreach ($b in $Buttons) { if ($b.Name -match "确定|OK|确认") { return $b } }
    return $null
}

function Invoke-UiaButton {
    param($Button)
    try {
        $p = $Button.Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke()
        return $true
    } catch { return $false }
}

# 兜底：按几何位置点击。WinForms 对话框按钮从左到右是「是 / 全部确定 / 否」。
# 目标 = 最左那个（是）：仅授权本次，不写 AllowList。
function Invoke-GeometricFallback {
    param($WinInfo)
    # 只点最左的「是」：仅授权本次，不写 AllowList。
    # 调试期 exe 每次重编译哈希都变，写白名单只会堆积立即过期的历史记录。
    $btns = @([TiaWin]::ChildButtons($WinInfo.Handle))
    if ($btns.Count -lt 2) { Write-Log ("  几何兜底跳过：按钮数 " + $btns.Count); return $false }
    $sorted = @($btns | Sort-Object Left)
    $target = $sorted[0]
    Write-Log ("  几何兜底：选中最左按钮(是) hwnd=" + $target.Handle + " pos=(" + $target.Left + "," + $target.Top + ") 共" + $sorted.Count + "个")
    if ($DryRun) { Write-Log "  [DryRun] 不点击"; return $true }
    return [TiaWin]::ClickWin32($target.Handle)
}

function Show-DialogDetail {
    param($WinInfo)
    Write-Log ("  窗口: pid=" + $WinInfo.Pid + " class=" + $WinInfo.ClassName + " title=" + $WinInfo.Title)
    Write-Log ("  矩形: (" + $WinInfo.Left + "," + $WinInfo.Top + ")-(" + $WinInfo.Right + "," + $WinInfo.Bottom + ")")
    $btns = @(Get-UiaButtons -Hwnd $WinInfo.Handle)
    Write-Log ("  UIA 按钮 " + $btns.Count + " 个：")
    foreach ($b in $btns) {
        Write-Log ("    - [" + $b.Name + "] id=" + $b.AutomationId + " enabled=" + $b.Enabled + " rect=(" + $b.X + "," + $b.Y + "," + $b.W + "x" + $b.H + ")")
    }
    $raw = @([TiaWin]::ChildButtons($WinInfo.Handle))
    Write-Log ("  Win32 按钮 " + $raw.Count + " 个：")
    foreach ($b in $raw) {
        Write-Log ("    - hwnd=" + $b.Handle + " text=[" + $b.Title + "] rect=(" + $b.Left + "," + $b.Top + ")")
    }
}

# 白名单条目快照：用于判断点击是否真的「授权并保存」
#   点「全部确定」-> 新增 Entry；点「是」-> 不新增。
#   两者都会让弹窗消失，无法从窗口判断，只能靠白名单差值。
function Get-AllowListSnapshot {
    $snap = @{}
    $root = "HKLM:\SOFTWARE\Siemens\Automation\Openness\AllowList"
    if (-not (Test-Path $root)) { return $snap }
    foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        $snap[$k.PSChildName] = @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue).Count
    }
    return $snap
}

function Compare-AllowListSnapshot {
    param($Before, $After)
    $changes = @()
    $allKeys = @($Before.Keys) + @($After.Keys) | Select-Object -Unique
    foreach ($k in $allKeys) {
        $b = if ($Before.ContainsKey($k)) { $Before[$k] } else { 0 }
        $a = if ($After.ContainsKey($k)) { $After[$k] } else { 0 }
        if ($a -ne $b) { $changes += ("{0}: {1} -> {2}" -f $k, $b, $a) }
    }
    return $changes
}

function Invoke-HandleOne {
    param($WinInfo, [string] $Tag = "")
    Write-Log ("检测到 Openness 弹窗 " + $Tag + "：" + $WinInfo.Title)
    Write-Log ("  窗口 hwnd=" + $WinInfo.Handle + " pid=" + $WinInfo.Pid + " rect=(" + $WinInfo.Left + "," + $WinInfo.Top + ")-(" + $WinInfo.Right + "," + $WinInfo.Bottom + ")")
    $btns = @(Get-UiaButtons -Hwnd $WinInfo.Handle)
    Write-Log ("  UIA 按钮 " + $btns.Count + " 个")
    if ($btns.Count -gt 0) {
        foreach ($b in $btns) { Write-Log ("    - [" + $b.Name + "] enabled=" + $b.Enabled) }
        $target = Select-TargetButton -Buttons $btns
        if ($null -ne $target) {
            if ($DryRun) { Write-Log ("  [DryRun] 将点击「" + $target.Name + "」"); return $true }
            $ok = Invoke-UiaButton -Button $target
            Write-Log ("  点击「" + $target.Name + "」 -> " + $(if ($ok) { "已触发" } else { "失败" }))
            if ($ok) { return $true }
        } else {
            Write-Log "  UIA 按钮里没有匹配项"
        }
    }
    # 记录全部 Win32 按钮的几何证据，便于事后核对到底点了哪个
    $raw = @([TiaWin]::ChildButtons($WinInfo.Handle))
    Write-Log ("  Win32 按钮 " + $raw.Count + " 个（文字均读不出属正常）：")
    foreach ($b in $raw) { Write-Log ("    - hwnd=" + $b.Handle + " x=" + $b.Left + " y=" + $b.Top + " w=" + ($b.Right - $b.Left) + " h=" + ($b.Bottom - $b.Top)) }
    if ($NoGeometricFallback) { Write-Log "  已禁用几何兜底，放弃"; return $false }
    Write-Log "  UIA 路径未成功，尝试几何兜底…"
    $snapBefore = Get-AllowListSnapshot
    $ok = Invoke-GeometricFallback -WinInfo $WinInfo
    if (-not $DryRun) {
        Start-Sleep -Milliseconds 1200
        $snapAfter = Get-AllowListSnapshot
        $diff = @(Compare-AllowListSnapshot -Before $snapBefore -After $snapAfter)
        if ($diff.Count -gt 0) {
            Write-Log ("  [注意] 白名单增长了 —— 本想只点「是」，实际可能点到了「全部确定」：" + ($diff -join "; "))
        } else {
            Write-Log "  [OK] 白名单未增长 —— 符合预期（点的是「是」，只授权本次）"
        }
    }
    return $ok
}
function Get-Dialogs { @([TiaWin]::FindOpennessDialogs()) }

# ---------- 白名单清理：删掉哈希已过期的条目 ----------
# 背景：每次 TIA 弹窗被授权都会追加一条 Entry，但旧哈希的条目不会被删。
#       实测 30 分钟内 3 次授权让条目从 4 条涨到 8 条。
# 安全边界：只删「该 exe 仍存在、但哈希对不上」的条目，绝不删当前有效条目。
function Invoke-PruneAllowList {
    param([switch] $Apply)
    $root = "HKLM:\SOFTWARE\Siemens\Automation\Openness\AllowList"
    if (-not (Test-Path $root)) { Write-Log "AllowList 注册表项不存在"; return }
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    Write-Log ("清扫白名单（管理员=" + $isAdmin + "，模式=" + $(if ($Apply) { "执行" } else { "预演" }) + "）")
    $totalRemoved = 0
    foreach ($exeKey in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        $exeName = $exeKey.PSChildName
        # 找到该 exe 的真实路径（取任意一条 Entry 的 Path）
        $realPath = $null
        foreach ($e in Get-ChildItem $exeKey.PSPath -ErrorAction SilentlyContinue) {
            $v = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
            if ($v.Path -and (Test-Path -LiteralPath $v.Path)) { $realPath = $v.Path; break }
        }
        if (-not $realPath) { Write-Log ("  " + $exeName + "：找不到现存 exe，跳过（不动）"); continue }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $fs = [System.IO.File]::OpenRead($realPath)
            $curHash = [Convert]::ToBase64String($sha.ComputeHash($fs))
        } finally { if ($fs) { $fs.Close() }; $sha.Dispose() }
        $removed = 0
        foreach ($e in Get-ChildItem $exeKey.PSPath -ErrorAction SilentlyContinue) {
            $v = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
            if ($v.FileHash -ne $curHash) {
                if ($Apply -and $isAdmin) {
                    Remove-Item -LiteralPath $e.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $e.PSPath)) { $removed++ }
                } else { $removed++ }
            }
        }
        if ($removed -gt 0) { Write-Log ("  " + $exeName + "：过期 " + $removed + " 条" + $(if ($Apply -and $isAdmin) { " 已删除" } else { "（未删）" })) }
        $totalRemoved += $removed
        # 若已删空则移除该 exe 键
        if ($Apply -and $isAdmin) {
            $left = @(Get-ChildItem $exeKey.PSPath -ErrorAction SilentlyContinue).Count
            if ($left -eq 0) { Remove-Item -LiteralPath $exeKey.PSPath -Recurse -Force -ErrorAction SilentlyContinue; Write-Log ("  已移除空键 " + $exeName) }
        }
    }
    Write-Log ("清扫完成：共 " + $totalRemoved + " 条过期" + $(if (-not ($Apply -and $isAdmin)) { "（需管理员并加 -Apply 才真删）" } else { "" }))
}

switch ($Action) {
    "list" {
        Write-Log "=== 扫描 Openness 弹窗 ==="
        $ds = @(Get-Dialogs)
        if ($ds.Count -eq 0) { Write-Log "未发现 Openness 弹窗" }
        foreach ($d in $ds) { Show-DialogDetail -WinInfo $d }
        Write-Log ("=== 共 " + $ds.Count + " 个 ===")
    }
    "once" {
        $ds = @(Get-Dialogs)
        if ($ds.Count -eq 0) { Write-Log "未发现 Openness 弹窗"; break }
        $i = 0
        foreach ($d in $ds) { $i++; Invoke-HandleOne -WinInfo $d -Tag ("#" + $i) | Out-Null }
    }
    "prune" {
        Invoke-PruneAllowList -Apply:(-not $DryRun)
    }
    "watch" {
        $end = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { [DateTime]::MaxValue }
        Write-Log ("=== 监听开始（间隔 " + $IntervalMs + "ms，上限 " + $(if ($Minutes -gt 0) { $Minutes.ToString() + " 分钟" } else { "不限" }) + "）===")
        $handled = @{}
        $detected = 0
        $clicked = 0
        while ((Get-Date) -lt $end) {
            foreach ($d in @(Get-Dialogs)) {
                $key = $d.Handle.ToInt64()
                if ($handled.ContainsKey($key)) { continue }
                $detected++
                $ok = Invoke-HandleOne -WinInfo $d -Tag ("#" + $detected)
                if ($ok) { $handled[$key] = $true; $clicked++ }
            }
            Start-Sleep -Milliseconds $IntervalMs
        }
        Write-Log ("=== 监听结束：检测到 " + $detected + " 个弹窗，成功点击 " + $clicked + " 个 ===")
        if ($PruneOnExit) { Invoke-PruneAllowList -Apply:(-not $DryRun) }
    }
}