//
//  SuperScreenshotLicense.m — 设备授权（UDID 解锁码验证）实现
//
#import "SuperScreenshotLicense.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>

static NSString * const kSuperScreenshotLicDomain  = @"com.axs.superscreenshot";
static NSString * const kSuperScreenshotLicUnlocked = @"License_Unlocked";
// 56 字符集（去掉易混淆的 0 O 1 l I）；用 C 字符串以支持下标取字符
static const char *kSuperScreenshotCharset = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz";

@implementation SuperScreenshotLicense

+ (NSUserDefaults *)_defs {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:kSuperScreenshotLicDomain];
    });
    return d;
}

#pragma mark - UDID

+ (NSString *)deviceUDID {
    static NSString *uid = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 私有 API：MGCopyAnswer("UniqueDeviceID")，经 dlopen MobileKeyBag 取符号
        void *h = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_LAZY);
        if (h) {
            NSString *(*mg)(NSString *) = dlsym(h, "MGCopyAnswer");
            if (mg) {
                @try { uid = mg(@"UniqueDeviceID"); } @catch (NSException *e) { uid = nil; }
            }
        }
        // 降级 1：老私有 API uniqueIdentifier
        if (!uid || !uid.length) {
            id dev = [UIDevice currentDevice];
            SEL s = NSSelectorFromString(@"uniqueIdentifier");
            if ([dev respondsToSelector:s]) {
                IMP imp = [dev methodForSelector:s];
                uid = ((id (*)(id, SEL))imp)(dev, s);
            }
        }
        // 降级 2：vendor id
        if (!uid || !uid.length) uid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        if (!uid || !uid.length) uid = @"unknown";
    });
    return uid;
}

#pragma mark - 解锁码

+ (NSString *)expectedCode {
    NSString *did = [self deviceUDID];
    const char *m = [did UTF8String];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)m, (CC_LONG)strlen(m), h);
    NSMutableString *code = [NSMutableString stringWithCapacity:15];
    unsigned long cl = strlen(kSuperScreenshotCharset);
    for (int i = 0; i < 15; i++) {
        unsigned int v = ((unsigned int)h[i * 2 % CC_SHA256_DIGEST_LENGTH] << 8)
                        | (unsigned int)h[(i * 2 + 1) % CC_SHA256_DIGEST_LENGTH];
        [code appendFormat:@"%C", (unichar)(unsigned char)kSuperScreenshotCharset[v % cl]];
    }
    return code;
}

+ (BOOL)verifyCode:(NSString *)code {
    if (!code) return NO;
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) return NO;
    return [code isEqualToString:[self expectedCode]];
}

#pragma mark - 状态

+ (BOOL)isUnlocked { return [[self _defs] boolForKey:kSuperScreenshotLicUnlocked]; }
+ (void)setUnlocked:(BOOL)v {
    [[self _defs] setBool:v forKey:kSuperScreenshotLicUnlocked];
    [[self _defs] synchronize];
}
+ (void)markUnlocked { [self setUnlocked:YES]; }
+ (void)revoke { [self setUnlocked:NO]; }

#pragma mark - 工具

+ (void)runOnMain:(dispatch_block_t)block {
    if (!block) return;
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// 取前台（或任意）UIWindowScene，用于安全地建窗口（iOS 13+ 必须挂到 scene）。
+ (UIWindowScene *)_frontScene {
    UIWindowScene *scene = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)sc).activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)sc; break;
        }
    }
    if (!scene) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
        }
    }
    return scene;
}

// 取 base 的最顶层已 present 的 VC，避免「already presenting」被 UIKit 静默忽略。
+ (UIViewController *)_topVCFrom:(UIViewController *)base {
    UIViewController *vc = base;
    while (vc && vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 安全弹窗（直接 present 在调用方 VC 上，不抢 key window）

+ (void)presentVerificationInViewController:(UIViewController *)vc
                                 completion:(void (^)(BOOL))completion {
    [self runOnMain:^{
        if (!vc) { if (completion) completion([self isUnlocked]); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"设备授权验证"
                                                                   message:@"本插件已绑定设备 UDID，需输入解锁码才能使用。点「复制 UDID」把设备标识发给开发者生成解锁码。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        NSString *baseMsg = @"本插件已绑定设备 UDID，需输入解锁码才能使用。点「复制 UDID」把设备标识发给开发者生成解锁码。";
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"解锁码（15 位）";
            tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        __block BOOL resolved = NO;
        void (^dismiss)(BOOL) = ^(BOOL ok) {
            if (resolved) return;
            resolved = YES;
            [a dismissViewControllerAnimated:YES completion:nil];
            if (completion) completion(ok);
        };

        [a addAction:[UIAlertAction actionWithTitle:@"复制 UDID"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            NSString *udid = [self deviceUDID];
            [[UIPasteboard generalPasteboard] setString:udid];
            a.message = [NSString stringWithFormat:
                @"已复制本机 UDID 到剪贴板：\n%@\n\n把此标识发给开发者生成解锁码，再在下方输入。", udid];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"验证"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            NSString *input = a.textFields.firstObject.text ?: @"";
            if ([self verifyCode:input]) {
                [self markUnlocked];
                dismiss(YES);
            } else {
                a.message = [baseMsg stringByAppendingString:@"\n\n❌ 解锁码无效，请重试，或点「取消」退出。"];
            }
        }]];

        // 取消 = 强制退出，干净 dismiss，绝不困住用户
        [a addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *act) {
            dismiss([self isUnlocked]);
        }]];

        if ([self isUnlocked]) {
            [a addAction:[UIAlertAction actionWithTitle:@"锁定本机"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *act) {
                [self revoke];
                dismiss(NO);
            }]];
        }

        UIViewController *top = [self _topVCFrom:vc];
        if (!top) { if (completion) completion([self isUnlocked]); return; }
        [top presentViewController:a animated:YES completion:nil];
    }];
}

// 兼容旧调用：在 keyWindow 的 rootViewController 上弹验证框。
+ (void)presentVerificationFromWindow:(UIWindow *)win
                           completion:(void (^)(BOOL))completion {
    (void)win;
    UIViewController *vc = nil;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (kw && kw.rootViewController) vc = kw.rootViewController;
    [self presentVerificationInViewController:vc completion:completion];
}

#pragma mark - 非阻塞提示（控制中心路径专用，绝不冻结）

+ (void)presentUnlockHint {
    [self runOnMain:^{
        UIWindowScene *scene = [self _frontScene];
        UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                            : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.frame = [UIScreen mainScreen].bounds;
        w.windowLevel = UIWindowLevelAlert + 1000;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = NO;   // 关键：不拦截任何触摸，纯粹提示，绝不冻结
        UIViewController *rvc = [[UIViewController alloc] init];
        rvc.view.backgroundColor = [UIColor clearColor];
        w.rootViewController = rvc;

        CGFloat ww = w.bounds.size.width;
        CGFloat hh = w.bounds.size.height;
        CGFloat bw = MIN(ww - 56, 320);
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake((ww - bw) / 2, hh / 2 - 52, bw, 104)];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.text = @"未授权：本功能需设备验证\n\n请到 设置 › 超级截图 › 设备授权\n输入解锁码后使用";
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.layer.cornerRadius = 14;
        l.layer.masksToBounds = YES;
        l.alpha = 0;
        [rvc.view addSubview:l];

        w.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{ l.alpha = 1; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; }
                             completion:^(BOOL f){
                                 w.hidden = YES;
                                 w.rootViewController = nil;
                             }];
        });
    }];
}

@end
