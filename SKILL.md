---
name: tia-openness-auth
description: 管理西门子 TIA Portal Openness 的访问授权：查看/预授权允许白名单（AllowList）、清理失效条目、关闭或恢复安全确认弹窗（NonSecureOpennessAccess）。当用户遇到「Openness 每次连接博途都弹窗要授权」「重新编译后又要重新授权」「Openness 访问被拒绝」「想让 Openness 免确认直接连」时使用。
argument-hint: "[status | grant -ExePath <exe> | prune | insecure -Popup off|on] [--dry-run]"
---

# TIA Portal Openness 授权管理

## 背景：Openness 到底在校验什么

每次进程连接 TIA Portal，Openness 会做两道检查，任一道不过就弹窗或拒绝：

| 检查 | 位置 | 说明 |
|---|---|---|
| **用户组** | Windows 本地组 `Siemens TIA Openness` | 当前用户必须在组内，改完要注销重登 |
| **程序指纹** | `HKLM\SOFTWARE\Siemens\Automation\Openness\AllowList\<exe名>\Entry (N)` | 校验调用方 exe 的 SHA256 |

每条 Entry 有三个字符串值（都是 `REG_SZ`）：

```
Path         = exe 的完整路径
DateModified = exe 最后修改时间的 UTC 字符串，格式 yyyy/M/d HH:mm:ss.fff
FileHash     = Base64(SHA256(exe 文件字节))
```

**这就是「每次重新编译都要重新授权」的根因**：重新编译 → exe 字节变了 → SHA256 变 → 与白名单里的记录对不上 → 弹窗。旧条目不会自动删除，于是越积越多（本机实测 228 条里 226 条已失效）。

## 另一条路：关闭确认弹窗

注册表 `HKLM\SOFTWARE\Siemens\Automation\Openness\<版本>\NonSecureOpennessAccess`：

- `1` = 不弹安全确认（任何客户端直接连）
- `0` 或不存在 = 弹窗开启

⚠️ 这是**全局**开关，关掉后本机任何程序调 Openness 都不再征求你同意。只在完全信任本机环境时用。

## 工具

`scripts/tia-openness-auth.ps1`，四个动作：

| 动作 | 作用 | 需要管理员 |
|---|---|---|
| `status` | 报告各版本弹窗开关 + 白名单有效/失效统计 | 否 |
| `grant -ExePath <exe>` | 按当前哈希预授权一个 exe | **是** |
| `prune` | 删除失效条目（文件已删或哈希过期） | **是** |
| `insecure -Popup off\|on` | 关闭 / 恢复安全确认弹窗 | **是** |

加 `-DryRun` 只打印将要做什么，不落盘。

## 用法

```powershell
$skill = "<安装路径>\scripts\tia-openness-auth.ps1"

# 1. 先看现状（不需要管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File $skill -Action status

# 2. 预授权一个 exe（管理员 PowerShell）
powershell -NoProfile -ExecutionPolicy Bypass -File $skill -Action grant -ExePath "D:\build\MyApp.exe"

# 3. 清理失效条目（管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File $skill -Action prune

# 4. 关闭弹窗（管理员，谨慎）
powershell -NoProfile -ExecutionPolicy Bypass -File $skill -Action insecure -Popup off
# 恢复
powershell -NoProfile -ExecutionPolicy Bypass -File $skill -Action insecure -Popup on
```

> 必须在**真实的 Windows PowerShell**（`powershell.exe`）里跑，不要在 pwsh 7 里直接 dot-source —— 5.1 的编码行为与注册表行为都更贴近 Openness 的实际校验环境。

## 什么时候用哪个

| 场景 | 用法 |
|---|---|
| 开发期反复编译，每次都弹窗 | `grant` 当前产物（每次编译后重跑一次），或临时 `insecure -Popup off` |
| 交付给客户，不想让客户点允许 | 交付前对最终 exe 跑一次 `grant`，把哈希写进白名单 |
| 白名单膨胀、排查授权问题 | `prune` 清理，再 `status` 确认 |
| CI/无人值守跑 Openness | `insecure -Popup off`（注意安全边界） |
| 只是想知道为什么不弹/为什么弹 | `status` |

## 关键事实（本机实测，2026-10-17）

- Openness 注册表版本项：`17.0`、`20.0`、`21.0`
- **`NonSecureOpennessAccess` 只在 `20.0` 下存在（=1）**；`21.0` 与 `17.0` 未设置 → **V21 仍会弹窗**
- 白名单现有 4 个 exe 名、228 条记录，其中 **226 条失效**（V21 那 70 条全部指向已删除的旧构建产物）
- `FileHash` 已用现存文件验证：**Base64(SHA256(文件字节))**，精确匹配
- `DateModified` 是 **UTC**（记录值比文件本地时间早 8 小时，本机为 Asia/Shanghai）
- V21 是模块化 Openness（`PublicAPI\V21\net48\Siemens.Engineering.Base.dll`），V16–V20 是单体 `Siemens.Engineering.dll`；**授权机制两者相同**


## 自动点击授权弹窗（已实测闭环）

`scripts/tia-openness-autoclick.ps1` —— 守护进程，发现 Openness 授权弹窗就自动点**「是」**（仅授权本次，**不写入白名单**）。

### 为什么需要它

为什么不点「全部确定」：调试期 exe 每次重编译哈希都变，写进白名单只会累积一堆立即过期的历史记录，反而让授权状态难以判断。点「是」放行本次即可，弹窗关掉、流程继续。

`grant` 预授权能防住「构建产物」的弹窗，但防不住：
- 别的进程（另一会话的测试）用不同 exe 调 Openness
- 正在运行的进程在授权前就发起连接

这时弹窗会**阻塞**调用方。自动点击是最后的兜底。

### 用法

```powershell
$ac = "<安装路径>\scripts\tia-openness-autoclick.ps1"

# 常驻守护（推荐：跑 8 小时，期间所有弹窗自动点）
pwsh -NoProfile -File $ac -Action watch -Minutes 480

# 看一眼当前有没有弹窗（不点击）
pwsh -NoProfile -File $ac -Action list

# 处理一次就退出
pwsh -NoProfile -File $ac -Action once

# 清理白名单里哈希过期的条目（需管理员）
pwsh -NoProfile -File $ac -Action prune

# 退出时顺便清理
pwsh -NoProfile -File $ac -Action watch -Minutes 480 -PruneOnExit
```

### 技术实现（为什么这样才work）

这个对话框有两个反常特性，导致常规办法全部失效：

| 常规做法 | 结果 | 原因 |
|---|---|---|
| UIA 从 RootElement 向下找 | **找不到** | 模态 WinForms 子窗口不在 RootElement 子树里 |
| `AutomationElement.FromHandle(hwnd)` | 找到窗口，但**按钮数 = 0** | 该对话框不提供 UIA 控件树 |
| Win32 `GetWindowText` 读按钮文字 | **全部返回空** | 按钮是自绘的，无 WM_GETTEXT |
| 按 class 匹配 BUTTON | 能用，但拿不到语义 | 6 个按钮先后出现，只能靠位置区分 |

**最终方案：Win32 枚举 + 几何定位**

```
EnumWindows 找 title 含 "Openness" 的可见窗口
  ↓
EnumChildWindows 拿所有 class 含 BUTTON 的子窗口
  ↓
按 x 坐标排序，取**最左**那个（= 「是」）
  ↓
SendMessage(hwnd, BM_CLICK)
```

### 实测证据（2026-10-17，30 分钟守护）

```
[11:25:21] 检测到弹窗 #1  hwnd=4653936  rect=(0,0)-(502,262)
  Win32 按钮 3 个：
    - hwnd=3214134 x=415 y=221 w=73 h=20   ← 否
    - hwnd=2231806 x=237 y=221 w=73 h=20   ← 是
    - hwnd=1641996 x=316 y=221 w=93 h=20   ← 全部确定（唯一 93px 宽）
  几何兜底：选中第 2 个 hwnd=1641996 位置=(316,221)
[11:26:47] 弹窗 #2 同上
[11:42:12] 弹窗 #3 同上（窗口位置变了：rect=(260,494)，按钮坐标同步偏移）
=== 监听结束：检测到 3 个弹窗，成功点击 3 个 ===
```

**几何特征**：三个按钮从左到右是「是(73px) / 全部确定(93px) / 否(73px)」。程序取**最左**那个，日志会打印 hwnd 与坐标便于核对。

**授权确实写入了**：同期白名单条目数增长，时间戳与点击完全对应：

| 时间 | 变化 |
|---|---|
| 11:21 | MyApp +1 |
| 11:22 | MyApp2 +1 |
| 11:24 | App +1（对应 11:25:21 点击） |
| 11:26 | MyApp +1（对应 11:26:47 点击） |
| 11:41 | MyApp +1（对应 11:42:12 点击） |

### 安全边界

1. **只点中间那个**。三个按钮时是「全部确定」；如果按钮数 ≠ 3，直接跳过不点（宁可留弹窗也不乱点）。
2. **几何定位的假设**：WinForms 标准对话框按钮顺序是「是 / 全部确定 / 否」。本机实测成立。若西门子改布局可能失效 —— 用 `-DryRun` 先验证。
3. **`-NoGeometricFallback`**：只允许 UIA 路径（当前环境会完全不动作，但最保守）。
4. **prune 只删哈希对不上的条目**，绝不删当前有效授权；且要求管理员。

### 白名单膨胀问题

每次授权都会追加一条 Entry，旧的不删。实测 30 分钟内 3 次授权让 MyApp 从 4 条涨到 8 条。另有发现：西门子自己会写重复条目（同一哈希、时间差 8 小时 = 本地时间 vs UTC）。

用 `-Action prune` 清理，实测一次删掉 12 条过期记录，14 条 → 2 条。

## 安全边界（必须向用户讲清）

1. `grant` 是**按哈希精确授权**，换一个 exe 或重新编译后哈希变化，授权即失效 —— 这本身是西门子的安全设计，不要试图绕过。
2. `insecure -Popup off` 是**全局降级**：本机任何程序调 Openness 都不再确认。不要在含生产凭证或连接真实产线的机器上长期开启。
3. 本技能只改注册表，**不改** Openness 的 DLL、不改 TIA 安装、不碰项目文件。
4. 任何写入都要求管理员权限；脚本会先 `Test-IsAdmin`，非管理员直接报错退出，不会静默失败。
5. `prune` 只删指向「文件不存在」或「哈希不匹配」的条目，**不删当前有效授权**。

## 故障排查

| 症状 | 处理 |
|---|---|
| 授权后仍弹窗 | 确认 exe 路径与你实际运行的是同一个（Debug/Release、AnyCPU/x64 会生成不同文件）；跑 `status` 看该 exe 的条目是否为 `valid` |
| `grant` 报「需要管理员权限」 | 用管理员身份重开 PowerShell；或先 `insecure` 绕过 |
| 用户组不在 | `net localgroup "Siemens TIA Openness" "%USERNAME%" /add`（管理员），然后**注销重登** |
| V21 不弹但 V20 弹 | 正常。`NonSecureOpennessAccess` 是**按版本**的，需对 21.0 单独设置 |
| 改了还是不生效 | TIA Portal 进程重启才重新读取；必要时重启博途 |

## 验证方式

`status` 的统计必须与注册表一致。手工核对：

```powershell
Get-ChildItem "HKLM:\SOFTWARE\Siemens\Automation\Openness\AllowList" | ForEach-Object {
  "{0}: {1} 条" -f $_.PSChildName, (Get-ChildItem $_.PSPath).Count
}
```

### 实测：点「是」的正确行为（2026-10-17）

```
点前白名单：2 条
几何兜底：选中最左按钮(是) hwnd=789956 pos=(497,715)    ← x=497 最左
点后白名单：2 条                                        ← 未增长 = 没写白名单
弹窗：已消失                                            ← 授权成功、流程继续
[OK] 白名单未增长 —— 符合预期（点的是「是」，只授权本次）
```

三项判据同时成立才算成功：

| 判据 | 期望 |
|---|---|
| 选中按钮 x 坐标 | 三个里最小的 |
| 弹窗 | 消失 |
| 白名单条目数 | **不变**（变了说明误点「全部确定」） |

### 构建流程不再碰白名单

`rebuild-all.ps1` 已移除 Openness 相关步骤（不生成 .reg、不提权、不写 HKLM）。
授权完全交给本守护进程点「是」处理。