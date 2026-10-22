# Game Save Backup

一个用于 Windows 的游戏存档发现、备份与恢复工具，也可作为 Codex skill 使用。它会在常见用户目录中按规则寻找疑似存档目录，把选中的目录复制到备份位置，并用清单记录来源，方便之后恢复。

扫描是只读的；备份只复制，不移动或删除源文件。恢复前会把目标位置的现有内容保存到回滚目录。识别结果是基于路径、目录名和文件扩展名的启发式判断，正式备份前请先检查扫描结果和 dry run 计划。

## 功能

- 扫描 AppData、文档、Saved Games、Public Documents、ProgramData，以及检测到 Steam 时的 `userdata`。
- 按 High、Medium、Low 置信度筛选候选，可按 Root 和正则表达式进一步缩小范围。
- 使用 `robocopy` 复制整个候选目录，保留 Root 和相对路径结构。
- 每次备份生成日志和 JSON manifest；恢复可以指定 manifest，也可以默认选最新一份。
- 恢复覆盖前尝试把目标目录的现有内容快照到 `_rollback`。
- 支持 dry run，先预览将执行的备份或恢复操作。

## 文件结构

```text
game-save-backup/
├── README.md
├── SKILL.md
├── references/
│   ├── detection-rules.md
│   └── known-game-paths.json
└── scripts/
    ├── Backup-GameSaves.ps1
    ├── Common.ps1
    ├── Get-GameSaves.ps1
    └── Restore-GameSaves.ps1
```

`SKILL.md` 描述 Codex skill 的调用方式；`references/detection-rules.md` 说明扫描和评分逻辑；`references/known-game-paths.json` 保存已知游戏路径与名称；PowerShell 脚本负责扫描、备份和恢复。

## 环境要求

- Windows PowerShell 5.1 或 PowerShell 7。
- Windows 自带的 `robocopy.exe`（扫描不依赖它；备份和恢复需要）。
- 建议把备份保存到独立磁盘或其他可靠存储位置。备份目录必须位于扫描根目录之外。

## 安装为 Codex skill

将整个 `game-save-backup` 目录复制到 Codex skills 目录，例如：

```powershell
$skillRoot = Join-Path $env:USERPROFILE '.agents\skills'
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
Copy-Item -Path .\game-save-backup -Destination $skillRoot -Recurse
```

安装后，Codex 可根据 `SKILL.md` 在用户要求查找、备份或恢复单机游戏存档时使用此 skill。直接运行脚本时无需安装；在克隆仓库根目录执行下方命令即可。

## 使用方法

以下命令假设当前目录是仓库根目录。可按实际情况替换备份盘符和路径。

### 1. 扫描并检查候选

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-GameSaves.ps1 |
    Format-Table Root, RelativePath, Confidence, Files, Evidence -AutoSize
```

默认最低置信度是 Medium。查看所有低置信度候选：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-GameSaves.ps1 `
    -MinConfidence Low |
    Format-Table Root, RelativePath, Confidence, Files, Evidence -AutoSize
```

仅扫描指定位置，或输出 JSON：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-GameSaves.ps1 `
    -Roots Documents,SavedGames

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-GameSaves.ps1 -Json
```

可用 Root：`Local`、`LocalLow`、`Roaming`、`Documents`、`SavedGames`、`PublicDocuments`、`ProgramData`、`SteamUserdata` 和 `All`。默认扫描这些存在的常见位置；Steam 根目录只有在注册表检测到 Steam 安装路径时才可用。

### 2. 预览备份计划，再执行备份

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Backup-GameSaves.ps1 `
    -Dest 'D:\game-save-backup' -DryRun

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Backup-GameSaves.ps1 `
    -Dest 'D:\game-save-backup'
```

只备份指定路径可以使用 `-Roots`、`-Include` 和 `-Exclude`。Include/Exclude 接受正则表达式，匹配 `Root\RelativePath`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Backup-GameSaves.ps1 `
    -Dest 'D:\game-save-backup' `
    -Roots Documents,SavedGames `
    -Include 'Documents\\My Games\\Skyrim' `
    -DryRun
```

确认 dry run 只列出预期候选后，移除 `-DryRun` 执行备份。若要收集更多候选，可加 `-MinConfidence Low`，但请逐项检查后再执行。

### 3. 预览恢复计划，再执行恢复

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restore-GameSaves.ps1 `
    -Backup 'D:\game-save-backup' -DryRun

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restore-GameSaves.ps1 `
    -Backup 'D:\game-save-backup'
```

默认读取备份目录中最新的 manifest。可通过 `-Manifest` 指定某次备份清单；可用 `-Item` 按 `Root\RelativePath` 的正则表达式只恢复部分项目：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restore-GameSaves.ps1 `
    -Backup 'D:\game-save-backup' `
    -Item 'Documents\\My Games\\Skyrim' `
    -DryRun
```

备份项状态不是 `ok` 时默认跳过；确认清单后可用 `-IncludeIncomplete` 强制纳入。恢复到另一台 Windows 电脑时，可以用 `-ProfileRoot` 指定目标用户配置文件根路径。执行恢复前请关闭相关游戏，并仔细检查 dry run 的目标路径。

## 备份目录与记录

备份目录保留原始 Root 和相对路径，例如：

```text
D:\game-save-backup\
├── Local\Larian Studios\Baldur's Gate 3\PlayerProfiles\...
├── Documents\My Games\Skyrim Special Edition\Saves\...
├── SteamUserdata\373762673\730\remote\...
├── logs\
│   ├── backup-<时间戳>.log
│   ├── manifest-<时间戳>.json
│   ├── restore-<时间戳>.log
│   ├── restore-<时间戳>.json
│   └── history.log
└── _rollback\<时间戳>\...
```

manifest 记录每个项目的 Root、相对路径、状态和文件信息，是恢复时定位文件的依据。备份会追加 `history.log`；恢复会写独立日志和 JSON 结果。恢复前的回滚快照用于找回被覆盖的旧版本，不会自动清理。

## 扫描规则与自定义

默认递归深度上限为 4。工具综合目录名（如 `save`、`saves`、`profile`）、存档或数据文件扩展名、已知游戏路径和目录层级打分：High 为 6 分及以上，Medium 为 4–5 分，Low 为 2–3 分。达到 High/Medium 的候选会停止向更深层搜索；被更具体候选覆盖的父目录会去重。缓存、临时目录、部分应用目录以及符号链接/目录联接会跳过。

若需补充已验证的游戏路径，可编辑 `references/known-game-paths.json`：

- `knownSavePaths`：相对于 Root 的路径；`*` 匹配一层目录名。
- `gameFolderNames`：游戏文件夹名。
- `publisherNames`：发行商或厂商目录名。

规则详见 [`references/detection-rules.md`](references/detection-rules.md)。已知路径会提高匹配置信度；添加不准确条目可能导致无关目录被选中。

## 范围和限制

- 不扫描游戏安装目录中的便携式存档，也不默认扫描 `Local\Packages` 下的 UWP / Game Pass 存档。
- 不下载云端占位文件，也不处理 OneDrive、Steam Cloud 等云同步；需要先确保文件已在本地可用。
- 不会从注册表或启动器云端恢复进度，也不提供删除、清理或同步功能。
- Steam 只备份 `userdata\<账号>\<AppID>\remote`，并跳过 AppID 760、`config` 和 `stats`。
- ProgramData 的部分目录可能需要管理员权限。失败项目会写入日志；备份/恢复结果应检查 manifest 和日志。
- 备份和恢复均为文件复制。被游戏占用、权限不足或文件在复制期间变化时，操作可能不完整；关闭游戏并检查结果。
- Steam `remote` 可能包含设置等非存档文件；匹配结果仍需人工确认。

## 隐私

存档目录可能包含游戏进度、用户名或其他个人数据。公开本仓库不会公开你的本地存档，但请勿把实际备份目录、生成的 manifest/logs 或个人配置文件提交到仓库。
