# NetPulse 应用图标

当前图标已更新为近白冰蓝底与蓝青色节点，使用内置 ImageGen 生成。[浅色版完整提示词](icon-light-prompt.md)。下方保留初版生成记录，深蓝初版已被替换。

2026-10-29。使用内置 ImageGen 工具生成，非 CLI/API fallback。选定产物复制到项目内，保留原始透明度。

- `app-icon.png`：生成的源图，1254 × 1254 RGBA PNG，圆角方形外透明。
- `NetPulse.icns`：由源图导出，包含 16/32/128/256/512 pt 的 1x/2x 图像。
- `../scripts/build-icon.sh`：使用系统 sips 缩放与 iconutil 打包；由 build.sh 调用。iconutil 在任务沙箱内可能报 Invalid Iconset，需要在沙箱外构建。
- `build.sh` 将图标复制到 `.app/Contents/Resources/NetPulse-<内容摘要>.icns`，通过 `CFBundleIconFile` 声明；窗口头部复用同一个图标。内容变化时资源名随之变化，应用启动时另显式设置 `NSApplication.applicationIconImage`，刷新运行中的 Dock 图标。

## 最终生成提示词（原文）

```text
Use case: logo-brand. Asset type: production app icon for NetPulse, a cross-platform network quality and route diagnostics utility. Generate ONE finished square 1024x1024 icon asset, not a mockup, not a contact sheet. A centered soft rounded-square tile occupies about 88 percent of the canvas with clean genuinely transparent space outside it. Tile has a refined restrained cobalt / royal blue gradient, slightly luminous near upper left, deeper at lower right, very subtle dimensional material, crisp edges, no external oversized shadow. The sole white foreground mark combines a bold clean signal pulse into an abstract N-shaped path with three small circular connected network nodes, suggesting network health and packet paths rather than a medical app. Uncluttered, carefully balanced, strong silhouette, thick smooth geometry, premium desktop utility aesthetic. Clearly readable at 16 and 32 pixels, generous internal padding, high contrast. No text, no letters printed separately, no tiny details, no border around canvas, no devices, no globe illustration, no map, no perspective, no surrounding scene, no watermark. Preserve real alpha transparency around the rounded square.
```

提示词请求的尺寸与实际输出尺寸有差异；应用使用规范尺寸导出，不依赖生成器精确满足请求像素数。
