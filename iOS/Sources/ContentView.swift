import SwiftUI

struct ContentView: View {
    @StateObject private var microphone = MicrophoneStreamer()
    @AppStorage("computerHost") private var host = ""
    @AppStorage("computerPort") private var port = "54345"
    @AppStorage("connectionHint") private var connectionHint = "usb"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("连接电脑")) {
                    Picker("连接方式", selection: $connectionHint) {
                        Text("USB 网络（推荐）").tag("usb")
                        Text("Wi-Fi 局域网").tag("wifi")
                    }
                    .disabled(microphone.isRunning)
                    TextField("电脑 IP 地址，例如 192.168.1.100", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(microphone.isRunning)
                    TextField("电脑客户端显示的端口", text: $port)
                        .keyboardType(.numberPad)
                        .disabled(microphone.isRunning)
                }
                Section(header: Text("音频")) {
                    Text("PCM · 硬件采样率 · 单声道 · 16 位")
                    Text("请在 AndroidMic 电脑端选择 Wi-Fi / TCP，并将输出设备设为虚拟音频线。电脑端会按收到的音频格式进行转换。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Button(microphone.isRunning ? "停止传输" : "连接并开启麦克风") {
                        if microphone.isRunning {
                            microphone.stop()
                        } else {
                            microphone.start(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
                        }
                    }
                    .foregroundColor(microphone.isRunning ? .red : .accentColor)
                    Text(microphone.status).font(.footnote)
                }
                Section(header: Text("使用说明")) {
                    if connectionHint == "usb" {
                        Text("用数据线连接 Windows，安装 Apple 设备支持驱动，在 iPhone 上信任电脑并开启个人热点。电脑出现 USB 网络适配器后，在电脑运行 ipconfig，填写该适配器的电脑 IPv4 地址（不是手机的网关地址）。")
                        Text("电脑端仍选择 TCP。若仅监听 Wi-Fi 地址，请切换到 USB 网卡地址或 0.0.0.0。USB 个人热点取决于运营商支持；本版不包含独立的 Apple USB 隧道服务。")
                    } else {
                        Text("手机和电脑需处于同一个局域网，填写电脑的局域网 IPv4 地址。")
                    }
                    Text("允许麦克风和本地网络权限；电脑防火墙需允许 AndroidMic。切换连接方式只改变操作提示，实际均通过 TCP 传输，应用无法保证系统一定选择 USB 路由。验证 USB 时可断开电脑 Wi-Fi。")
                    Text("本版为非官方 iOS 移植，支持网络 TCP 音频传输，不包含安卓 USB ADB、UDP 或降噪功能。音频不加密，请只在可信网络使用。")
                    Text("未签名 IPA 需要自行签名后安装；无需登录或上传录音到云端。")
                }.font(.footnote)
            }
            .navigationTitle("手机麦克风")
        }
        .navigationViewStyle(.stack)
    }
}
