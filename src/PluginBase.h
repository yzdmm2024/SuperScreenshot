//
//  PluginBase.h  — SuperScreenshot 插件基类
//
//  实现了 SuperScreenshotPlugin 协议里 SuperScreenshot 会调用的全部关键 selector。
//  SuperScreenshotPluginManager 在截图动作菜单里把插件列为动作，触发时把裁剪后的
//  图片 + 选区矩形交给插件，子类在 runWithImage: 里实现真正的功能。
//
#import <UIKit/UIKit.h>

@interface PluginBase : NSObject

// 子类必须提供：唯一标识（对应 Settings 里 plugin-enabled-%@ 的开关）
- (NSString *)pluginIdentifier;

// 子类必须实现：收到截图后的实际处理
- (void)runWithImage:(UIImage *)image;

// 可选重写
- (UIImage *)imageForMenuAndSettings;
- (BOOL)shouldRegister;                  
- (BOOL)isBottomPlugin;

// 最近一次拿到/保存的快照图
@property (nonatomic, strong) UIImage *latestSnapImage;

@end