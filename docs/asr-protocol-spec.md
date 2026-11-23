# 流式语音识别（ASR）网络通信协议规格文档

> 本文档为纯网络通信协议与数据格式规范，面向 macOS 独立客户端实现，仅描述客观的网络端点、握手参数、帧结构、编解码及加解密/签名规范。

---

## 0. 协议总览与通用音频约定

### 0.1 渠道对比总览

| 维度 | 豆包输入法 | 微信输入法 | Chatterfly | 千问输入法 | 八哥说（有道） |
|---|---|---|---|---|---|
| **传输协议** | HTTPS 设备注册 + WSS | WSS（内嵌 HTTP-over-Protobuf） | WSS | WSS | HTTPS Ticket + WSS |
| **账号要求** | 免登录（匿名设备注册） | 免登录（ECDH + 匿名 UIN） | 免登录（可选 Bearer Token） | 免登录（本地生成 UTDID） | 需 `.youdao.com` 登录 Cookie |
| **音频格式** | 裸 Opus（VOIP, 16 kbps） | 自定义容器封装 Opus（AUDIO, 64 kbps） | 裸线性 PCM（`int16_le`） | 裸线性 PCM（`int16_le`） | 裸线性 PCM（`int16_le`） |
| **分帧/分包** | 20 ms / 帧，逐帧发送 | 20 ms / 帧，每 6 帧（120 ms）打包 | 20 ms / 帧，逐帧发送 | 固定 3840 字节 / 包（120 ms） | 20 ms / 帧，逐帧发送 |
| **上行帧封装** | Protobuf（Binary 帧） | HTTP-over-Protobuf（Binary 帧） | 加密首帧（Text）+ 裸 PCM（Binary） | Protobuf（Binary 帧） | JSON 控制帧（Text）+ 裸 PCM（Binary） |
| **下行帧格式** | Protobuf 内嵌 JSON | HTTP-over-Protobuf（AES + Snappy） | 明文 JSON | 明文 JSON | 明文 JSON |
| **应用层加密/签名** | 无（仅 TLS） | secp128r1 ECDH + AES-256-ECB + Snappy + SHA-256/MD5 | RSA-OAEP(SHA-256) + AES-256-CBC | AES-128-CBC + HMAC-SHA1 | MD5 参数签名 |
| **长连接复用** | 单次识别一连 | 支持预建连与长连接复用 | 单次识别一连 | 支持预建连与长连接复用 | 单次识别换新 Ticket |

### 0.2 通用音频输入基线

所有渠道均以同一原始采集格式为基准（必要时再经 Opus 编码）：

- **采样率**：`16,000 Hz`
- **声道数**：`1`（单声道 Mono）
- **采样位深与字节序**：16-bit 有符号整数，小端序（`Signed 16-bit Little-Endian PCM`，简称 `int16_le`）
- **基础帧长**：`20 ms` = `320` 采样点 = `640` 字节原始 PCM；停止采集时若末尾残留不足 320 采样点，在末尾补零（`0x0000`）凑齐一帧。
- **前导静音与实时节拍（Pacing）**：
  - 对于豆包输入法、微信输入法、千问输入法，建议在真实语音开始前先发送 **200 ms（10 帧 × 20 ms）全零静音帧** 以协助服务端 VAD 起音，并以**不快于实时速率（每 20 ms 最多送出 1 帧）**发送音频，防止建连/握手期间缓存积压的音频瞬间突发写入导致服务端限流或拒收。

### 0.3 Protocol Buffers 编码约定

本文中提及的 Protobuf 帧均遵循标准 **Protocol Buffers v2/v3 二进制线格式（Wire Format）**：

- **Varint（Wire Type `0`）**：小端 Base-128 变长无符号整数。
- **Length-delimited（Wire Type `2`）**：`uvarint(byte_length)` 后紧跟原始字节流（用于 `string`、`bytes` 与嵌套 `message`）。
- **KV 键值对子消息**：文中标记为 `KV(key, value)` 的字段，表示嵌套的 Length-delimited 子消息，固定包含两个字符串字段：`field 1 = key`、`field 2 = value`。

---

## 1. 豆包输入法（Doubao IME）

### 1.1 服务端点与连接方式

1. **匿名设备注册（HTTPS POST）**
   - URL：`https://log-klink.zijieapi.com/service/2/device_register/`
   - 用途：获取服务端签发的 `device_id`（下称 `did`），本地持久化缓存供后续复用。
2. **流式语音识别（WebSocket over TLS）**
   - URL：`wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=401734&device_id=<did>`
   - 连接方式：每次识别新建一条 WSS 连接，连接超时建议 10 秒。

### 1.2 请求头、握手参数与设备标识生成规则

#### 1.2.1 固定应用参数

| 参数名 | 固定值 |
|---|---|
| `aid` | `401734` |
| `app_name` | `oime` |
| `channel` | `official` |
| `version_code` | `100406010` |
| `version_name` | `1.4.6` |
| `manifest_version_code` | `100406010` |
| `update_version_code` | `100406010` |
| `package` | `com.bytedance.android.doubaoime` |
| ASR 内置鉴权令牌（App Token） | `OrnqKvSSrs` |

#### 1.2.2 设备画像与 User-Agent

每次执行设备注册时，选定一组一致的 Android 设备画像参数（品牌 `brand`、型号 `model`、系统版本 `os`、API 级别 `api`、构建号 `build`、分辨率 `resolution`、像素密度 `dpi`），并与获取到的 `did` 绑定持久化保存。例如：

| 品牌 (`brand`) | 型号 (`model`) | Android (`os`) | API (`api`) | 构建号 (`build`) | 分辨率 (`resolution`) | DPI (`dpi`) |
|---|---|---|---|---|---|---|
| `google` | `Pixel 7 Pro` | `16` | `36` | `BP2A.250605.031.A2` | `1080*2340` | `420` |
| `google` | `Pixel 8` | `15` | `35` | `AP4A.250205.002` | `1080*2400` | `420` |
| `samsung` | `SM-S9210` | `14` | `34` | `UP1A.231005.007` | `1080*2340` | `480` |
| `Xiaomi` | `23127PN0CC` | `14` | `34` | `UKQ1.230804.001` | `1200*2670` | `440` |

`User-Agent` 模板（用于注册请求与 WebSocket 握手）：

```text
com.bytedance.android.doubaoime/100406010 (Linux; U; Android <os>; en_US; <model>; Build/<build>; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)
```

#### 1.2.3 设备注册请求（HTTPS POST）

- **HTTP 请求头**：
  - `User-Agent`：按 1.2.2 模板生成
  - `Content-Type`：`application/json`
- **URL Query 参数**：
  - 上述 8 个固定应用参数；
  - 设备环境参数：`device_platform=android`、`os=android`、`os_api=<api>`、`os_version=<os>`、`device_type=<model>`、`device_brand=<brand>`、`device_model=<model>`、`resolution=<resolution>`、`dpi=<dpi>`、`language=zh`、`timezone=8`、`access=wifi`、`rom=<build>`、`rom_version=<build>`；
  - 动态参数：`ssmix=a`、`_rticket=<当前 Unix 毫秒时间戳>`、`cdid=<随机 UUIDv4>`、`ac=wifi`。
- **JSON 请求体**：
  - `magic_tag`：`"ss_app_log"`
  - `_gen_time`：当前 Unix 毫秒时间戳（64 位无符号整数）
  - `header`：对象，包含上述全部应用参数和设备环境参数，外加：
    - `device_id`：`0`，`install_id`：`0`
    - `cdid`：与 Query 相同的 UUIDv4
    - `openudid`：16 位小写十六进制随机数（64-bit 随机值）
    - `clientudid`：独立随机 UUIDv4
    - `region`：`"CN"`，`tz_name`：`"Asia/Shanghai"`，`tz_offset`：`28800`
    - `sim_region`：`"cn"`，`carrier_region`：`"cn"`，`cpu_abi`：`"arm64-v8a"`，`build_serial`：`"unknown"`
    - `not_request_sender`：`0`，`sig_hash`：`""`，`google_aid`：`""`，`mc`：`""`，`serial_number`：`""`
- **响应解析**：HTTP 200 JSON 中优先读取 `device_id_str`（字符串），若为空则回退读取整数 `device_id` 并转字符串。若结果为空或 `"0"` 则判定注册失败。

#### 1.2.4 WebSocket 握手请求头

| Header 名 | 取值 |
|---|---|
| `User-Agent` | 与已注册 `did` 绑定的设备 `User-Agent` |
| `proto-version` | `v2` |
| `x-custom-keepalive` | `true` |

### 1.3 音频输入格式要求

- **前置格式**：16 kHz / 单声道 / 16-bit PCM，20 ms / 帧（320 采样点），建议加 200 ms 前导静音。
- **编码方式**：标准 **Opus 裸数据包**（无 Ogg/WebM 容器头）。
  - `sample_rate`：`16000`
  - `channels`：`1`
  - `application`：`OPUS_APPLICATION_VOIP`（`2048`）
  - `bitrate`：`16000` bps
  - `complexity`：`5`
- **打包方式**：每 20 ms 编码产生 1 个 Opus 包，直接作为单个 Protobuf 帧的 `field 7` 发送。

### 1.4 上行消息帧结构

所有上行消息均为 **WebSocket Binary 帧**，承载如下 Protobuf 消息（空字符串、空字节或值为 0 的可选字段可省略）：

| 字段编号 | Wire Type | 类型 | 说明 |
|---|---|---|---|
| `2` | 2 (bytes) | string | 应用鉴权令牌。控制帧填 `"OrnqKvSSrs"`；音频帧（`TaskRequest`）省略 |
| `3` | 2 (bytes) | string | 服务标识，固定为 `"ASR"` |
| `5` | 2 (bytes) | string | 方法名：`StartTask` / `StartSession` / `TaskRequest` / `FinishSession` |
| `6` | 2 (bytes) | string | JSON 负载文本（会话配置或帧元数据） |
| `7` | 2 (bytes) | bytes | 单帧裸 Opus 音频字节（仅非末帧的 `TaskRequest` 携带） |
| `8` | 2 (bytes) | string | 单次会话请求 ID（随机 UUIDv4，整次识别全程一致） |
| `9` | 0 (varint) | uint64 | 音频流序列标记（仅 `TaskRequest` 携带）：首帧 = `1`，中间帧 = `3`，结束空帧 = `9` |

#### 会话交互顺序

1. **启动任务**：发送 `field 2 = "OrnqKvSSrs"`, `field 3 = "ASR"`, `field 5 = "StartTask"`, `field 8 = <rid>`；等待下行 `event == "TaskStarted"` 且 `status == 20000000`（超时 10 秒）。
2. **启动会话**：发送 `field 2 = "OrnqKvSSrs"`, `field 3 = "ASR"`, `field 5 = "StartSession"`, `field 8 = <rid>`，`field 6` 为如下 JSON：
   ```json
   {
     "audio_info": {
       "channel": 1,
       "format": "speech_opus",
       "sample_rate": 16000
     },
     "enable_punctuation": true,
     "enable_speech_rejection": true,
     "extra": {
       "app_name": "oime",
       "cell_compress_rate": 8,
       "did": "<did>",
       "enable_asr_threepass": false,
       "enable_asr_twopass": true,
       "input_mode": "stream"
     }
   }
   ```
   等待下行 `event == "SessionStarted"` 且 `status == 20000000`（超时 10 秒）。
3. **流式发送音频**：记首帧发送前的 Unix 毫秒时间戳为 `ts0`，对第 `i` 帧（`i = 0, 1, 2, ...`）：
   - `field 2`：省略
   - `field 3`：`"ASR"`
   - `field 5`：`"TaskRequest"`
   - `field 6`：`{"extra":{},"timestamp_ms":<ts0 + i * 20>}`
   - `field 7`：当前帧 Opus 编码字节
   - `field 8`：`<rid>`
   - `field 9`：`i == 0` 填 `1`，否则填 `3`

### 1.5 下行响应解析规则

下行消息均为 **WebSocket Binary 帧**封装的 Protobuf：

| 字段编号 | Wire Type | 类型 | 说明 |
|---|---|---|---|
| `4` | 2 (bytes) | string | 事件名（如 `TaskStarted`、`SessionStarted`、`SessionFinished`、`*Failed` 等） |
| `5` | 0 (varint) | int32 | 状态码（按 32 位有符号整数解读）；成功为 `20000000` |
| `6` | 2 (bytes) | string | 状态或错误信息描述 |
| `7` | 2 (bytes) | string | 识别结果 JSON 字符串（为空时忽略） |

#### 识别文本解析（`field 7` JSON）

解析 JSON 顶层的 `results` 数组，需兼容两种结构：

1. **整段累计模式**（`results` 中所有元素均不含 `index` 字段）：
   - 读取 `results[0].text`（非空）直接作为从头到当前的完整文本，覆盖此前全部文本。
2. **分句定稿模式**（元素包含整数字段 `index`）：
   - 遍历 `results` 中每条 `text` 非空的记录：
     - **单句定稿条件**：`extra.nonstream_result == true`，**或**（`is_interim == false` 且 `is_vad_finished == true`）。
     - 满足定稿条件：以 `index`（缺失时取当前最大索引 + 1）为键存入有序映射（相同 `index` 覆盖旧值），并清空当前未定稿句缓存。
     - 未满足定稿条件：更新当前未定稿句缓存（partial）。
   - **拼接展示文本**：按 `index` 升序拼接所有已定稿句，末尾拼接当前未定稿句。若相邻两段交界字符均不属于 CJK 区段（`U+2E80..U+9FFF`、`U+F900..U+FAFF`、`U+FF00..U+FFEF`），则在中间插入一个空格。

#### 终态与错误处理

- **整段最终定稿（final）**：收到 `event == "SessionFinished"`，取当前拼接结果作为最终文本。
- **服务端错误**：`event` 以 `"Failed"` 结尾，或在握手阶段对应事件的 `status != 20000000`。
- **风控恢复策略**：若握手失败，或最终以 `*Failed` 结束且无任何已识别文本（如设备被风控拒绝），应清除本地设备缓存、重新注册新 `did`；若本地留存了音频帧，可以约 4 倍速（每帧间隔约 5 ms）重放一次。

### 1.6 结束流与超时处理

- **结束流发送**：
  1. 发送 `TaskRequest` 结束空帧：`field 3 = "ASR"`、`field 5 = "TaskRequest"`、`field 6 = {"extra":{},"timestamp_ms":<ts0 + N * 20>}`、**省略 `field 7`**、`field 8 = <rid>`、`field 9 = 9`。
  2. 紧接着发送 `FinishSession`：`field 2 = "OrnqKvSSrs"`、`field 3 = "ASR"`、`field 5 = "FinishSession"`、`field 8 = <rid>`。
- **超时控制**：
  - 握手等待超时：每步 `10 秒`。
  - 流式接收兜底超时：`600 秒`（静音期间服务端不回包）。
  - 结束定稿等待超时：建议设为 `10 + (已发送音频帧数 / 200)` 秒（基础 10 秒叠加音频时长四分之一）。超时后若已有识别文本则返回已有文本，否则报错并关闭连接。

### 1.7 加密与签名

- 仅使用标准 **TLS 1.2/1.3（HTTPS / WSS）**，无应用层加解密与签名算法。

---

## 2. 微信输入法（WeType）

### 2.1 服务端点与连接方式

- **WebSocket 地址**：`wss://wetype.weixin.qq.com/`
- **连接方式**：
  - 握手时必须指定子协议头：`Sec-WebSocket-Protocol: wxws_pb`。
  - 单条 WSS 连接上采用**严格请求-响应（一问一答）**模式，在二进制 Protobuf 帧内承载类 HTTP `POST` 请求与响应。
  - 完整握手耗时约 400 ms，**建议预建连并在多次语音输入间复用该连接**；若复用连接上的首包失败，则重连重新握手并重发该包。

### 2.2 请求头、握手参数与设备标识生成规则

#### 2.2.1 固定协议常量

| 常量含义 | 固定值 |
|---|---|
| `HOST` | `wetype.weixin.qq.com` |
| 签名密钥（`SIGN_KEY`） | `zN7rB3bL4pO8jW1o`（16 字节 ASCII） |
| 初始引导密钥（`BOOT_KEY`） | `D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6`（32 字节 ASCII） |
| 客户端版本（`Kb-Version`） | `2.2.3(657)` |
| 操作系统类型（`Kb-OsType`） | `5`（macOS） |
| 平台标识（`Kb-Platform` 参与签名） | `2` |
| 系统版本（`Kb-SystemVersion`） | `27.0.0` |
| 设备型号示例 | `Mac16,12`（长度须 ≤ 17 字节） |

#### 2.2.2 设备标识（`device`）生成规则

设备标识为 **64 字符字符串**，与服务端签发的 `uin` 配对持久化存储：

1. 构造 32 字符主体：`body = "MAC" + ("0" 重复 17 - len(device_model) 次) + device_model + 12 位随机小写英文字母(a-z)`。
2. 计算 32 字符校验尾：`suffix = uppercase_hex(MD5(UTF8(body + SIGN_KEY)))`。
3. 最终设备标识：`device = body + suffix`。

#### 2.2.3 内层 HTTP 请求头规范

每次通过 Protobuf 发送内层 `POST` 请求时，均需组装如下请求头列表：

| Header 名 | 携带条件 | 取值说明 |
|---|---|---|
| `Kb-GenUinToken` | 仅 `/gen_uin_v2` | 密钥交换响应返回的令牌 |
| `Kb-Uin` | 全部请求 | 用户 UIN 十进制字符串（注册前为 `"0"`） |
| `Kb-DeviceCodeRestrictionV2` | 仅密钥交换与签发 UIN | `"1"` |
| `Kb-SharedKeySuffix` | 非密钥交换且已有会话密钥 | 32 字节会话密钥的最后 4 个 ASCII 字符 |
| `Kb-CmdId` | 非密钥交换 | 当前命令号十进制字符串 |
| `Kb-SubCmdId` | 非密钥交换 | `"0"` |
| `Kb-OsType` | 全部请求 | `"5"` |
| `Kb-Version` | 全部请求 | `"2.2.3(657)"` |
| `Kb-SystemVersion` | 全部请求 | `"27.0.0"` |
| `Kb-PackageType` | 全部请求 | `"3"` |
| `Use_DebugNet` | 全部请求 | `"0"` |
| `Kb-TimeStamp` | 全部请求 | 当前 Unix 毫秒时间戳字符串 |
| `Kb-BodyMd5` | 全部请求 | 加密后 HTTP Body 字节的 **MD5 32 位大写十六进制** |
| `Kb-TraceId` | 全部请求 | 16 位随机小写英文字母（`a-z`） |
| `Kb-TaskId` | 全部请求 | 密钥交换与签发 UIN 填命令号；其余请求在单条连接内从 `1` 开始逐次自增 |
| `Kb-Scene` | 全部请求 | `"2"` |
| `Kb-Sign` | 全部请求 | 64 位大写十六进制 SHA-256 签名（算法见 2.7） |
| `Content-Length` | 全部请求 | 加密后 HTTP Body 的十进制字节长度 |
| `Kb-CompressionType` | 全部请求 | `"1"`（未压缩）或 `"2"`（Snappy 压缩，仅语音识别接口） |
| `Content-Type` | 全部请求 | `"application/octet-stream"` |
| `HOST` | 全部请求 | `"wetype.weixin.qq.com"` |

#### 2.2.4 连接握手流程（顺序一问一答）

| 步骤 | 路径 (`path`) | 命令号 (`cmd`) | 压缩类型 | 加密密钥 | 请求/响应说明 |
|---|---|---|---|---|---|
| 1. 通道初始化 | `/timestamp` | `0` | `"1"` | 无（空 Body） | 发送空 Body，确认通道响应 |
| 2. 密钥交换 | `/oauth_pubkey_v2` | `2147483646` (`0x7FFFFFFE`) | `"1"` | `BOOT_KEY` | ECDH 协商会话密钥；首次注册时请求签发 `gen_uin_token` |
| 3. 签发 UIN（条件） | `/gen_uin_v2` | `2147483133` (`0x7FFFFDFD`) | `"1"` | `session_key` | 仅无本地身份或旧身份步骤 2 失败时执行，获取非零 `uin` 并持久化 |
| 4. 就绪通知 | `/api_v2` | `8074` | `"1"` | `session_key` | Body 为对空字节序列做 AES-256-ECB(PKCS#7) 加密得到的 16 字节密文 |

- **步骤 2（`/oauth_pubkey_v2`）明文 Protobuf**：
  - 上行：`field 1 (string)` = 客户端公钥、`field 2 (string)` = 客户端公钥、`field 3 (varint)` = 需新注册 UIN 时填 `1`（否则省略）、`field 4 (string)` = 64 字符设备号、`field 5 (varint)` = 已有 UIN 整数值（需新注册时省略）、`field 7 (string)` = `""`、`field 8 (string)` = 设备型号（如 `"Mac16,12"`）、`field 9 (string)` = `""`。
  - 下行：`field 2 (string)` = 服务端公钥（66 字符非压缩点十六进制）、`field 4 (string)` = `gen_uin_token`（新注册时必存在）。
- **步骤 3（`/gen_uin_v2`）明文 Protobuf**：
  - 上行：`field 1 (string)` = 64 字符设备号、`field 2 (string)` = 服务端公钥字符串、`field 4 (string)` = `gen_uin_token`。
  - 下行：`field 2 (varint)` = 服务端分配的非零整数 `uin`。

### 2.3 音频输入格式要求

- **前置格式**：16 kHz / 单声道 / 16-bit PCM，20 ms / 帧（320 采样点），建议加 200 ms 前导静音。
- **Opus 编码参数**：
  - `sample_rate`：`16000`
  - `channels`：`1`
  - `application`：`OPUS_APPLICATION_AUDIO`（`2049`）
  - `bitrate`：`64000` bps
  - `complexity`：`9`
- **分批与容器打包格式**：
  - 每累计 **6 帧 Opus（120 ms）** 打包为一次上传请求（流结束时将剩余不足 6 帧的包随结束标志一并发出）。
  - **首包容器头**（仅在本次识别 `seq == 1` 的二进制负载开头写入，固定 16 字节）：

    | 偏移（字节） | 长度 | 内容 | 说明 |
    |---|---|---|---|
    | `0` | 13 | ASCII `"#!OPUS_RAW_V1"` (`23 21 4F 50 55 53 5F 52 41 57 5F 56 31`) | 容器魔数 |
    | `13` | 3 | `0x02, 0x01, 0x00` | 固定格式参数头 |

  - **逐帧打包单元**（紧跟首包头之后，以及后续每批包的起始处，循环拼接每个 Opus 帧）：

    | 偏移（相对帧起始） | 长度 | 类型与字节序 | 说明 |
    |---|---|---|---|
    | `0` | 2 | `uint16` 小端（Little-Endian） | 当前 Opus 帧负载字节数 `L` |
    | `2` | `L` | 原始字节 | 当前 20 ms 裸 Opus 帧数据 |

### 2.4 上行消息帧结构

#### 2.4.1 外层 WebSocket 二进制帧（HTTP-over-Protobuf）

| 字段编号 | Wire Type | 类型 | 说明 |
|---|---|---|---|
| `1` | 0 (varint) | uint64 | 固定 `0` |
| `2` | 0 (varint) | uint64 | 固定 `0` |
| `3` | 0 (varint) | uint64 | 与 `Kb-TaskId` 一致的任务编号 |
| `5` | 2 (bytes) | message | 内嵌 HTTP 请求消息，结构见下表 |

内嵌 HTTP 请求消息（外层 `field 5`）：

| 字段编号 | Wire Type | 类型 | 说明 |
|---|---|---|---|
| `1` | 2 (bytes) | string | HTTP 方法，固定 `"POST"` |
| `3` | 2 (bytes) | string | 请求路径（如 `"/api_v2"`） |
| `4` | 2 (bytes) | string | 固定空字符串 `""` |
| `5` | 2 (bytes) | repeated `KV(k, v)` | 请求头键值对列表（可重复出现） |
| `6` | 2 (bytes) | bytes | HTTP 请求体（加密后字节流） |

#### 2.4.2 语音识别业务明文载荷（`POST /api_v2`, `cmd = 4548`, `Kb-CompressionType = "2"`）

外层业务 Protobuf 仅含 `field 1`（embedded message），封装如下内层语音消息：

| 内层字段编号 | Wire Type | 类型 | 说明 |
|---|---|---|---|
| `2` | 2 (bytes) | string | `voice_id`：单次识别生成的 32 位小写无连字符 UUIDv4 |
| `4` | 2 (bytes) | bytes | 当前批次打包好的 Opus 容器字节（结束轮询空包省略） |
| `5` | 0 (varint) | uint64 | 音频格式枚举，固定 `5` |
| `6` | 0 (varint) | uint64 | 结束标志：末包及结束轮询包填 `1`，中间包省略 |
| `7` | 0 (varint) | uint64 | 分片序号 `seq`：音频上传包从 `1` 递增；结束轮询空包填 `0` |
| `11` | 0 (varint) | uint64 | 截至本包已发送音频负载的累计总字节数（含首包 16 字节头与全部 2 字节帧长前缀；> 0 时填） |
| `22` | 0 (varint) | uint64 | 固定 `1` |
| `23` | 0 (varint) | uint64 | 固定 `1` |
| `24` | 0 (varint) | uint64 | 固定 `1` |

封装管线：`明文业务 Protobuf` → **Snappy 原始块压缩** → **AES-256-ECB（PKCS#7）加密** → 放入 HTTP Body（`field 6`）。

### 2.5 下行响应解析规则

1. **外层帧解包**：解析下行 WebSocket Binary 帧的 `field 4`（embedded message）得到 HTTP 响应：
   - `field 2 (varint)`：HTTP 状态码，非 `200` 或响应体为空则判定请求失败。
   - `field 5 (bytes)`：加密后的响应体。
   - 其他 `Wire Type 2` 且字段号非 `5` 的条目：每条按 `KV(header_name, header_value)` 解码为响应头。
2. **解密与解压**：
   - 使用当前 `session_key`（密钥交换阶段使用 `BOOT_KEY`）执行 **AES-256-ECB（PKCS#7）解密**。
   - 若响应头 `Kb-CompressionType`（或 `CompressionType`）值为 `"2"`，执行 **Snappy 原始块解压**。
3. **业务识别结果提取**：
   - 解析明文 Protobuf，取 `field 1` 嵌套子消息（若无 `field 1` 则直接解析顶层）：
     - `field 4 (string)`：实时识别文本（中间结果 partial / 原始文本，每次返回均覆盖为当前整段文本）。
     - `field 14 (string)`：服务端后处理定稿文本（polished final）。

### 2.6 结束流与超时处理

- **发送末包**：录音结束时，将剩余未发出的 Opus 帧（可为空批）打包发送，`seq` 继续递增、`total` 更新、设置 `field 6 = 1`。
- **定稿轮询**：若末包响应中 `field 14` 为空，则每隔 **250 ms** 发送一次结束轮询空包（省略 `field 4`、`field 6 = 1`、`field 7 = 0`、`field 11 = total`），最多轮询 **8 次**（总计约 2 秒），一旦获得非空 `field 14` 即停止轮询并作为最终结果返回；若 8 次后 `field 14` 仍为空，则回落返回最后一次非空的 `field 4` 文本。
- **超时控制**：单次请求-响应等待超时 `15 秒`。任一步骤失败或超时须标记当前长连接失效并关闭，下次请求重建连接。

### 2.7 加密、压缩与签名算法细节

#### 2.7.1 ECDH 密钥协商（SECG `secp128r1`）

使用素数域短 Weierstrass 椭圆曲线 $y^2 \equiv x^3 + ax + b \pmod p$：

- $p = \text{0xFFFFFFFDFFFFFFFFFFFFFFFFFFFFFFFF}$ ($2^{128} - 2^{97} - 1$)
- $a = \text{0xFFFFFFFDFFFFFFFFFFFFFFFFFFFFFFFC}$
- $b = \text{0xE87579C11079F43DD824993C2CEE5ED3}$
- $G_x = \text{0x161FF7528B899B2D0C28607CA52C5B86}$
- $G_y = \text{0xCF5AC8395BAFEB13C02DA292DDED7A83}$
- 阶 $n = \text{0xFFFFFFFE0000000075A30D1B9038A115}$

- **密钥生成与编码**：随机选取私钥 $k \in [1, n-1]$，计算公钥 $Q = k \cdot G = (x_Q, y_Q)$；编码为 66 字符非压缩点大写十六进制字符串：`"04" + hex32_upper(x_Q) + hex32_upper(y_Q)`。
- **共享密钥派生**：校验服务端公钥为 `"04"` 开头的 66 字符十六进制字符串，解析 $(x_S, y_S)$ 并计算 $S = k \cdot Q_S = (x', y')$。将 $x'$ 格式化为 **32 字符大写十六进制字符串**，直接取其 **32 字节 ASCII 编码**作为 AES-256 会话密钥 `session_key`。

#### 2.7.2 对称加密与压缩

- **对称加密**：`AES-256-ECB`，填充模式 `PKCS#7`（16 字节分组；空明文加密输出 16 字节密文）。
- **压缩算法**：标准 **Snappy Raw Block Format**（非 Snappy Framed 流格式；首部为未压缩长度 Varint，后接字面量与反向拷贝标签流）。

#### 2.7.3 请求签名（`Kb-Sign`）

将下列字段按顺序**无分隔符直接拼接**，末尾追加 `SIGN_KEY`（`zN7rB3bL4pO8jW1o`），计算 **SHA-256** 并输出 64 位大写十六进制：

- **密钥交换（`cmd == 2147483646`）**：
  `OsType + Version + Platform + TimeStamp + BodyMd5 + TraceId + CmdId + SIGN_KEY`
- **签发 UIN（`cmd == 2147483133`）**：
  `OsType + Version + Platform + TimeStamp + BodyMd5 + GenUinToken + TraceId + CmdId + SIGN_KEY`
- **其他接口（`/timestamp`, `/api_v2`）**：
  `OsType + Version + Platform + CmdId + "0" + TimeStamp + BodyMd5 + Uin + TraceId + TaskId + SIGN_KEY`

其中 `OsType = "5"`、`Version = "2.2.3(657)"`、`Platform = "2"`。

---

## 3. Chatterfly（元宝输入法 / SRSS 流式协议）

### 3.1 服务端点与连接方式

- **WebSocket 地址**：`wss://srss.speech.sogou.com/srss/v1/speech/streaming_recognize`
- **连接方式**：每次语音识别建立一条新的 WSS 连接，建连超时建议 10 秒。

### 3.2 请求头、握手参数与设备标识生成规则

#### 3.2.1 WebSocket 握手请求头

每次建连前生成随机 32 字节 AES 密钥与 16 字节 IV（见 3.7），用于封装首帧配置并填入如下请求头：

| Header 名 | 必选 | 取值说明 |
|---|---|---|
| `X-Srss-Cipher-Key-Type` | 是 | 固定 `"1"` |
| `X-Srss-Cipher-Key-Sec` | 是 | Base64(RSA-OAEP-SHA256(32 字节随机 AES 密钥)) |
| `X-Srss-Cipher-Key-Vec` | 是 | Base64(16 字节随机 AES-CBC IV) |
| `Authorization` | 否 | 若具备外部凭证，填 `"Bearer <token>"`；匿名接入可省略 |

#### 3.2.2 标识生成规则

- `device_uuid`、`device_aid`、`device_qid`、`audio_id`、`audio_slice_id` 均**必须为 32 位小写十六进制字符串**（16 字节随机数的十六进制编码），否则服务端会返回参数校验失败（如 `invalid audio info`）。

### 3.3 音频输入格式要求

- **格式**：`16,000 Hz`、单声道、16-bit 有符号小端线性 PCM（协议标识 `LINEAR16`）。
- **压缩与封装**：无压缩、无自定义帧头。每 `20 ms`（320 采样点 = 640 字节）裸 PCM 直接作为一条 **WebSocket Binary 帧**明文发送（音频帧不加密）。

### 3.4 上行消息帧结构

1. **首帧：加密会话配置（WebSocket Text 帧）**
   - 建连成功后立即发送一条 **Text 帧**，内容为对下述 UTF-8 JSON 明文执行 `AES-256-CBC(PKCS#7)` 加密后再标准 **Base64** 编码的字符串：

   ```json
   {
     "config": {
       "encoding": "LINEAR16",
       "language_code": "zh-cmn-Hans-CN",
       "model": "default",
       "punctuation_mode": "NORMAL_PUNCTUATION",
       "convert_number": true,
       "metadata": {
         "client_info": {
           "product_category": "ime",
           "product_id": "com.tencent.inputmethod.chatterfly",
           "product_version": "1.0.9.13509"
         },
         "sdk_info": {
           "sdk_category": "mac",
           "sdk_id": "nsrss",
           "sdk_version": "1.0.0"
         },
         "record_device_info": {
           "device_category": "mac",
           "device_uuid": "<32位小写hex>",
           "device_aid": "<32位小写hex>",
           "device_qid": "<32位小写hex>"
         },
         "record_os_info": {
           "os_category": "mac",
           "os_id": "mac",
           "os_version": "14.0"
         },
         "host_device_info": {
           "device_category": "mac",
           "device_uuid": "<同 record_device_info>",
           "device_aid": "<同 record_device_info>",
           "device_qid": "<同 record_device_info>"
         },
         "host_os_info": {
           "os_category": "mac",
           "os_id": "mac",
           "os_version": "14.0"
         },
         "user_info": {
           "user_category": "normal",
           "user_id": "0"
         },
         "audio_info": {
           "audio_id": "<32位小写hex>",
           "audio_slice_id": "<32位小写hex>"
         },
         "network_info": {
           "network_type": "wifi",
           "network_proxy_type": "none"
         },
         "runtime_info": {
           "consumer_product_id": "com.tencent.inputmethod.chatterfly",
           "consumer_purpose": "ime",
           "consumer_input_type": "voice"
         }
       }
     },
     "interim_results": true,
     "single_utterance": false
   }
   ```

   - **字段约束说明**：
     - 若携带了 Bearer Token，同步在 `config.auth_token` 中填入相同 `<token>`。
     - `metadata.client_info` 不可缺失或删减字段，否则服务端返回 `invalid client info`。
     - `single_utterance` **必须为 `false`**；若设为 `true`，服务端 VAD 会将开口前的前导静音误判为单句结束并主动断开连接。
2. **音频帧（WebSocket Binary 帧）**：逐帧发送裸 `int16_le` PCM 字节。
3. **结束帧（WebSocket Text 帧）**：发送字面量 `"{}"`。

### 3.5 下行响应解析规则

服务端下行均为**明文 UTF-8 JSON**（可能承载于 Text 或 Binary 帧）：

- **错误判定**：检查顶层 `error` 字段；若存在且非 `null`，读取 `error.code`（整数）与 `error.message`（字符串）并中止识别。
- **识别文本提取**：遍历顶层 `results` 数组，依次取每个元素的 `alternatives[0].transcript` 并无分隔符直接拼接，得到从开头到当前的整句文本。
- **中间结果（partial）与最终定稿（final）区分**：
  - 若 `results` 数组中**任意元素**的 `is_final == true`，则当前拼接文本为带标点的最终定稿（final），可结束接收并关闭连接。
  - 否则视为中间结果（partial），在文本变化时回调刷新展示。

### 3.6 结束流与超时处理

- **结束流发送**：音频采集完毕后发送一条内容为 `"{}"` 的 **WebSocket Text 帧**，继续等待服务端下发 `is_final: true` 的定稿消息。
- **超时策略**：采用 **30 秒滑动空闲超时**（每收到一条可解析的 JSON 消息即重置 30 秒倒计时，防止长语音被总时长截断）。若触发超时或连接中断，已有非空识别文本则直接作为最终结果返回，否则报错。

### 3.7 加密与签名算法细节

仅首帧配置信息采用混合加密（数字信封）：

1. 生成 32 字节密码学安全随机密钥 $K$ 与 16 字节随机初始向量 $IV$。
2. **对称加密**：使用 `AES-256-CBC` + `PKCS#7` 填充，以 $(K, IV)$ 加密首帧 JSON 明文，密文经标准 Base64 编码后作为首帧 Text 负载。
3. **非对称密钥封装**：使用服务端 3072-bit RSA 公钥（X.509 SubjectPublicKeyInfo 格式），采用 **`RSAES-OAEP`**（哈希算法与 MGF1 均使用 **`SHA-256`**）加密 32 字节密钥 $K$，密文 Base64 编码后放入 `X-Srss-Cipher-Key-Sec`；$IV$ Base64 编码后放入 `X-Srss-Cipher-Key-Vec`。

**服务端 3072-bit RSA 公钥（PEM / SPKI）**：

```pem
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA042we0tp1Qf9oJ5HPTtD
bevvl883q/e3FXXwnQbE7b4p6OqtVjQxprCusNKCiPPctzWUzOmLCnozWp/7j3sR
OdTDPK7ZtElf6fLL+l2bbdHijfSr0Z98yLwQOumOOPWtcxT34Ssrq5G3Sqaw8/RC
9ZluoONqouzEl2ausPo21W+yctmIzQ8otMKOkTunNSg+f5bM7phhsYoNy4nkCiIS
uXjlVpEnvb9V0t4ih2sAAvqCmGim4PQODJqDDz68Iz0a32kMUIR1ydMqjoHokRdO
k/VXgjE7OmJsVVe7Fn4ezdg7hYfnKVCPJxvzh0cgdbCMUUSXOP8foKnJEEoGIQcV
+lYgKqNUSJJRrfzG33i58aRwJ29UOVHuhGJ/SqFXqNmTvYQR5/Y8kvMCoTdxQG6c
5bWy9jTesrc/OliezEMS9GlepeiNdlHh3couDyn2zyYwE6aBpqp7k3uVQr/7PiAJ
6ZDBQkzVX2PGyqFeAoPFE4xg6LLTYH4EydbpZXIDg4zzAgMBAAE=
-----END PUBLIC KEY-----
```

---

## 4. 千问输入法（Qwen IME）

### 4.1 服务端点与连接方式

- **WebSocket 地址**：
  `wss://voice-input.qianwen.com/ws/v1/voice?<Query参数>`
- **连接方式**：
  - 标准 HTTP/1.1 Upgrade 至 WSS，建连超时建议 10 秒。
  - **支持预建连与长连接复用**：单次识别完成后清除会话状态（`sessionId`、`roundId`），保留底层 WebSocket；下次识别直接发起新的 `attach` 绑定（若复用连接 `attach` 失败，则新建连接重试一次）。

### 4.2 请求头、握手参数与设备标识生成规则

#### 4.2.1 标识与动态参数生成

- **设备标识（`utdid`）**：本机首次使用时生成并持久化缓存，建议为 22 位大写字母数字字符串（例如 2 位固定大写字母前缀 + 20 位随机大写十六进制字符）。若建连失败可清除缓存重新生成。
- **通道 ID（`chid`）**：每次新建 WebSocket 连接时生成，格式为 `<小写带连字符 UUIDv4>_1`。
- **请求时间戳（`reqt`）**：当前 Unix 毫秒时间戳十进制字符串。
- **客户端版本（`ve`）**：固定 `"1.2.35.46"`。
- **加密设备凭证（`ut`）** 与 **WSG v1 签名（`sign`）**：派生规则见 4.7。

#### 4.2.2 URL Query 参数

其中 `ut` 须进行 **RFC 3986 百分号编码**（仅保留 `A-Z` `a-z` `0-9` `-` `.` `_` `~`，其余字节编码为 `%XX` 大写形式）：

| 参数名 | 取值 |
|---|---|
| `chid` | `<chid>` |
| `biz_id` | `ai_qwen_input` |
| `from` | `kkframenew_quark_asr` |
| `uc_param_str` | `vepffrprsvchut` |
| `ut` | `<RFC3986 编码后的 ut>` |
| `ve` | `1.2.35.46` |
| `pf` | `8002` |
| `pr` | `qwen` |
| `fr` | `mac` |
| `sv` | `release` |
| `ch` | `qianwen-ime` |

#### 4.2.3 WebSocket 握手请求头

| Header 名 | 取值 |
|---|---|
| `Cache-Control` | `no-cache` |
| `Origin` | `https://www.qianwen.com` |
| `User-Agent` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 TONGYI_DESKTOP/0.1.0 QuarkPC/ime_voice` |
| `clt-acs-ut` | `<RFC3986 编码后的 ut>` |
| `clt-acs-ve` | `1.2.35.46` |
| `clt-acs-kp` | `""`（空字符串） |
| `clt-acs-reqt` | `<reqt>` |
| `clt-acs-wsgnver` | `1` |
| `clt-acs-request-params` | `chid` |
| `clt-acs-sign` | `<44 位小写签名字符串>` |
| `clt-acs-caer` | `tlbe` |
| `x-wpk-reqid` | `<chid>` |

### 4.3 音频输入格式要求

- **格式**：`16,000 Hz`、单声道、16-bit 有符号小端线性 PCM，建议加 200 ms 前导静音。
- **固定分块打包**：不压缩，按固定 **`3,840` 字节**（1,920 采样点 = **120 ms**）切块封装至上行 Protobuf 音频帧中。
- **尾块对齐**：音频采集结束后，若缓冲区中残留字节数大于 0 且小于 3,840，必须在末尾补 `0x00` 填充至正好 **3,840 字节**后再发送最后一块音频。

### 4.4 上行消息帧结构

所有上行消息均为 **WebSocket Binary 帧**，采用统一的顶层 Protobuf 帧结构：

| 字段编号 | Wire Type | 类型 | 说明 |
|---|---|---|---|
| `1` | 2 (bytes) | string | 路由路径（`route`） |
| `2` | 2 (bytes) | string | 通道 ID（`chid`） |
| `3` | 2 (bytes) | repeated `KV(k, v)` | 请求头，必含 `KV("clt-acs-reqt", <当前 Unix 毫秒时间戳>)` |
| `4` | 2 (bytes) | repeated `KV(k, v)` | 会话路由参数（`attach` 后必含 `KV("roundId", ...)` 与 `KV("sessionId", ...)`） |
| `5` | 2 (bytes) | repeated `KV(k, v)` | 业务扩展参数列表 |
| `6` | 2 (bytes) | message | 二进制附件子消息（仅音频帧携带）：`field 1 = "audio"`, `field 2 = "pcm"`, `field 3 = <3840 字节 PCM>` |

#### 三类控制与数据帧

1. **会话绑定帧（Attach）**
   - `field 1`：`"/voice_assistant/channel/attach"`
   - `field 2`：`<chid>`
   - `field 3`：`KV("clt-acs-reqt", <reqt>)`
   - `field 5` 包含 3 个键值对：
     - `KV("asrConfig", <JSON字符串>)`：
       ```json
       {
         "body": {
           "bitDepth": "16",
           "channel": "mono",
           "format": "pcm",
           "maxEndSilence": "180000",
           "maxStartSilence": "180000",
           "sampleRate": "16000",
           "type": "manualStreamStop"
         },
         "chid": "<chid>",
         "header": {
           "clt-acs-reqt": "<reqt>",
           "ai_polish_mode": "off"
         },
         "param": {},
         "route": "/app/live/init"
       }
       ```
     - `KV("pipelineContext", <JSON字符串>)`：
       ```json
       {
         "biz_data": {},
         "biz_id": "ai_command",
         "chat_client": "native",
         "client_tm": "<reqt>",
         "endpoint_config": {},
         "from": "kkframenew_quark_asr",
         "scene": "voice_input_assistant",
         "ai_polish_mode": "off"
       }
       ```
     - `KV("trigger", "local_device")`
   - **等待确认**：发出后循环读取下行 JSON，直至获取到非空 `data.sessionId`（总超时 **8 秒**）。记录 `sessionId`，并取 `data.roundId`（若缺失或为空，则默认为 `"ro_<sessionId>_0"`）。

2. **流式音频帧（Send）**
   - `field 1`：`"/voice_assistant/channel/asr/send"`
   - `field 2`：`<chid>`
   - `field 3`：`KV("clt-acs-reqt", <当前毫秒时间戳>)`
   - `field 4`：`KV("roundId", <roundId>)`、`KV("sessionId", <sessionId>)`
   - `field 5`：`KV("streamInputState", "process")`
   - `field 6`：子消息 `{ field 1: "audio", field 2: "pcm", field 3: <3840 字节 PCM> }`

3. **结束流帧（Complete）**
   - `field 1`：`"/voice_assistant/channel/asr/complete"`
   - `field 2`：`<chid>`
   - `field 3`：`KV("clt-acs-reqt", <当前毫秒时间戳>)`
   - `field 4`：`KV("roundId", <roundId>)`、`KV("sessionId", <sessionId>)`

### 4.5 下行响应解析规则

下行数据负载为 **UTF-8 明文 JSON**（无论通过 Text 帧还是 Binary 帧送达均按 JSON 解析）：

- **绑定响应**：当 `route == "/voice_assistant/channel/attach"` 且 `data.sessionId` 非空时，更新 `sessionId` 与 `roundId`。
- **中间/累计文本（partial）**：递归遍历 JSON 树中的对象与数组，定位任意包含 `content.text`（非空字符串）的对象，将该文本作为最新的整段识别结果覆盖更新并触发回调。
- **最终定稿完成标记（final）**：当响应中同时存在非空 `data.sessionId` 与非空 `data.newRoundId` 时，表示本轮识别已定稿完成（同时可记录 `newRoundId`），终止等待。
- **异常处理**：若通信过程中断但客户端已缓存到非空识别文本，可兜底返回已识别文本；若无识别文本则向上报错误。

### 4.6 结束流与超时处理

- **结束流程**：先将残余 PCM 补零至 3,840 字节发出，随后立即发送 `/voice_assistant/channel/asr/complete` 帧。
- **定稿等待超时**：发送 `complete` 后等待包含 `data.newRoundId` 的响应，超时上限 **`2,000 ms`（2 秒）**。到达终态或超时后，重置会话状态并将 WebSocket 归还连接池复用；若最终文本为空则判定本次无有效识别文本。

### 4.7 加密与签名算法细节（WSG v1）

#### 4.7.1 `ut` 加密派生

- **对称加密算法**：`AES-128-CBC`，填充模式 `PKCS#7`
- **密钥（Key）**：`a0a6237b2b735a54`（16 字节 ASCII 字符串原样使用）
- **初始向量（IV）**：`a0a6237b2b735a54`（与 Key 相同，16 字节 ASCII）
- **封装步骤**：
  1. 对 UTF-8 编码的 `utdid` 执行 `AES-128-CBC(PKCS#7)` 加密得到密文 `C`。
  2. 拼接 2 字节固定头：`P = [0x4E, 0xA4] || C`。
  3. 对 `P` 执行标准 Base64 编码，得到原始 `ut` 字符串（注：用于签名时取此原始 Base64；填入 URL Query 和 `clt-acs-ut` 请求头时须再做 RFC 3986 URL 编码）。

#### 4.7.2 请求签名（`clt-acs-sign`）

- **签名算法**：`HMAC-SHA1`
- **HMAC 密钥**：`2d473b000fdb53e617446f805d4eaaacbb324bd16ee9f6d8237abd0ab79c5e48`（64 字节 ASCII 字符串原样作为密钥字节，**不要**按十六进制解码）
- **签名原文**：无分隔符直接拼接 `ut（原始 Base64） + "1.2.35.46" + chid + reqt`
- **输出格式**：固定前缀 `"4ea4"` + 40 位小写十六进制 HMAC-SHA1 摘要（总长 44 字符）。

---

## 5. 八哥说 / 叭哥说（网易有道实时语音协议）

### 5.1 服务端点与连接方式

1. **账号登录获取 Cookie（前置认证）**
   - 登录引导页：`https://shared.youdao.com/dict/application/bageshuo-login-h5/index.html`
   - 作用域：`.youdao.com`
   - 有效登录态判定（满足以下任一组合即可）：
     - Cookie 包含 `DICT_PERS`；**或**
     - Cookie 同时包含 `DICT_SESS` 与 `DICT_LOGIN`。
2. **申请一次性会话 Ticket（HTTPS POST）**
   - URL：`https://dict-typeless.youdao.com/api/v1/realtime/tickets?<签名查询参数>`
   - 超时建议：10 秒。
3. **流式语音识别（WebSocket over TLS）**
   - URL：动态取自 Ticket 接口返回的 `websocketUrl`。
   - **域名安全校验（强制）**：由于连接该 WSS 时需要携带用户的 `.youdao.com` 登录 Cookie，客户端**必须**严格解析并验证返回地址满足：
     - Scheme 必须为 `wss`；
     - Host 必须严格等于 `youdao.com` 或以 `.youdao.com` 结尾（须防范子域伪造、userinfo `@` 注入及路径伪造）。

### 5.2 请求头、握手参数与设备标识生成规则

#### 5.2.1 固定协议常量

| 常量含义 | 固定值 |
|---|---|
| `appVersion` | `1.0.30` |
| `User-Agent` | `bageshuo/1.0.30` |
| `keyid` | `typeless_mac_main` |
| 签名密钥（`SECRET`） | `1TNWxQEtUtTg1XkhvJvQJl84TmtLXmCe` |
| 默认机型（`model` / `deviceModel`） | `Mac14,2` |

#### 5.2.2 设备标识与 `abtest` 算法

- **设备标识（`device`）**：首次使用时生成一个标准小写带连字符 **UUIDv4** 字符串并持久化存储，在查询参数中同时作为 `mid`、`imei`、`yduuid` 的值。
- **`abtest` 计算**：对 `device` 字符串的 UTF-8 字节序列按 32 位无符号回绕整数计算多项式哈希后对 10 取模：
  $$h_0 = 0, \quad h_{i+1} = (h_i \times 31 + \text{byte}_i) \bmod 2^{32}, \quad \text{abtest} = h_n \bmod 10$$

#### 5.2.3 Ticket 请求参数与请求头

- **参与签名的 14 个查询参数**（签名方法见 5.7）：

  | 参数名 | 取值 |
  |---|---|
  | `product` | `typeless` |
  | `appVersion` | `1.0.30` |
  | `client` | `mac` |
  | `mid` | `<device>` |
  | `vendor` | `direct` |
  | `screen` | `1920x1080` |
  | `model` | `Mac14,2` |
  | `imei` | `<device>` |
  | `network` | `wifi` |
  | `keyfrom` | `typeless.1.0.30.mac` |
  | `abtest` | `<0~9>` |
  | `yduuid` | `<device>` |
  | `keyid` | `typeless_mac_main` |
  | `mysticTime` | `<当前 Unix 毫秒时间戳>` |

- **签名结果与附加查询参数**（不参与签名计算，追加于 Query 中）：
  - `sign`：32 位小写 MD5 签名
  - `pointParam`：`abtest,appVersion,client,imei,keyfrom,keyid,mid,model,mysticTime,network,product,screen,vendor,yduuid`（上述 14 个参与签名的键名按 ASCII 升序以逗号拼接）
  - `generationStreaming`=`true`、`osName`=`macOS`、`osVersion`=`14.0`、`architecture`=`arm64`、`chip`=`""`、`deviceModel`=`Mac14,2`

- **Ticket HTTP 请求头与请求体**：
  - 请求头：`Cookie: <有道登录 Cookie>`、`User-Agent: bageshuo/1.0.30`、`Content-Type: application/json`。
  - JSON 请求体：
    ```json
    {
      "protocolVersion": 1,
      "capabilities": {
        "generationStreaming": true
      }
    }
    ```
  - **响应解析**：
    - HTTP `401`：登录态已过期，提示重新登录。
    - HTTP `2xx`：从 JSON 的 `data.websocketUrl`（若 `data` 非对象则从顶层 `websocketUrl`）提取 WSS 地址；失败时读取 `message` 或 `msg` 字段作为错误说明。

- **WebSocket 握手请求头**：
  - `Cookie: <有道登录 Cookie>`
  - `User-Agent: bageshuo/1.0.30`

### 5.3 音频输入格式要求

- **格式**：`16,000 Hz`、单声道、16-bit 有符号小端线性 PCM。
- **封装方式**：无压缩、无自定义头，每 `20 ms`（320 采样点 = 640 字节）裸 PCM 直接通过 **WebSocket Binary 帧**发送。

### 5.4 上行消息帧结构与握手时序

建立 WebSocket 连接后，所有控制消息均采用 **WebSocket Text 帧（UTF-8 JSON）**，音频数据采用 **Binary 帧**：

1. **等待通道就绪**：建连后等待服务端下发 `{"type": "connection.ready", ...}`（超时 10 秒；期间遇 `type == "error"` 立即失败）。
2. **发送开始话语帧（Text 帧）**：生成单次话语随机 UUIDv4 作为 `utteranceId`：
   ```json
   {
     "v": 1,
     "type": "utterance.start",
     "utteranceId": "<utteranceId>",
     "payload": {
       "operation": "POLISH",
       "asrLang": "zh-CHS",
       "preRollPcmBase64": ""
     }
   }
   ```
   > 注：服务端 `payload.operation` 仅接受 `"POLISH"` 或 `"TRANSLATE"`。
3. **等待话语就绪**：等待服务端下发 `{"type": "utterance.ready", ...}`（超时 10 秒，跳过 `utterance.preparing` 等过渡通知）。
4. **流式音频帧（Binary 帧）**：收到 `utterance.ready` 后开始连续发送裸 PCM 二进制帧。
5. **结束话语帧（Text 帧）**：音频采集完毕后发送：
   ```json
   {
     "v": 1,
     "type": "utterance.end",
     "utteranceId": "<utteranceId>"
   }
   ```

### 5.5 下行响应解析规则

下行控制与结果消息均为 **UTF-8 JSON**，按顶层 `type` 字段分类处理：

| `type` 字段值 | 类别 | 解析规则 |
|---|---|---|
| `connection.ready` | 握手就绪 | 建连完成，允许发送 `utterance.start` |
| `utterance.ready` | 话语就绪 | 允许开始推送 PCM 音频帧 |
| `transcript.partial` | 中间结果（partial） | 读取 `payload.fullText`（从开头到当前的整段识别文本），非空且变化时回调刷新 |
| `transcript.final` | 最终定稿（final） | 读取 `payload.fullText`（若无有效语音可能为空）；若非空则替换已有文本，并结束本次识别 |
| `error` | 错误通知 | 读取 `payload.message` 与 `payload.code` 作为错误原因中止会话 |
| 其他类型（如 `utterance.preparing` 及后续润色流事件） | 忽略/跳过 | 仅获取纯语音识别结果时无需处理 |

> 说明：服务端在返回 `transcript.final` 后可能继续推送 AI 润色/改写事件（可能改变原意或插入换行），若客户端只需原始 ASR 定稿文本，收到 `transcript.final` 后直接结束并关闭连接即可。

### 5.6 结束流、心跳与超时处理

- **结束信号**：发送 `type == "utterance.end"` 的 JSON Text 帧，保持接收直至收到 `transcript.final` 或 `error`。
- **心跳保活**：流式识别期间每 **`15 秒`** 发送一次标准 WebSocket `Ping` 控制帧（空负载）。
- **超时策略**：
  - 握手阶段每步等待（`connection.ready`、`utterance.ready`）：`10 秒`。
  - 识别阶段滑动空闲超时：**`30 秒`**（每次上行发出帧或下行收到合法消息均重置 30 秒计时器）。
  - 容错兜底：若发生超时或连接意外断开时已缓存非空识别文本，可直接返回已有文本；若未采集到任何音频且文本为空则报错。

### 5.7 加密与签名算法细节

- **传输加密**：仅使用标准 **TLS（HTTPS / WSS）**，无应用层负载加密。
- **Ticket 接口签名算法（MD5）**：
  1. 将 5.2.3 中 14 个参与签名的参数按**参数名 ASCII 字典序升序**排列。
  2. 拼接为标准查询字符串形式并追加固定密钥：
     `<k1>=<v1>&<k2>=<v2>&...&<k14>=<v14>&key=1TNWxQEtUtTg1XkhvJvQJl84TmtLXmCe`
  3. 计算 **MD5** 摘要并输出 **32 位小写十六进制字符串**作为 `sign`。

- **标准测试向量（用于校验独立实现正确性）**：
  - 输入：`device = "3f2a7c1e-9b4d-4e8a-a1c2-5d6e7f809a1b"`，`mysticTime = 1700000000000`
  - 预期输出：
    - `abtest` = `"6"`
    - `pointParam` = `"abtest,appVersion,client,imei,keyfrom,keyid,mid,model,mysticTime,network,product,screen,vendor,yduuid"`
    - `sign` = `"7bb9c7bc03e44cd83603facb55604fba"`
