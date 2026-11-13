# KTake · Mac 录唱工作台

KTake 可以从歌曲里提取伴奏，跟着 MV 和同步歌词练唱。录下来的人声可单独回听、补录，也可以和伴奏一起导出到 GarageBand。

## 安装

打开 DMG，把 KTake 拖到「应用程序」。录唱支持 **macOS 14 及以上**的 Apple 芯片和 Intel Mac，伴奏分离需要 Apple 芯片。[下载 KTake 0.10.15 DMG](https://github.com/rifflelin/ktake/releases/download/v0.10.15/KTake-0.10.15-macOS-universal.dmg)

安装包内置 GarageBand 工程模板，无需另行下载。要打开导出的 `.band` 工程，Mac 上需要安装 GarageBand。

当前安装包未经 Apple 公证。首次启动若被系统拦截，确认下载来源后，可参照 [Apple 的打开说明](https://support.apple.com/zh-cn/102445)。

## 从伴奏到第一条录音

1. **导入歌曲。** 点击「导入伴奏」（⌘O）选择音频，或把 MP3、M4A、WAV、AIFF 文件拖进窗口。KTake 会把伴奏复制到左侧曲库，并选中新曲目。也可以从左栏「5sing 找伴奏」搜索并下载到本地曲库。
2. **加上歌词和画面。** 点击「歌词」（⌘L）导入 LRC，或点「搜歌词」在 LRCLIB 里查找。需要画面时，点击「MV」（⇧⌘O）导入 MP4 或 MOV。有独立伴奏时，MV 只播放画面；单独导入 MV 时，会播放它自带的音轨。
3. **选调和练唱。** 在「伴奏升降调」里调整 −6 到 +6 个半音，播放速度保持不变。点击任意歌词跳到对应位置，用「歌词延后」微调字幕，或用「设 A」「设 B」和「循环」反复练一段。
4. **连接麦克风。** 在右侧选择输入、输出和麦克风通道，点击「启用麦克风」并允许系统授权。先点「试音」检查音量。戴上耳机后可开启「实时效果监听」，调整明亮度、压缩和混响。
5. **开始录音。** 在「录前准备」选直接录、倒数或先听一小段伴奏，点击「开始录音」（⌘R）。唱完点「结束录音」。原始 WAV 只保存人声，伴奏和监听效果不会录进去。

旧版临时打开过的伴奏，可以用「导入伴奏」重新选一次。导入后可在左侧搜索，也可以从曲目右侧的「…」提取伴奏、在 Finder 中显示或移出曲库。

## 用 music-dl 找歌

在 KTake 左栏点「music-dl 聚合搜索」。KTake 会自动启动随包安装的 go-music-dl。搜索和试听需要联网，找到歌曲后点「加入曲库」，KTake 会尝试匹配同步歌词。

若已经下载了匹配的音频，KTake 会直接读取。否则，首次从曲库打开该歌曲时，KTake 会读取播放流并缓存到曲库，供歌词定位、升降调和录音回听使用。

## 从歌曲提取伴奏

此功能需要搭载 Apple 芯片的 Mac。先在曲库打开歌曲，再点曲目右侧的「…」，选择 Kim Vocal 2、UVR Inst HQ 3 或 Small Karaoke。想去掉主唱、保留背景和声，可以选 Small Karaoke。

安装包内置分离引擎，模型按需下载。提取前，KTake 会检查模型目录。有对应模型就直接使用，缺少时会显示下载大小和存放位置，点击「下载并提取」即可。已下载的模型可以离线使用。

提取时可查看进度和预计剩余时间。每个版本单独保存为 WAV。播放时点「切换音轨」，就能在原唱和已提取的版本间对比，保留当前播放位置、歌词、MV、升降调和 A/B 循环。

## 回听、补录和导出

- **回听与混音：** 在「我的录音」打开一条录音，选择只听人声或带伴奏回听。可以调节两路音量、微调人声对齐，试听人声效果，或导出立体声混音 WAV。也可以从录音的「…」菜单导出原始人声 WAV。
- **补录一段：** 在「回听与混音」里设 A、B 点，点击「准备补录…」，回到主界面点击「开始补录」。录到 B 点会自动结束。再打开原录音，可对比原版和补录，选择要采用的一版。原始录音会保留。
- **导出到 GarageBand：** 在录音的「…」菜单选择「导出到 GarageBand…」。分轨 WAV 可以导出同一伴奏、同一调性的多条人声。把导出的文件拖进 GarageBand，让每条轨道从同一起点开始。安装包也支持把伴奏和一条人声直接导出为 `.band` 工程。

按 ⇧⌘F 可以在 Finder 中打开录音文件夹。

## 存放位置和外置硬盘

打开「KTake → 设置」（⌘,），可以分别指定以下三个位置。

| 设置 | 默认位置与更改方式 |
| --- | --- |
| KTake 数据 | `~/Library/Application Support/KTV Pro/`。选择新位置后，重启 KTake 会把曲库、提取的伴奏、歌词和录音复制到所选文件夹下的 `KTake Data`，并切换到新位置。原文件保留为备份。 |
| 伴奏分离模型 | 数据目录下的 `Separation`。自选位置后，新下载的模型存入所选文件夹下的 `KTake Models/v1`。把已有的模型子文件夹复制到这里即可继续使用。 |
| music-dl 下载 | `~/Library/Application Support/KTV Pro/MusicDL/data/downloads/`。更改后，新下载会使用所选文件夹。 |

从曲库移出导入的伴奏时，可以把曲库副本移到废纸篓。直接打开的 MV 仍从原文件播放。

## 从源码运行

安装 Apple Command Line Tools 后，在仓库目录运行下列命令。

```sh
./scripts/build-app.sh
open dist/KTake.app
```

开发构建会下载并构建固定版本的 music-dl。直接导出 `.band` 需要随安装包提供的工程模板，源码构建仍可导出对齐的分轨 WAV。

在 Apple 芯片 Mac 上运行 `./scripts/package-dmg.sh`，可构建带 Intel 和 Apple 芯片两种架构的 DMG。构建需要 `Resources/GarageBandTemplate.band`，会校验运行库，并附上内置 music-dl 对应的源代码和许可证。构建产物位于 `dist/`。设置 `KTAKE_SIGN_IDENTITY` 可使用 Developer ID 签名。

第三方组件和模型来源见 [ThirdPartyNotices.txt](scripts/distribution/ThirdPartyNotices.txt)。
