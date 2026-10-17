# tia-openness-auth

> 西门子 TIA Portal **Openness 授权**管理 —— 一个 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 技能，同时也能被任何支持 `SKILL.md` 的 Agent 使用。

**中文** | [English](README.md)

解决三个真实痛点：

| 痛点 | 症状 | 本项目的解法 |
|---|---|---|
| **反复弹窗** | 每次重新编译 exe，TIA 又弹「Openness 访问」确认框 | `-Action grant` 预授权（按 SHA256 写入白名单） |
| **弹窗卡住无人值守** | CI / 通宵跑测试时，弹窗一直停着等点击 | `-Action watch` 守护进程，自动点「是」 |
| **白名单无限膨胀** | 注册表里堆了几百条早已过期的哈希 | `-Action prune` 清理失效条目 |

---

## 背景：Openness 到底在校验什么

每次进程连接 TIA Portal，Openness 做两道检查，任一不过就弹窗或拒绝：

| 检查 | 位置 |
|---|---|
| **用户组** | Windows 本地组 `Siemens TIA Openness`（改完需注销重登） |
| **程序指纹** | `HKLM\SOFTWARE\Siemens\Automation\Openness\AllowList\<exe名>\Entry (N)` |

每条 Entry 有三个 `REG_SZ` 值：

```
Path         = exe 完整路径
DateModified = exe 最后修改时间（本地时区，格式 yyyy/MM/dd HH:mm:ss.fff）
FileHash     = Base64(SHA256(exe 文件字节))
```

**这就是「每次重编译都要重新授权」的根因**：exe 字节变了 → SHA256 变 → 与白名单对不上 → 弹窗。

---

## 关键认知：两个按钮语义相反

授权弹窗有三个按钮，**前两个语义完全不同**：

| 按钮 | 行为 | 该用在哪 |
|---|---|---|
| **是** | 只授权**本次**，不写白名单 | ✅ 调试期（exe 反复重编译） |
| **全部确定** | 授权并把当前哈希**写进白名单** | ✅ 交付期（exe 定型不再变） |
| 否 | 拒绝 | — |

> ⚠️ **调试期不要点「全部确定」**。每编译一次就写一条，很快堆出几百条立即过期的记录（实测一台机器积到 228 条）。用「是」放行本次即可。

---

## 安装

**DeepSeek Harness**：把整个目录放进技能根目录之一：

```
~/.dsh/skills/tia-openness-auth/        # 用户级
<项目>/.dsh/skills/tia-openness-auth/   # 项目级
```

**其它 Agent**（Claude Code / Codex / Cursor 等）：放进各自的 skills 目录，只要能读到 `SKILL.md` 即可。

**前置条件**：

- Windows
- PowerShell 7（`pwsh`）—— 脚本用了 PS7 的 UTF-8 默认编码
- TIA Portal V15–V21（已在 V21 实测）
- 当前用户属于 `Siemens TIA Openness` 本地组

---

## 用法

```powershell
$skill = "<安装路径>/scripts/tia-openness-auth.ps1"

# 查看当前授权状态（不需要管理员）
pwsh -File $skill -Action status

# 预授权一个 exe（需管理员：写 HKLM）
pwsh -File $skill -Action grant -ExePath "D:\build\MyApp.exe"

# 清理过期条目（需管理员）
pwsh -File $skill -Action prune

# 关闭 / 恢复安全确认弹窗（全局开关，慎用）
pwsh -File $skill -Action insecure -Popup off
pwsh -File $skill -Action insecure -Popup on
```

### 自动点击守护

```powershell
$ac = "<安装路径>/scripts/tia-openness-autoclick.ps1"

# 常驻监听（8 小时）
pwsh -File $ac -Action watch -Minutes 480

# 只看当前有没有弹窗（不点）
pwsh -File $ac -Action list

# 处理一次就退出
pwsh -File $ac -Action once

# 预演：只显示会点哪个按钮
pwsh -File $ac -Action once -DryRun
```

### 开机自启（静默）

把下面内容存为 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\openness-autoclick.vbs`：

```vbscript
Dim shell, script
Set shell = CreateObject("WScript.Shell")
script = "<安装路径>\scripts\tia-openness-autoclick.ps1"
shell.Run "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """ -Action watch", 0, False
```

`0` = 隐藏窗口，`False` = 不等待。

---

## 技术内幕：为什么不能靠 UI Automation

那个授权对话框是实现上的一朵奇葩，常规办法全部失效：

| 常规做法 | 结果 | 原因 |
|---|---|---|
| UIA `RootElement.FindAll` | 找不到对话框 | 模态 WinForms 子窗口不在 RootElement 子树里 |
| `AutomationElement.FromHandle(hwnd)` | 拿到窗口，但**按钮数 = 0** | 该对话框不提供 UIA 控件树 |
| Win32 `GetWindowText` 读按钮 | **全部空字符串** | 按钮自绘，无 `WM_GETTEXT` 响应 |

**实际可行的方案**：

```
EnumWindows              找标题含 "Openness" 的可见窗口
      ↓
EnumChildWindows         取 class 含 BUTTON 的子窗口
      ↓
按 x 坐标排序，取最左     ← 最左 = 「是」
      ↓
SendMessage(hwnd, BM_CLICK)
```

### 几何特征（实测，502×262 对话框）

```
是         x=497  w=73   ← 最左，目标
全部确定    x=576  w=93   ← 唯一更宽的（文字更长）
否         x=675  w=73   ← 最右
```

窗口位置变了按钮坐标会同步偏移，但**相对顺序与宽度不变**，所以按 x 排序取最左是稳的。

### 点后自检

点击后对比白名单条目数：

| 结果 | 含义 |
|---|---|
| **不增长** | ✅ 点的是「是」（仅本次授权） |
| 增长 | ⚠️ 误点了「全部确定」，或布局变了 |

---

## 安全边界

1. **只匹配标题含 `Openness` 的窗口**。TIA 的「是否对设备进行修改」等确认框**不会**被触碰——那类操作会真的写 PLC，必须人工判断。
2. 按钮数 < 2 时**跳过不点**，宁可留弹窗也不乱点。
3. `-NoGeometricFallback`：只用 UI Automation 路径（最保守，可能完全不动作）。
4. `-DryRun`：只打印将要点击的按钮，不真点。
5. `prune` 只删**哈希对不上**的条目，绝不删当前有效授权。
6. `insecure -Popup off` 是**全局降级**——本机任何程序调 Openness 都不再确认。仅限完全可信的测试机。

---

## 实测记录

**环境**：Windows 10 · TIA Portal V21 · PowerShell 7.6.7 · D 盘安装

```
# 自动点击（30 分钟守护，3 个弹窗）
[12:09:00] 检测到 Openness 弹窗 #1  hwnd=986384  rect=(260,494)-(762,756)
[12:09:00]   几何兜底：选中最左按钮(是) hwnd=1969044 pos=(497,715) 共3个
[12:09:01]   [OK] 白名单未增长 —— 符合预期（点的是「是」，只授权本次）

# 白名单清理
清扫白名单（管理员=True，模式=执行）
  MyApp.exe：过期 3 条 已删除
  合计：14 条 -> 2 条
```

---

## 已知限制

- **按钮文字读不出**，只能靠几何位置。若西门子改了对话框布局，需重新校准（用 `-DryRun` 验证）。
- **只测过 V21**。V15–V20 的单体 Openness API 授权机制理论相同（同注册表项），但未实测。
- `grant` 写 HKLM **需要管理员**；脚本会检测并明确报错，不会静默失败。

---

## License

MIT