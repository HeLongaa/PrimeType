# Third-Party Notices

PrimeType (Prime 输入法) 使用或分发了以下第三方开源软件与词库资源。我们衷心感谢各项目作者与开源社区的贡献。

---

## 1. 第三方库与引擎（二进制/静态链接）

| 组件名称 | 版本 / 提交 | 项目主页 | 许可证 | 打包位置 / 链接方式 |
|---|---|---|---|---|
| **librime** | `1.17.0` (`33e7814`) | https://github.com/rime/librime | BSD-3-Clause | 动态链接 `Contents/Frameworks/librime.1.dylib` |
| **librime-lua** | `ec52e48` | https://github.com/hchunhui/librime-lua | BSD-3-Clause（内嵌 Lua 为 MIT） | 插件 `Contents/Frameworks/rime-plugins/librime-lua.dylib` |
| **librime-octagram** | `dfcc151` | https://github.com/lotem/librime-octagram | BSD-3-Clause | 插件 `Contents/Frameworks/rime-plugins/librime-octagram.dylib` |
| **librime-predict** | `920bd41` | https://github.com/rime/librime-predict | BSD-3-Clause | 插件 `Contents/Frameworks/rime-plugins/librime-predict.dylib` |
| **libopus** | `1.6.1` | https://opus-codec.org/ · https://github.com/xiph/opus | BSD-3-Clause | 静态链接 `Vendor/opus/lib/libopus.a` |

> 注：其余音频采集、网络通信、加解密与界面渲染均直接使用 macOS 系统框架（`Cocoa`、`SwiftUI`、`InputMethodKit`、`CoreAudio`、`AudioToolbox`、`AVFoundation`、`CryptoKit`、`CommonCrypto`、`Security`、`NaturalLanguage`、`Carbon`、`URLSession`）。

---

## 2. 第三方输入方案与词库资源

以下词库与输入方案以独立资源包形式随应用分发于 `Contents/Resources/` 目录下，保留各自的原始许可证文件与版权声明：

| 词库 / 方案名称 | 版本 | 项目主页 | 许可证 | 资源目录 |
|---|---|---|---|---|
| **雾凇拼音（rime-ice）** | 上游主干 | https://github.com/iDvel/rime-ice | GPL-3.0-only | `Contents/Resources/SharedSupport/` |
| **薄荷拼音（oh-my-rime）** | 上游发行版 | https://github.com/Mintimate/oh-my-rime | GPL-3.0 | `Contents/Resources/Dictionaries/oh_my_rime/` |
| **万象拼音（rime_wanxiang）** | `18.2.0` | https://github.com/amzxyz/rime_wanxiang | CC-BY-4.0 | `Contents/Resources/Dictionaries/wanxiang/` |

---

## 3. 表情与符号数据

| 组件名称 | 项目主页 | 许可证 | 说明 |
|---|---|---|---|
| **rime-emoji** | https://github.com/rime/rime-emoji | LGPL-3.0 | Rime 表情候选数据 |
| **emojibase** | https://github.com/milesj/emojibase | MIT | Unicode 表情与符号元数据 |

---

## 4. 语音输入与底层音频参考（致谢）

| 项目名称 | 项目主页 | 类型 | 说明 |
|---|---|---|---|
| **VoiceKey (`J3n5en/voicekey`)** | https://github.com/J3n5en/voicekey | 参考致谢 | 参考其语音输入交互实现 |
| **Handy / VoiceInk** | https://github.com/Beingpax/VoiceInk | 参考致谢 | 参考底层 CoreAudio 低延迟采集机制 |

---

## 5. 许可证声明摘要

### 5.1 librime 及 Rime 插件（BSD-3-Clause）

```text
Copyright (c) 2011-present, Rime Developers (librime, librime-lua, librime-octagram, librime-predict contributors)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

> `librime` 二进制内部还可能静态包含其上游依赖组件（如 Boost、yaml-cpp、LevelDB、Marisa-trie、OpenCC、glog、Lua 等），均遵循其各自开源许可证（Boost Software License / MIT / BSD-3-Clause / Apache-2.0）。

---

### 5.2 libopus（BSD-3-Clause）

完整许可证原文位于 [Vendor/opus/LICENSE](Vendor/opus/LICENSE)：

```text
Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Opus is subject to the royalty-free patent licenses specified at:
- Xiph.Org Foundation: https://datatracker.ietf.org/ipr/1524/
- Microsoft Corporation: https://datatracker.ietf.org/ipr/1914/
- Broadcom Corporation: https://datatracker.ietf.org/ipr/1526/
```

---

### 5.3 雾凇拼音（rime-ice）与薄荷拼音（oh-my-rime）— GNU GPL v3.0

- **雾凇拼音（rime-ice）**：依据 GNU General Public License v3.0 only 授权，完整许可证文本随词库分发于 `Contents/Resources/SharedSupport/LICENSE`，源码地址：https://github.com/iDvel/rime-ice 。
- **薄荷拼音（oh-my-rime）**：依据 GNU General Public License v3.0 授权，完整许可证文本随词库分发于 `Contents/Resources/Dictionaries/oh_my_rime/LICENSE`，源码地址：https://github.com/Mintimate/oh-my-rime 。

---

### 5.4 万象拼音（rime_wanxiang）— CC BY 4.0

- **万象拼音（rime_wanxiang）**：依据 [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)（[中文说明](https://creativecommons.org/licenses/by/4.0/deed.zh-hans)）许可协议授权，作者 `amzxyz`，项目主页：https://github.com/amzxyz/rime_wanxiang 。

---

### 5.5 表情与符号数据（LGPL-3.0 / MIT）

- **rime-emoji**：依据 GNU Lesser General Public License v3.0 (LGPL-3.0) 授权，项目主页：https://github.com/rime/rime-emoji 。
- **emojibase**：依据 MIT 许可证授权，项目主页：https://github.com/milesj/emojibase 。
