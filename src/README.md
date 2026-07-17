# Native core

本目录构建 `/sd/apps/airplay_service/modules/airplay_core.so`。模块使用 SDK `0x00030000` 的 `module_host_api_v2` 基础接口，只通过稳定宿主过程 ID 获取 Lua、PSRAM、任务和 I2S。完整 ABI 头文件已随项目固化在 [`main/module_abi.h`](main/module_abi.h)，因此本项目不依赖任何相邻 app 或固件源码目录。它是针对 HoloCubic 固件 1.200 的同步副本；构建更新固件时，应先以固件工程的 `src/dynmod/module_abi.h` 更新此文件并重新回归。正式构建对模块自身使用已在真机验证的 `-Os`；`-O2` 在 iPhone 加密 ALAC 协商阶段触发 launcher 重启，须完成根因分析后才能再次启用。

Lua 导出接口：

- `capabilities() -> { apple_challenge, aes, alac, l16, native_socket_abi }`
- `apple_response(challenge_b64, local_ip, mac_hex) -> response_b64`
- `configure({ codec, fmtp, rsaaeskey, aesiv, payload_type, sample_rate, channels })`
- `start({ i2s_port, data_out_pin, output_channels, buffer_count, buffer_len })`
- `push_rtp(packet) -> true | nil, err`
- `flush()`
- `stop()`
- `set_volume(db, linear_gain)`
- `network_start({ audio_port, control_port, timing_port })`
- `network_set_peer({ ip, control_port, timing_port })`
- `network_set_timing(active)` / `network_clear_peer()` / `network_stop()`
- `state() -> { left, right, buffered_packets, received, lost, ... }`

实现分为：

1. `airplay_crypto.c`：共享 AirPlay 1 RSA 私钥的 Montgomery 运算、PKCS#1 v1.5、OAEP/SHA-1 和查表优化的 AES-128-CBC。
2. `airplay_core.c`：原生 RTP/control/timing UDP worker、RTP/PCM 双层缓冲、短丢包隐藏、ALAC/L16 解码、自适应重传、双核生产者/消费者 I2S 流水线和模块 ABI。
3. `airplay_socket_abi.h`：[`../README_HOST_ABI.md`](../README_HOST_ABI.md) 所述 SDK3 optional Socket 过程 ID 与 POD 声明；完整 ABI 定义在同目录的 `module_abi.h`。
4. `CMakeLists.txt`：把核心编译成无未解析符号的 Xtensa PIC 共享对象，并修补 Espressif ALAC 静态库中不适合动态加载的 section。

`build_stub.c` 只用于让普通 `idf.py build` 校验项目配置，不会进入动态模块。

构建：

在已加载 ESP-IDF 6.0.2 环境的终端中执行：

```powershell
idf.py -B build-v6.0.2 reconfigure
ninja -C build-v6.0.2 airplay_core_so
```

产物会自动复制到 `../package/modules/airplay_core.so`。
