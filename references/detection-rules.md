# 识别规则

## 扫描根目录

| Root | 路径 |
| --- | --- |
| `Local` | `$env:LOCALAPPDATA` |
| `LocalLow` | `$env:USERPROFILE\AppData\LocalLow` |
| `Roaming` | `$env:APPDATA` |
| `Documents` | `[Environment]::GetFolderPath('MyDocuments')`，兼容 OneDrive 重定向 |
| `SavedGames` | `$env:USERPROFILE\Saved Games` |
| `PublicDocuments` | `[Environment]::GetFolderPath('CommonDocuments')` |
| `ProgramData` | `$env:ProgramData` |
| `SteamUserdata` | 注册表 `HKCU\Software\Valve\Steam\SteamPath` 下的 `userdata` |

默认扫描前 7 个，加上检测到的 `SteamUserdata`。传 `-Roots All` 等价于全部存在的根目录；传 `-Roots Documents,SavedGames` 可只扫指定位置。

`-ProfileRoot` 默认是当前用户。传入其它路径时，所有根目录都会落在该路径下，便于在测试目录里验证规则。

## 扫描方式

从每个根目录逐层向下，默认最大深度 4：

| 深度 | 典型路径 |
| --- | --- |
| 1 | `Roaming\<厂商或游戏>` |
| 2 | `Roaming\<厂商>\<游戏>` |
| 3 | `...\<存档目录>` |
| 4 | `...\<存档目录>\<档案或槽位>` |

命中 High/Medium 候选后停止向下遍历；Low 候选会继续向下找更强的子目录，最后再删掉“已被子候选覆盖”的父目录，避免同一份存档重复备份。重解析点（junction / symlink）跳过。

## 评分

| 证据 | 分值 |
| --- | --- |
| 目录名是 save、saves、savegame、gamesaves、存档 等 | +5 |
| 目录名是 profile、profiles、slot、checkpoint 等 | +2 |
| 路径以 `Saved\SaveGames` 结尾（Unreal） | +6 |
| 命中 `known-game-paths.json` | +6 |
| 含 1 个存档扩展名文件 | +2 |
| 含 3 个以上存档文件 | 再 +2 |
| 含 5 个以上存档文件 | 再 +1 |
| 含 3 个以上 `.dat` / `.json` / `.xml` 等数据文件 | +1 |
| 含 Unity 的 `Player.log` 或 `output_log.txt` | +1 |
| 同时含 Unity 日志和存档/数据文件 | 再 +2 |
| 深度 >= 2 且含存档文件 | 再 +2 |
| 深度 >= 2 且含数据文件 | 再 +1 |
| 目录名在 `gameFolderNames` | +2 |
| 目录名在 `publisherNames` | +1 |

置信度：High >= 6，Medium >= 4，Low >= 2；低于 2 不输出。

存档扩展名：`.sav`、`.save`、`.savx`、`.srm`、`.sl2`、`.ess`、`.fos`、`.lsv`、`.savegame`、`.sg`、`.psv`、`.mcr`、`.co3`、`.zks`、`.jkr`。
数据扩展名：`.dat`、`.bin`、`.json`、`.xml`、`.db`、`.sqlite`、`.sqlite3`、`.state`、`.bak`、`.backup`。

## 裁剪目录

所有根目录都会跳过：`Cache`、`GPUCache`、`Code Cache`、`ShaderCache`、`Crashpad`、`CrashDumps`、`Temp`、`Logs`、`node_modules`、`.git` 等缓存或临时目录。

按根目录追加：

- `Local` / `LocalLow` / `Roaming`：`Microsoft`、`Google`、`Mozilla`、`NVIDIA`、`Steam`、`EpicGamesLauncher`、`Packages`、`baidunetdisk` 等系统或应用目录，以及 Ren'Py 的 `tokens` 缓存。
- `Documents` / `SavedGames` / `PublicDocuments`：浏览器、Office、IDE 等目录；保留 `Microsoft Games`，那里可能存着游戏存档。
- `ProgramData`：`Microsoft`、`Windows`、`Package Cache`、`Windows Defender`、`NVIDIA`、`AMD`、`Intel` 等。
- `SteamUserdata`：AppID `760`、`config`、`stats`。

## 扩展

`references/known-game-paths.json` 有三个字段：

- `knownSavePaths`：`root` 取上表的 Root 名，`path` 相对于该根目录；`*` 匹配一层目录名。支持 `savegame*` 这种半段通配。
- `gameFolderNames`：游戏目录名，不区分大小写。
- `publisherNames`：厂商目录名，不区分大小写。

只添加确认过的路径。错误条目会让工具备份无关目录，甚至把浏览器配置当成游戏存档。

## 已知缺口

- `Local\Packages`：UWP / Game Pass 游戏的 `LocalState`、`SystemAppData\wgs`，包名不可读，默认不扫描。
- 游戏安装目录：少数老游戏把存档写在 exe 旁边，本技能不遍历游戏库。
- 云存档：OneDrive、Steam Cloud 的占位文件需要先下载到本地。
- 只存在注册表或启动器云端的进度，不会出现在文件系统里。
- Steam `remote` 目录可能同时包含设置和截图之外的小文件，目前整目录复制。
- `ProgramData` 部分路径需要管理员权限；权限失败的项会记入日志，不会静默跳过。