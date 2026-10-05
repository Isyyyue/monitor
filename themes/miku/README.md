# 初音主题 (可选)

给 monitor 面板换上初音未来动态壁纸的自定义样式。这是一个可选主题，
默认不启用，喜欢的自己装。

## 效果

- 全屏初音背景视频/图片，铺满整个页面
- 面板卡片变透明，透出后面的初音
- 图表、提示框适配深色背景

## 使用方法

### 方法一：直接加 CSS (推荐)

1. 准备一张初音壁纸 (图片或视频)，放到主题的 assets 目录
2. 把 `miku-bg.css` 的内容加到你的主题自定义 CSS 里
3. 在页面 HTML 里加一个背景元素：

```html
<video id="miku-bg" autoplay muted loop>
  <source src="miku-bg.mp4" type="video/mp4">
</video>
<!-- 或用图片 -->
<!-- <img id="miku-bg" src="miku-bg.jpg"> -->
```

### 方法二：打包成主题

参考 [主题开发文档](https://monitor-document.pages.dev/)，把 CSS 和资源文件
打包成 `theme.tar.gz`，在面板的主题页面上传安装。

## 文件说明

- `miku-bg.css`: 核心样式，7 行。控制背景铺满、卡片透明、图表适配。
  后台管理页面 (`body.is-admin`) 不受影响，保持正常显示。

## 注意

- 背景视频文件较大 (约 20MB)，不建议直接进 git。用的时候自己准备。
- CSS 里假设背景元素 id 为 `miku-bg`，自己改 HTML 时保持一致。
