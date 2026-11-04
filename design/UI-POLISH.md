# UI 打磨清单（用户反馈 2026-11-04）

参考截图：feedback-misaligned-edge.png、screenshot-main-v1.png、screenshot-menubar-v1.png

1. 左边界不对齐：表格（表头分隔线、内容）从分栏分隔线处开始，而工具栏标题 "Xup / 全部 · N 个可更新" 有额外内边距。改用 `.navigationTitle` + `.navigationSubtitle` 交给系统对齐；表格不加自定义 leading padding；确认表格与标题左缘在同一垂直线。
2. 复选框列与"名称"列之间不应有表头分隔线；复选框列无表头文字。
3. 状态栏左侧"共 N 项"前的灰色方块占位去掉（或换成有语义的 SF Symbol）。
4. 行内来源图标与名称间距 8pt；副标题统一 `.caption` `.secondary`。
5. 表格列宽：确保 920 宽窗口下无横向滚动（已初步调整：96/96/150/120）。
6. 菜单栏面板上下有白边（feedback-menubar-white-edges.png）：面板内容的自定义背景没有铺满 MenuBarExtra 窗口，顶部与底部露出窗口底色。要求：面板根视图不要自绘不透明背景，让系统 material 铺满；或根视图 `.ignoresSafeArea()` 且去掉外层 padding，确保头部摘要与底部菜单区直接贴边；状态栏图标（含数量 Label）也应和系统图标垂直居中一致。
