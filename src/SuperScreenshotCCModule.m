//
//  SuperScreenshotCCModule.m — 控制中心截图模块
//
//  架构与 SuperScreenshot 官方 CC 模块一致：
//    1. 编译期继承 CCUIToggleModule（符号延迟解析，运行时由 ControlCenterUIKit 提供）
//    2. 模块本身只做一件事：被点按时发一条 darwin 通知
//       com.axs.superscreenshot.cc.capture
//    3. 真正的截屏 + 浮动菜单由主 tweak（Tweak.xm，SpringBoard 内）监听执行
//
//  关键修正（v3.09，修控制中心“空白/无图标/点不动”）：
//    - 之前用 KVC 给 iconGlyph 赋值，但现代 iOS 里 iconGlyph 多为只读属性，
//      setValue:forKey: 抛异常被 @try 吞掉 → 图标为 nil → 按钮既不显示也不响应点击。
//    - 现改为覆盖 glyphImageForState:（控制中心取图标的标准方法），并提供
//      SF Symbol → Core Graphics 兜底，保证永远返回非空图标，按钮必可点。
//    - 老 iOS 仍尝试 KVC 赋值 iconGlyph（可写时生效），双路兜底。
//
//  注意：绝不可 @property/@synthesize 一个 selected！父类 CCUIToggleModule 自带
//  该属性与 ivar，子类重复声明会改掉父类 ivar 布局，导致 setSelected: 状态机错乱、
//  SpringBoard 原生崩溃 → 进安全模式（v3.07 的坑）。
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

// 父类由 ControlCenterUIKit 在运行时提供，只前向声明用到的方法/返回类型。
@interface CCUIToggleModule : NSObject
- (void)setSelected:(BOOL)arg1;
- (BOOL)isSelected;
- (UIImage *)glyphImageForState:(UIControlState)state;
@end

// 关闭 SpringBoard 控制中心（iOS 13-16 均由 SBControlCenterController 管理）。
// 点按我们的模块后必须先把控制中心收起，否则截到的永远是控制中心界面。
static void SuperScreenshot_DismissControlCenter(void) {
    @try {
        Class cls = NSClassFromString(@"SBControlCenterController");
        id cc = nil;
        if (cls) {
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                cc = [cls performSelector:@selector(sharedInstance)];
            } else if ([cls respondsToSelector:@selector(_sharedInstance)]) {
                cc = [cls performSelector:@selector(_sharedInstance)];
            }
        }
        if (!cc) { NSLog(@"[SuperScreenshot] SBControlCenterController not found"); return; }
        SEL s1 = NSSelectorFromString(@"dismissAnimated:");
        if ([cc respondsToSelector:s1]) {
            ((void(*)(id, SEL, BOOL))objc_msgSend)(cc, s1, YES);
            NSLog(@"[SuperScreenshot] control center dismissed (dismissAnimated:)");
            return;
        }
        SEL s2 = NSSelectorFromString(@"dismissAnimated:completion:");
        if ([cc respondsToSelector:s2]) {
            ((void(*)(id, SEL, BOOL, id))objc_msgSend)(cc, s2, YES, nil);
            NSLog(@"[SuperScreenshot] control center dismissed (dismissAnimated:completion:)");
        }
    } @catch (NSException *e) {
        NSLog(@"[SuperScreenshot] dismiss CC failed: %@ %@", e.name, e.reason);
    }
}

// 图标加载：从模块自身 bundle 读取模板 PNG（白底透明，控制中心会按 tint 染色），
// 名称由「控制中心图标」偏好（CC_Icon）决定；找不到再退回 SF Symbol / CG 兜底。
// v6.18 修正：之前只读 /var/jb/Library/SuperScreenshot.bundle（该路径不存在）→ 永远走兜底，
//          且 SF Symbol 在 iOS 16.6.1 控制中心里取不到 → 图标空白。现改为读本 bundle 内的 PNG。
static UIImage *SuperScreenshotLoadBundledGlyph(NSString *name) {
    NSBundle *b = [NSBundle bundleForClass:NSClassFromString(@"SuperScreenshotCCModule")];
    if (!b) return nil;
    UIImage *img = [UIImage imageNamed:name inBundle:b compatibleWithTraitCollection:nil];
    if (img && img.size.width > 1) {
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

static UIImage *SuperScreenshotGlyphImage(void) {
    // 读用户选的图标（默认相机）
    NSString *choice = [[NSUserDefaults standardUserDefaults] stringForKey:@"CC_Icon"];
    if (!choice.length) choice = @"camera";

    UIImage *g = SuperScreenshotLoadBundledGlyph(choice);
    if (g) return g;
    // 老名字兜底
    g = SuperScreenshotLoadBundledGlyph(@"icon");
    if (g) return g;
    // SF Symbol 兜底
    g = [UIImage systemImageNamed:@"camera.viewfinder"];
    if (g) return g;
    g = [UIImage systemImageNamed:@"camera.fill"];
    if (g) return g;
    // Core Graphics 兜底：画一个相机
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(64.0, 64.0), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        [[UIColor systemBlueColor] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(2.0, 2.0, 60.0, 60.0));
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, CGRectMake(22.0, 26.0, 20.0, 14.0));   // 机身
        CGContextFillRect(ctx, CGRectMake(28.0, 20.0, 8.0, 8.0));    // 顶部凸起
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img ?: [[UIImage alloc] init];
}

@interface SuperScreenshotCCModule : CCUIToggleModule
@end

@implementation SuperScreenshotCCModule

- (instancetype)init {
    self = [super init];
    if (self) {
        // 老 iOS：iconGlyph 可写，直接赋值；失败忽略（现代 iOS 走 glyphImageForState:）
        @try { [self setValue:SuperScreenshotGlyphImage() forKey:@"iconGlyph"]; } @catch (NSException *e) {}
        @try { [self setValue:[UIColor systemBlueColor] forKey:@"selectedColor"]; } @catch (NSException *e) {}
    }
    return self;
}

// 现代 iOS 控制中心取图标的标准入口：覆盖它最稳，确保按钮永远有图标、可点。
- (UIImage *)glyphImageForState:(UIControlState)state {
    return SuperScreenshotGlyphImage();
}

// 触发型按钮：点按一次即触发（不是持久开关）。
// 1) 先关闭控制中心（否则截图永远是控制中心界面）；
// 2) 等收起动画完成后（~0.35s）再发通知，Tweak 截到的就是真实屏幕。
- (void)setSelected:(BOOL)selected {
    if (selected) {
        NSLog(@"[SuperScreenshot] CC module tapped -> dismiss CC, post com.axs.superscreenshot.cc.capture");
        SuperScreenshot_DismissControlCenter();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.axs.superscreenshot.cc.capture"),
                NULL, NULL, TRUE);
        });
    }
    // 交还父类维护视觉状态；触发型按钮始终回弹为“未选中”
    [super setSelected:NO];
}

@end
