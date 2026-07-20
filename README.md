# AirPlay Service

AirPlay Service 将 HoloCubic透明小电视 (https://item.taobao.com/item.htm?id=1052832922780&skuId=6257264774009) 变成一台 AirPlay 音箱。安装后，iPhone、iPad 或 Mac 可在系统的 AirPlay 音频输出列表中选择设备，将音乐无线播放到 HoloCubic；服务在后台运行，未播放时不会占用扬声器。

本仓库是独立的 AirPlay Service 工程，不包含 HoloCubic 的其它应用或固件目录。原生模块构建所需的 Host ABI 快照已包含在 [`src/main/module_abi.h`](src/main/module_abi.h)；升级目标固件前，请按 [`README_HOST_ABI.md`](README_HOST_ABI.md) 同步该头文件后重新构建与真机验证。

## 使用要求

- HoloCubic 固件 **1.200 或更高版本**。
- 设备已连接 Wi-Fi 并取得 IPv4 地址；发送设备与 HoloCubic 应位于同一局域网，且网络允许 mDNS/Bonjour 发现。
- 支持 AirPlay 音频输出的 iPhone、iPad 或 Mac。

> 本应用仅支持 AirPlay 1 音频（RAOP），不支持 AirPlay 2、视频、屏幕镜像、FairPlay 视频或密码配对。

## 核心功能

- 自动广播为 AirPlay 音箱；Wi-Fi 连接到同一个子网后即可在 Apple 设备的输出列表中发现。
- 支持加密的 Apple Lossless（ALAC）及 L16 音频播放，并适配 HoloCubic 的扬声器输出。
- 显示歌曲标题、歌手和专辑信息；网易云音乐播放时支持浮层歌词，其他情况可选显示本地 `.lrc` 歌词。
- 提供设备端控制台，可查看播放状态和网络、缓冲等运行指标，并调整文字浮层显示偏好。
- 具备网络抖动缓冲、丢包重传和短暂丢包隐藏能力，提升 Wi-Fi 环境下的播放连续性。

## 安装

1. 下载或取得本目录下的 [`package`](package) 文件夹。
2. 将 `package` 内的全部内容复制到 SD 卡的 `/sd/apps/holocubic-airplay-service/`。
3. 将 SD 卡装回设备并重启 HoloCubic。服务会自动启动，并在 Wi-Fi 可用后开始广播。
4. 在 iPhone、iPad 或 Mac 的 AirPlay 音频输出列表中选择设备。默认名称为 `HoloCubic`。

安装后的目录应如下：

```text
/sd/apps/holocubic-airplay-service/
  app.info
  info.html
  main.lua
  modules/
    airplay_core.so
```

### 可选配置

若要修改 AirPlay 名称或高级参数，将 `config.example.lua` 复制为 `/sd/apps/holocubic-airplay-service/config.lua` 后再编辑。大多数用户无需修改配置。

若要使用逐行歌词，可将 UTF-8 编码的 `.lrc` 文件放入 `/sd/apps/holocubic-airplay-service/lyrics/`，文件名使用 `<歌手> - <标题>.lrc` 或 `<标题>.lrc`。AirPlay 发送端通常不会传送歌词；仅在歌曲标题稳定时，服务才会按播放进度匹配本地歌词。

## 使用与状态查看

播放时，设备屏幕会以轻量文字浮层显示歌曲信息。打开以下地址可进入服务控制台，查看当前播放状态和缓冲情况，并设置浮层的显示开关、位置、背景和字号：

```text
http://<设备 IP>/holocubic-airplay-service/
```

AirPlay 与设备上的本地音乐播放不能同时使用扬声器；开始 AirPlay 播放前，请先停止本地音乐。

## 已知限制

- 同一时间仅支持一个发送端会话。
- 网络隔离、访客 Wi-Fi 或被拦截的 mDNS/Bonjour 可能导致设备无法被发现；请确认两台设备在同一局域网。
- 长时间弱 Wi-Fi 或严重丢包仍可能造成短暂静音，建议让设备保持良好无线信号。

开发、调试、测试和原生核心构建说明见 [DEVELOPMENT_NOTES.md](DEVELOPMENT_NOTES.md) 与 [src/README.md](src/README.md)。
