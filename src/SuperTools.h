//
//  SuperTools.h — 窗口B 全部按钮的底层实现
//  只使用 iOS 16 系统自带框架：Vision / PDFKit / Photos / CoreGraphics / UIKit / CommonCrypto
//  不引入任何第三方库。
//

#import <UIKit/UIKit.h>

@interface SuperTools : NSObject

#pragma mark 第一排：识别编辑

// 1. OCR：Vision VNRecognizeTextRequest 本地离线识别，text 可能为空
+ (void)ocr:(UIImage *)image completion:(void (^)(NSString *text))completion;

// 1b. OCR 带文字框：boxes 为 NSValue(CGRect)，坐标系是图片「像素」左上原点
+ (void)ocr:(UIImage *)image withBoxes:(void (^)(NSString *text, NSArray<NSValue *> *boxes))completion;

// 2. 翻译：OCR 取文 → 网络翻译接口 → src=原文 dst=译文 err=失败原因(非空)
+ (void)translate:(UIImage *)image completion:(void (^)(NSString *src, NSString *dst, NSString *err))completion;

// 3. 画图：自绘 CoreGraphics 画板（画笔/马克笔/橡皮/换色/撤销），edited=nil 表示取消
+ (void)draw:(UIImage *)image completion:(void (^)(UIImage *edited))completion;

// 4. 识码：Vision 识别 QR / 条码，返回 payload 文本
+ (void)codeScan:(UIImage *)image completion:(void (^)(NSString *code))completion;

// 5. 打码：手动色块涂抹 + 智能识别手机号/身份证自动脱敏，edited=nil 表示取消
+ (void)mosaic:(UIImage *)image completion:(void (^)(UIImage *edited))completion;

#pragma mark 第二排：输出操作

// 6. 复制：UIPasteboard 直接写剪贴板，不强制保存相册
+ (void)copy:(UIImage *)image;

// 7. 贴图：新建悬浮 UIWindow 贴纸，支持拖拽摆放；rect 为所选拖选框（屏幕坐标），为空则用默认尺寸
+ (void)floating:(UIImage *)image;
+ (void)floating:(UIImage *)image withScreenRect:(CGRect)rect;

// 8. 保存：PHPhotoLibrary 写入相册
+ (void)save:(UIImage *)image completion:(void (^)(BOOL ok))completion;

// 9. 分享：原生 UIActivityViewController
+ (void)share:(UIImage *)image fromWindow:(UIWindow *)win;

// 9c. 打开豆包：把图写入剪贴板并直接 Deep Link 拉起豆包 App；返回 YES 表示已拉起（未安装返回 NO，调用方可回退系统分享）
+ (BOOL)openDoubaoWithImage:(UIImage *)image;

// 9d. 打开任意 App：把图写入剪贴板并直接 Deep Link 拉起该 scheme 的 App（weixin:// / mqq:// / xianyu:// 等）；
//     返回 YES 表示已拉起（未安装返回 NO，调用方可回退系统分享）
+ (BOOL)openAppScheme:(NSString *)scheme withImage:(UIImage *)image;

// 9e. 读取「快捷启动」App 列表（设置面板管理），返回过滤后的数组（元素 {name, scheme}），无则返回 @[]
+ (NSArray<NSDictionary *> *)superscreenshotLaunchApps;

// 9b. 加手机壳：给截图套一个 iPhone 外壳边框
+ (UIImage *)phoneCase:(UIImage *)image;

#pragma mark 「更多」二级

// 10a. 导出 PDF：PDFKit 输出图片 PDF，返回文件路径
+ (NSString *)exportPDF:(UIImage *)image;

// 10b. 压缩：CGImageDestination 改 JPEG 质量
+ (UIImage *)compress:(UIImage *)image quality:(CGFloat)quality;

// 10c. 去状态栏：抹掉顶部状态栏
+ (UIImage *)stripStatusBar:(UIImage *)image;

// 10d. 取色器：拾取图片像素色值，展示 HEX 并可复制
+ (void)colorPicker:(UIImage *)image fromWindow:(UIWindow *)win;

@end
