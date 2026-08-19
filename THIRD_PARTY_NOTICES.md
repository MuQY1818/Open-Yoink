# Third-Party Notices & Clean-Implementation Record

Open-Yoink 是一个**清洁实现（clean-room implementation）**。我们参考了若干开源项目的**公开可观察行为与架构思路**，但没有复制其源代码、UI 素材或专有实现。本文件记录行为参考来源；如未来引入任何第三方代码或资源，会在此追加其许可证文本与版权归属。

## 第三方代码

应用内包含以下第三方代码：

1. **Sparkle**（自动更新框架，Swift Package Manager 引入，`upToNextMajorVersion: 2.6.0`，实际解析 2.9.6）。Sparkle 以 binary framework 形式链入 app，用于检查更新（GitHub Pages 上的 appcast feed）与安装更新包（GitHub Releases 上的 DMG，EdDSA 签名校验）。
2. **mediaremote-adapter**（供默认关闭、完全本地处理的可选 Now Playing 模块使用）。OpenYoink 固定于上游提交 `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`，捆绑其 Perl 适配脚本、从该提交源码构建的通用二进制 `MediaRemoteAdapter.framework` 和 capability probe 客户端。应用不直接链接私有 MediaRemote 符号；用户未启用媒体模块时不会启动 helper。

### mediaremote-adapter

- 项目名：mediaremote-adapter
- 仓库：https://github.com/ungive/mediaremote-adapter
- 许可证：BSD 3-Clause
- 版权：Copyright (c) 2025, Jonas van den Berg and contributors

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

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

### Sparkle

- 项目名：Sparkle
- 仓库：https://github.com/sparkle-project/Sparkle
- 许可证：MIT（完整文本如下，自包内 `LICENSE` 原样复制）

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## 行为参考（行为级研究，未复制代码）

| 项目 | 仓库 | 许可证 | 参考点 |
|---|---|---|---|
| HoldMac | https://github.com/Funnyrz/HoldMac | MIT | 文件引用式暂存、Finder 拖拽启发式触发思路 |
| DropKit | https://github.com/chenyuxiaojin/DropKit | MIT | shelf + 菜单栏产品结构、摇动召唤交互思路 |
| ShelfMate | https://github.com/stoimeniliev/shelfmate | MIT | NSPanel 窗口行为、摇动检测思路 |
| NotchPocket | https://github.com/ijashuzain/NotchPocket | MIT | NSPanel + NSItemProvider 拖放结构 |
| nab | https://github.com/jameshiew/nab | MIT-0 | 最小 shelf 生命周期与窗口行为 |
| Dropshit | https://github.com/iamsumanp/Dropshit | MIT | fileURL + NSFilePromiseProvider 多表示拖出思路 |

> ClipKit（GPL-3.0）仅作为剪贴板功能的行为参考，未复制其代码；Open-Yoink v1 不含剪贴板历史。

## 项目自有资源

- **App 图标**：`Scripts/AppIcon-master.png` 由项目作者使用 ChatGPT（AI 图像生成）创作并人工选定，版权归项目作者本人所有，随项目以 MIT 许可证发布；`Scripts/generate-icon.swift` 为项目自绘的重采样脚本，负责从主图生成 `Assets.xcassets` 全部槽位。
- 其余代码、界面、文案、本地化字符串均为项目原创。

## 当前版本确认声明

**OpenYoink v1.4.x 包含 Sparkle（MIT）与 mediaremote-adapter（BSD 3-Clause）；除此之外不含其他第三方代码、库、图片或字体。** 「行为参考」表所列其他项目仅为行为级参考，无任何代码或素材进入本仓库。如未来版本引入更多第三方代码或资源，将在此文件追加其许可证文本与版权归属。

## 商标声明

「Yoink」是 Eternal Storms Software 的产品名称。Open-Yoink 与其无任何隶属或授权关系，仅借鉴其公开描述的用户行为，不复制其代码、图标、文案或品牌资产。

## Apple 平台

本应用使用 Apple 公开 API（AppKit、SwiftUI、UniformTypeIdentifiers、Quick Look 等）开发，遵循 Apple Developer Program License Agreement。
