# 月伴 Yueban · 交接文档

> 一句话：一个原生 macOS 桌面小桌宠（AppKit，非网页），帮你记录生理期、判断当前激素期、预测下次经期，并支持用照片一键生成专属形象。
>
> 本文档面向接手的人：看完能跑起来、能改、能发版。最后一章是可以直接复制给 AI 的 prompt。

---

## 一、一页速览

| 项 | 内容 |
| --- | --- |
| 产品名 | 月伴 Yueban |
| 形态 | 桌面小宠物 + 便利贴（浮在所有窗口之上，不占 Dock） |
| 平台 | macOS 11+，通用二进制（Apple 芯片 + Intel） |
| 技术栈 | Swift + AppKit，**单文件 `main.swift`（1573 行）**，零第三方依赖 |
| 代码仓库 | https://github.com/xingqiyi-97/yueban |
| 最新版本 | v1.0.1（Release 附件 `Yueban-Mac.zip`，约 1.3 MB） |
| 许可证 | MIT |
| 数据存储 | 本机 `~/Library/Application Support/Yueban/`，不联网、无账号、无埋点 |
| 用户安装 | 一行命令 `curl -fsSL .../install.sh \| bash` |

### 目录结构

```
yueban/
├── main.swift                      # 全部代码（见下方模块索引）
├── Info.plist                      # App 配置（LSUIElement=true，无 Dock 图标）
├── build.sh                        # 本地构建 → 月伴.app（默认通用二进制）
├── install.sh                      # 用户一键安装脚本
├── AppIcon.icns                    # 应用图标（CI 组装 app 需要，必须入库）
├── assets/ 或 docs/screenshots/    # README 用截图
├── .github/workflows/release.yml   # 打 tag 自动编译 + 发 Release
├── README.md                       # 面向用户的说明
├── LICENSE                         # MIT
└── docs/HANDOVER.md                # 本文件
```

### `main.swift` 模块索引

| 行号区间 | MARK | 职责 |
| --- | --- | --- |
| 6 | 基础工具 | `NSColor(hex:)` 等 |
| 38 | 激素期 | `Phase` 枚举：名称 / 主题色 / 提醒文案 |
| 88 | 数据 | `PetData`（持久化）、`CycleRun`、`Status` |
| 124 | 计算引擎 | `Engine`：记录合并、周期推算、阶段判定、未来预测 |
| 273 | 自定义形象 | `AvatarStore`：照片 → 抠图 → 贴纸描边 → 存盘 |
| 502 | 桌宠画法 | `PetView`：手绘小猫 + 照片形象两种模式 |
| 797 | 气泡便利贴 | `BubbleView`：三行文案 + 跟随阶段变色 |
| 861 | 桌宠窗口 | `PetWindow`（`NSPanel`）：拖动、锁定、双击、右键菜单 |
| 911 | 日历格子 | `DayCell` / `FlippedView` |
| 993 | 日历窗口 | `CalendarController`：月份切换、点击标记、统计、预设值 |
| 1241 | App | `AppDelegate`：菜单栏图标、生命周期、数据同步 |
| 1467 | 离线自检 | 通过环境变量把界面渲染成 PNG，用于无头验证外观 |

---

## 二、能力清单

### 1. 记录与展示
- 双击桌宠 → 打开日历；**点一下日期 = 标记「这天来月经了」，再点取消**
- 气泡三行：**今天什么期 + 周期第几天** / **一句提醒** / **距下次经期还有几天**
- 右键菜单：记录今天 / 打开日历 / 自定义形象 / 恢复默认形象 / 锁定位置 / 关于 / 退出
- 菜单栏常驻水滴图标，可打开日历、看今日状态
- 拖动位置会被记住；窗口若落在屏幕外（如拔掉副屏）自动拉回主屏

### 2. 四个激素期 + 一个异常态

| 阶段 | 主题色 | 提醒文案（每天轮换，简短） |
| --- | --- | --- |
| 月经期 | 粉 `#FF7A94` | 别喝冰的，暖一暖 / 补点铁，别硬撑 / 今天允许你摆烂 / 疼就吃药，别扛 |
| 卵泡期 | 绿 `#3FC0A0` | 状态回升，开新坑 / 难啃的事放今天 / 动一动，精力旺 / 学新东西最省力 |
| 排卵期 | 紫 `#9B8CFF` | 精力巅峰，冲 KPI / 重要会议安排上 / 注意避孕或备孕 / 社交也格外顺 |
| 黄体期 | 橙 `#F5A94F` | 嘴馋正常，别自责 / 少咖啡，早点睡 / 情绪敏感是激素 / 清淡点，少胀气 |
| 经期推迟 | 红 `#E4606F` | 来了就点日历记一下 / 推迟几天也常见 / 别焦虑，先保暖 |

桌宠头顶挂件随阶段变化：水滴 / 叶子 / 星星 / 月亮。气泡底色也跟随阶段色。

### 3. 桌宠绘制
- 手绘风小猫：棕色虚线描边、椭圆眼（会眨眼）、黄鼻子、六根胡须、粉腮红、薄荷绿蝴蝶结 + 粉玫瑰
- 呼吸起伏动画、随机眨眼
- **两种绘制模式**：默认手绘形象 / 用户上传照片生成的贴纸形象

### 4. 照片自定义形象（全部本机处理，不上传）
右键 →「自定义形象…（用照片）」→ 选图 → 自动抠出主体 + 白色贴纸描边 → 成为专属桌宠。
激素期信息照旧表达：照片下方有当期颜色垫子、右上角挂件、气泡颜色不变。
随时可「恢复默认形象」。

### 5. 日历与预测
- 日历图例：实心粉圈 = 已记录，虚线粉圈 = 预测经期，紫点 = 预测排卵日，描边 = 今天
- 底部显示：平均周期、平均行经天数、预测下次
- 记录不足时使用可调节的预设值（默认周期 28 天 / 行经 5 天）

### 6. 分发与发布
- 别人一行命令安装（`install.sh`）
- 打 tag（如 `v1.0.2`）→ GitHub Actions 自动编译双架构、组装 app、打包、发 Release
- 首次打开会被 Gatekeeper 拦一次（无苹果开发者证书），README 与脚本都给了一键解法

---

## 三、关键实现说明

### 3.1 周期推算算法（`Engine`）

```
runs()            把已标记日期合并成连续经期段（相邻间隔 ≤ 2 天算同一段，容忍漏记 1 天）
avgCycle          取相邻两次经期「开始日」间隔，只采纳 15~60 天区间，取最近 6 个求平均
                  记录不足 2 段 → 用预设 28 天
avgPeriod         只统计「已结束」的经期（结束日距今 ≥ 2 天），取最近 6 次长度平均，
                  结果须落在 1~12 天，否则回落预设值
ovulationDay      下次经期日 − 14 天，并夹紧到 [行经天数+1, 周期长度−3]
排卵日（绝对日期） = 本次经期开始日 + (排卵日序号 − 1)
阶段判定          周期第 d 天：
                    d ≤ 有效行经天数          → 月经期
                    距下次经期 ≤ 0 天         → 经期推迟
                    d < 排卵日 − 3            → 卵泡期
                    d ≤ 排卵日 + 1            → 排卵期
                    其余                      → 黄体期
预测              predictedDays / predictedOvulationDays：按平均周期向后推 8 个周期
```

### 3.2 数据结构（`PetData`，JSON 存本地）
- `marked: Set<String>` — 已标记日期，键格式 `yyyy-MM-dd`
- `presetCycle: Int = 28`、`presetPeriod: Int = 5`
- `originX / originY: Double?` — 桌宠窗口位置

### 3.3 照片抠图管线（`AvatarStore.foregroundCutout`）

用 Vision 的 `VNGenerateForegroundInstanceMaskRequest`（**须 macOS 14+**）。三个必踩的点：

1. `generateMask(forInstances:)` 返回的是 **OneComponent32Float（'L00f'）** 像素缓冲，不是 8-bit 灰度 —— 要逐像素做 `Float(bitPattern:)` 转 `UInt8`
2. **mask 尺寸 ≠ 原图尺寸**（模型输出如 512×512，原图可能 800/2048）。直接 `CGImage.masking()` 会错位 —— 必须先把 mask 画成 gray `CGImage`，再用 `CGContext.draw` **重采样到原图尺寸**
3. `CGImage.masking()` 只接受**真 image mask**（用 `CGImage(maskWidth:...)` 构造），传普通灰度图返回 `nil`；且 Vision 里前景 = 255，而 masking 语义是 **0 = 绘制**，得用 `decode: [1, 0]` 反转

抠完后做贴纸描边：用 `NSRect.fill(using: .sourceAtop)` 把图染白得到剪影，沿 16 个方向偏移绘制剪影，再压上原图。
**降级链**：抠图失败、或前景占比 > 0.85（说明是风景照，几乎整图都是「前景」）→ 自动改做圆形头像，绝不报错。

### 3.4 通用二进制（发给别人的 Mac）
- 用两个 `-target` 分别编译 arm64 与 x86_64，再 `lipo -create` 合并
- **不要用 `-static-stdlib`**（Apple 平台已不支持）
- **绝对不能引入 async/await**：会依赖 `libswift_Concurrency.dylib`，macOS 11~14 没这个库，对方双击即崩
- 对方**不需要**装 Xcode 命令行工具
- 组装后 `codesign --force --deep -s -`（ad-hoc 签名）

### 3.5 离线自检（无头验证界面外观）

没有显示屏/截图权限时，靠环境变量把界面直接渲染成 PNG：

| 环境变量 | 作用 |
| --- | --- |
| `YUEBAN_SNAPSHOT=<目录>` | 输出各激素期外观图 + 日历图 |
| `YUEBAN_ICON=<路径>` | 输出 1024×1024 App 图标 |
| `YUEBAN_TEST_PHOTO=<图片>` | 跑一遍抠图管线 |
| `YUEBAN_TEST_AVATAR_OUT=<png>` | 抠图结果输出到指定路径（避免碰用户数据目录） |

用法：
```bash
./build.sh && YUEBAN_SNAPSHOT=/tmp/yb ./月伴.app/Contents/MacOS/Yueban && open /tmp/yb
```

---

## 四、踩过的坑（省时间用）

1. **别引入 async/await** —— 会让 App 在老系统上直接崩溃（见 3.4）
2. **Vision mask 是 32 位浮点、且尺寸和原图不一致** —— 见 3.3
3. **构建脚本别用管道吞错误**：`./build.sh | tail` 会把编译错误藏起来，让人误以为在跑新二进制。`build.sh` 现已把错误写进日志并显式退出
4. **CI 产物名不要用中文**：GitHub Actions 会把 `月伴-Mac版.zip` 上传成 `-Mac.zip`（中文被吃掉）。已统一改为 ASCII 的 `Yueban-Mac.zip`
5. **fine-grained PAT 的限制**：不能创建仓库；即使 API 显示 `permissions.push: true`，若没勾 **Contents: Read and write**，`git push` 依然 403。推送 `.github/workflows/` 还需要 **Workflows: Read and write**。**推荐直接用 SSH 密钥**（无 scope 限制）
6. **本机沙箱/安全钩子**：对用户数据目录（如 `~/Library/Application Support/Yueban/avatar.png`）的删除或覆盖可能被拦截。构建与打包脚本应使用覆盖式操作（`cp`、`ditto`、`copytree(dirs_exist_ok=True)`），避免 `rm`
7. **`gh auth setup-git` 可能留下残留锁文件** `~/.gitconfig.lock`，会导致后续 `git config --global` 报 "could not lock config file"
8. 桌宠窗口默认落点要做屏幕外保护，否则外接显示器拔掉后窗口会「消失」

---

## 五、可直接复用的 Prompt

> 这一章是给交接对象的「复制即用」部分。

### Prompt A —— 从零复刻这个 App

```
帮我用 Swift + AppKit 做一个 macOS 桌面小桌宠 App（不是网页，是原生窗口）。

【形态】
- 一个小窗口浮在所有窗口之上，不占 Dock（LSUIElement=true），可以拖动、位置要记住
- 窗口旁边跟一张「便利贴气泡」，显示三行字

【要显示的信息】
- 今天处于哪个激素期（月经期 / 卵泡期 / 排卵期 / 黄体期 / 经期推迟）+ 周期第几天
- 一句该注意什么，要求极简短（例如月经期「别喝冰的，暖一暖」），每个阶段准备 4 条按天轮换
- 距下次经期还有几天（或「预计就是今天」「已推迟 N 天」）
- 每个阶段有主题色，桌宠的装饰和气泡底色都跟着变

【交互】
- 双击桌宠 → 打开日历窗口
- 日历里点一下日期 = 标记「这天来月经了」，再点一次取消
- 标记用实心圈，预测经期用虚线圈，预测排卵日用圆点，今天有描边
- 右键桌宠 → 菜单：记录今天 / 打开日历 / 锁定位置（防误拖）/ 退出
- 菜单栏加一个常驻图标，也能打开日历

【算法】
- 把连续标记的日期合并成一段段经期（中间漏记 1 天也算同一段）
- 有 2 段以上记录：周期 = 相邻经期开始日间隔（只取 15~60 天）的最近 6 次平均；不足则用预设值（默认 28 天，可在日历里改）
- 排卵日 = 下次经期日往前 14 天，并夹紧到合理区间
- 阶段判定：周期第 d 天，d 在行经天数内 = 月经期；距下次经期 ≤0 天 = 推迟；d < 排卵日−3 = 卵泡期；d ≤ 排卵日+1 = 排卵期；其余 = 黄体期

【形象】
- 手绘风格的白色小猫：棕色虚线描边、椭圆眼（会眨眼）、黄鼻子、胡须、腮红、蝴蝶结，带轻微呼吸动画
- 再提供一个「用照片自定义形象」：选一张照片，自动抠出主体 + 加白色贴纸描边，变成专属桌宠；处理必须全部在本机完成、不联网；抠不出来时降级成圆形头像，不能报错

【存储】
- 数据只存在本机 ~/Library/Application Support/<AppName>/data.json，不要任何账号、服务器、埋点

【工程要求】
- 优先单文件实现，零第三方依赖
- 构建脚本要同时编译 arm64 和 x86_64 并 lipo 合并成通用二进制
- 不要使用 async/await（会引入 libswift_Concurrency 依赖，导致 macOS 11~14 上崩溃）
- 提供一个「离线自检」开关：设置环境变量后把各状态界面渲染成 PNG，方便没有截图权限时检查外观
```

### Prompt B —— 接手继续开发（带上现状）

```
我在维护一个叫「月伴 Yueban」的 macOS 桌面小桌宠，代码在 https://github.com/xingqiyi-97/yueban 。

现状：
- Swift + AppKit，单文件 main.swift（约 1500 行），零第三方依赖
- 功能：记录生理期、判断激素期、预测下次经期、照片自定义形象、日历窗口、菜单栏图标
- 数据存 ~/Library/Application Support/Yueban/data.json，完全本地
- 构建：./build.sh 产出通用二进制（arm64 + x86_64）的 月伴.app
- 发版：打 tag（如 v1.0.2）推送后，GitHub Actions 自动编译并发布 Release 附件 Yueban-Mac.zip

硬性约束（改动时必须遵守）：
1. 不要引入 async/await 或任何需要新版系统运行时的 API，必须兼容 macOS 11
2. 产物文件名用纯 ASCII，不要用中文（CI 会吃掉中文字符）
3. 新增视觉逻辑后，请用 YUEBAN_SNAPSHOT=<目录> 渲染自检图确认外观
4. 医学相关文案保持简短，不要长篇大论

我现在想加：<在这里写你的需求>
```

### Prompt C —— 发布新版本

```
在 yueban 仓库发一个新版本：
1. 提交改动到 main 并推送
2. 打 tag：git tag -a v1.0.2 -m "说明" && git push origin v1.0.2
3. 等 GitHub Actions 跑完（gh run watch）
4. 确认 Release 附件是 Yueban-Mac.zip 且为 Latest
注意：推送用 SSH 远端 git@github.com:xingqiyi-97/yueban.git；CI 产物名必须是 ASCII。
```

---

## 六、日常维护

| 想做什么 | 怎么做 |
| --- | --- |
| 本地改完看效果 | `cd yueban && BUILD_ARCH=native ./build.sh && open 月伴.app`（只编本机架构，快） |
| 改完确认外观 | `rm -rf /tmp/yb && mkdir -p /tmp/yb && YUEBAN_SNAPSHOT=/tmp/yb ./月伴.app/Contents/MacOS/Yueban` |
| 发布新版 | 打 tag 推送 → Actions 自动出 Release |
| 改提醒文案 | `main.swift` 的 `Phase.tips` |
| 改配色 | `main.swift` 的 `Phase.color` |
| 改形象 | `main.swift` 的 `PetView.draw` |
| 用户数据在哪 | `~/Library/Application Support/Yueban/data.json`（记录）、`avatar.png`（自定义形象） |

---

## 七、交接清单 / 已知待办

- [ ] **删除 GitHub 上遗留的 `v1.0.0` Release**（它的附件名有 bug，叫 `-Mac.zip`）。v1.0.1 才是正确的 Latest，但 v1.0.0 还留在列表里。需要网页上手动删（当前 token 无写权限）
- [ ] 本机 `~/.gitconfig.lock` 是残留锁文件，会导致 `git config --global` 报错，可删除
- [ ] **版权风险**：默认形象是 Hello Kitty 风格致敬造型，与三丽鸥无任何关联。README 已加免责声明；若要公开推广，建议替换为完全原创形象（可参考「照片自定义形象」功能的设计思路）
- [ ] 未实现的可能需求：经前 1 天系统通知、开机自启、iCloud 同步、多设备
- [ ] 医疗免责：本工具是基于日历记录的**推算**，不是医疗建议，不能用于避孕或疾病诊断

---

## 八、给接手人的三句话

1. 代码是**单文件**的，从上往下读一遍就能改；所有视觉逻辑都集中在 `PetView`，所有计算都集中在 `Engine`。
2. 改外观**一定要跑自检渲染**（`YUEBAN_SNAPSHOT`），不要凭想象改坐标。
3. 想加功能前先看第四章「踩过的坑」，尤其「不要引入 async/await」和「CI 产物名不要用中文」这两条，都是实际崩过的。
