# Unspoken — 一切尽在不言中

Unspoken 是一款端到端加密的匿名 iOS 一对一聊天 App。它超越了传统即时通讯，让你能实时看到对方正在输入的内容——包括犹豫、修改的每一个细节。

## 功能特性

- **实时输入显示** — 对方输入时，内容实时出现在你屏幕上的预览气泡中
- **端到端加密** — RSA-2048 密钥交换，AES-256-GCM 消息加密，服务器永远看不到明文
- **完全匿名** — 无需账号、手机号或邮箱
- **固定房间（Pinned Room）** — 让房间在 App 重启、服务器重启后依然存在；对方离线时消息自动排队，上线后送达
- **告别不打断** — 取消固定不会让房间立刻消失：它会以只读状态保留 7 天，让对方从容读完最后那几句话
- **图片与表情包** — 发送相册照片，或直接按关键词搜索表情包
- **按住说话** — 按住麦克风按钮说话，松手发送。对方离线时（固定房间）这条语音会一直等到对方上线再送达
- **心率分享** — 通过 Apple Watch 将实时心率分享给对方，对方会以触感震动感受到你的心跳节奏
- **连接自检** — 首页的「Speed Test」会对服务器完整演练一遍聊天，再用大白话告诉你这条线路好不好用：消息多久送达、发一张照片要几秒、发一条语音要多久
- **截图保护** — 聊天内容无法被截图或录屏捕获
- **自动重连** — Wi-Fi 与蜂窝网络切换或任何断线场景下自动恢复连接

## 工作原理

1. 一方创建房间并分享房间链接
2. 另一方通过链接加入
3. 完成密钥交换，建立加密通道
4. 开始聊天；你输入的内容会实时出现在对方屏幕上
5. 按发送提交消息，或直接清空——完全由你决定

## 技术架构

```
iOS 客户端 (SwiftUI)  ←—— WSS ——→  Python 服务器  ←—— WSS ——→  iOS 客户端 (SwiftUI)
```

- **iOS 客户端** — SwiftUI，[Starscream](https://github.com/daltoniam/Starscream) 处理 WebSocket，CryptoKit + Security framework 负责加密
- **服务器** — 单文件 Python（约 800 行），`asyncio` + `websockets`，JSON 文件持久化
- **watchOS 伴侣 App** — HKWorkoutSession 获取实时心率，WatchConnectivity 将 BPM 传至 iPhone

## 开始使用

### 直接使用托管版本

在 App Store 下载 Unspoken，连接默认服务器即可使用。App Store 版本为付费 App，用于支持服务器运营和持续开发。

### 自己部署服务器

如果你希望运行自己的服务器：

```bash
cd Unspoken-server
pip install websockets cryptography
python3 unspoken.py --no-ssl   # 本地开发模式
```

生产环境请在 `unspoken.py` 中配置 TLS 证书路径（推荐 Let's Encrypt），去掉 `--no-ssl` 参数运行。

### 自己编译客户端

```bash
open Unspoken.xcodeproj
```

需要 Xcode 15+，部署目标 iOS 15.0+。唯一依赖 Starscream 通过 Swift Package Manager 管理。

在连接界面填写你的服务器地址和端口，或使用 URL Scheme 直接跳转：

```
unspoken://your-host:8765/room_id
```

## 开源协议

MIT — 你可以自由使用、修改和再分发本代码，包括用于商业目的，保留版权声明即可。

代码开源的目的是让任何人都可以审查，确认没有后门或隐藏的数据收集。有技术能力的用户欢迎自行编译和部署。如果你希望开箱即用，App Store 版本连接的是作者维护的托管服务器。
