# App icon asset / 应用图标

- Asset: `Resources/AppIcon.png` (1254 × 1254 PNG with transparency).
- Generated on 2026-10-17 with the built-in `image_gen` tool.
- Native macOS `sips` and `iconutil` convert the master into the standard 16–1024 pixel `.icns` representations. The generated artwork and alpha are preserved; only packaging sizes change.
- The moon represents sleep; the shield represents protection. Teal follows SleepSeal's native interface.

## Final generation prompt

```text
Use case: logo-brand
Asset type: final macOS application icon for SleepSeal, a native utility that protects a MacBook during sleep and reduces unwanted wireless activity.
Primary request: create one polished, original, highly recognizable app icon combining a calm crescent moon with a subtle protective shield, matching the app's existing teal visual identity.
Composition: one centered macOS rounded-square tile, about 86% of a square 1024x1024 transparent canvas, with consistent generous optical margins. The tile is the actual icon artwork, not a product mockup. Outside its rounded corners is genuinely transparent.
Style: refined native macOS app icon, restrained soft sculpted depth, crisp simple silhouette, clean rounded geometry, expertly balanced negative space. Deep ocean teal tile (#226F70 to #164D56), a warm ivory moon/shield mark with a soft mint highlight. Gentle top-left light, subtle edge definition, quiet and trustworthy. The moon and shield should read as one coherent emblem and remain legible at 16-32 pixels.
Constraints: no text, no letters, no Z symbols, no laptop, no Wi-Fi or Bluetooth symbols, no tiny badges, no busy circuitry, no photographic scene, no Apple logo, no watermark, no thick outer white border, no exaggerated glass/neon. Deliver only the single finished icon.
```

## 中文

应用图标由内置 imagegen 生成，采用蓝绿色、月亮与守护盾主题。透明 PNG 原图保存在 `Resources/AppIcon.png`，构建时转换为 macOS 标准图标尺寸并加入应用包。上方保留完整生成提示词。菜单栏继续使用适合系统菜单栏的单色符号。

