//
//  Common.h
//  SuperScreenshot
//
//  共享常量与工具。偏好存放在默认域 com.axs.superscreenshot
//
#import <UIKit/UIKit.h>

#define XZ_PREFS_DOMAIN     @"com.axs.superscreenshot"

// 总开关（设置面板 Root.plist 第一项，Tweak.xm 中生效）
#define XZ_KEY_MENU_ENABLED     @"Menu_Enabled"

// 各插件开关
// v5.23.0: OCR 整块重做, 砍掉百度/本地/Vision, 只走智谱 BigModel glm-4v-flash (OpenAI 兼容协议)
// v5.25.3 修: 这四个键原先也叫 XZ_KEY_AI_*, 和下面「问 AI」段的 XZ_KEY_AI_* 重名,
//   C 预处理器取最后一次定义 → OCR 实际读的是 AskAI_APIKey,
//   而 Root.plist 「识别引擎(智谱 BigModel)」段写的是 BigModel_APIKey, 两边对不上,
//   用户填了 Key 也永远是空的。拆成独立的 XZ_KEY_BM_* 前缀, 两套互不干扰。
#define XZ_KEY_BM_BASEURL       @"BigModel_BaseURL"      // 默认 https://open.bigmodel.cn/api/paas/v4
#define XZ_KEY_BM_KEY           @"BigModel_APIKey"       // 智谱 API Key
#define XZ_KEY_BM_MODEL         @"BigModel_Model"        // 默认 glm-4v-flash
#define XZ_KEY_BM_PROMPT        @"BigModel_Prompt"       // 提示词 (可选, 默认「识别图中所有文字」)
// 旧键保留, 仅供 VisionOCR / 翻译/AskAI 三个 plugin 内部使用
#define XZ_KEY_OCR_LANGS        @"OCR_Languages"         // v5.23.0 保留, 供 VisionOCR 类内部读取
#define XZ_KEY_TB_ORDER         @"Toolbar_Order"         // v5.18：工具栏按钮顺序(逗号分隔的tag)
#define XZ_KEY_TB_DISABLED      @"Toolbar_Disabled"      // v5.18：工具栏禁用的按钮(逗号分隔的tag)
#define XZ_KEY_TB_LAYOUT        @"Toolbar_Layout"        // v5.18：工具栏布局 — 0=双排(默认), 1=单排滑动

// v6.20.9：快捷启动 App 列表（NSArray<NSDictionary {name, scheme}>），设置面板「快捷启动」管理，工具栏「启动」按钮读取
#define XZ_KEY_LAUNCH_APPS      @"LaunchApps"
// v6.21：微信输入法「隔空传送」直达 scheme（默认 wetype://；可用 Filza 查微信输入法
//        Info.plist 的 CFBundleURLSchemes 确认真实 scheme 后，在此键 override）
#define XZ_KEY_WXTRANS_SCHEME   @"WeChatTransfer_Scheme"
#define XZ_KEY_TRANS_ENABLED    @"Translate_Enabled"
#define XZ_KEY_TRANS_APPID      @"Translate_APIAppID"
#define XZ_KEY_TRANS_KEY        @"Translate_APIKey"
#define XZ_KEY_TRANS_TARGET     @"Translate_TargetLang"
#define XZ_KEY_LONG_ENABLED     @"LongShot_Enabled"
#define XZ_KEY_LONG_OVERLAP     @"LongShot_Overlap"     // 帧重叠比例 (0~0.3)
#define XZ_KEY_LONG_MAXH        @"LongShot_MaxHeight"   // 最大拼接高度上限 (px)
#define XZ_KEY_LONG_INTERVAL    @"LongShot_Interval"    // 每帧滚动后的等待秒数
#define XZ_KEY_LONG_QUICK       @"LongShot_Quick"       // 长截图快速模式（更短间隔+更大步进）
#define XZ_KEY_AI_ENABLED       @"AskAI_Enabled"
#define XZ_KEY_AI_BASEURL       @"AskAI_BaseURL"
#define XZ_KEY_AI_KEY           @"AskAI_APIKey"
#define XZ_KEY_AI_MODEL         @"AskAI_Model"
#define XZ_KEY_AI_PROMPT        @"AskAI_Prompt"

// v6.05：手机壳库（仅对「正常截图」生效，局部截图不受影响）
#define XZ_KEY_PHONE_CASE       @"PhoneCase_Id"      // 选中的手机壳 id（none=不套壳；custom:<名称>=自定义机框）
#define XZ_KEY_PHONE_CASE_ON    @"PhoneCase_AutoOn"  // 正常截图自动套壳开关

// v6.06：触发方式 —— 音量+电源键拦截系统截图，改为拉起超级截图（默认关，实验性）
#define XZ_KEY_SS_TRIGGER       @"Screenshot_Trigger"
// v6.06：截图统计 + 历史记录
#define XZ_KEY_SNAP_COUNT       @"Snap_Count"        // 累计截图次数
#define XZ_KEY_HISTORY_ENABLED  @"History_Enabled"   // 历史记录开关（默认开）
#define XZ_KEY_HISTORY_MAX      @"History_Max"       // 历史保留条数（默认 50）

// v6.07：大模型库 —— 统一 识别引擎 / 问AI / 翻译 三处配置，避免各填一套、误点即崩
//   库本身以 JSON 字符串存于 XZ_KEY_MODEL_LIB（NSUserDefaults，domain 同 prefs）
//   每个模型: {id, name, baseURL, apiKey, model, vendor}
//   各功能只存「选中的模型 id」，真正配置集中在库里（面板=登录口子，模型=真正干活的）
#define XZ_KEY_MODEL_LIB        @"ModelLibrary_JSON" // 模型库数组(JSON 字符串)
#define XZ_KEY_MODEL_AI         @"ModelAI_ID"        // 问AI 选用的模型 id（空=未选）
#define XZ_KEY_MODEL_OCR        @"ModelOCR_ID"       // 识别引擎 选用的模型 id
#define XZ_KEY_MODEL_TRANS      @"ModelTrans_ID"     // 翻译 选用的模型 id
#define XZ_KEY_MODEL_MIGRATED   @"ModelLib_Migrated" // 一次性迁移标记

// v6.11：内置百度 PaddleOCR（AI Studio 免费版，独立通道，不走大模型库）
//   注意：用户要的免费 PP-OCR 是 AI Studio 的 PaddleOCR（aistudio.baidu.com/paddleocr/task），
//   不是百度智能云「文字识别」(aip.baidubce.com)。AI Studio 用 API_URL + Token 鉴权、JSON 提交。
//   开启 XZ_KEY_PPOCR_ON 后，识别引擎 / 翻译 走 PaddleOCR，忽略大模型库的 OCR 模型选择
#define XZ_KEY_PPOCR_ON    @"PPOCR_Enabled"   // 是否启用内置 PaddleOCR（默认关）
#define XZ_KEY_PPOCR_URL   @"PPOCR_APIURL"    // AI Studio PaddleOCR 的 API_URL（从 paddleocr/task 页面复制）
#define XZ_KEY_PPOCR_TOKEN @"PPOCR_Token"     // AI Studio Access Token
#define XZ_KEY_PPOCR_MODEL @"PPOCR_Model"     // PaddleOCR 模型名（默认 PP-OCRv6；亦可填 PP-OCRv5 等）
#define XZ_PPOCR_SENTINEL  @"__paddleocr__"   // 识别引擎选择器里「内置 PaddleOCR」选中的哨兵 id（不走大模型库）

// 自定义资源目录（用户用 Filza 放入；SpringBoard 可调取）
#define XZ_PHONE_FRAME_DIR  @"/var/mobile/Documents/com.axs.superscreenshot/Frames"   // 自定义机框：每机型一个子目录(frame.png + info.json)
#define XZ_HISTORY_DIR       @"/var/mobile/Documents/com.axs.superscreenshot/History" // 历史截图缩略图

// 长截图：帧间重叠比例（0~0.3），Vision 配准失败时的兜底值
#define XZ_LONG_OVERLAP_DEFAULT  0.50

@interface Common : NSObject
+ (BOOL)boolPref:(NSString *)key default:(BOOL)def;
+ (NSString *)stringPref:(NSString *)key default:(NSString *)def;
+ (int)intPref:(NSString *)key default:(int)def;       // v5.18
+ (void)setPref:(NSString *)key value:(id)value;
+ (NSArray<NSString *> *)ocrLanguages;   // 供 VisionOCR / 翻译/AskAI 三个 plugin 读取识别语言 (v5.23.0 主 OCR 走 BigModel, 此方法保留为 plugin 内部使用)
+ (UIImage *)systemIcon:(NSString *)name;   // SF Symbol 渲染成 UIImage（iOS>=13）
+ (void)toast:(NSString *)msg;              // 顶部轻量提示
+ (void)superscreenshotAlertError:(NSString *)title message:(NSString *)msg;  // v5.23.0: 弹 alert 提示 (不静默, 用户必须看到)
+ (UIColor *)accentColor;
+ (UIWindow *)topWindow;
+ (UIWindowScene *)activeWindowScene;   // iOS 13+：弹窗必须挂到 scene 才能显示

#pragma mark - v4.1 新增

// 当前屏幕安全区（取 keyWindow 的 safeAreaInsets，取不到时按顶部 20pt 兜底）
+ (UIEdgeInsets)screenSafeInsets;

// 最上层可 present 的 ViewController（沿 presentedViewController 链走到最后）
// 窗口B 自带 rootViewController，present 一律走它，不再依赖 SpringBoard 的 keyWindow
+ (UIViewController *)topViewControllerFrom:(UIWindow *)win;

// 安全 present：找不到承载 VC 时降级为 toast，避免静默失败
+ (void)present:(UIViewController *)vc fromWindow:(UIWindow *)win;

// 主线程执行（darwin 通知回调不在主线程）
+ (void)runOnMain:(dispatch_block_t)block;

#pragma mark - v6.07 大模型库解析（tweak 侧）

// 模型库（NSArray<NSDictionary *>），从 XZ_KEY_MODEL_LIB(JSON) 解析；空返回 @[]
+ (NSArray<NSDictionary *> *)superscreenshotModelLibrary;
// 按 id 取模型；取不到返回 nil
+ (NSDictionary *)superscreenshotModelById:(NSString *)mid;
// 从模型 dict 取字段，nil/空时回退默认值（各功能共用，避免各自硬编码 key 顺序）
+ (NSString *)superscreenshotModelField:(NSDictionary *)m key:(NSString *)k def:(NSString *)def;
// 各功能当前选中的模型配置（含 baseURL/apiKey/model）；未选返回 nil
+ (NSDictionary *)superscreenshotAIConfig;
+ (NSDictionary *)superscreenshotOCRConfig;
+ (NSDictionary *)superscreenshotTransConfig;
// 一次性迁移：把旧的 AskAI_* / BigModel_* 配置并入模型库，避免「误点即崩」+ 老用户配置不丢
+ (void)superscreenshotMigrateModelsIfNeeded;

@end