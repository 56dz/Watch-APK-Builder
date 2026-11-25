---
name: oppo-watch-round-apk
description: 为圆屏安卓手表（以 OPPO OWW251 为样本：466x466 px、density 320、Android 11/API 30、FLAG_ROUND）构建原生 APK，并把方屏 UI 改造成圆屏布局。用于圆屏设备的新建、移植、控件越界排查。构建链与 adb 方法沿用 oppo-watch2-apk。
---

# 圆屏安卓手表原生 APK

先加载 oppo-watch2-apk：构建链（aapt2 + javac + r8.jar + adddex.py + zipalign + apksigner）、adb 配方、缓存/滚动/防烧屏经验全部照用。本 skill 只写圆屏的差异，数据来自 OWW251 真机（cs2watch 圆屏移植）。

## 设备采样
- `wm size` → 466x466；`wm density` → 320（233x233 dp）；`dumpsys display` 含 FLAG_ROUND；`pm list features` 含 oplus.wear.screen.round。换机型重新采样。
- Android 11：targetSdk 可设 30，minSdk 26；https 接口不受影响；不查询其它包就不需要 <queries>。
- 安装输出多一行 Incremental/Streamed Install，最后仍是 Success。

## adb 差异
- 息屏黑图 1866 字节（方屏 1610）。判断规则用“< 3 KB 即息屏”，不要硬编码字节数。
- keyevent 224/26 同样唤不醒；用 battery set ac 1 → unplug → 调 screen_off_timeout，收尾 battery reset 并还原超时（先记下原值）。
- 手表 Wi-Fi 关着时 App 显示“无法连接 / Unable to resolve host”，是环境问题；svc wifi enable 不会自动连上，要用户在表上连网。
- 防烧屏压暗后，第一下点击只恢复亮度。自动化测试先点一下中心再操作。

## 布局（核心）
详见 references/lessons.md 第 5 节，要点：
1. cx=w/2, cy=h/2, R=min(w,h)/2, safe=6dp, lim=R−safe。控件四角 hypot ≤ lim，用 fitsInCircle 校验并 Log.w 越界。
2. 列表行左右内边距 = max(8dp, cx − sqrt(lim² − dy²))，dy 取卡片上下沿离圆心更远者；宽度 < 60dp 的行不画。
3. 标题居中，基线 cy−R+30dp；详情页用顶部居中的“‹ 返回 · 页面名”代替左上箭头。
4. 刷新等圆形按钮放在边缘环上：ring=R−safe−12dp，角度 −60°，半径 11dp。
5. 筛选胶囊改成弧形环段：round-cap stroke 沿 arcMid 画，drawTextOnPath 写字，vOffset=0.35×字号；极坐标命中。
6. 分页小点沿底部弧：半径 R−safe−10dp，角度 90° + ((N−1)/2 − i)·7°。
7. 内容区 contentTop=cy−R+54dp，contentBottom=cy+R−34dp；min/maxScroll 让首末项能停到中间。
8. 详情页固定列：colHalf=min(77dp, lim−8dp)；多列行按测量宽度分配，不能沿用方屏固定偏移。
9. 触摸顺序：刷新 → 胶囊 → 圆点 → 返回 → 列表。

## 验收
- 每页截图，read_image 检查；可选脚本统计半径 > R−12px 处亮像素，必须为 0。
- 每个边缘控件 input tap 实点并截图确认。
- logcat -s AndroidRuntime:E 无异常；收尾 battery reset。
