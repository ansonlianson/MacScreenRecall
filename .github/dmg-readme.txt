Screen Recall — 安装指南
============================

【0. 系统要求】
  • macOS 26.0 或更高（Liquid Glass 设计语言要求）
  • Apple Silicon（M 系列）

【1. 安装】
  把 ScreenRecall.app 拖到旁边的「Applications」文件夹。

【2. 首次打开 — 绕过 Gatekeeper】
  这个 app 是 ad-hoc 签名（没走 Apple 公证），第一次双击会提示
  "Apple 无法验证 ScreenRecall 不包含恶意软件" 或 "已损坏"。

  选其中一种方式打开：

  方式 A（推荐）：
    1. 在「访达」里找到 /Applications/ScreenRecall.app
    2. 按住 Control 键，点击图标 → 选「打开」
    3. 弹窗里再点一次「打开」（或在系统设置 → 隐私与安全性 → 「仍要打开」）

  方式 B（命令行，最稳妥）：
    打开「终端」，粘贴执行：
      xattr -dr com.apple.quarantine /Applications/ScreenRecall.app
    然后正常双击打开。

【3. 授予屏幕录制权限】
  首次启动会弹「系统希望访问屏幕共享」 — 点 "在系统设置中打开"
  → 把 ScreenRecall 的开关打开 → 关掉再开一次 ScreenRecall.app。
  右上角菜单栏会出现一个眼睛图标 👁，点它能看采集状态。

【4. 配置一个模型（必须，否则不会分析）】
  点菜单栏图标 → 打开主窗口 → 左侧「设置」Tab：
  • 在「模型管理」里编辑默认两条 profile（笔形图标），把「API Key」
    填入你自己的 key
  • 默认 endpoint 指向阿里云 DashScope (https://coding.dashscope.aliyuncs.com)
    需要 DashScope key；如果你想用 OpenAI / Claude / 本地模型，
    把 endpoint 改成对应 baseURL（OpenAI 兼容用 .../v1，Anthropic 用 .../v1）

  Tier-1（实时分析）建议选个便宜快的多模态模型；
  Tier-2（提问 / 报告）可以选更强的对话模型。

【5. 开始使用】
  • 「概览」: 今日采集情况
  • 「回溯」(Rewind 风格): 主区是当前时间点的全屏画面，底部时间轴
    可以横向滚动 + ← → 键切换；顶部搜索框关键字检索 / 自然语言提问；
    提问后命中帧在时间轴上高亮显示
  • 「报告」: 立即生成今日日报（默认每晚 23:00 自动）
  • 「TODO」: 自动从屏幕中提取的待办

【6. 数据完全本地】
  截图、分析结果、API Key 全部保存在你本机：
    ~/Library/Application Support/ScreenRecall/
  没有任何云端同步；只有调用模型 API 时会把当前画面+元数据发到你
  指定的 endpoint。
  画面没有变化的截图会自动 dedup 不写盘也不入库（节省空间）；
  锁屏期间完全不采集。

【7. 卸载】
  把 ScreenRecall.app 拖进废纸篓。要彻底清数据：
    rm -rf ~/Library/Application\ Support/ScreenRecall/
  Keychain 里的 API Key 也可以在「钥匙串访问」里搜
  com.anson.ScreenRecall 删除。

【8. 报问题 / 看源码】
  https://github.com/ansonlianson/MacScreenRecall
