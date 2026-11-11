# HEADPHONE LAB 独立宿主（HeadphoneLabHost）

以独立 macOS 应用方式运行 beyerdynamic **HEADPHONE LAB** 插件（AU），把它的耳机校准与音箱仿真带到系统级音频——任何应用的声音都可以经过插件处理。

**非官方项目**，与 beyerdynamic 无任何隶属关系；插件本体需自行从 [beyerdynamic 官网](https://www.beyerdynamic.com) 下载安装。

## 特性

- **全自动接管**（eqmac 式体验）：启动 app 即自动把系统输出切到「〈当前设备〉 (Headphone Lab)」虚拟设备；在系统菜单里切换扬声器/耳机会自动跟随改名
- **自研音频驱动**（AudioServerPlugIn）：音频在 `coreaudiod` 内经共享内存推送给 app——全链路无音频输入流，**无麦克风指示灯、系统音量键原生可用**
- 插件原生界面完整嵌入，EQ 参数自动保存
- 静音 8 秒自动挂起引擎（释放防睡眠断言）；合盖睡眠、设备插拔自动恢复
- 无外部依赖（不需要 BlackHole/eqMac/Loopback）

## 安装与使用

```bash
# 1. 安装音频驱动（需要密码，重启 coreaudiod）
make install-driver-system

# 2. 构建并运行 app
make run
```

日常使用：打开 app → 自动接管 → 在插件界面选择你的耳机型号即可。退出 app 自动切回真实设备并还原音量。

也可以下载 Release 里的 app 解压使用（见下方说明）。

## 构建

要求：macOS 14+、Xcode 命令行工具。

```bash
make          # 构建 app + 驱动 → dist/
make run      # 运行 app
make clean
```

## 架构

```
系统声音 → HeadphoneLab.driver（coreaudiod 内写共享内存）
        → app（AVAudioSourceNode）→ HEADPHONE LAB 插件 → 真实输出设备
```

- `Sources/driver/`：AudioServerPlugIn 虚拟输出设备（移植自 [eqMac](https://github.com/bitgapp/eqMac) 驱动，Apache 2.0），实现动态改名、音量控件、共享内存推送
- `Sources/ShmCapture.swift`：共享内存环形缓冲协议
- `Sources/HostEngine.swift`：AVAudioEngine 图（source → 插件 → 输出，图内重采样）
- `Sources/main.swift`：接管路由、音量同步、唤醒/看门狗自愈
- `main` 分支保留无驱动方案（BlackHole/Oray + 聚合设备回退），可用 `disableExperimentalDriver=1` 切换

## macOS 27 踩坑记录（本项目实测）

- 带输入流的音频会话，输出只能绑定双工设备（`-10851`）→ 采集必须独立于主 app
- 麦克风指示灯对任何输入流都会亮，无豁免 API → 驱动 shm 推送方案根治
- 单设备聚合 `stacked=1` 静音（需 `stacked=0`）
- 全双工（输入+输出流）插件设备的 IO 在本版系统上无法激活，输出单工正常
- 设备采样率设置请求被系统会话静默忽略 → 图内重采样兜底
- `pkill` 不触发 `applicationWillTerminate` → sigaction + 管道兜底清理

## 许可证

[Apache License 2.0](LICENSE)。驱动部分移植自 eqMac 并注明出处。app 图标使用 beyerdynamic 官方 logo，版权归属原厂商。
