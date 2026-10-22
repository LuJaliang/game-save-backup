---
name: game-save-backup
description: 扫描 Windows 用户的 AppData、Documents、Saved Games、Public Documents、ProgramData 和 Steam userdata，识别游戏存档文件夹，按 <备份目录>/<Root>/<相对路径> 备份，并支持从最新备份一键恢复。用于查找存档位置、备份或还原单机游戏存档；不用于云存档同步、游戏本体备份或整盘备份。
---

# 游戏存档备份

扫描当前用户的常见存档位置，把可能是游戏存档的文件夹原样复制到指定目录。扫描只读，备份只增不改，恢复前会自动留存当前版本。移动、删除原始存档不在本技能范围内。

## 扫描范围

| Root | 实际位置 | 默认 |
| --- | --- | --- |
| `Local` | `%LOCALAPPDATA%` | 是 |
| `LocalLow` | `%USERPROFILE%\AppData\LocalLow` | 是 |
| `Roaming` | `%APPDATA%` | 是 |
| `Documents` | 当前用户的“文档”已知文件夹（可能是 OneDrive 或其它盘） | 是 |
| `SavedGames` | `%USERPROFILE%\Saved Games` | 是 |
| `PublicDocuments` | `%PUBLIC%\Documents` | 是 |
| `ProgramData` | `%ProgramData%` | 是 |
| `SteamUserdata` | `<Steam 安装目录>\userdata`，从注册表探测 | 是，检测到 Steam 时 |

`SteamUserdata` 只取 `userdata\<账号>\<AppID>\remote`，跳过 AppID 760（Steam 客户端配置和截图）。`Local\Packages`（UWP / Game Pass）默认跳过。

## 流程

1. 扫描，只读，不改动任何文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\Get-GameSaves.ps1" |
    Format-Table Root, RelativePath, Confidence, Files, Evidence -AutoSize
```

2. 把 High/Medium 列表交给用户确认。需要更全时加 `-MinConfidence Low`；用 `-Include` / `-Exclude`（正则，匹配 `Root\RelativePath`）缩小范围。`-Roots All` 表示全部根目录。
3. 先看备份计划和总大小，再正式备份。默认会包含 Steam `remote` 和较大的 Unity 目录，几百 MB 很常见：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\Backup-GameSaves.ps1" -Dest "D:\game-save-backup" -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\Backup-GameSaves.ps1" -Dest "D:\game-save-backup"
```

4. 需要还原时，用最新一次备份一键恢复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\Restore-GameSaves.ps1" -Backup "D:\game-save-backup" -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\Restore-GameSaves.ps1" -Backup "D:\game-save-backup"
```

`<skill-dir>` 指本技能所在目录。备份目录必须在所有扫描根目录之外，脚本会拒绝把备份写进 AppData、Documents 等扫描源。

## 备份结构

源 `AppData\Roaming\game1\save` 复制到 `<Dest>\Roaming\game1\save`：

```text
D:\game-save-backup\
  Local\
    Larian Studios\Baldur's Gate 3\PlayerProfiles\...
  Documents\
    My Games\Skyrim Special Edition\Saves\...
  SavedGames\
    CD Projekt Red\Cyberpunk 2077\...
  SteamUserdata\
    373762673\730\remote\...
  logs\
    backup-20261022-194115.log
    manifest-20261022-194115.json
    history.log
    restore-20261022-195002.log
  _rollback\
    20261022-195002\...   # 恢复前的旧版本
```

## 日志

每次备份都会写三份说明：

- `logs\backup-<时间戳>.log`：开始/结束时间、扫描参数、每一项的置信度、证据、源路径、目标路径、文件数、大小、状态和错误原因。
- `logs\manifest-<时间戳>.json`：同一批内容的机器可读清单，恢复脚本用它定位文件和目标 Root。
- `logs\history.log`：每次备份/恢复追加一行摘要，方便快速回看。

恢复同样写 `logs\restore-<时间戳>.log` 和 `.json`，并追加 `history.log`。

## 恢复与回滚

- 默认读取 `logs` 下最新的 `manifest-*.json`，也可用 `-Manifest <路径>` 指定。
- 覆盖已有目录前，先把当前内容快照到 `<Dest>\_rollback\<时间戳>\<Root>\<相对路径>`。快照失败时跳过该项，不会硬覆盖。
- 只复制备份中存在的文件，不删除目标目录里多出来的文件。
- `-Item` 可用正则只恢复部分内容，例如 `-Item 'Skyrim|GameOne'`。
- 备份状态不是 `ok` 的项默认跳过并标记 `backup-incomplete`；确认备份完整后才可用 `-IncludeIncomplete` 强制恢复。
- 目标 Root 不存在时（例如另一台机器没有 Steam）标记 `root-unavailable` 并跳过。
- 备份/恢复前先退出游戏；文件被占用时会记录 `failed` 或 `verify-mismatch`。

## 判定与维护

识别规则、评分、裁剪名单和置信度阈值见 `references/detection-rules.md`。常用游戏的精确路径和名称表在 `references/known-game-paths.json`，可直接追加；路径里的 `*` 匹配一层目录名。

## 边界

- 不扫描游戏安装目录里的 portable 存档，也不扫描 `Local\Packages`（UWP / Game Pass）。
- 不处理 OneDrive、Steam Cloud 等云端占位文件；需要先在客户端下载到本地。
- 加密或打包成单一容器的存档按普通文件复制，能否还原取决于游戏本身。
- `ProgramData` 中部分目录需要管理员权限，失败项会写入日志，不会静默跳过。
- 不提供删除、清理或云同步功能。