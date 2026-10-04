# AndroidMic 非官方 iOS 客户端

原项目仅提供安卓客户端，本目录是协议兼容的原生 Swift iOS 移植，不是将 APK 转换成 IPA。沿用仓库 GPL-3.0 许可。

> 未签名 IPA 需要自行签名才能安装。编译成功与协议测试通过不代表已在 iPhone 上完成端到端验证。

## 有线连接优先

1. Windows 安装 Apple Devices 所需的 Apple 设备支持驱动，用可传输数据的 USB 线连接 iPhone，并选择信任电脑。
2. iPhone 开启个人热点。该功能需要系统与运营商支持。
3. Windows 出现 Apple USB 网络适配器后，运行 `ipconfig`，查找该适配器的电脑 IPv4 地址。不要填手机网关地址。
4. AndroidMic 电脑端选择 Wi-Fi / TCP，监听 USB 网卡地址或所有接口，端口默认 `54345`。按需放行防火墙，不要关闭整个防火墙。
5. 手机输入该电脑地址与端口，点击连接。首次允许麦克风和本地网络权限。
6. 验证确实使用 USB 时断开电脑 Wi-Fi，确认连接仍正常。界面中的 USB / Wi-Fi 选择只是配置提示，不会强行指定网络路由。

这是 TCP over USB 网络，不是 USB Audio Class 麦克风，也不是 usbmux 隧道。没有个人热点时可用 Wi-Fi；独立 USB 隧道未实现。

## 低延迟实现与限制

- 使用 `AVAudioSinkNode` 按实际硬件音频周期接收输入，避免依赖 input tap 的不确定缓冲粒度。
- 请求 5 ms I/O 缓冲；系统可能使用不同值，界面显示实际 `ioBufferDuration` 和 `inputLatency`。二者都不是完整端到端延迟。
- 使用实际硬件采样率、PCM16 单声道，不在手机做重采样、编码压缩或降噪。
- 上报的采样率就是接入 `AVAudioSinkNode` 的格式采样率，也正是渲染回调的帧率；硬件无法满足 48000 时按实际速率上报，不会出现“上报一个值、实际发另一个值”的无声重采样。
- Float32 → PCM16 的采样转换使用满量程 `32767` 缩放并配合 `lrintf`（就近舍入，默认银行家舍入），转换前对 `[-1, 1]` 做对称 clamp，非有限值（NaN/±Inf）映射为 0。这样避免截断带来的直流偏置，以及 ±1.0 映射不对称引入的偶次失真；不做抖动（dither），因为在采集链上叠加噪声对传声质量只有副作用，抖动更适合量化位深远低于 16 bit 且需要感知整形时。
- 音频会话为 `AVAudioSession.Category.record` + `Mode.measurement`。`measurement` 关闭系统 AGC、降噪等语音处理型 DSP，尽量原样采集麦克风信号交给电脑端自行处理；默认的 `.voiceChat`/`.spokenAudio` 会做增益控制，容易在轻声段落“抽气”或门限截断，不利于传声质量。代价是电平完全依赖麦克风与用户摆位，没有系统自动补偿。
- 硬件为多声道时，`AVAudioEngine.connect` 以显式单声道格式接入，由系统转换器完成下行混音；只有在无法构造单声道格式时，回调内才做逐帧通道合并，并在检测到两通道能量相近但相关性为负（相位抵消特征）时改用能量最高的单通道，避免平均后静音。这里不做“每帧挑最大通道”之类会在通道间切换产生爆音的策略。
- 采集回调只做有界的多声道→单声道转换并写入一块预分配的 C11 SPSC 环形缓冲（`AudioRingBuffer.c`）：回调内不分配堆内存、不加锁、不派发队列、不调用 Network.framework。若环形缓冲放不下一个完整音频块，回调直接丢弃该块（有界丢包），不会阻塞音频线程。
- 高优先级串行队列以约 1 ms 轮询环形缓冲，取整块后组装 protobuf 并通过 `NWConnection.send` 发送；发送采用连接级背压，最多 3 个在途，拥塞时丢弃新块而非无限积压。
- 环形缓冲 32 KiB（48 kHz 单声道约 341 ms），“过期丢弃阈值”设为 400 ms，大于环形缓冲容量，因此正常负载下不会触发丢弃分支；该分支仅在严重调度停滞后作为安全阀，避免把数百毫秒旧音频一次性发出去。界面会每约 5 秒在出现丢块时显示采集丢、拥塞丢、过期丢的计数，便于观测是否持续丢音。
- 保持未压缩 PCM，不引入 AAC/Opus：虽然压缩能降低带宽，但软件编码会增加采集链延迟与抖动、引入编码器状态与第三方依赖，且 TCP 上还需要额外封装；在局域网/USB 网场景带宽不是瓶颈，端到端延迟与传声质量优先，因此不做为实现而实现。
- 拆除顺序：先停消费者（并在发送队列上同步等待其退出），再停 `AVAudioEngine`（`stop()` 返回后渲染回调不再执行），之后才释放环形缓冲与临时缓冲，避免释放后仍被回调访问。
- TCP 设置 `noDelay`，整帧一次提交。严重拥塞仍可能有 TCP 内核缓冲与队头阻塞，不能保证固定延迟。
- 电脑端优先选择相同采样率，关闭不需要的降噪与音效；虚拟音频线及目标应用的音频缓冲仍影响总延迟。

诚实说明（不做超出实现的承诺）：

- 该环形缓冲只在 `_Atomic size_t` 本身无锁时才真正无锁；代码在创建时用 `atomic_is_lock_free` 检测，界面会在非无锁平台给出提示。Apple arm64/x86_64 上为无锁。
- 渲染回调仍会通过 `weak self` 读取 Swift 对象属性，存在极小的引用计数开销；这不是教科书级的硬实时实现。
- 上述改动只是移除采集路径上的分配、锁和线程跳转，**不等于消除了端到端延迟**。

## 测试与构建

GitHub Actions 工作流 `Chinese Android and unsigned iOS` 使用 macOS、XcodeGen 和 Xcode 构建真机 Release `.app`，禁用签名后包装到 `Payload` 生成 IPA。

协议单元测试验证 PCM 字节载荷、protobuf 标签/变长整数及 4 字节大端 TCP 长度前缀。环形缓冲测试验证 SPSC 的空/满、跨回绕、丢弃、无锁检测以及生产者/消费者并发字节完整性。两者都不验证麦克风硬件、权限、后台运行和电脑端播放。

在 macOS 上本地运行与 CI 相同的两条测试：

```sh
# 协议（与 CI 相同命令）
swiftc Sources/AudioPacketEncoder.swift Tests/main.swift -o /tmp/androidmic-protocol-test
/tmp/androidmic-protocol-test

# 环形缓冲（需要 clang；仅 macOS/Linux）
clang -std=c11 -O2 -Wall -Wextra -pthread Sources/AudioRingBuffer.c Tests/ring_test.c -o /tmp/androidmic-ring-test
/tmp/androidmic-ring-test
```

生成工程与真机构建（禁签名）：

```sh
cd iOS
brew install xcodegen && xcodegen generate
xcodebuild -project AndroidMicIOS.xcodeproj -scheme AndroidMicIOS -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

真机验收应至少覆盖：USB 断 Wi-Fi、Wi-Fi、拒绝权限、错误端口、电脑断连、锁屏录音、来电中断、连续运行 30 分钟及音频回环测量。测量请同时录制参考声音与电脑播放声音，用波形间隔统计中位数和 P95，不能用网络 ping 代替音频端到端延迟。

## 安全与范围

声音仅发送到填写的电脑地址，客户端不上传录音到云端。协议沿用上游明文 TCP 和固定握手，不能提供加密或身份认证；只在可信网络使用。支持网络 TCP，不支持安卓 USB ADB、UDP 或内置虚拟麦克风驱动。
