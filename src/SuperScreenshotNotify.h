//
//  SuperScreenshotNotify.h — 跨进程通知名常量（SpringBoard ↔ 前台聊天 App）
//
//  说明：CFNotificationCenter 的 userInfo 跨进程不投递，因此「精确偏移值」改用
//  notify 的共享状态（notify_set_state / notify_get_state，按名字系统级共享，
//  沙箱内 App 也能用）传递；capture 通知仅作触发信号。
//
#ifndef SuperScreenshotNotify_h
#define SuperScreenshotNotify_h

#define SuperScreenshot_LS_ARM      "com.axs.superscreenshot.ls.arm"       // SB -> App：开始（自动滚动）采集
#define SuperScreenshot_LS_DISARM   "com.axs.superscreenshot.ls.disarm"    // SB -> App：停止（提前结束）
#define SuperScreenshot_LS_CAPTURE  "com.axs.superscreenshot.ls.capture"  // App -> SB：请抓一帧（偏移已写入 OFFSET 状态）
#define SuperScreenshot_LS_DONE     "com.axs.superscreenshot.ls.done"      // App -> SB：已滚到底，自动采集结束
#define SuperScreenshot_LS_OFFSET   "com.axs.superscreenshot.ls.offset"    // App 写入 / SB 读取：当前 contentOffset.y(点)*100
#define SuperScreenshot_LS_REGIONH  "com.axs.superscreenshot.ls.regionh"   // SB 写入 / App 读取：采集区域高(点)*100

#endif /* SuperScreenshotNotify_h */
