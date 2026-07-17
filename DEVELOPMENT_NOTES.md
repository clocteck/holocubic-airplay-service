# AirPlay Service 开发记录（2026-07-14～2026-07-17）

本文记录 `airplay_service` 第一阶段的实现、真机调优结论和后续图形 App 接入注意事项。当前版本为 `0.3.22`，目标为 HoloCubic ESP32-S3、ESP-IDF 6.0.2 和 AirPlay 1/RAOP 音频。

## 今日完成

- 新增后台 service 包：空闲时只做网络广播，不占用 I2S，不影响原有本地音乐 App。
- 实现 `_raop._tcp.local` 广播、RTSP 会话、audio/control/timing UDP、重传请求和时间响应。
- 实现 Apple-Challenge、固定 AirPlay 1 RSA 私钥运算、OAEP/SHA-1、AES-128-CBC、ALAC 和 L16。
- 增加 DMAP 标题/歌手/专辑、进度、音量、封面大小/类型和左右声道峰值解析。
- 增加只读状态接口 `GET /airplay_service/status`，供隔离 Lua VM 中的图形 App 获取播放状态和可视化数据。
- 完成 iPhone 真机发现、连接、加密 ALAC 播放以及长时间指标采样。

## 最终实时架构

1. Lua service 负责 mDNS、RTSP 和元数据；RTP、控制重传和 timing UDP 都由原生 Socket worker 处理，不在 Lua 中解密或解码音频。
2. 原生模块把 RTP 放入 512 包 PSRAM 抖动缓冲，预缓冲 160 包。
3. 优先级 10 的生产者完成 AES-CBC、ALAC 和电平计算，把 PCM 放入 256 包队列。
4. core 0 的消费者只负责阻塞式 I2S 写入，避免“解码耗时 + 8 ms 播放耗时”串行相加。
5. 零星缺包最多等待 192 个 2 ms 周期；PCM 队列低于 24 包时取消等待并单帧掩蔽，防止长阻塞形成级联欠载。
6. RTP 序列跨度超过 192 包时跳到最新安全窗口，作为异常网络情况下的最后保护。

关键默认值：

| 参数 | 值 | 目的 |
| --- | ---: | --- |
| RTP slots | 512 | 乱序、重传和网络抖动 |
| RTP prebuffer | 160 包（约 1.28 s） | 启播和 Wi-Fi 抖动余量 |
| PCM slots | 256 包（约 2.05 s） | 解码/I2S 解耦 |
| retransmit floor | 24 包 | 保留约 192 ms 播放安全余量 |
| I2S DMA | 12×512 | 减少短时调度抖动 |
| producer / output core | 任意 / 0 | 双核流水线 |
| producer / output priority | 10 / 11 | I2S 输出优先 |

## 核心坑与结论

### 服务已安装不等于服务已运行

Launcher 能展示 service 只能证明包被扫描到。最初 RTSP 5000 没有监听，是 Lua 5.4 编译错误和后台 VM 环境差异导致服务未启动。诊断时必须同时检查 TCP 端口、状态接口和服务脚本编译结果。

### Lua 5.4 泛型 for 变量是 const

`for _, label in ipairs(...) do label = ... end` 会报 `attempt to assign to const variable`。需要复制到新的局部变量后再修改。

### 后台 service VM 没有 `wifi` 全局

后台 VM 与普通 App 不同。服务通过固件本机 `http://127.0.0.1/api/system/state` 异步读取 STA IPv4，并持续重试；不能假设 `wifi.sta.getip()` 可用。

### 固件 mDNS 已占用 UDP 5353

Lua 服务无法绑定 5353，但仍能从临时 UDP 端口主动发送合法 RAOP 公告，iPhone 可以发现。当前保留警告并继续广播，而不是把地址占用视为致命错误。

### 串行解码和 I2S 无法达到实时速率

旧路径每包先 AES/ALAC、再阻塞写 8 ms I2S，实测只能处理约 77 包/秒，而 44.1 kHz、352 frame 的 AirPlay 流需要约 125 包/秒。结果是 RTP 缓冲持续上涨、周期性追帧和明显破音。双任务 PCM 队列消除了这个结构性瓶颈。

### AES 是复杂音乐/人声段的主要 CPU 热点

原实现每个 AES 字节都用循环计算 GF(2^8) 乘法，ALAC 包越大越容易卡。最终使用 4×256 字节只读乘法表；真机 45 秒采样中 PCM 队列保持 30–32 包，`pcm_underruns=0`、`buffer_resyncs=0`、`decode_errors=0`。

不要恢复曾测试过的“辅助函数版快速逆 MixColumns”。它在 Windows 密码学向量测试中正确，但 ESP32-S3 收到首批加密音频后会使 service VM 重启，iPhone 随即退回本机扬声器。只读查表版经过同一 iPhone 链路验证，不会触发该问题。

### 固定重传等待会造成反向级联

`missing_wait_ticks=1` 会把很快到达的重传包过早判为迟到，产生少量爆音；无条件改成 12 又会在长 Wi-Fi 阻塞中逐包等待，拖空 PCM 队列并造成大量 RTP 覆盖。最终策略必须看 PCM 安全水位：队列充足时等，低于 24 包立即保播放连续性。

### RTSP 响应必须串行发送

连续调用异步 TCP `send()` 会让 iPhone 在约一分钟后主动结束会话并退回本机扬声器。`0.3.10` 起通过 `sent` 回调串行泵送 RTSP 响应，消除了这一类固定时间断开。

`0.3.21` 进一步把收到 `SET_PARAMETER` 后的 DMAP 解析、状态订阅和浮层刷新移到该请求的 `200 OK` 已经写入 TCP 后执行；同时浮层刷新改为 100 ms 定时合并。此前状态接口出现 `last_session_end="disconnect"`、`last_disconnect_pending_responses=2` 且最后方法为 `SET_PARAMETER`，说明发送端在等待控制回复时自行关闭了连接，而不是 AES/ALAC 或 UDP 音频链路崩溃。更新后 PC 端连续 100 次元数据更新与 8 个并行 `OPTIONS` 压测得到 `115/115` 回复、0 发送错误、0 遗留响应；100 次元数据仅触发 43 次浮层渲染，单次最高 1 ms。

### 透明浮层必须完整覆写并限速

在固件 1.200 上，`service_ui.clear()` 若在 `lv_canvas_frame_begin()` 事务外调用，合成层可能保留上一行的字形，歌词连续更新会重叠。更严重的是个别 CJK 渲染可达 600～700 ms；若每次 `SET_PARAMETER` 都立刻绘制，会拖慢整个 Lua/显示调度并间接放大无线到包空洞。`0.3.22` 将清理和透明键背景填充放入同一 canvas frame，确保完整覆写；同时保留 100 ms 的脏状态合并，但把实际绘制下限设为 1 秒。真机重启后的 30 秒会话中，浮层最新渲染为 1 ms、PCM 欠载增量为 0；仍有少量 Wi-Fi 丢包及 PLC，但不再出现由浮层造成的数秒音频空洞。

### 消费序号必须在 AES/ALAC 之前推进

旧实现清空 RTP slot 后要等约 2.5 ms 的 AES/ALAC 工作结束才推进 `expected_sequence`；这段窗口内到达的重传包会重新填回刚清空的 slot，并在一整圈后形成碰撞。`0.3.15` 在复制编码数据后立即推进序号，再进行解密和解码，解决了该竞争。

### UDP 热路径必须绕开 Lua 调度

旧 ABI 下 UDP 接收和重传发送必须经过 Lua 事件循环；前台图形 App 阻塞 Lua 时，数据会在进入 `airplay_core` 前丢失，AES/ALAC 优化和扩大缓冲都无法恢复从未交付给模块的数据。固件 1.200 提供 SDK3 optional Socket ABI 后，`0.3.18` 将 RTP、控制重传和 timing 三个 UDP 端口迁入优先级 11 的原生 worker，Lua 只保留 RTSP、元数据和 mDNS，并在 ABI/绑定失败时兼容回退。

部署前先用只解析不调用的探针确认 `0x000F0001`～`0x000F000E` 全部存在，真机返回 `socket_proc_mask=0x3FFF`。随后用 PC L16 探针故意丢弃 30 包：原生端发出 11 次 D5、请求 31 包并全部收到 D6，最终 `received=1880`、`decoded=1880`、`lost=0`、`pcm_underruns=0`，且 poll/recv/send 错误均为 0。ALAC handshake-only 回归也完成 4 次 D2/D3 timing 往返。这验证了私有固件 README 所述地址、poll 和 sockaddr 结构布局。

弱 Wi-Fi 会产生相同症状。一次前台无 App 的故障会话中，RSSI 为 -78～-85 dBm，记录到 `lost=5660`、`late=2951`、`pcm_underruns=117`、RTP 最大空洞 504 ms 和输出最大空洞 1.13 s；同期 AES+ALAC 平均约 2.56 ms/包，证明瓶颈在无线到包而非解码算力。诊断时应先把 RSSI 恢复到约 -70 dBm 或更好，再比较服务版本。

### 短丢包不能直接插入硬静音

原生 UDP 消除了 Lua 回调阻塞，但 Wi-Fi/lwIP 仍可能偶发 100～300 ms 到包空洞。旧路径对最终未追回的 RTP 包直接写入全零 PCM，波形在边界瞬间跳变，少量丢包也会听成爆点或顿挫。`0.3.20` 保存最近一帧已调音量、已下混的输出 PCM：最多连续 6 包（约 48 ms）采用帧方向交替的镜像延拓，并在整个窗口内线性衰减；真实音频恢复时用 64 个采样帧交叉淡入。更长的突发仍退回静音，避免重复波形形成持续音调。

首轮 iPhone 加密 ALAC 真机测试中，5 个丢包突发共 29 包，其中 15 包由 PLC 隐藏，超出窗口的 14 包安全静音；随后连续约 3700 个解码包中计数不再增长，PCM 队列稳定在 183～185，`pcm_underruns=0`，Socket 错误为 0。

### 固件 1.200 的单扬声器 I2S 兼容

固件从 1.101 更新到 1.200 后，iPhone 能连接、RTP/ALAC 能解码、I2S `write()` 也持续成功，但设备完全无声。PC 端 10 秒 L16 流记录到 `1253/1253` 包、`written_bytes=1612160`、I2S 平均约 7.2 ms/包且无欠载，证明问题不在网络或解码。

对比固件内置的本地音乐播放器后确认，其原生播放器实际以单声道启动 I2S，而 AirPlay 一直以双声道启动。`0.3.16` 保留双声道 ALAC/L16 解码和左右电平，在 PCM 入队前下混为单声道，并以 `MODULE_I2S_CHANNEL_MONO_LEFT` 启动输出；固件 1.200 真机 PC 测试已恢复声音。模块同时改用 SDK `0x00030000` 的 `module_host_api_v2` 基础接口，避免继续依赖历史 v1 命名头文件。

## 真机诊断指标

状态接口的 `audio` 对象至少关注：

- `buffered_packets`：RTP 抖动缓冲；持续上涨表示生产者跟不上。
- `pcm_buffered_packets`：PCM 队列；长期接近 0 表示解码或调度余量不足。
- `pcm_underruns`：软件 PCM 欠载；稳定播放期间应保持不变。
- `lost` / `late` / `resend_serial`：无线丢包与重传效果。
- `native_udp_*`：原生 Socket worker 的收包、重传、timing 和错误计数；正常时 `native_udp_active=1`、`native_udp_task_running=1`，三个错误计数保持 0。
- `concealed_packets` / `conceal_silence_packets` / `conceal_recoveries`：短丢包隐藏、超窗静音和恢复交叉淡入计数。
- `decode_errors`：ALAC/AES 数据正确性；正常应为 0。
- `buffer_resyncs`：高水位追帧；正常网络下应为 0。
- `metrics.rtsp_responses_queued` / `rtsp_responses_sent` / `rtsp_send_errors`：控制回复的排队、完成和错误数；稳定会话结束前前两者应相等。
- `last_rtsp_response_latency_ms` / `max_rtsp_response_latency_ms` 及 `rtsp_response_over_250ms`：定位 Lua/前台 UI 导致的控制链路延迟。
- `last_disconnect_pending_responses` / `last_disconnect_pending_methods`：若非正常断开时仍有待发回复，可直接判断为 RTSP 控制链路积压。
- `overlay_updates` / `overlay_updates_coalesced` / `max_overlay_render_ms`：确认歌词或元数据频繁更新没有直接占满事件循环。

诊断时应看一段时间内的增量，不要只看累计总数。一次启动早期的计数不等于持续问题。

## 构建、测试和发布注意事项

- 使用 ESP-IDF 6.0.2 和 ESP32-S3 Xtensa 工具链。
- 正式发布的 `airplay_core.so` 使用已验证的 `-Os`。`-O2` 版本在 iPhone 加密 ALAC 协商阶段触发 launcher 重启，故已撤回；根因定位和充分真机回归前，不应再次启用 `-O2/-O3`。
- 模块必须是 PIC 共享对象，且 `nm -D -u` 结果为空，不能引用宿主固件未导出的 IDF/libc 符号。
- Espressif ALAC 静态库包含不适合动态加载的 section，CMake 会复制并用 `objcopy` 修补后再链接。
- Windows 环境中 Ninja 偶尔无输出挂起；可用 `ninja -t commands airplay_core_so` 取得 CMake 生成的精确命令并直接执行。
- 发布前必须运行主机密码学测试，再做 iPhone 加密 ALAC 真机测试。

### TODO：热路径的分段优化验证（暂不实施）

- 保持模块默认和非热路径为 `-Os`。
- 仅对 AES、RTP 和 PCM 的候选热点函数或独立编译单元，逐项尝试 `-O3`，不得把整个动态模块切到 `-O3`。
- 每一项都要完成主机密码学测试、PC 协议探针、iPhone 加密 ALAC 长时间播放，以及前台图形 App 并发的真机回归；出现重连、跳出、Launcher 重启或音质回退即撤回。

### 构建原生核心

在已加载 ESP-IDF 6.0.2 环境的终端中，从 `airplay_service/src` 执行：

```powershell
idf.py -B build-v6.0.2 reconfigure
ninja -C build-v6.0.2 airplay_core_so
```

产物会复制到 `package/modules/airplay_core.so`。不要在发布文档中固定开发者的 SDK 或工作区路径。

### 测试与调试

主机密码学回归测试：

```powershell
python tests/test_crypto_host.py
```

设备加载服务后，可通过 Lua 控制台执行 `AIRPLAY_SERVICE.self_test()` 检查服务能力。PC 端协议探针和参数说明见 [`tools/raop_pcm_probe.py`](tools/raop_pcm_probe.py)；调试时应使用测试设备的地址，不要把具体局域网 IP 写入对外文档。

## 明日图形 App 计划

- 本地音乐播放器空闲时保持现有本地文件 UI；状态接口 `playing=true` 时切换到 AirPlay Now Playing 页面。
- 展示标题、歌手、专辑、进度和封面；标准 AirPlay 元数据通常不带歌词，可按标题/歌手匹配本地歌词或后续歌词源。
- 使用 `left/right` 峰值做基础频谱/波形动画；若需要真正 FFT，需要在原生核心增加低成本频带统计，避免把 PCM 跨 VM 复制给 Lua。
- 接入音频焦点：本地播放器与 AirPlay 不可同时占用 I2S，UI 切换必须和 `set_audio_focus_handler` 状态一致。
- 增加长时间播放、网络切换、来电/暂停、断线重连和本地播放恢复测试。
