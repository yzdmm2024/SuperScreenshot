//
//  Common.m
//
#import <CommonCrypto/CommonDigest.h>
#import "Common.h"
#import "ResultWindow.h"      // v6.09: 错误提示改走久经验证的 Alert+600 结果浮层

// ============================================================================
// v6.09 崩溃复盘（重要，勿再犯）
//
// v6.07/v6.08 为了解决「OCR 失败提示被工具栏遮住点不了」，自建了一个
// UIWindow(Alert+750) 并在其上 presentViewController: 一个 UIAlertController。
// 这套写法引入了三个致命问题，导致点 OCR/翻译 直接把 SpringBoard 打进安全模式：
//
//   1) [w makeKeyAndVisible] —— 在 SpringBoard 里向系统抢 key window。
//      SpringBoard 不是普通 app，随手抢 key window 会破坏其窗口状态机。
//      正确做法：只设 w.hidden = NO（触摸投递本来就不要求成为 key window）。
//
//   2) initWithWindowScene: 没有显式 frame —— 窗口尺寸依赖场景推断，不可靠。
//      正确做法：initWithFrame: 显式给 bounds。
//
//   3) 靠 presentationController.delegate 回收窗口 —— 该属性是 weak（v6.08 已用
//      静态强引用兜住），但更本质的错是：presentationControllerDidDismiss: 只在
//      「用户手势交互式 dismiss」时触发，UIAlertController 点按钮属于程序化
//      dismiss，该回调**根本不会触发** → 2750 层的空窗口永久残留、盖住全屏吞掉
//      所有触摸。这正是 v5.25.4 早已踩过并写在 EditToolbarWindow.m 注释里的坑。
//
// v6.09 的修法：不再自建窗口、不再碰 presentationController。直接复用本项目
// 已长期跑通的 ResultWindow（Alert+600，显式 frame、hidden=NO、单例管生命周期、
// 自带关闭按钮），它本来就是为「稳盖过工具栏面板(_panelWin≈2000)」设计的。
// ============================================================================

@implementation Common

+ (NSUserDefaults *)defaults {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    });
    return d;
}

+ (BOOL)boolPref:(NSString *)key default:(BOOL)def {
    id v = [[self defaults] objectForKey:key];
    return v ? [v boolValue] : def;
}
+ (NSString *)stringPref:(NSString *)key default:(NSString *)def {
    NSString *v = [[self defaults] stringForKey:key];
    return v && v.length ? v : def;
}
+ (int)intPref:(NSString *)key default:(int)def {
    id v = [[self defaults] objectForKey:key];
    return v ? [v intValue] : def;
}
+ (void)setPref:(NSString *)key value:(id)value {
    [[self defaults] setObject:value forKey:key];
    [[self defaults] synchronize];
}

// v5.23.0: 此方法保留, 供 VisionOCR / 翻译/AskAI 三个 plugin 内部使用. 主 OCR 入口已改走智谱 BigModel, 不依赖此方法.
+ (NSArray<NSString *> *)ocrLanguages {
    id v = [[self defaults] objectForKey:XZ_KEY_OCR_LANGS];
    if ([v isKindOfClass:[NSArray class]] && [v count]) return v;
    if ([v isKindOfClass:[NSString class]]) {
        NSArray *parts = [v componentsSeparatedByString:@","];
        NSMutableArray *out_ = [NSMutableArray array];
        for (NSString *p in parts) {
            NSString *s = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (s.length) [out_ addObject:s];
        }
        if (out_.count) return out_;
    }
    return @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
}

+ (UIImage *)systemIcon:(NSString *)name {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

+ (UIColor *)accentColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemBlueColor];
    }
    return [UIColor blueColor];
}

// v6.20.16 提示浮层重做：
//  1) 位置从屏幕顶部移到底部（home indicator 上方）——顶部经常与状态栏/App 标题等
//     文字重叠看不清，底部为系统 toast 惯用位置，冲突少。
//  2) 新提示直接替换旧提示（静态引用 + removeFromSuperview）——修复「点复制出现
//     两条提示叠在一起」（如局部工具栏复制：SuperTools copy: 一条 + 调用方一条）。
//  3) 纯白字+阴影改为半透明深色胶囊底（alpha 0.72）——透明背景在浅色壁纸上压不住字。
static UILabel *_xzToastLabel = nil;

+ (void)toast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [self topWindow];
        if (!w) return;
        if (_xzToastLabel) { [_xzToastLabel removeFromSuperview]; _xzToastLabel = nil; }
        CGFloat h = 40;
        CGFloat ww = w.bounds.size.width;
        CGFloat bottom = MAX(w.safeAreaInsets.bottom, 8);
        CGFloat restY = w.bounds.size.height - bottom - h - 16;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, w.bounds.size.height, ww - 32, h)];
        l.text = msg;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        l.layer.cornerRadius = 14;
        l.layer.masksToBounds = YES;
        _xzToastLabel = l;
        [w addSubview:l];
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ l.frame = CGRectMake(16, restY, ww - 32, h); }
                         completion:^(BOOL fin){
            [UIView animateWithDuration:0.25 delay:1.6 options:UIViewAnimationOptionCurveEaseIn
                             animations:^{ l.alpha = 0; }
                             completion:^(BOOL f){
                if (_xzToastLabel == l) _xzToastLabel = nil;
                [l removeFromSuperview];
            }];
        }];
    });
}

// v5.23.0: OCR/网络等失败时提示 (不静默, 用户必须看到)
// v6.09: 不再自建 UIWindow + UIAlertController（v6.07/6.08 因此崩进安全模式，见文件头复盘）。
//        改用 ResultWindow —— 本项目已长期跑通的 Alert+600 结果浮层：
//        · 显式 frame、hidden=NO（不抢 SpringBoard 的 key window）
//        · 单例持有窗口，关闭按钮/点空白处 确定性回收，无残留
//        · Alert+600(≈2600) 天然盖过工具栏面板(_panelWin≈2000)与选区窗(≈1990) → 可见且可点
+ (void)superscreenshotAlertError:(NSString *)title message:(NSString *)msg {
    NSString *t = title.length ? title : @"出错了";
    NSString *m = msg.length ? msg : @"未知错误";
    NSLog(@"[SuperScreenshot] superscreenshotAlertError: %@ / %@", t, m);
    [self runOnMain:^{
        @try {
            [ResultWindow showWithTitle:t text:m image:nil];
        } @catch (NSException *e) {
            // 兜底：走已有 @try/@catch 保护的 present:fromWindow: 通道（proven 路径）
            NSLog(@"[SuperScreenshot] superscreenshotAlertError ResultWindow 异常，降级 alert: %@ %@", e.name, e.reason);
            @try {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:t
                                                                          message:m
                                                                   preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
                [self present:a fromWindow:[self topWindow]];
            } @catch (NSException *e2) {
                NSLog(@"[SuperScreenshot] superscreenshotAlertError 降级仍失败: %@ %@", e2.name, e2.reason);
            }
        }
    }];
}

+ (UIWindow *)topWindow {
    NSArray *scenes;
    if (@available(iOS 13.0, *)) {
        NSSet *set = [UIApplication sharedApplication].connectedScenes;
        scenes = set.allObjects;
    }
    if (scenes.count) {
        id scene = scenes.firstObject;
        for (UIWindow *w in [scene valueForKey:@"windows"]) {
            if (w.isKeyWindow) return w;
        }
        id win = [scene valueForKey:@"keyWindow"];
        if (win) return win;
    }
    return [UIApplication sharedApplication].keyWindow;
}

+ (UIWindowScene *)activeWindowScene {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *active = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                active = (UIWindowScene *)scene;
                break;
            }
        }
        if (!active) {
            // 兜底：任意已连接的 window scene。SpringBoard 的激活态判定有时不稳，
            // 若 windowScene 取到 nil，UIWindow 在 iOS13+ 会因未挂到 scene 而不显示，
            // 表现为「截图完成但两排工具栏不弹」。这里兜底保证窗口一定能挂上场景。
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) { active = (UIWindowScene *)scene; break; }
            }
        }
        return active;
    }
    return nil;
}

#pragma mark - v4.1 新增

+ (UIEdgeInsets)screenSafeInsets {
    if (@available(iOS 11.0, *)) {
        UIWindow *w = [self topWindow];
        if (w) return w.safeAreaInsets;
    }
    return UIEdgeInsetsMake(20, 0, 0, 0);
}

+ (UIViewController *)topViewControllerFrom:(UIWindow *)win {
    UIViewController *root = win.rootViewController;
    NSInteger guard = 0;
    while (root.presentedViewController && guard++ < 16) {
        root = root.presentedViewController;
    }
    return root;
}

+ (void)present:(UIViewController *)vc fromWindow:(UIWindow *)win {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *host = [self topViewControllerFrom:win];
            if (!host) host = [self topViewControllerFrom:[self topWindow]];
            if (host && host.view.window) {
                // v5.25.6: 不再手动抬层。工具栏窗口已降到 Alert-10(1990) < 系统 alert(2000),
                // 弹窗由系统自然浮在工具栏之上, 且 dismiss 后正常清理, 无残留(修复「关不掉」)。
                [host presentViewController:vc animated:YES completion:nil];
            } else {
                NSLog(@"[SuperScreenshot] present failed: no host view controller");
            }
        } @catch (NSException *e) {
            NSLog(@"[SuperScreenshot] present exception: %@ %@", e.name, e.reason);
        }
    });
}

+ (void)runOnMain:(dispatch_block_t)block {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

#pragma mark - v6.07 大模型库解析

// v6.09 加固：偏好里的 JSON 可能被误编辑/写坏/被别的版本写成别的结构。
// 只要有一个元素不是字典，旧实现在 superscreenshotModelById: 里就会 [非字典 objectForKey:] →
// unrecognized selector → SpringBoard 崩。这里逐元素过滤，只放行真正的字典。
+ (NSArray<NSDictionary *> *)superscreenshotModelLibrary {
    NSString *json = [self stringPref:XZ_KEY_MODEL_LIB default:@""];
    if (![json isKindOfClass:[NSString class]] || !json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return @[];
    id obj = nil;
    @try {
        NSError *e = nil;
        obj = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:&e];
    } @catch (NSException *ex) {
        NSLog(@"[SuperScreenshot] superscreenshotModelLibrary JSON 解析异常: %@", ex.reason);
        return @[];
    }
    if (![obj isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *clean = [NSMutableArray array];
    for (id m in (NSArray *)obj) {
        if ([m isKindOfClass:[NSDictionary class]]) [clean addObject:m];
    }
    return clean;
}

+ (void)superscreenshotSetModelLibrary:(NSArray *)arr {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr ?: @[] options:0 error:&e];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    [self setPref:XZ_KEY_MODEL_LIB value:json];
}

// v6.09 加固：id 字段可能不是字符串（NSNumber/NSNull/嵌套容器）。
// 旧实现直接 isEqualToString: → unrecognized selector → 崩。这里先做类型校验。
+ (NSDictionary *)superscreenshotModelById:(NSString *)mid {
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return nil;
    for (NSDictionary *m in [self superscreenshotModelLibrary]) {
        id v = [m objectForKey:@"id"];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v isEqualToString:mid]) return m;
    }
    return nil;
}

+ (NSDictionary *)superscreenshotAIConfig    { [self superscreenshotMigrateModelsIfNeeded]; return [self superscreenshotModelById:[self stringPref:XZ_KEY_MODEL_AI    default:@""]]; }
+ (NSDictionary *)superscreenshotOCRConfig   { [self superscreenshotMigrateModelsIfNeeded]; return [self superscreenshotModelById:[self stringPref:XZ_KEY_MODEL_OCR   default:@""]]; }
+ (NSDictionary *)superscreenshotTransConfig { [self superscreenshotMigrateModelsIfNeeded]; return [self superscreenshotModelById:[self stringPref:XZ_KEY_MODEL_TRANS default:@""]]; }

// v6.09 加固：m 传进来的可能不是字典（上游取值失败/结构被写坏），先校验再取值。
+ (NSString *)superscreenshotModelField:(NSDictionary *)m key:(NSString *)k def:(NSString *)def {
    if (![m isKindOfClass:[NSDictionary class]] || ![k isKindOfClass:[NSString class]]) return def;
    id v = [m objectForKey:k];
    return ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) ? (NSString *)v : def;
}

// 一次性迁移：把旧的 AskAI_* / BigModel_* 配置并入模型库，老用户配置不丢，
// 也避免「三个功能各填一套、误点某项 BaseURL 就把 OCR/AI 一起带崩」。
+ (void)superscreenshotMigrateModelsIfNeeded {
    if ([self boolPref:XZ_KEY_MODEL_MIGRATED default:NO]) return;
    [self setPref:XZ_KEY_MODEL_MIGRATED value:@YES];

    NSMutableArray *lib = [[self superscreenshotModelLibrary] mutableCopy];
    BOOL changed = NO;

    // 问 AI（OpenAI 兼容）
    NSString *aiKey  = [self stringPref:XZ_KEY_AI_KEY     default:@""];
    NSString *aiURL  = [self stringPref:XZ_KEY_AI_BASEURL default:@""];
    NSString *aiModel= [self stringPref:XZ_KEY_AI_MODEL   default:@""];
    if (aiKey.length || aiURL.length || aiModel.length) {
        if (![self superscreenshotModelById:@"mig_ai"]) {
            [lib addObject:@{@"id":@"mig_ai", @"name":@"我的对话模型",
                             @"baseURL":aiURL.length?aiURL:@"https://api.deepseek.com/v1",
                             @"apiKey":aiKey, @"model":aiModel.length?aiModel:@"deepseek-chat",
                             @"vendor":@"openai"}];
            [self setPref:XZ_KEY_MODEL_AI value:@"mig_ai"];
            changed = YES;
        }
    }

    // 识别引擎（智谱 BigModel）
    NSString *bmKey  = [self stringPref:XZ_KEY_BM_KEY     default:@""];
    NSString *bmURL  = [self stringPref:XZ_KEY_BM_BASEURL default:@""];
    NSString *bmModel= [self stringPref:XZ_KEY_BM_MODEL   default:@""];
    if (bmKey.length || bmURL.length || bmModel.length) {
        if (![self superscreenshotModelById:@"mig_ocr"]) {
            [lib addObject:@{@"id":@"mig_ocr", @"name":@"智谱 BigModel (识别)",
                             @"baseURL":bmURL.length?bmURL:@"https://open.bigmodel.cn/api/paas/v4",
                             @"apiKey":bmKey, @"model":bmModel.length?bmModel:@"glm-4v-flash",
                             @"vendor":@"zhipu"}];
            [self setPref:XZ_KEY_MODEL_OCR value:@"mig_ocr"];
            changed = YES;
        }
    }

    if (changed) [self superscreenshotSetModelLibrary:lib];
}

@end