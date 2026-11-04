# v1.1 立项：electron-updater blockmap 增量下载

立项日期：2026-11-04（用户拍板）

## 背景
Electron 应用（如 Alma，arm64 zip ≈ 413 MB）每次整包下载耗时 7 分钟左右。electron-builder 发布时会随 zip 一起发布 `<file>.blockmap`（已确认 `updates.alma.now/alma-0.4.421-mac-arm64.zip.blockmap` 存在），electron-updater 据此只下载有变化的块。Xup v1 是整包下载。

## 目标
- 对 electron-updater 来源（自动识别或手动 latest-mac.yml）的 zip 文件，优先走 blockmap 增量下载；无 blockmap、无基准包或任何一步失败时自动回退整包。
- 典型收益：Electron 应用小版本升级下载量从数百 MB 降到数十 MB。

## 方案要点
1. **基准包管理**：Xup 保留每个 electron 应用最近一次成功安装的 zip（`~/Library/Caches/dev.fming.xup/electron/<bundleid>/<version>.zip`），作为下次增量的"旧包"；首次更新无基准 → 整包并缓存。磁盘上限可配置（默认每应用保留 1 个版本）。
   - 可选：复用应用自身 electron-updater 的缓存（`~/Library/Caches/<updaterCacheDirName>/pending/*.zip`，Alma 为 `alma-updater`）作为基准，省掉首次整包。
2. **blockmap 解析**：下载 `new.zip.blockmap`（gzip JSON：`{version, files:[{name, offset, checksums[], sizes[]}]}`）；旧包的 blockmap 同样下载（`old.zip.blockmap`，若已缓存则直接读）；无旧 blockmap 时按新 blockmap 的分块参数在本地对旧包计算 checksum（sha256 → base64）。
3. **差分计划**：按 electron-updater 的 `DataSplitter` 逻辑，逐块比对 checksum，生成操作序列：`copy(oldOffset, length)` / `download(newOffset, length)`；相邻 download 合并成一个 Range 请求。
4. **下载执行**：对新 zip 用 HTTP `Range: bytes=a-b` 请求拉取变化块（服务器须支持 Range，先 HEAD 检查 `Accept-Ranges`），写入目标文件；复制块直接从旧包读。`useMultipleRangeRequest: false` 时单段请求逐个发（Alma 即此配置）。
5. **校验**：拼完后整文件 sha512 必须等于 latest-mac.yml 的 `sha512`，不一致则删除并回退整包。再走既有 `AppInstaller`（解压、codesign 校验、替换）。
6. **UI/日志**：日志显示"增量下载：复用 X MB，下载 Y MB（Z%）"；失败回退时显示原因。设置 › 通用 增加"electron 应用使用增量下载"开关（默认开）与缓存清理按钮。

## 范围外
- Sparkle delta（需要 BinaryDelta，不在控制范围）。
- dmg 的增量（blockmap 仅对 zip 有效；electron-updater 在 mac 上也只对 zip 做差分）。

## 验收标准
- Alma 从缓存基准 0.4.421 升到下一版时，下载量显著小于整包，sha512 校验通过，安装与重启流程正常。
- 删除基准包 / 服务器不支持 Range / blockmap 404 三种情况均自动回退整包并成功。
- 单元测试：blockmap 解析、差分计划生成（含块边界、文件边界）、Range 合并。

## 预估
核心（解析 + 差分 + Range 下载 + 校验 + 回退）1 天；缓存管理与设置 UI 0.5 天；测试 0.5 天。
