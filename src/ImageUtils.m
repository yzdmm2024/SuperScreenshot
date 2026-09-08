//
//  ImageUtils.m — 图片工具实现
//

#import "ImageUtils.h"
#import "Common.h"
#import <Photos/Photos.h>
#import <dlfcn.h>

// v6.06：自定义机框支持（用户用 Filza 把机框 PNG + info.json 放进 XZ_PHONE_FRAME_DIR/<名称>/）
@interface ImageUtils ()
+ (UIImage *)applyCustomPhoneFrame:(UIImage *)image customName:(NSString *)name;
@end

@implementation ImageUtils

#pragma mark - 截屏

+ (UIImage *)captureScreen {
    // 优先：私有 UIGetScreenImage 抓真实整屏（含控制中心下层 App 内容）。
    // 用 dlsym 动态解析，避免链接私有符号导致编译/链接失败；符号不存在时回退。
    UIImage *(*getScreenImage)(void) = NULL;
    getScreenImage = (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    if (getScreenImage) {
        UIImage *img = getScreenImage();
        // v4.4：必须校验是「全屏、有效」的图，否则退化回退会截到 SpringBoard 小窗 → 白底/裁区无效。
        if ([self isFullScreenImage:img]) return img;
        NSLog(@"[SuperScreenshot] UIGetScreenImage returned degenerate image (%.0fx%.0f), fallback",
              img ? img.size.width : 0, img ? img.size.height : 0);
    }

    // 回退：把当前场景里【所有可见 window】逐层合成到全屏画布（不再只抓 keyWindow，
    // 避免抓到 SpringBoard 的一个小窗导致白底 / 选区坐标越界裁剪失败）。
    UIImage *fallback = [self captureFromWindows];
    if (fallback) return fallback;

    // 最后兜底：单个 keyWindow
    UIWindow *keyWin = [self topWindow];
    if (!keyWin) return nil;
    CGRect b = keyWin.bounds;
    if (b.size.width < 2 || b.size.height < 2) return nil;
    UIGraphicsBeginImageContextWithOptions(b.size, YES, 0);
    [keyWin drawViewHierarchyInRect:b afterScreenUpdates:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// v4.4：判断 UIGetScreenImage 的返回是否为「覆盖整屏」的有效图。
// 只要像素尺寸与屏幕点尺寸按 scale 基本吻合即视为有效；否则走回退（防白底/小图）。
+ (BOOL)isFullScreenImage:(UIImage *)img {
    if (!img || !img.CGImage) return NO;
    if (img.size.width < 2 || img.size.height < 2) return NO;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    if (sw <= 0 || sh <= 0) return YES; // 拿不到屏幕尺寸就不拦，直接用
    CGFloat scale = img.scale > 0 ? img.scale : 1.0;
    CGFloat pxW = img.size.width * scale;
    CGFloat pxH = img.size.height * scale;
    // 允许 ±15% 误差（不同机型/状态栏高度），过小判定为退化
    CGFloat minW = sw * scale * 0.85;
    CGFloat minH = sh * scale * 0.85;
    return (pxW >= minW && pxH >= minH);
}

// v4.4：合成当前所有已连接场景的可见 window 到一张全屏不透明图（兜底捕获）。
+ (UIImage *)captureFromWindows {
    @try {
        CGRect scr = [UIScreen mainScreen].bounds;
        if (scr.size.width < 2 || scr.size.height < 2) return nil;
        CGFloat scale = [UIScreen mainScreen].scale;
        if (scale <= 0) scale = 2.0;

        UIGraphicsBeginImageContextWithOptions(scr.size, YES, scale);
        // 先铺一层与系统一致的底色，避免透明区在无 App 内容处露白
        [[UIColor blackColor] setFill];
        UIRectFill(scr);

        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.hidden) continue;
                    if (CGRectIsEmpty(w.bounds)) continue;
                    @try {
                        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
                    } @catch (NSException *e) { /* 单个窗失败不影响其他 */ }
                }
            }
        }
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    } @catch (NSException *e) {
        NSLog(@"[SuperScreenshot] captureFromWindows exception: %@ %@", e.name, e.reason);
        return nil;
    }
}

+ (UIWindow *)topWindow {
    if (@available(iOS 13.0, *)) {
        NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

#pragma mark - v4.1：坐标空间换算 / 裁剪 / 取色
//
// 【v4.0 的致命 bug】
//   旧代码 screenCropInPixels 把选区 (点) × UIScreen.scale 得到「像素 rect」，
//   然后 cropImage:toPixelRect: 里又拿它跟 img.size（UIGetScreenImage 返回的图
//   size 通常是【点】，scale 可能是 1）做 CGRectIntersection：
//       CGRectIntersection(像素rect, 点bounds)
//   -> 落在屏幕下半部分的选区会被裁成空/极小 -> 返回 nil -> 弹「裁剪失败」
//   -> 窗口B 永远不出现（用户反馈「圈选范围后没有两排功能按钮区域」）。
//
// 【v4.2 根因修复】
//   v4.1 用 ratio = image.size.width / 屏幕宽(点) 做换算，但 CGImageCreateWithImageInRect
//   是按【CGImage 像素坐标】裁剪的。iOS16 上 UIGetScreenImage 返回的 UIImage 是
//   scale=3、size=点数(如 390×844)，其底层 CGImage 是 1170×2532 像素：
//     ratio = 390/390 = 1 → 点 rect 被直接当像素 rect → 永远裁中屏幕左上角一小块。
//   正确做法：比例基准 = CGImage 真实像素宽 / 屏幕点宽，目标空间 = 像素空间。
+ (CGRect)imageRectForScreenRect:(CGRect)screenRect image:(UIImage *)image {
    if (!image) return CGRectZero;
    CGImageRef cg = image.CGImage;
    if (!cg) return CGRectZero;

    CGFloat pxW = (CGFloat)CGImageGetWidth(cg);    // CGImage 真实像素宽
    CGFloat pxH = (CGFloat)CGImageGetHeight(cg);
    if (pxW <= 0 || pxH <= 0) return CGRectZero;

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) return CGRectZero;

    // 点 → 像素：像素空间 rect（无论 image.size 是点还是像素都成立）
    CGFloat ratio = pxW / screenW;
    CGRect r = CGRectMake(floor(screenRect.origin.x * ratio),
                          floor(screenRect.origin.y * ratio),
                          floor(screenRect.size.width * ratio),
                          floor(screenRect.size.height * ratio));

    // 钳制进图像边界，防越界
    CGRect bounds = CGRectMake(0, 0, pxW, pxH);
    r = CGRectIntersection(r, bounds);
    if (CGRectIsNull(r)) return CGRectZero;
    return r;
}

+ (UIImage *)cropImage:(UIImage *)image screenRect:(CGRect)screenRect {
    if (!image) return nil;
    CGImageRef cgimg = image.CGImage;
    if (!cgimg) return nil;

    CGRect r = [self imageRectForScreenRect:screenRect image:image];
    if (r.size.width < 4 || r.size.height < 4) {
        NSLog(@"[SuperScreenshot] crop failed: screenRect=(%.1f,%.1f,%.1f,%.1f) imgSize=(%.0f,%.0f) CGImage=(%.0f,%.0f) outRect=(%.0f,%.0f,%.0f,%.0f)",
              screenRect.origin.x, screenRect.origin.y,
              screenRect.size.width, screenRect.size.height,
              image.size.width, image.size.height,
              (CGFloat)CGImageGetWidth(cgimg), (CGFloat)CGImageGetHeight(cgimg),
              r.origin.x, r.origin.y, r.size.width, r.size.height);
        return nil;
    }
    CGImageRef cut = CGImageCreateWithImageInRect(cgimg, r);
    if (!cut) return nil;
    UIImage *out = [UIImage imageWithCGImage:cut
                                       scale:image.scale
                                 orientation:image.imageOrientation];
    CGImageRelease(cut);
    return out;
}

+ (UIColor *)pixelColorAtPoint:(CGPoint)pt inImage:(UIImage *)image {
    CGImageRef cgimg = image.CGImage;
    if (!cgimg) return nil;
    if (image.size.width <= 0 || image.size.height <= 0) return nil;

    CGFloat pxW = (CGFloat)CGImageGetWidth(cgimg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cgimg);
    if (pxW <= 0 || pxH <= 0) return nil;

    // pt 是 image 自身坐标系（image.size）下的位置 -> 归一化 -> 映射到像素
    CGFloat x = floor((pt.x / image.size.width) * pxW);
    CGFloat y = floor((pt.y / image.size.height) * pxH);
    if (x < 0 || y < 0 || x >= pxW || y >= pxH) return nil;

    unsigned char raw[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(raw, 1, 1, 8, 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    // 把整张图按 1:1 像素画进 1×1 的画布，并把目标像素推到画布原点
    CGContextDrawImage(ctx, CGRectMake(-x, -y, pxW, pxH), cgimg);
    CGContextRelease(ctx);

    return [UIColor colorWithRed:raw[0] / 255.0
                           green:raw[1] / 255.0
                            blue:raw[2] / 255.0
                           alpha:raw[3] / 255.0];
}

#pragma mark - 相册

+ (void)saveToCustomAlbum:(UIImage *)image completion:(void (^)(BOOL, NSError *))completion {
    // 先检查相册权限
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // v6.20.5：兼容 iOS 14+「限定访问(Limited)」权限，否则相册创建/写入会被误判为"无权限"而失败
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                if (completion) completion(NO, [NSError errorWithDomain:@"ImageUtils" code:-1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"没有相册权限"}]);
                return;
            }
            
            // 查找或创建「超级截图」相册
            __block PHAssetCollection *targetAlbum = nil;
            PHFetchResult *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                 subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                                 options:nil];
            [collections enumerateObjectsUsingBlock:^(PHAssetCollection *obj, NSUInteger idx, BOOL *stop) {
                if ([obj.localizedTitle isEqualToString:@"超级截图"]) {
                    targetAlbum = obj;
                    *stop = YES;
                }
            }];
            
            if (!targetAlbum) {
                // 创建新相册
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:@"超级截图"];
                } completionHandler:^(BOOL success, NSError *error) {
                    if (success) {
                        // 重新查找
                        PHFetchResult *newCol = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                        subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                                        options:nil];
                        [newCol enumerateObjectsUsingBlock:^(PHAssetCollection *obj, NSUInteger idx, BOOL *stop) {
                            if ([obj.localizedTitle isEqualToString:@"超级截图"]) {
                                targetAlbum = obj;
                                *stop = YES;
                            }
                        }];
                        [self saveImage:image toAlbum:targetAlbum completion:completion];
                    } else {
                        if (completion) completion(NO, error);
                    }
                }];
            } else {
                [self saveImage:image toAlbum:targetAlbum completion:completion];
            }
        });
    }];
}

+ (void)saveImage:(UIImage *)image toAlbum:(PHAssetCollection *)album completion:(void (^)(BOOL, NSError *))completion {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *assetReq = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        PHAssetCollectionChangeRequest *albumReq = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
        [albumReq addAssets:@[assetReq.placeholderForCreatedAsset]];
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, error);
        });
    }];
}

#pragma mark - 手机外壳

// v6.05：按机型外壳参数把整屏截图套进透明「屏幕窗」，再在四周绘制手机中框 + 刘海。
//       仅对「正常截图」生效（captureFullScreenAndSave 调用），局部截图不走这里。
// v6.06：支持「自定义机框」——Root.plist 的 PSMultiValue 选「自定义」时 caseId=@"custom"，
//       这里实时读 PhoneCase_CustomName 展开成 custom:<名称>；直接传 custom:<名称> 也能用。
+ (UIImage *)applyPhoneFrame:(UIImage *)image caseId:(NSString *)caseId {
    if (!image || !image.CGImage) return image;

    // —— v6.06：展开「自定义」哨兵 ——
    if ([caseId isEqualToString:@"custom"]) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
        NSString *nm = [d stringForKey:@"PhoneCase_CustomName"];
        nm = [nm stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!nm.length) return image;            // 选了自定义但没填名称 → 不套壳
        caseId = [@"custom:" stringByAppendingString:nm];
    }
    if ([caseId hasPrefix:@"custom:"]) {
        NSString *name = [caseId substringFromIndex:7];
        UIImage *out = [self applyCustomPhoneFrame:image customName:name];
        if (out) return out;
        NSLog(@"[SuperScreenshot] custom frame '%@' load failed, fallback to original", name);
        return image;
    }

    NSDictionary *p = [self phoneCaseParams:caseId];
    if (!p) return image;                         // none / 未知 → 原图返回（不套壳）
    CGFloat bezel   = [p[@"bezel"] floatValue];   // 中框厚度（点）
    CGFloat screenR = [p[@"screenR"] floatValue]; // 屏幕圆角（点）
    UIColor *bezelColor = p[@"color"];
    BOOL notch = [p[@"notch"] boolValue];

    CGFloat w = image.size.width, h = image.size.height;
    CGFloat scale = image.scale > 0 ? image.scale : [UIScreen mainScreen].scale;
    if (scale <= 0) scale = 3.0;
    CGFloat bz = bezel * scale;                   // 中框（像素）
    CGFloat sr = screenR * scale;                 // 屏幕圆角（像素）
    CGFloat outW = w * scale + 2 * bz;
    CGFloat outH = h * scale + 2 * bz;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(outW, outH), NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // 外框（中框）
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, outW, outH)
                                                      cornerRadius:sr + bz];
    [bezelColor setFill];
    [outer fill];

    // 屏幕区域（先把黑底铺上，避免截图透明处露白，再贴截图）
    CGRect screenRect = CGRectMake(bz, bz, w * scale, h * scale);
    UIBezierPath *screen = [UIBezierPath bezierPathWithRoundedRect:screenRect cornerRadius:sr];
    [screen addClip];
    [[UIColor blackColor] setFill];
    CGContextFillRect(ctx, screenRect);
    [image drawInRect:screenRect];

    // 刘海（屏幕顶部居中黑块）
    if (notch) {
        CGFloat nW = w * scale * 0.40, nH = 30 * scale;
        CGFloat nX = (outW - nW) / 2.0;
        UIBezierPath *np = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(nX, bz, nW, nH)
                                                  byRoundingCorners:UIRectCornerBottomLeft | UIRectCornerBottomRight
                                                        cornerRadii:CGSizeMake(14 * scale, 14 * scale)];
        [[UIColor blackColor] setFill];
        [np fill];
    }

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result ?: image;
}

// 机型外壳参数表（v6.05 首版：iPhone 12 Pro 四色；后续可扩展）
+ (NSDictionary *)phoneCaseParams:(NSString *)caseId {
    if (!caseId || [caseId isEqualToString:@"none"]) return nil;
    if ([caseId isEqualToString:@"12pro_black"])
        return @{@"bezel":@26.0, @"screenR":@47.0, @"color":[UIColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1], @"notch":@YES};
    if ([caseId isEqualToString:@"12pro_blue"])
        return @{@"bezel":@26.0, @"screenR":@47.0, @"color":[UIColor colorWithRed:0.15 green:0.21 blue:0.30 alpha:1], @"notch":@YES};
    if ([caseId isEqualToString:@"12pro_silver"])
        return @{@"bezel":@26.0, @"screenR":@47.0, @"color":[UIColor colorWithRed:0.85 green:0.86 blue:0.88 alpha:1], @"notch":@YES};
    if ([caseId isEqualToString:@"12pro_gold"])
        return @{@"bezel":@26.0, @"screenR":@47.0, @"color":[UIColor colorWithRed:0.92 green:0.86 blue:0.76 alpha:1], @"notch":@YES};
    return nil;
}

// v6.06：自定义机框 —— 用户用 Filza 把机框 PNG + info.json 放进
//   /var/mobile/Documents/com.axs.superscreenshot/Frames/<名称>/
// info.json 结构（坐标单位 = frame.png 的像素，推荐导出 1x 或 2x；iOS 加载 data 默认 scale=1）：
//   {
//     "screen":    {"x":60,"y":60,"width":1080,"height":2340},  // 截图在机框 PNG 里的位置/尺寸
//     "frameSize": {"width":1200,"height":2460},                // 机框 PNG 尺寸（仅校验用）
//     "radius":    47,                                          // 屏幕圆角(可选,默认0)
//     "background": "#000000"                                    // 屏幕区底色(可选,默认黑)
//   }
// 截图会以 aspect-fill 填进 screen 区域（居中、超出裁切，保证铺满），再叠在机框之上。
+ (UIImage *)applyCustomPhoneFrame:(UIImage *)image customName:(NSString *)name {
    if (!name.length) return nil;
    NSString *dir = [XZ_PHONE_FRAME_DIR stringByAppendingPathComponent:name];
    NSString *framePath = [dir stringByAppendingPathComponent:@"frame.png"];
    NSString *infoPath  = [dir stringByAppendingPathComponent:@"info.json"];

    NSData *frameData = [NSData dataWithContentsOfFile:framePath];
    if (!frameData) { NSLog(@"[SuperScreenshot] custom frame missing png: %@", framePath); return nil; }
    UIImage *frame = [UIImage imageWithData:frameData];
    if (!frame || !frame.CGImage) { NSLog(@"[SuperScreenshot] custom frame bad png: %@", framePath); return nil; }

    NSData *infoData = [NSData dataWithContentsOfFile:infoPath];
    if (!infoData) { NSLog(@"[SuperScreenshot] custom frame missing info.json: %@", infoPath); return nil; }
    NSError *je = nil;
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:infoData options:0 error:&je];
    if (!info || je) { NSLog(@"[SuperScreenshot] custom frame info.json parse err: %@", je.localizedDescription); return nil; }

    NSDictionary *sc = info[@"screen"];
    if (!sc || ![sc isKindOfClass:[NSDictionary class]]) { NSLog(@"[SuperScreenshot] custom frame info.json 缺 screen"); return nil; }
    CGFloat sx = [sc[@"x"] floatValue], sy = [sc[@"y"] floatValue];
    CGFloat sw = [sc[@"width"] floatValue], sh = [sc[@"height"] floatValue];
    if (sw <= 0 || sh <= 0) { NSLog(@"[SuperScreenshot] custom frame screen 尺寸非法"); return nil; }
    CGFloat radius = [info[@"radius"] floatValue];          // 0 = 不圆角

    CGFloat scale = frame.scale > 0 ? frame.scale : 1.0;
    CGSize canvas = CGSizeMake(frame.size.width * scale, frame.size.height * scale);

    UIGraphicsBeginImageContextWithOptions(canvas, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // 1) 机框本体
    [frame drawInRect:CGRectMake(0, 0, canvas.width, canvas.height)];

    // 2) 截图塞进 screen 区域
    CGRect screenRect = CGRectMake(sx * scale, sy * scale, sw * scale, sh * scale);
    if (radius > 0) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:screenRect
                                                        cornerRadius:radius * scale];
        [clip addClip];
    }
    // 屏幕区底色（防止截图透明处露白）
    if (info[@"background"]) {
        NSString *hex = info[@"background"];
        UIColor *bg = [self _colorFromHex:hex] ?: [UIColor blackColor];
        [bg setFill];
        CGContextFillRect(ctx, screenRect);
    } else {
        [[UIColor blackColor] setFill];
        CGContextFillRect(ctx, screenRect);
    }
    // aspect-fill：以 screen 区域为画布，居中填满
    CGFloat ir = image.size.width / image.size.height;
    CGFloat sr = screenRect.size.width / screenRect.size.height;
    CGRect drawRect;
    if (ir > sr) {
        CGFloat w = screenRect.size.height * ir;
        drawRect = CGRectMake(screenRect.origin.x + (screenRect.size.width - w) / 2.0,
                              screenRect.origin.y, w, screenRect.size.height);
    } else {
        CGFloat h = screenRect.size.width / ir;
        drawRect = CGRectMake(screenRect.origin.x,
                              screenRect.origin.y + (screenRect.size.height - h) / 2.0,
                              screenRect.size.width, h);
    }
    [image drawInRect:drawRect];

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result ?: image;
}

// v6.06：#RRGGBB / #RRGGBBAA 解析（自定义机框 info.json 的 background 字段用）
+ (UIColor *)_colorFromHex:(NSString *)hex {
    if (!hex.length) return nil;
    NSString *s = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (s.length == 6 || s.length == 8) {
        unsigned int v = 0;
        [[NSScanner scannerWithString:s] scanHexInt:&v];
        if (s.length == 6) return [UIColor colorWithRed:((v>>16)&0xFF)/255.0
                                                  green:((v>>8)&0xFF)/255.0
                                                   blue:(v&0xFF)/255.0 alpha:1.0];
        return [UIColor colorWithRed:((v>>24)&0xFF)/255.0
                                green:((v>>16)&0xFF)/255.0
                                 blue:((v>>8)&0xFF)/255.0 alpha:(v&0xFF)/255.0];
    }
    return nil;
}

// 向后兼容
+ (UIImage *)applyPhoneFrame:(UIImage *)image {
    return [self applyPhoneFrame:image caseId:@"none"];
}

#pragma mark - 悬浮窗口

+ (UIWindow *)createFloatingWindowWithImage:(UIImage *)image {
    CGFloat fw = 120, fh = 120 * image.size.height / image.size.width;
    if (fh > 200) { fh = 200; fw = 200 * image.size.width / image.size.height; }
    CGFloat fx = UIScreen.mainScreen.bounds.size.width - fw - 20;
    CGFloat fy = UIScreen.mainScreen.bounds.size.height / 2 - fh / 2;
    
    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(fx, fy, fw, fh)];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];
    
    UIImageView *iv = [[UIImageView alloc] initWithFrame:win.bounds];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12;
    iv.clipsToBounds = YES;
    iv.layer.borderColor = [UIColor whiteColor].CGColor;
    iv.layer.borderWidth = 2;
    [win addSubview:iv];
    
    // 关闭按钮
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(fw - 28, 0, 28, 28);
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor redColor];
    [closeBtn addTarget:self action:@selector(dismissFloating:) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:closeBtn];
    
    // 拖拽
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloating:)];
    [win addGestureRecognizer:pan];

    // 双击退出（v4.1 修正：手势的 sender 是 UITapGestureRecognizer，
    // 不能复用 dismissFloating: 里 btn.superview 的写法，否则 unrecognized selector 崩溃）
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissFloatingByGesture:)];
    dt.numberOfTapsRequired = 2;
    [win addGestureRecognizer:dt];

    return win;
}

+ (void)dismissFloating:(UIButton *)btn {
    UIView *v = btn.superview;
    if ([v isKindOfClass:[UIWindow class]]) {
        ((UIWindow *)v).hidden = YES;
    }
}

+ (void)dismissFloatingByGesture:(UITapGestureRecognizer *)gesture {
    UIView *v = gesture.view;
    if ([v isKindOfClass:[UIWindow class]]) {
        ((UIWindow *)v).hidden = YES;
    }
}

+ (void)panFloating:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}

@end