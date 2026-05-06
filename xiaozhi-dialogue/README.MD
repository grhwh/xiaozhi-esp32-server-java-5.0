这是一个**可独立启动的实时语音对话模块**，负责处理 ESP32 设备的 WebSocket 连接和语音交互。

### 核心功能

**1. WebSocket 通信服务**

* [`DialogueApplication.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/DialogueApplication.java") - Spring Boot 启动入口
* [`WebSocketHandler.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/communication/server/websocket/WebSocketHandler.java") - WebSocket 消息处理，支持文本和二进制消息
* [`MessageHandler.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/communication/common/MessageHandler.java") - 统一消息分发处理

**2. 会话管理**

* [`SessionManager.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/communication/common/SessionManager.java") - 管理所有连接会话，设备注册，验证码状态
* [`ChatSession.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/communication/common/ChatSession.java") - 会话上下文，音频流管理
* 支持横向扩展，通过 Redis Pub/Sub 实现实例间协作

**3. 音频处理管道**

* [`VadService.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/audio/VadService.java") - 语音活动检测 (Silero VAD 模型)
* [`AecService.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/audio/AecService.java") - 回声消除
* 支持 Opus 编解码，PCM 处理

**4. 对话核心**

* [`DialogueService.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/DialogueService.java") - 对话处理主服务
* [`Persona.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/runtime/Persona.java") - 角色实体，聚合 ChatModel、TTS、Player
* 集成 STT (语音识别) → LLM → TTS (语音合成) 完整流程

**5. LLM 工具调用**

* [`IotService.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/llm/tool/device/IotService.java") - IoT 设备控制
* [`DeviceMcpService.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/llm/tool/mcp/device/DeviceMcpService.java") - MCP 协议工具
* 内置工具：音乐播放、角色切换、会话退出等

**6. 音频播放**

* [`Player.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/playback/Player.java") - 音频播放器
* [`Synthesizer.java`](https://file+.sourcegraphstatic.com/main-resource-nonce?877583319# "点击打开文件: xiaozhi-dialogue/src/main/java/com/xiaozhi/dialogue/playback/Synthesizer.java") - TTS 合成调度

### 技术栈

* Spring Boot 3 + WebSocket
* Spring AI (LLM + MCP Client)
* ONNX Runtime (VAD 模型推理)
* WebRTC (音频处理)
* Redis (分布式会话)
* MyBatis Plus (数据持久化)

### 设计特点

* 支持打断 (abort) 机制，用户说话时中断 TTS 播放
* 虚拟线程并发，高效处理音频流
* 事件驱动架构，松耦合组件通信



## Redis 和数据库依赖分析

### Redis 的作用

| 功能 | 类 | 说明 |
|------|-----|------|
| 设备-实例映射 |DeviceRegistry| 集群部署时，记录设备连接到哪个实例 |
| 跨实例广播 |RedisBroadcast/RedisSubscriber| 角色变更/配置变更/会话关闭等事件通知所有实例 |
| 缓存 | spring.cache.type: redis | 配置缓存、Token 缓存等 |

**核心用途：支持多实例横向扩展**

---

### 数据库的作用

| 功能 | Repository | 说明 |
|------|------------|------|
| 设备信息 | DeviceRepository| 设备注册/绑定/状态更新 |
| 角色配置 | RoleRepository | 获取角色的 STT/TTS/LLM 配置 |
| 系统配置 | ConfigRepository | 获取 STT/TTS 服务配置 |

**核心用途：持久化设备和角色配置数据**

---
