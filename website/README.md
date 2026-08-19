# OpenYoink 官网与使用文档

本目录使用 VitePress 1.6 构建，包含：

- 中英文使用文档
- 自定义官网首页
- 可交互的虚拟 MacBook / OpenYoink Island 演示
- 本地全文搜索、站点地图、深色模式与 Reduce Motion 适配

## 本地预览

```bash
cd website
npm install
npm run dev
```

访问终端显示的 `/OpenYoink/` 地址。

## 构建

```bash
npm run build
```

产物位于 `website/.vitepress/dist`。构建脚本会把现有 `docs/appcast.xml` 复制到产物根目录，确保 Sparkle 更新地址继续保持：

```text
https://muqy1818.github.io/OpenYoink/appcast.xml
```

正式切换 GitHub Pages 前，应先在预览环境检查所有页面，再确认 Pages 部署源和自定义工作流；不要在没有复制 `appcast.xml` 的情况下替换现有站点。

## 内容边界

- 首页虚拟 MacBook 只使用内置示例数据，不读取浏览器中的本机文件。
- Stable 与开发预览功能必须明确区分。
- 安装与文件安全描述应以应用真实行为为准，不把 Sparkle EdDSA 签名描述成 Apple 公证。
- 截图放在 `public/screenshots/`，发布前检查是否包含个人信息。
