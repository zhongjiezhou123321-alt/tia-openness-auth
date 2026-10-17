# tia-openness-auth

> **Siemens TIA Portal Openness authorization** for AI agents — a [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) skill that also works with any agent supporting `SKILL.md` (Claude Code, Codex, Cursor, …).

**English** | [中文](README.zh-CN.md)

Solves three real problems:

| Problem | Symptom | Fix |
|---|---|---|
| **Repeated prompts** | TIA asks for Openness authorization again every time the exe is rebuilt | `-Action grant` pre-authorizes by SHA256 |
| **Prompt blocks unattended runs** | CI / overnight test runs stall waiting for a click | `-Action watch` daemon clicks "Yes" automatically |
| **Allowlist bloat** | Hundreds of stale hash entries pile up in the registry | `-Action prune` removes expired entries |

---

## Background: what Openness actually checks

Every process connecting to TIA Portal is validated against two checks. Failing either one triggers a prompt or a refusal:

| Check | Location |
|---|---|
| **User group** | Windows local group `Siemens TIA Openness` (sign out and back in after changing) |
| **Program fingerprint** | `HKLM\SOFTWARE\Siemens\Automation\Openness\AllowList\<exe name>\Entry (N)` |

Each Entry holds three `REG_SZ` values:

```
Path         = full path to the exe
DateModified = exe last-write time (local timezone, format yyyy/MM/dd HH:mm:ss.fff)
FileHash     = Base64(SHA256(exe file bytes))
```

**This is why every rebuild asks again**: the exe bytes change → SHA256 changes → no match in the allowlist → prompt.

---

## Critical: the two confirm buttons mean opposite things

The authorization dialog has three buttons. **The first two behave very differently:**

| Button | Behavior | When to use |
|---|---|---|
| **Yes (是)** | Authorizes **this call only**. Nothing is written to the allowlist. | ✅ Development (exe rebuilt constantly) |
| **Always allow (全部确定)** | Authorizes **and writes the current hash** into the allowlist. | ✅ Delivery (exe frozen) |
| No (否) | Refuses | — |

> ⚠️ **Do not click "Always allow" during development.** Every rebuild writes another entry, and within days you have hundreds of immediately-stale records (one machine reached 228). Click "Yes" instead.

---

## Installation

**DeepSeek Harness** — drop the folder into any skill root:

```
~/.dsh/skills/tia-openness-auth/        # user level
<project>/.dsh/skills/tia-openness-auth/   # project level
```

**Other agents** (Claude Code / Codex / Cursor / …) — place it in the agent's skills directory. As long as `SKILL.md` is readable, it works.

**Requirements**:

- Windows
- PowerShell 7 (`pwsh`) — scripts rely on PS7's UTF-8 default
- TIA Portal V15–V21 (tested on V21)
- Current user in the `Siemens TIA Openness` local group

---

## Usage

```powershell
$skill = "<install path>/scripts/tia-openness-auth.ps1"

# Inspect current authorization state (no admin needed)
pwsh -File $skill -Action status

# Pre-authorize an exe (admin required: writes HKLM)
pwsh -File $skill -Action grant -ExePath "D:\build\MyApp.exe"

# Remove stale entries (admin required)
pwsh -File $skill -Action prune

# Disable / restore the global security prompt (use with care)
pwsh -File $skill -Action insecure -Popup off
pwsh -File $skill -Action insecure -Popup on
```

### Auto-click daemon

```powershell
$ac = "<install path>/scripts/tia-openness-autoclick.ps1"

# Run for 8 hours, clicking every prompt that appears
pwsh -File $ac -Action watch -Minutes 480

# List current prompts without clicking
pwsh -File $ac -Action list

# Handle one prompt and exit
pwsh -File $ac -Action once

# Dry run: show which button would be clicked
pwsh -File $ac -Action once -DryRun
```

### Silent autostart

Save as `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\openness-autoclick.vbs`:

```vbscript
Dim shell, script
Set shell = CreateObject("WScript.Shell")
script = "<install path>\scripts\tia-openness-autoclick.ps1"
shell.Run "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """ -Action watch", 0, False
```

`0` hides the window, `False` means do not wait.

---

## Why UI Automation does not work

The authorization dialog is an unusual implementation. Every conventional approach fails:

| Approach | Result | Reason |
|---|---|---|
| UIA `RootElement.FindAll` | Dialog not found | Modal WinForms child window is not in the RootElement subtree |
| `AutomationElement.FromHandle(hwnd)` | Window found, but **0 buttons** | The dialog exposes no UIA control tree |
| Win32 `GetWindowText` on buttons | **All empty strings** | Owner-drawn buttons, no `WM_GETTEXT` handler |

**What actually works**:

```
EnumWindows              find visible window whose title contains "Openness"
      ↓
EnumChildWindows         collect child windows whose class contains BUTTON
      ↓
sort by x, take leftmost  ← leftmost = "Yes"
      ↓
SendMessage(hwnd, BM_CLICK)
```

### Geometry (measured, 502×262 dialog)

```
Yes            x=497  w=73   ← leftmost, target
Always allow   x=576  w=93   ← only wider button (longer text)
No             x=675  w=73   ← rightmost
```

If the window moves, button coordinates shift with it, but **relative order and widths stay constant** — so sorting by x and taking the leftmost is stable.

### Post-click verification

After clicking, compare the allowlist entry count:

| Result | Meaning |
|---|---|
| **No growth** | ✅ Clicked "Yes" (this call only) |
| Growth | ⚠️ Clicked "Always allow", or layout changed |

---

## Safety boundaries

1. **Only windows whose title contains `Openness` are matched.** TIA's "modify device?" confirmations are **never** touched — those write to a real PLC and must be judged by a human.
2. Fewer than 2 buttons → **skip, do not click**. Leaving a prompt is better than clicking blindly.
3. `-NoGeometricFallback` — use the UI Automation path only (most conservative; may do nothing on this environment).
4. `-DryRun` — print the button that would be clicked, without clicking.
5. `prune` only removes entries whose **hash does not match**; it never deletes the currently valid authorization.
6. `insecure -Popup off` is a **global downgrade** — no program on this machine will be asked again. Test machines only.

---

## Measured results

**Environment**: Windows 10 · TIA Portal V21 · PowerShell 7.6.7 · Portal installed on D:

```
# Auto-click (30-minute run, 3 prompts)
[12:09:00] detected Openness prompt #1  hwnd=986384  rect=(260,494)-(762,756)
[12:09:00]   geometric fallback: leftmost button (Yes) hwnd=1969044 pos=(497,715) of 3
[12:09:01]   [OK] allowlist unchanged — expected (clicked "Yes", this call only)

# Allowlist pruning
prune (admin=True, mode=execute)
  MyApp.exe: 3 stale entries deleted
  total: 14 -> 2
```

---

## Known limitations

- **Button text cannot be read**, so geometry is the only signal. If Siemens changes the dialog layout, recalibrate with `-DryRun`.
- **Only tested on V21.** V15–V20 use the monolithic Openness API; the registry mechanism is the same but untested here.
- `grant` writes HKLM and **requires admin**. The script detects this and fails loudly rather than silently.

---

## License

MIT
