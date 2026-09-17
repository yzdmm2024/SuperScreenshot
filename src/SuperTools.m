//
//  SuperTools.m — 窗口B 全部按钮的底层实现（超级截图 v4.1）
//
//  只使用 iOS 16 系统自带框架：Vision / PencilKit / PDFKit / Photos / CoreGraphics / UIKit
//
//  v4.1 补全：
//   · 打码：从 v4.0 的占位 toast 升级为完整实现
//       模式A 手动涂抹：手指在图上画，画过的区域像素化（马赛克）
//       模式B 智能脱敏：Vision OCR 取文字坐标 → 正则匹配手机号/身份证/银行卡/邮箱
//                       → 命中区域自动叠加色块
//   · 取色器：从占位升级为完整实现（点图取像素色值，显示 HEX，可复制）
//   · 翻译：从「返回原文占位」升级为真实网络翻译调用（免费 gtx 接口，可换 API）
//   · OCR 重构为「逐行带坐标」的底层方法，翻译/智能脱敏共用
//
//  ⚠️ Vision 相关全部走 NSClassFromString + KVC，原因：CI 用的 theos SDK 是
//     iPhoneOS14.5，iOS 13+ 才有的 Vision 符号在头文件里并不齐全，直接引用会编译失败。
//

#import "SuperTools.h"
#import "Common.h"
#import "AskAIEngine.h"   // v5.17：大模型OCR（OpenAI 兼容，AI Studio/Doubao 等免费）
#import "ImageUtils.h"
#import "EditToolbarWindow.h"   // v6.20.20：分享/打开 App 时统一收起截图面板
#import "MaskCropWindow.h"
#import "HistoryWindow.h"

// 私有方法声明（PaddleOCR 异步任务协议辅助）
@interface SuperTools ()
+ (void)_ppocrJobsSubmitURL:(NSURL *)u token:(NSString *)token model:(NSString *)model jpeg:(NSData *)jpeg scaleX:(CGFloat)sx scaleY:(CGFloat)sy attempt:(NSInteger)attempt completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion;
+ (void)_ppocrJobsPollJob:(NSString *)jobId baseURL:(NSURL *)u token:(NSString *)token scaleX:(CGFloat)sx scaleY:(CGFloat)sy attempt:(NSInteger)attempt completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion;
+ (void)_ppocrFetchResult:(NSString *)jsonl scaleX:(CGFloat)sx scaleY:(CGFloat)sy completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion;
+ (void)_ppocrSyncWithURL:(NSURL *)u token:(NSString *)token jpeg:(NSData *)jpeg scaleX:(CGFloat)sx scaleY:(CGFloat)sy completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion;
+ (CGRect)_superscreenshotRectFromPaddlePoly:(id)poly;
// v6.20.20 分享相关私有方法
+ (NSURL *)sharedTemporaryPNGForImage:(UIImage *)image;
+ (void)dismissScreenshotPanels;
+ (void)_showShareSheetWithItems:(NSArray *)items fromWindow:(UIWindow *)win cleanupURL:(NSURL *)cleanupURL;
@end

#import <Vision/Vision.h>
#import <PDFKit/PDFKit.h>
#import <Photos/Photos.h>
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>

#pragma mark - 私有类 / 私有方法前置声明

@class XZPaintView;
@class XZMosaicEditor;
@class XZColorPicker;
@class XZDrawCanvas;
@class XZDrawStroke;
@class XZDrawEditor;
@interface XZDrawEditor : NSObject
+ (void)edit:(UIImage *)image completion:(void (^)(UIImage *edited))completion;
@end

// 本文件内部使用的私有方法（打码编辑器 / 取色器窗口会回调进来）
@interface SuperTools (Private)
+ (void)ocrObservations:(UIImage *)image
             completion:(void (^)(NSArray<NSDictionary *> *items))completion;
+ (void)ocrObservations:(UIImage *)image languages:(NSArray *)langs
             completion:(void (^)(NSArray<NSDictionary *> *items))completion;
+ (NSArray<NSDictionary *> *)_superscreenshotSortItemsByReadingOrder:(NSArray<NSDictionary *> *)items; // v6.20.3
+ (UIImage *)bdShrink:(UIImage *)src maxDim:(CGFloat)maxDim;                     // v5.13
+ (void)detectSensitiveRects:(UIImage *)image
                  completion:(void (^)(NSArray<NSValue *> *rects))completion;
+ (void)translateText:(NSString *)text completion:(void (^)(NSString *dst, NSString *err))completion;
+ (UIImage *)pixelatedImage:(UIImage *)src ratio:(CGFloat)ratio;
+ (UIImage *)applyMask:(CGImageRef)maskCG toPixelated:(UIImage *)pixelated onImage:(UIImage *)orig;
+ (CGImageRef)createMaskWithSize:(CGSize)pxSize
                           rects:(NSArray<NSValue *> *)rects
                           paths:(NSArray<UIBezierPath *> *)paths
                      pathWidths:(NSArray<NSNumber *> *)widths;
+ (UIImage *)gaussianBlurImage:(UIImage *)src radius:(CGFloat)radius;
@end

@interface XZMosaicEditor : NSObject
+ (void)edit:(UIImage *)image completion:(void (^)(UIImage *edited))completion;
@end

@interface XZColorPicker : NSObject
+ (void)show:(UIImage *)image;
@end

#pragma mark - 小工具

// 等比居中：算出 content 放进 bounds 后的实际显示区域（aspectFit）
static CGRect XZFitRect(CGSize content, CGRect bounds) {
    if (content.width <= 0 || content.height <= 0) return bounds;
    CGFloat s = MIN(bounds.size.width / content.width, bounds.size.height / content.height);
    CGSize out = CGSizeMake(content.width * s, content.height * s);
    return CGRectMake(bounds.origin.x + (bounds.size.width - out.width) / 2.0,
                      bounds.origin.y + (bounds.size.height - out.height) / 2.0,
                      out.width, out.height);
}

// 从 NSValue 里安全取 CGRect
static CGRect XZRectFromValue(id v) {
    if ([v isKindOfClass:[NSValue class]]) {
        return [(NSValue *)v CGRectValue];
    }
    return CGRectZero;
}

@implementation SuperTools

#pragma mark - 0. OCR 阅读顺序重排（v6.20.3）
// 按人类阅读顺序重排：有效 box 的块按「中心 y 聚类成行 + 行内按中心 x 升序」排序；
// 无坐标(全 Zero)的块保持原相对顺序并置于末尾。对单列竖向截图几乎完美。
+ (NSArray<NSDictionary *> *)_superscreenshotSortItemsByReadingOrder:(NSArray<NSDictionary *> *)items {
    if (!items || items.count < 2) return items ?: @[];
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *invalid = [NSMutableArray array];
    for (NSDictionary *it in items) {
        CGRect r = XZRectFromValue(it[@"box"]);
        if (r.size.width > 1 && r.size.height > 1) [valid addObject:it];
        else [invalid addObject:it];
    }
    if (valid.count < 2) return items; // 有效块不足，原序（含全 Zero 情况）
    NSMutableArray<NSValue *> *centers = [NSMutableArray array];
    NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
    for (NSDictionary *it in valid) {
        CGRect r = XZRectFromValue(it[@"box"]);
        [centers addObject:[NSValue valueWithCGPoint:CGPointMake(r.origin.x + r.size.width/2,
                                                                r.origin.y + r.size.height/2)]];
        [heights addObject:@(r.size.height)];
    }
    NSArray *sh = [heights sortedArrayUsingSelector:@selector(compare:)];
    CGFloat medH = [sh[sh.count/2] floatValue];
    CGFloat rowTol = MAX(medH * 0.7, 2.0);
    NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
    for (NSInteger i = 0; i < valid.count; i++) [idx addObject:@(i)];
    [idx sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b){
        CGPoint pa = [centers[a.integerValue] CGPointValue];
        CGPoint pb = [centers[b.integerValue] CGPointValue];
        if (pa.y < pb.y) return NSOrderedAscending;
        if (pa.y > pb.y) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableArray<NSNumber *> *cur = [NSMutableArray array];
    CGFloat rowBaseY = -1;
    void (^flush)(void) = ^{
        if (cur.count) {
            [cur sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b){
                CGPoint pa = [centers[a.integerValue] CGPointValue];
                CGPoint pb = [centers[b.integerValue] CGPointValue];
                if (pa.x < pb.x) return NSOrderedAscending;
                if (pa.x > pb.x) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            for (NSNumber *n in cur) [out addObject:valid[n.integerValue]];
            [cur removeAllObjects];
        }
    };
    for (NSNumber *n in idx) {
        CGPoint p = [centers[n.integerValue] CGPointValue];
        if (rowBaseY < 0 || (p.y - rowBaseY <= rowTol && rowBaseY - p.y <= rowTol)) {
            [cur addObject:n];
            if (rowBaseY < 0) rowBaseY = p.y;
        } else {
            flush();
            [cur addObject:n];
            rowBaseY = p.y;
        }
    }
    flush();
    [out addObjectsFromArray:invalid];
    return out;
}

// v6.20.3：PaddleOCR 结果里的坐标可能是 4 点多边形 [[x,y]×4] 或 [x,y,w,h]，统一转成 CGRect
+ (CGRect)_superscreenshotRectFromPaddlePoly:(id)poly {
    if (![poly isKindOfClass:[NSArray class]]) return CGRectZero;
    NSArray *a = (NSArray *)poly;
    if (a.count == 4) {
        id p0 = a[0];
        if ([p0 isKindOfClass:[NSArray class]] && [(NSArray *)p0 count] == 2) {
            CGFloat xs[4], ys[4];
            for (int i = 0; i < 4; i++) {
                NSArray *pt = a[i];
                if (![pt isKindOfClass:[NSArray class]] || pt.count < 2) return CGRectZero;
                xs[i] = [pt[0] floatValue];
                ys[i] = [pt[1] floatValue];
            }
            CGFloat minX = MIN(MIN(xs[0],xs[1]), MIN(xs[2],xs[3]));
            CGFloat minY = MIN(MIN(ys[0],ys[1]), MIN(ys[2],ys[3]));
            CGFloat maxX = MAX(MAX(xs[0],xs[1]), MAX(xs[2],xs[3]));
            CGFloat maxY = MAX(MAX(ys[0],ys[1]), MAX(ys[2],ys[3]));
            return CGRectMake(minX, minY, maxX-minX, maxY-minY);
        }
        if ([a[0] isKindOfClass:[NSNumber class]]) {
            return CGRectMake([a[0] floatValue], [a[1] floatValue], [a[2] floatValue], [a[3] floatValue]);
        }
    }
    return CGRectZero;
}

#pragma mark - 1. OCR（v5.23.0 整块重做: 只走智谱 BigModel glm-4v-flash, OpenAI 兼容协议）

// 入口: ocrObservations: → ocrViaBigModel → 失败弹 alert (不静默, 不 fallback)
// 返回 items: @[ @{@"text":NSString, @"box":NSValue(CGRect 像素坐标)} ]
+ (void)ocrObservations:(UIImage *)image
             completion:(void (^)(NSArray<NSDictionary *> *items))completion {
    [self ocrObservations:image languages:nil completion:completion];
}

// languages 参数保留只是为了不破坏旧调用方, v5.23.0 走 BigModel 完全不依赖它
+ (void)ocrObservations:(UIImage *)image languages:(NSArray *)langs
             completion:(void (^)(NSArray<NSDictionary *> *items))completion {
    if (!image.CGImage) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        }
        return;
    }
    [self ocrViaBigModel:image completion:^(NSArray<NSDictionary *> *items, NSString *err) {
        if (err.length) {
            // 失败弹 alert (不静默, 不 fallback, 不回退本地/百度)
            dispatch_async(dispatch_get_main_queue(), ^{
                [Common superscreenshotAlertError:@"OCR 失败" message:err];
            });
        }
        // v6.20.3：交付前按阅读顺序重排（智能脱敏等下游按 box+text 绑定关系使用，重排不影响其正确性）
        if (completion) completion([self _superscreenshotSortItemsByReadingOrder:items]);
    }];
}

// v5.23.0: 智谱 BigModel glm-4v-flash 多模态 OCR
//   BaseURL  默认 https://open.bigmodel.cn/api/paas/v4
//   Endpoint /chat/completions
//   协议     OpenAI 兼容 (messages:[{role:user, content:[{type:text,...},{type:image_url,image_url:{url:data:image/jpeg;base64,...}}]}])
//   响应     choices[0].message.content (纯文本, 无 markdown 代码块)
// 失败: 弹 alert 显示原始 error message, 调用方收到 nil items
+ (void)ocrViaBigModel:(UIImage *)image
            completion:(void (^)(NSArray<NSDictionary *> *items, NSString *err))completion {
    // v6.10：若启用了内置百度 PP-OCR，则走独立免费通道（覆盖大模型库）
    if ([Common boolPref:XZ_KEY_PPOCR_ON default:NO]) {
        [self ocrViaPPOCR:image completion:completion];
        return;
    }
    // v6.14：识别引擎选择器里直接选了「内置 PaddleOCR」（哨兵 id），走免费通道
    NSString *selOCR = [Common stringPref:XZ_KEY_MODEL_OCR default:@""];
    if ([selOCR isEqualToString:XZ_PPOCR_SENTINEL]) {
        [self ocrViaPPOCR:image completion:completion];
        return;
    }
    // v6.07：识别引擎改走「大模型库」——从 ModelOCR_ID 取选中的模型配置
    NSDictionary *cfg = [Common superscreenshotOCRConfig];
    // v6.13：大模型库里选中的识别模型若是「百度 PaddleOCR」，直接走独立免费通道
    if ([[Common superscreenshotModelField:cfg key:@"vendor" def:@""] isEqualToString:@"paddleocr"]) {
        [self ocrViaPPOCR:image completion:completion];
        return;
    }
    if (!cfg) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"识别引擎未选择模型：请到「设置 → 大模型库 → 识别引擎·使用模型」选一个模型（也可一键导入预设）。");
            });
        }
        return;
    }
    NSString *bu   = [Common superscreenshotModelField:cfg key:@"baseURL" def:@"https://open.bigmodel.cn/api/paas/v4"];
    NSString *key  = [Common superscreenshotModelField:cfg key:@"apiKey"  def:@""];
    NSString *md   = [Common superscreenshotModelField:cfg key:@"model"   def:@"glm-4v-flash"];
    NSString *pr   = [Common stringPref:XZ_KEY_BM_PROMPT default:@""];

    if (!key.length) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"所选识别模型未填 API Key：请到「设置 → 大模型库」编辑该模型填入 Key。");
            });
        }
        return;
    }

    // 缩图: 智谱多模态限 4MB, 截全屏可能超, 压到最长边 2048 + JPEG 0.7 一般 200-500KB
    UIImage *tiny = [self bdShrink:image maxDim:2048];
    NSData *jpeg = UIImageJPEGRepresentation(tiny, 0.7);
    if (!jpeg.length) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"图像编码失败"); });
        }
        return;
    }
    NSString *b64 = [jpeg base64EncodedStringWithOptions:0];
    NSString *dataURL = [@"data:image/jpeg;base64," stringByAppendingString:b64];

    NSString *prompt = pr.length ? pr : @"识别这张图片中的全部文字，严格按人类阅读顺序输出：从上到下、同一行从左到右；若图片分多栏，请逐栏完整读完一栏再读下一栏；图文混排时按视觉位置顺序。按原文逐行输出，不要任何解释、不要代码块、不要编号、不要翻译。";
    NSDictionary *pic = @{ @"type": @"image_url",
                           @"image_url": @{ @"url": dataURL } };
    NSDictionary *txt = @{ @"type": @"text", @"text": prompt };
    NSArray *messages = @[ @{ @"role": @"user", @"content": @[ txt, pic ] } ];

    // 复用 AskAIEngine 的 OpenAI 兼容 askMessages: (已支持 BigModel / 智谱)
    [AskAIEngine askMessages:messages baseURL:bu apiKey:key model:md
                  completion:^(NSString *answer, NSString *err) {
        if (err.length) {
            NSLog(@"[SuperScreenshot] BigModel OCR failed: %@", err);
            if (completion) completion(nil, err);
            return;
        }
        if (!answer.length) {
            if (completion) completion(nil, @"智谱返回为空（模型未识别到任何文字）");
            return;
        }
        // 清理 markdown 代码块 (```...```) 和多余空行
        NSString *clean = [self _stripMarkdownCodeBlocks:answer];
        NSArray *lines = [clean componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSString *ln in lines) {
            NSString *s = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (s.length) {
                [items addObject:@{ @"text": s, @"box": [NSValue valueWithCGRect:CGRectZero] }];
            }
        }
        if (!items.count) {
            if (completion) completion(nil, @"智谱返回为空（模型未识别到任何文字）");
            return;
        }
        if (completion) completion(items, nil);
    }];
}

#pragma mark - v6.11 内置百度 PaddleOCR（AI Studio 免费版，独立通道）

// AI Studio PaddleOCR 有两种接口形态：
//   1) v2 异步任务接口（用户实际用的，URL 含 /api/v2/ocr/jobs）：
//        POST multipart/form-data（字段 model + optionalPayload(JSON串) + 文件 part 名 file）
//        → 取 data.jobId → GET /{jobId} 轮询到 state=done → 取 data.resultUrl.jsonUrl(JSONL)
//        → 每行 {"result":{"ocrResults":[{"prunedResult":{"rec_texts":[...]}}]}}
//        鉴权：Authorization: Bearer <TOKEN>
//   2) 同步接口（其它老地址，兜底）：POST JSON {"file":b64,"fileType":1}，直接回 result。
// 文字最终都在 result.ocrResults[].prunedResult.rec_texts。
+ (void)ocrViaPPOCR:(UIImage *)image
         completion:(void (^)(NSArray<NSDictionary *> *items, NSString *err))completion {
    NSString *apiURL = [Common stringPref:XZ_KEY_PPOCR_URL default:@""];
    NSString *token  = [Common stringPref:XZ_KEY_PPOCR_TOKEN default:@""];
    NSString *model  = [Common stringPref:XZ_KEY_PPOCR_MODEL default:@"PP-OCRv6"];
    if (!apiURL.length || !token.length) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 未配置：请到「设置 → 超级截图 → 识别引擎 → 百度 PaddleOCR」填入 API_URL 和 Token（均从 aistudio.baidu.com/paddleocr/task 页面获取，免费）。");
            });
        }
        return;
    }
    NSURL *u = [NSURL URLWithString:apiURL];
    if (!u) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 的 API_URL 无效，请检查是否完整复制（需以 https:// 开头）。");
            });
        }
        return;
    }
    UIImage *tiny = [self bdShrink:image maxDim:2048];
    NSData *jpeg = UIImageJPEGRepresentation(tiny, 0.8);
    // v6.20.3：计算原图/缩图比例，供坐标缩放回原图（脱敏需原图坐标）
    CGFloat sX = 1.0, sY = 1.0;
    CGImageRef oig = image.CGImage, tig = tiny.CGImage;
    if (oig && tig) {
        CGFloat ow = CGImageGetWidth(oig), oh = CGImageGetHeight(oig);
        CGFloat tw = CGImageGetWidth(tig), th = CGImageGetHeight(tig);
        if (tw > 0) sX = ow / tw;
        if (th > 0) sY = oh / th;
    }
    if (!jpeg.length) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"图像编码失败"); });
        }
        return;
    }
    // v6.15：优先走 v2 异步任务接口；其它地址走同步兜底
    BOOL isJobs = [[u.path lowercaseString] containsString:@"/api/v2/ocr/jobs"];
    if (isJobs) {
        [self _ppocrJobsSubmitURL:u token:token model:model jpeg:jpeg scaleX:sX scaleY:sY attempt:0 completion:completion];
    } else {
        [self _ppocrSyncWithURL:u token:token jpeg:jpeg scaleX:sX scaleY:sY completion:completion];
    }
}

// —— v2 异步任务：提交（multipart），队列满则重试 ——
+ (void)_ppocrJobsSubmitURL:(NSURL *)u token:(NSString *)token model:(NSString *)model
                        jpeg:(NSData *)jpeg scaleX:(CGFloat)sx scaleY:(CGFloat)sy attempt:(NSInteger)attempt
                   completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    NSString *boundary = @"----SuperScreenshotPaddleOCRBoundary7Q2k9X";
    NSMutableData *body = [NSMutableData data];
    void (^appendField)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    };
    appendField(@"model", model);
    appendField(@"optionalPayload", @"{\"useDocOrientationClassify\":false,\"useDocUnwarping\":false,\"useTextlineOrientation\":false}");
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: image/jpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:jpeg];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    [req setHTTPMethod:@"POST"];
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setHTTPBody:body];
    [req setTimeoutInterval:40];

    NSURLSession *sess = [NSURLSession sharedSession];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *od, NSURLResponse *r, NSError *oe) {
        if (oe) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 提交失败：%@", oe.localizedDescription]);
            });
            return;
        }
        id oj = [NSJSONSerialization JSONObjectWithData:od options:0 error:nil];
        if (![oj isKindOfClass:[NSDictionary class]]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 返回非 JSON（API_URL 可能不正确）");
            });
            return;
        }
        NSNumber *code = oj[@"code"];
        if (code && code.integerValue != 0) {
            NSString *msg = oj[@"msg"] ?: @"未知错误";
            // 队列已满 → 重试（最多 4 次，间隔 3s）
            if (code.integerValue == 10010 && attempt < 4) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self _ppocrJobsSubmitURL:u token:token model:model jpeg:jpeg scaleX:sx scaleY:sy attempt:attempt+1 completion:completion];
                });
                return;
            }
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 错误(%@)：%@", code, msg]);
            });
            return;
        }
        NSString *jobId = oj[@"data"][@"jobId"];
        if (![jobId isKindOfClass:[NSString class]] || !jobId.length) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 未返回任务 ID");
            });
            return;
        }
        [self _ppocrJobsPollJob:jobId baseURL:u token:token scaleX:sx scaleY:sy attempt:0 completion:completion];
    }] resume];
}

// —— v2 异步任务：轮询直到 done / failed / 超时 ——
+ (void)_ppocrJobsPollJob:(NSString *)jobId baseURL:(NSURL *)u token:(NSString *)token
                  scaleX:(CGFloat)sx scaleY:(CGFloat)sy attempt:(NSInteger)attempt
               completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    if (attempt > 40) { // 40*2s = 80s 超时
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, @"百度 PaddleOCR 任务轮询超时（服务器繁忙，请稍后重试）");
        });
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", [u absoluteString], jobId]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"GET"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setTimeoutInterval:30];
    NSURLSession *sess = [NSURLSession sharedSession];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *od, NSURLResponse *r, NSError *oe) {
        if (oe) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 轮询失败：%@", oe.localizedDescription]);
            });
            return;
        }
        id oj = [NSJSONSerialization JSONObjectWithData:od options:0 error:nil];
        if (![oj isKindOfClass:[NSDictionary class]]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 轮询返回异常");
            });
            return;
        }
        NSDictionary *data = oj[@"data"];
        NSString *state = [data isKindOfClass:[NSDictionary class]] ? data[@"state"] : nil;
        if ([state isEqualToString:@"done"]) {
            NSString *jsonl = data[@"resultUrl"][@"jsonUrl"];
            if ([jsonl isKindOfClass:[NSString class]] && jsonl.length) {
                [self _ppocrFetchResult:jsonl scaleX:sx scaleY:sy completion:completion];
            } else {
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, @"百度 PaddleOCR 任务完成但未返回结果地址");
                });
            }
        } else if ([state isEqualToString:@"failed"]) {
            NSString *em = data[@"errorMsg"] ?: @"任务失败";
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 识别失败：%@", em]);
            });
        } else { // pending / running → 继续轮询
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self _ppocrJobsPollJob:jobId baseURL:u token:token scaleX:sx scaleY:sy attempt:attempt+1 completion:completion];
            });
        }
    }] resume];
}

// —— v2 异步任务：取 JSONL 结果并解析文字 ——
+ (void)_ppocrFetchResult:(NSString *)jsonl scaleX:(CGFloat)sx scaleY:(CGFloat)sy
               completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    NSURL *url = [NSURL URLWithString:jsonl];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"GET"];
    [req setTimeoutInterval:40];
    // 注意：jsonl 是带 bce-auth 的 BOS 短链，不要再带 AI Studio token
    NSURLSession *sess = [NSURLSession sharedSession];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *od, NSURLResponse *r, NSError *oe) {
        if (oe) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 结果下载失败：%@", oe.localizedDescription]);
            });
            return;
        }
        NSString *text = [[NSString alloc] initWithData:od encoding:NSUTF8StringEncoding];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!t.length) continue;
            id oj = [NSJSONSerialization JSONObjectWithData:[t dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![oj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *res = oj[@"result"];
            if (![res isKindOfClass:[NSDictionary class]]) continue;
            NSArray *ocrResults = res[@"ocrResults"];
            if (![ocrResults isKindOfClass:[NSArray class]]) continue;
            for (NSDictionary *rr in ocrResults) {
                if (![rr isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *pr = rr[@"prunedResult"];
                if (![pr isKindOfClass:[NSDictionary class]]) continue;
                NSArray *texts = pr[@"rec_texts"];
                if (![texts isKindOfClass:[NSArray class]]) continue;
                // v6.20.3：尽量保留 PaddleOCR 坐标（rec_polys/rec_boxes/boxes），用于阅读顺序排序与脱敏定位
                NSArray *polys = pr[@"rec_polys"];
                if (![polys isKindOfClass:[NSArray class]]) polys = pr[@"rec_boxes"];
                if (![polys isKindOfClass:[NSArray class]]) polys = pr[@"boxes"];
                for (NSInteger ti = 0; ti < texts.count; ti++) {
                    id x = texts[ti];
                    if (![x isKindOfClass:[NSString class]] || ![x length]) continue;
                    CGRect box = CGRectZero;
                    if ((NSUInteger)ti < polys.count) box = [self _superscreenshotRectFromPaddlePoly:polys[ti]];
                    if (box.size.width > 0 && box.size.height > 0) {
                        // 缩图坐标 → 原图坐标（脱敏需原图坐标，排序只关心相对位置）
                        box = CGRectMake(box.origin.x * sx, box.origin.y * sy,
                                         box.size.width * sx, box.size.height * sy);
                    } else {
                        box = CGRectZero; // 无坐标则降级，排序函数会将其置后
                    }
                    [items addObject:@{ @"text": x, @"box": [NSValue valueWithCGRect:box] }];
                }
            }
        }
        if (!items.count) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 未识别到任何文字");
            });
            return;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(items, nil); });
    }] resume];
}

// —— 同步接口兜底（非 /api/v2/ocr/jobs 的其它地址）——
+ (void)_ppocrSyncWithURL:(NSURL *)u token:(NSString *)token jpeg:(NSData *)jpeg
               scaleX:(CGFloat)sx scaleY:(CGFloat)sy
               completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    NSString *b64 = [jpeg base64EncodedStringWithOptions:0];
    BOOL isHub = [[u.host lowercaseString] containsString:@"aistudio-hub"];
    NSDictionary *body = isHub ? @{ @"image": b64 } : @{ @"file": b64, @"fileType": @1 };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setHTTPBody:json];
    [req setTimeoutInterval:30];
    NSURLSession *sess = [NSURLSession sharedSession];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *od, NSURLResponse *or_, NSError *oe) {
        if (oe) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 请求失败：%@", oe.localizedDescription]);
            });
            return;
        }
        id oj = [NSJSONSerialization JSONObjectWithData:od options:0 error:nil];
        if (![oj isKindOfClass:[NSDictionary class]]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 返回非 JSON 数据（API_URL 可能不正确）");
            });
            return;
        }
        NSNumber *ec = oj[@"errorCode"];
        if (ec && ec.integerValue != 0) {
            NSString *em = oj[@"errorMsg"] ?: @"百度 PaddleOCR 错误";
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"百度 PaddleOCR 错误(%@)：%@", ec, em]);
            });
            return;
        }
        NSDictionary *res = oj[@"result"];
        // v6.20.3：同步接口也保留坐标（逐条收 text+poly），避免丢坐标导致排序/脱敏失效
        NSMutableArray<NSDictionary *> *raw = [NSMutableArray array]; // @[ @{@"text":NSString, @"poly":id} ]
        if ([res isKindOfClass:[NSDictionary class]]) {
            NSArray *ocrResults = res[@"ocrResults"];
            if ([ocrResults isKindOfClass:[NSArray class]]) {
                for (NSDictionary *r in ocrResults) {
                    if (![r isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *pr = r[@"prunedResult"];
                    NSArray *texts = nil, *polys = nil;
                    if ([pr isKindOfClass:[NSDictionary class]]) {
                        texts = pr[@"rec_texts"];
                        polys = pr[@"rec_polys"];
                        if (![polys isKindOfClass:[NSArray class]]) polys = pr[@"rec_boxes"];
                        if (![polys isKindOfClass:[NSArray class]]) polys = pr[@"boxes"];
                    }
                    if (![texts isKindOfClass:[NSArray class]]) texts = r[@"rec_texts"];
                    if (![texts isKindOfClass:[NSArray class]]) continue;
                    for (NSInteger ti = 0; ti < texts.count; ti++) {
                        id x = texts[ti];
                        if (![x isKindOfClass:[NSString class]] || ![x length]) continue;
                        id poly = ((NSUInteger)ti < polys.count) ? polys[ti] : nil;
                        [raw addObject:@{ @"text": x, @"poly": (poly ?: [NSNull null]) }];
                    }
                }
            }
            if (!raw.count && [res[@"texts"] isKindOfClass:[NSArray class]]) {
                for (id x in res[@"texts"]) {
                    if ([x isKindOfClass:[NSString class]] && [x length])
                        [raw addObject:@{ @"text": x, @"poly": [NSNull null] }];
                }
            }
        }
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSDictionary *kv in raw) {
            NSString *t = kv[@"text"];
            if (![t isKindOfClass:[NSString class]] || !t.length) continue;
            CGRect box = CGRectZero;
            id poly = kv[@"poly"];
            if (poly && poly != [NSNull null]) box = [self _superscreenshotRectFromPaddlePoly:poly];
            if (box.size.width > 0 && box.size.height > 0) {
                box = CGRectMake(box.origin.x * sx, box.origin.y * sy,
                                 box.size.width * sx, box.size.height * sy);
            } else {
                box = CGRectZero;
            }
            [items addObject:@{ @"text": t, @"box": [NSValue valueWithCGRect:box] }];
        }
        if (!items.count) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"百度 PaddleOCR 未识别到任何文字");
            });
            return;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(items, nil); });
    }] resume];
}

// v6.13：把各种可能的文字数组（字符串数组 / {text:..} 对象数组）拍平成 NSString 列表
+ (NSArray<NSString *> *)_superscreenshotFlattenTexts:(id)texts {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![texts isKindOfClass:[NSArray class]]) return out;
    for (id x in (NSArray *)texts) {
        if ([x isKindOfClass:[NSString class]]) [out addObject:x];
        else if ([x isKindOfClass:[NSDictionary class]]) {
            id t = x[@"text"] ?: x[@"rec_text"];
            if ([t isKindOfClass:[NSString class]]) [out addObject:t];
        }
    }
    return out;
}

// 去掉 ```xxx\n...\n``` 代码块包裹 (智谱有时会包)
+ (NSString *)_stripMarkdownCodeBlocks:(NSString *)s {
    if (![s containsString:@"```"]) return s;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    BOOL inBlock = NO;
    NSArray *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *ln in lines) {
        NSString *t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"```"]) {
            inBlock = !inBlock;
            continue;
        }
        if (inBlock) continue;
        [out appendFormat:@"%@\n", ln];
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (void)ocr:(UIImage *)image completion:(void (^)(NSString *text))completion {
    [self ocrObservations:image completion:^(NSArray<NSDictionary *> *items) {
        NSMutableString *m = [NSMutableString string];
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            if (t.length) [m appendFormat:@"%@\n", t];
        }
        if (completion) completion(m.length ? m : nil);
    }];
}

+ (void)ocr:(UIImage *)image withBoxes:(void (^)(NSString *text, NSArray<NSValue *> *boxes))completion {
    [self ocrObservations:image completion:^(NSArray<NSDictionary *> *items) {
        NSMutableString *m = [NSMutableString string];
        NSMutableArray<NSValue *> *boxes = [NSMutableArray array];
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            if (t.length) [m appendFormat:@"%@\n", t];
            NSValue *b = it[@"box"];
            if (b) [boxes addObject:b];
        }
        if (completion) completion(m.length ? m : nil, boxes);
    }];
}

#pragma mark - 2. 翻译（OCR 取文 → 网络翻译）

+ (void)translate:(UIImage *)image completion:(void (^)(NSString *src, NSString *dst, NSString *err))completion {
    [self ocr:image completion:^(NSString *text) {
        if (!text.length) {
            if (completion) completion(nil, nil, @"OCR 未识别到文字，无法翻译（请确认图片含清晰文字）");
            return;
        }
        [self translateText:text completion:^(NSString *dst, NSString *err) {
            if (completion) completion(text, dst, err);
        }];
    }];
}

// 网络翻译入口。v6.07：若「大模型库」里翻译功能选了模型，则走该模型（chat 补全，提示词翻译）；
// 否则回退旧的百度翻译 API（设置里填了 APP ID/KEY 即用），再不行回退 gtx（国内常被墙）。
+ (void)translateText:(NSString *)text completion:(void (^)(NSString *dst, NSString *err))completion {
    NSDictionary *cfg = [Common superscreenshotTransConfig];
    if (cfg) {
        NSString *bu  = [Common superscreenshotModelField:cfg key:@"baseURL" def:@"https://api.openai.com/v1"];
        NSString *key = [Common superscreenshotModelField:cfg key:@"apiKey"  def:@""];
        NSString *md  = [Common superscreenshotModelField:cfg key:@"model"   def:@"gpt-4o-mini"];
        if (!key.length) {
            if (completion) completion(nil, @"翻译所选模型未填 API Key：请到「设置 → 大模型库」编辑该模型填入 Key。");
            return;
        }
        NSString *to = [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh"];
        if (!to.length) to = @"zh";
        NSString *langName = [self _langName:to];
        NSString *prompt = [NSString stringWithFormat:@"You are a translator. Translate the following text into %@ (%@). Output ONLY the translation, no explanations, no quotes, no markdown.\n\n%@", to, langName, text];
        NSArray *messages = @[ @{ @"role": @"user", @"content": prompt } ];
        [AskAIEngine askMessages:messages baseURL:bu apiKey:key model:md
                      completion:^(NSString *answer, NSString *err) {
            if (err.length) { if (completion) completion(nil, err); return; }
            NSString *a = [answer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            a = [self _stripMarkdownCodeBlocks:a];
            if (!a.length) { if (completion) completion(nil, @"模型返回为空，翻译失败"); return; }
            if (completion) completion(a, nil);
        }];
        return;
    }
    // 回退：旧百度翻译 API
    NSString *appid = [Common stringPref:XZ_KEY_TRANS_APPID default:@""];
    NSString *key   = [Common stringPref:XZ_KEY_TRANS_KEY default:@""];
    if (appid.length && key.length) {
        [self baiduTranslate:text appid:appid key:key completion:completion];
    } else {
        // v5.8：未配置百度密钥时，明确告知并仍尝试 gtx，失败则给出诊断
        [self gtxTranslate:text completion:^(NSString *dst, NSString *err) {
            if (dst.length) { if (completion) completion(dst, nil); }
            else { if (completion) completion(nil, @"未配置翻译模型（也未配置百度翻译密钥），已回退 Google 接口但失败：国内通常不通。请到「设置 → 大模型库」给翻译选一个模型。"); }
        }];
    }
}

+ (NSString *)_langName:(NSString *)code {
    NSDictionary *m = @{@"zh":@"Chinese", @"en":@"English", @"ja":@"Japanese", @"ko":@"Korean",
                        @"fr":@"French", @"de":@"German", @"ru":@"Russian", @"es":@"Spanish"};
    return m[code] ?: code;
}

+ (NSString *)md5:(NSString *)str {
    if (!str) return @"";
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return @"";
    unsigned char dig[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, dig);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", dig[i]];
    return out;
}


// 等比缩到长边不超过 maxDim，避免大模型OCR因图片过大/超长报错
+ (UIImage *)bdShrink:(UIImage *)src maxDim:(CGFloat)maxDim {
    CGFloat w = src.size.width, h = src.size.height;
    if (w < 1 || h < 1) return src;
    CGFloat m = MAX(w, h);
    if (m <= maxDim) return src;
    CGFloat s = maxDim / m;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w*s, h*s), NO, 1.0);
    [src drawInRect:CGRectMake(0, 0, w*s, h*s)];
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o ?: src;
}

// 百度翻译开放平台「通用文本翻译」（需 APP ID + 密钥，见设置面板说明）。
// 签名 sign = md5(appid + q + salt + key)；from=auto。
+ (void)baiduTranslate:(NSString *)text appid:(NSString *)appid key:(NSString *)key completion:(void (^)(NSString *dst, NSString *err))completion {
    NSString *to = [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh"];
    if (!to.length) to = @"zh";
    NSString *salt = [NSString stringWithFormat:@"%ld", (long)([NSDate date].timeIntervalSince1970 * 1000.0)];
    NSString *sign = [self md5:[NSString stringWithFormat:@"%@%@%@%@", appid, text, salt, key]];
    NSString *(^enc)(NSString *) = ^NSString *(NSString *s) {
        return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
    };
    NSString *query = [NSString stringWithFormat:
        @"q=%@&from=auto&to=%@&appid=%@&salt=%@&sign=%@",
        enc(text), enc(to), enc(appid), enc(salt), enc(sign)];
    NSURL *url = [NSURL URLWithString:[@"https://fanyi-api.baidu.com/api/trans/vip/translate?" stringByAppendingString:query]];
    if (!url) { if (completion) completion(nil, @"翻译请求地址构造失败"); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *out = nil;
        NSString *outErr = nil;
        @try {
            if (!err && data) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    id ec = json[@"error_code"];
                    if (ec) {
                        NSString *ecStr = [NSString stringWithFormat:@"%@", ec];
                        NSString *em = json[@"error_msg"] ? [NSString stringWithFormat:@"%@", json[@"error_msg"]] : @"";
                        outErr = [NSString stringWithFormat:@"百度翻译错误 %@：%@%@", ecStr, em, [self baiduErrorHint:ecStr]];
                    } else {
                        id tr = json[@"trans_result"];
                        if ([tr isKindOfClass:[NSArray class]]) {
                            NSMutableString *m = [NSMutableString string];
                            for (id item in tr) {
                                if ([item isKindOfClass:[NSDictionary class]]) {
                                    id dst = item[@"dst"];
                                    if ([dst isKindOfClass:[NSString class]]) [m appendString:(NSString *)dst];
                                }
                            }
                            out = m.length ? m : nil;
                        }
                        if (!out) outErr = @"百度翻译返回为空（trans_result 缺失）";
                    }
                } else {
                    outErr = @"百度翻译返回非 JSON";
                }
            } else {
                outErr = [NSString stringWithFormat:@"翻译网络请求失败：%@", err.localizedDescription];
            }
        } @catch (NSException *e) { outErr = [NSString stringWithFormat:@"翻译解析异常：%@", e.reason]; }
        NSString *finalErr = outErr;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out, finalErr); });
    }] resume];
}

// 百度翻译错误码 → 通俗提示（重点提示密钥/配置问题）
+ (NSString *)baiduErrorHint:(NSString *)code {
    NSDictionary *h = @{
        @"52001": @"（请求超时，重试即可）",
        @"52002": @"（系统错误，稍后重试）",
        @"54000": @"（缺少必填参数，检查译文语言设置）",
        @"54001": @"（签名错误：请核对 APP ID 与密钥是否填反/填错）",
        @"54003": @"（访问频率受限，请稍后再试）",
        @"54004": @"（账户余额不足，请到百度翻译控制台充值）",
        @"54005": @"（长 query 频率受限）",
        @"58000": @"（服务未开通，请到百度翻译开放平台开通服务）",
        @"58001": @"（译文语言方向不支持）",
        @"58002": @"（服务已关闭）",
    };
    NSString *t = h[code];
    return t ? t : @"";
}

// 免费 gtx 兜底（国内常不通，仅当未配置百度密钥时启用）
+ (void)gtxTranslate:(NSString *)text completion:(void (^)(NSString *dst, NSString *err))completion {
    NSString *tl = [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh-CN"];
    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *us = [NSString stringWithFormat:
                    @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%@&dt=t&q=%@",
                    tl, q ?: @""];
    NSURL *url = [NSURL URLWithString:us];
    if (!url) { if (completion) completion(nil, @"翻译请求地址构造失败"); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *out = nil;
        NSString *outErr = nil;
        @try {
            if (!err && data) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSArray class]] && [json count] > 0) {
                    id segs = json[0];
                    if ([segs isKindOfClass:[NSArray class]]) {
                        NSMutableString *m = [NSMutableString string];
                        for (id seg in segs) {
                            if ([seg isKindOfClass:[NSArray class]] && [seg count] > 0) {
                                id s0 = seg[0];
                                if ([s0 isKindOfClass:[NSString class]]) [m appendString:(NSString *)s0];
                            }
                        }
                        out = m.length ? m : nil;
                    }
                }
                if (!out) outErr = @"Google 翻译接口未返回译文";
            } else {
                outErr = [NSString stringWithFormat:@"Google 翻译请求失败：%@", err.localizedDescription];
            }
        } @catch (NSException *e) { outErr = [NSString stringWithFormat:@"翻译解析异常：%@", e.reason]; }
        NSString *finalErr = outErr;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out, finalErr); });
    }] resume];
}

#pragma mark - 3. 画图（自定义 CoreGraphics 画布，避免 PencilKit 在 SpringBoard 崩溃）

+ (void)draw:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    if (!image) { if (completion) completion(nil); return; }
    [XZDrawEditor edit:image completion:completion];
}

#pragma mark - 4. 识码（Vision Barcode）

+ (void)codeScan:(UIImage *)image completion:(void (^)(NSString *code))completion {
    if (!image.CGImage) { if (completion) completion(nil); return; }
    CGImageRef cg = image.CGImage;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *txt = [NSMutableString string];

        // ① 先用 CoreImage CIDetector 扫二维码（最常见、最稳，一次到位）
        @try {
            CIImage *ci = [CIImage imageWithCGImage:cg];
            CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                                       context:nil
                                                       options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
            if (detector && ci) {
                NSArray *features = [detector featuresInImage:ci];
                for (CIFeature *f in features) {
                    NSString *msg = nil;
                    @try {
                        id v = [f valueForKey:@"messageString"];
                        if ([v isKindOfClass:[NSString class]]) msg = (NSString *)v;
                    } @catch (NSException *e) { msg = nil; }
                    if (msg.length) [txt appendFormat:@"%@\n", msg];
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[SuperScreenshot] QR CIDetector exception: %@", e);
        }

        // ② 没扫到二维码 → 用 Vision 扫其他条码（EAN / Code128 / PDF417 等）
        if (txt.length == 0) {
            @try {
                Class reqCls = NSClassFromString(@"VNDetectBarcodesRequest");
                Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
                if (reqCls && handlerCls) {
                    id req = [[reqCls alloc] init];
                    // v5.7：Vision 默认 symbologies 可能为空 → 显式指定常用条码，否则扫不到
                    Class symCls = NSClassFromString(@"VNSymbology");
                    if (symCls) {
                        NSMutableArray *syms = [NSMutableArray array];
                        for (NSString *nm in @[@"EAN13", @"EAN8", @"Code128", @"Code39",
                                              @"Code93", @"PDF417", @"Aztec", @"DataMatrix", @"UPCE",
                                              @"QR", @"Code39FullASCII", @"ITF14", @"Interleaved2of5"]) {
                            id s = [symCls valueForKey:nm];
                            if (s) [syms addObject:s];
                        }
                        if (syms.count) { @try { [req setValue:syms forKey:@"symbologies"]; } @catch (NSException *e) {} }
                    }
                    id handler = [[handlerCls alloc] init];
                    SEL hSel = NSSelectorFromString(@"initWithCGImage:options:");
                    if ([handler respondsToSelector:hSel]) {
                        handler = ((id (*)(id, SEL, CGImageRef, NSDictionary *))objc_msgSend)(handler, hSel, cg, @{});
                        NSError *err = nil;
                        SEL pSel = NSSelectorFromString(@"performRequests:error:");
                        ((BOOL (*)(id, SEL, NSArray *, NSError **))objc_msgSend)(
                            handler, pSel, [NSArray arrayWithObject:req], &err);

                        NSArray *results = nil;
                        @try { results = [req valueForKey:@"results"]; } @catch (NSException *e) { results = nil; }
                        for (id obs in results) {
                            NSString *s = nil;
                            @try {
                                id v = [obs valueForKey:@"payloadStringValue"];
                                if ([v isKindOfClass:[NSString class]]) s = (NSString *)v;
                            } @catch (NSException *e) { s = nil; }
                            if (s.length) [txt appendFormat:@"%@\n", s];
                        }
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"[SuperScreenshot] barcode exception: %@", e);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(txt.length ? txt : nil);
        });
    });
}

#pragma mark - 5. 打码（马赛克）

+ (void)mosaic:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    if (!image) { if (completion) completion(nil); return; }
    [XZMosaicEditor edit:image completion:completion];
}

// 像素化：先缩到 1/ratio 再放大回去（最近邻 → 马赛克）
+ (UIImage *)pixelatedImage:(UIImage *)src ratio:(CGFloat)ratio {
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    CGFloat pxW = (CGFloat)CGImageGetWidth(cg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cg);
    if (pxW < 4 || pxH < 4) return nil;

    CGFloat smallW = MAX(2, pxW / ratio);
    CGFloat smallH = MAX(2, pxH / ratio);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef smallCtx = CGBitmapContextCreate(NULL, (size_t)smallW, (size_t)smallH, 8, 0, cs,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!smallCtx) return nil;
    CGContextSetInterpolationQuality(smallCtx, kCGInterpolationNone);
    CGContextDrawImage(smallCtx, CGRectMake(0, 0, smallW, smallH), cg);
    CGImageRef smallCG = CGBitmapContextCreateImage(smallCtx);
    CGContextRelease(smallCtx);
    if (!smallCG) return nil;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(pxW, pxH), NO, 1.0);
    CGContextRef bigCtx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(bigCtx, kCGInterpolationNone);
    if (bigCtx) CGContextDrawImage(bigCtx, CGRectMake(0, 0, pxW, pxH), smallCG);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(smallCG);
    return out;
}

// 模糊（不引 CoreImage）：先平滑降采样到 1/ratio，再平滑升采样回原尺寸 → 近似高斯模糊观感。
// v5.8：打码新增「模糊」档位用。
+ (UIImage *)blurredImage:(UIImage *)src ratio:(CGFloat)ratio {
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    CGFloat pxW = (CGFloat)CGImageGetWidth(cg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cg);
    if (pxW < 4 || pxH < 4) return nil;

    CGFloat smallW = MAX(2, round(pxW / ratio));
    CGFloat smallH = MAX(2, round(pxH / ratio));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef smallCtx = CGBitmapContextCreate(NULL, (size_t)smallW, (size_t)smallH, 8, 0, cs,
                                                  kCGImageAlphaPremultipliedLast | kCGImageByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!smallCtx) return nil;
    CGContextSetInterpolationQuality(smallCtx, kCGInterpolationLow);
    CGContextDrawImage(smallCtx, CGRectMake(0, 0, smallW, smallH), cg);
    CGImageRef smallCG = CGBitmapContextCreateImage(smallCtx);
    CGContextRelease(smallCtx);
    if (!smallCG) return nil;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(pxW, pxH), NO, 1.0);
    CGContextRef bigCtx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(bigCtx, kCGInterpolationDefault);  // 平滑升采样 → 模糊
    if (bigCtx) CGContextDrawImage(bigCtx, CGRectMake(0, 0, pxW, pxH), smallCG);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(smallCG);
    return out;
}

// 真正的平滑高斯模糊（CoreImage CIGaussianBlur）——和「方块像素」马赛克明显区分，
// v5.10「模糊」档用。radius 单位为像素（相对图片自身尺寸，各处观感一致）。
+ (UIImage *)gaussianBlurImage:(UIImage *)src radius:(CGFloat)radius {
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    CIImage *input = [CIImage imageWithCGImage:cg];
    if (!input) return nil;
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!blur) return nil;
    [blur setValue:input forKey:kCIInputImageKey];
    [blur setValue:@(MAX(1.0, radius)) forKey:kCIInputRadiusKey];
    CIImage *output = blur.outputImage;
    if (!output) return nil;
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef outCG = [ctx createCGImage:output fromRect:input.extent];
    if (!outCG) return nil;
    UIImage *out = [UIImage imageWithCGImage:outCG
                                       scale:(src.scale > 0 ? src.scale : 1.0)
                                 orientation:src.imageOrientation];
    CGImageRelease(outCG);
    return out;
}
+ (UIImage *)applyMask:(CGImageRef)maskCG
          toPixelated:(UIImage *)pixelated
              onImage:(UIImage *)orig {
    CGImageRef px = pixelated.CGImage;
    if (!px || !maskCG) return nil;
    CGImageRef masked = CGImageCreateWithMask(px, maskCG);
    if (!masked) return nil;

    CGSize size = orig.size;
    UIGraphicsBeginImageContextWithOptions(size, NO, orig.scale > 0 ? orig.scale : 1.0);
    [orig drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *layer = [UIImage imageWithCGImage:masked
                                         scale:(orig.scale > 0 ? orig.scale : 1.0)
                                   orientation:UIImageOrientationUp];
    [layer drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(masked);
    return out;
}

// 用一组「像素坐标矩形 + 一组像素坐标路径」生成 DeviceGray 掩码
+ (CGImageRef)createMaskWithSize:(CGSize)pxSize
                          rects:(NSArray<NSValue *> *)rects
                          paths:(NSArray<UIBezierPath *> *)paths
                     pathWidths:(NSArray<NSNumber *> *)widths {
    size_t W = (size_t)MAX(2, pxSize.width);
    size_t H = (size_t)MAX(2, pxSize.height);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    if (!cs) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    UIGraphicsPushContext(ctx);
    // 转成 UIKit 坐标系（左上原点），这样下面的 UIKit 绘制才不会上下颠倒
    CGContextTranslateCTM(ctx, 0, (CGFloat)H);
    CGContextScaleCTM(ctx, 1, -1);

    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, (CGFloat)W, (CGFloat)H));

    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    for (NSValue *v in rects) {
        CGRect r = [v CGRectValue];
        if (r.size.width > 0 && r.size.height > 0) UIRectFill(r);
    }
    for (NSUInteger i = 0; i < paths.count; i++) {
        UIBezierPath *p = paths[i];
        CGFloat w = (i < widths.count) ? [widths[i] doubleValue] : 20.0;
        p.lineWidth = MAX(1.0, w);
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [p stroke];
    }
    UIGraphicsPopContext();

    CGImageRef mask = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return mask;
}

// 智能脱敏：OCR 出文字坐标，正则命中就返回对应区域（像素坐标）
+ (void)detectSensitiveRects:(UIImage *)image completion:(void (^)(NSArray<NSValue *> *rects))completion {
    [self ocrObservations:image completion:^(NSArray<NSDictionary *> *items) {
        NSMutableArray<NSValue *> *out = [NSMutableArray array];
        NSArray *patterns = @[
            @"1[3-9]\\d{9}",                                        // 手机号
            @"\\d{17}[0-9Xx]",                                      // 身份证 18 位
            @"\\d{15}",                                             // 身份证 15 位
            @"\\d{16,19}",                                          // 银行卡
            @"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",     // 邮箱
        ];
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            CGRect box = XZRectFromValue(it[@"box"]);
            if (!t.length || box.size.width <= 0) continue;
            for (NSString *pat in patterns) {
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat
                                                                                   options:0 error:nil];
                if (!re) continue;
                NSRange r = [re rangeOfFirstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
                if (r.location != NSNotFound) {
                    // 命中就整行打码，并向外扩一点避免露出边缘笔画
                    CGRect padded = CGRectInset(box, -box.size.height * 0.15, -box.size.height * 0.15);
                    [out addObject:[NSValue valueWithCGRect:padded]];
                    break;
                }
            }
        }
        if (completion) completion(out);
    }];
}

#pragma mark - 6. 复制

+ (void)copy:(UIImage *)image {
    if (!image) return;
    [UIPasteboard generalPasteboard].image = image;
    [Common toast:@"已复制图片到剪贴板"];
}

#pragma mark - 7. 贴图（悬浮窗口）

static UIWindow *_floatWin = nil;

// 贴图：浮窗尺寸默认匹配所选拖选框（rect，屏幕坐标）；rect 为空则用 120 默认
+ (void)floating:(UIImage *)image {
    [self floating:image withScreenRect:CGRectZero];
}

+ (void)floating:(UIImage *)image withScreenRect:(CGRect)rect {
    if (!image) return;
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }

    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat fw, fh;
    BOOL useRect = (rect.size.width >= 20 && rect.size.height >= 20);
    if (useRect) {
        // 按选框尺寸（并限制在屏幕内），与所选区域等大
        fw = MIN(rect.size.width,  scr.size.width  - 20);
        fh = MIN(rect.size.height, scr.size.height - 120);
    } else {
        fw = 120.0;
        fh = 120.0 * image.size.height / MAX(1, image.size.width);
        if (fh > 200) { fh = 200; fw = 200 * image.size.width / MAX(1, image.size.height); }
    }

    CGFloat ox, oy;
    if (useRect) {
        // 定位到选框原位（夹在屏幕内），与所选区域重合
        ox = MIN(MAX(rect.origin.x, 8.0),                       scr.size.width  - fw - 8);
        oy = MIN(MAX(rect.origin.y, [Common screenSafeInsets].top + 4), scr.size.height - fh - 8);
    } else {
        ox = scr.size.width - fw - 20;
        oy = scr.size.height / 2 - fh / 2;
    }

    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(ox, oy, fw, fh)];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.backgroundColor = [UIColor clearColor];
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:win.bounds];
    // v5.11：贴图标识图按「显示尺寸」预缩放（不再是全分辨率原图），拖动无卡顿
    iv.image = [self downscaledToDisplay:image forSize:win.bounds.size scale:[UIScreen mainScreen].scale];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12;
    iv.clipsToBounds = YES;
    iv.layer.borderColor = [UIColor whiteColor].CGColor;
    iv.layer.borderWidth = 2;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; // v5.14：随窗口缩放
    [win addSubview:iv];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(fw - 28, 0, 28, 28);
    [close setImage:[Common systemIcon:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor redColor];
    [close addTarget:self action:@selector(closeFloat) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:close];

    // v5.10：贴图拖动 —— 手势挂到图片 iv 上（不是 win），图片任意处都可拖动；
    //        左上角再加一个「大头针」，拖大头针也能拖动整张贴图（更直观可靠）。
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloat:)];
    [iv addGestureRecognizer:pan];

    // v5.14：贴图捏合缩放 —— 两指捏合放大/缩小整张贴图，中心不动。
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchFloat:)];
    [win addGestureRecognizer:pinch];

    UIView *pin = [[UIView alloc] initWithFrame:CGRectMake(4, 4, 30, 30)];
    pin.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    pin.layer.cornerRadius = 15;
    pin.layer.borderWidth = 1;
    pin.layer.borderColor = [UIColor whiteColor].CGColor;
    UIImageView *pinIc = [[UIImageView alloc] initWithFrame:CGRectInset(pin.bounds, 6, 6)];
    pinIc.image = [Common systemIcon:@"pin.fill"];
    pinIc.contentMode = UIViewContentModeScaleAspectFit;
    pinIc.tintColor = [UIColor systemYellowColor];
    pinIc.userInteractionEnabled = NO;
    [pin addSubview:pinIc];
    UIPanGestureRecognizer *pinPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloat:)];
    [pin addGestureRecognizer:pinPan];
    [win addSubview:pin];
    [win bringSubviewToFront:pin];
    [win bringSubviewToFront:close];

    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeFloatByGesture:)];
    dt.numberOfTapsRequired = 2;
    [win addGestureRecognizer:dt];

    _floatWin = win;
    win.hidden = NO;
    [Common toast:@"已贴图：拖动图片或大头针移动，双指捏合缩放，双击或点 X 关闭"];
}

+ (void)closeFloat {
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }
}
+ (void)closeFloatByGesture:(UITapGestureRecognizer *)g {
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }
}

// v5.11：贴图显示图预缩放（按显示尺寸×屏scale，最多不超原图），大幅降低拖动逐帧合成开销
+ (UIImage *)downscaledToDisplay:(UIImage *)img forSize:(CGSize)ptSize scale:(CGFloat)scl {
    if (!img) return nil;
    CGFloat maxPx = MAX(ptSize.width * scl, ptSize.height * scl);
    CGFloat sx = MAX(1.0, (CGFloat)img.size.width);
    CGFloat scale = MIN(1.0, maxPx / MAX(1.0, MAX(sx, (CGFloat)img.size.height)));
    if (scale >= 1.0) return img;
    CGSize newPx = CGSizeMake(floor(sx * scale), floor((CGFloat)img.size.height * scale));
    UIGraphicsBeginImageContextWithOptions(newPx, NO, 1.0);
    [img drawInRect:CGRectMake(0, 0, newPx.width, newPx.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

// v5.15 / v6.05：贴图拖动。改用窗口 center 移动，图片 iv 始终相对窗口原位不变——
//        不重绘、不重排，根除画面抖动/闪烁。坐标用 pan.view.superview（即浮窗自身坐标系，
//        等于屏幕点坐标），避免 locationInView:nil 在 iOS13+ 场景模式下返回坐标错位导致的跳动/闪烁。
+ (void)panFloat:(UIPanGestureRecognizer *)pan {
    if (!_floatWin) return;
    UIView *coordView = pan.view.superview ?: _floatWin;
    static CGPoint _floatLast;
    if (pan.state == UIGestureRecognizerStateBegan) {
        _floatLast = [pan locationInView:coordView];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint loc = [pan locationInView:coordView];
        CGFloat dx = loc.x - _floatLast.x;
        CGFloat dy = loc.y - _floatLast.y;
        _floatLast = loc;
        if (dx == 0 && dy == 0) return;
        CGRect scr = [UIScreen mainScreen].bounds;
        CGPoint c = _floatWin.center;
        CGFloat halfW = _floatWin.frame.size.width / 2.0;
        CGFloat halfH = _floatWin.frame.size.height / 2.0;
        c.x = MAX(halfW, MIN(c.x + dx, scr.size.width  - halfW));
        c.y = MAX(halfH, MIN(c.y + dy, scr.size.height - halfH));
        _floatWin.center = c;
    }
}

// v5.15：贴图捏合缩放。直接改窗口尺寸（等比、中心不动、夹在屏幕内），图片 iv 由
//        autoresizing 自动撑开、contentMode 拉伸——不逐帧重绘，手感顺滑且无抖动。
+ (void)pinchFloat:(UIPinchGestureRecognizer *)g {
    if (!_floatWin) return;
    static CGFloat _pinchLastScale = 1.0;
    if (g.state == UIGestureRecognizerStateBegan) {
        _pinchLastScale = 1.0;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat d = g.scale / MAX(0.01, _pinchLastScale);
        _pinchLastScale = g.scale;
        if (d <= 0 || !isfinite(d)) return;

        CGRect scr = [UIScreen mainScreen].bounds;
        CGRect f = _floatWin.frame;
        CGFloat nw = MAX(36.0, MIN(f.size.width  * d, scr.size.width  * 0.92));
        CGFloat nh = MAX(36.0, MIN(f.size.height * d, scr.size.height * 0.88));
        if (nw == f.size.width && nh == f.size.height) return;

        // 中心不动
        CGFloat cx = f.origin.x + f.size.width / 2.0;
        CGFloat cy = f.origin.y + f.size.height / 2.0;
        f = CGRectMake(cx - nw / 2.0, cy - nh / 2.0, nw, nh);
        f.origin.x = MAX(0, MIN(f.origin.x, scr.size.width  - f.size.width));
        f.origin.y = MAX(0, MIN(f.origin.y, scr.size.height - f.size.height));
        _floatWin.frame = f;
    }
}

#pragma mark - 8. 保存

+ (void)save:(UIImage *)image completion:(void (^)(BOOL ok))completion {
    if (!image) { if (completion) completion(NO); return; }
    // v6.20.5：所有保存统一走自定义相册「超级截图」，不再只进相机胶卷
    [ImageUtils saveToCustomAlbum:image completion:^(BOOL ok, NSError *e) {
        if (e) NSLog(@"[SuperScreenshot] save to album failed: %@", e);
        if (completion) completion(ok);
    }];
}

#pragma mark - 8b. 打开豆包（带图）

+ (BOOL)openDoubaoWithImage:(UIImage *)image {
    if (!image) return NO;
    // v6.20.8：把截图写入系统剪贴板，豆包启动后通常能识别并在输入框提示插入；
    // 同时用 doubao:// 直接拉起豆包 App（与 iOS 快捷指令同款 Scheme，豆包 App ≥ v3.0.0）。
    [[UIPasteboard generalPasteboard] setImage:image];
    NSURL *url = [NSURL URLWithString:@"doubao://"];
    if (!url) return NO;
    // ⚠️ tweak 宿主 App 不一定在 LSApplicationQueriesSchemes 声明 doubao，
    //    故不能用 canOpenURL 判断，直接 openURL 并以返回值确认是否拉起成功。
    //    用同步返回 BOOL 的 openURL:（新版 openURL:options:completionHandler: 返回 void，会编译报错）。
    BOOL opened = [[UIApplication sharedApplication] openURL:url];
    return opened;
}

#pragma mark - 8c. 打开任意 App（带图）

+ (BOOL)openAppScheme:(NSString *)scheme withImage:(UIImage *)image {
    if (!scheme || scheme.length == 0) return NO;
    // 把图写入系统剪贴板，App 启动后长按输入框可粘贴（与打开豆包同款补偿：多数 App 的 scheme 不接受图片参数）
    if (image) [[UIPasteboard generalPasteboard] setImage:image];
    NSURL *url = [NSURL URLWithString:scheme];
    if (!url) return NO;
    // 同步返回 BOOL 的 openURL:（新版 openURL:options:completionHandler: 返回 void，会编译报错）
    return [[UIApplication sharedApplication] openURL:url];
}

// v6.21：微信输入法「隔空传送」直达。纯 openURL 拉起 微信输入法(com.tencent.wetype,即「微信键盘」)，
//        无任何常驻后台 / 定时器，调用即用、用完静默，满足低功耗要求。
//        scheme 默认 wetype://，可经 XZ_KEY_WXTRANS_SCHEME override（真机若未落在隔空传送页，
//        用 Filza 打开 微信输入法.app/Info.plist 查 CFBundleURLSchemes 的确切值写回这里）。
+ (BOOL)openWeChatTransfer {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    NSString *scheme = [d stringForKey:XZ_KEY_WXTRANS_SCHEME];
    if (!scheme || scheme.length == 0) scheme = @"wetype://";
    if ([scheme rangeOfString:@"://"].location == NSNotFound) scheme = [scheme stringByAppendingString:@"://"];
    NSURL *url = [NSURL URLWithString:scheme];
    if (!url) return NO;
    // 同 doubao：宿主(SpringBoard)未在 LSApplicationQueriesSchemes 声明 wetype，canOpenURL 会误判，
    //    故直接 openURL 并以返回值判断是否拉起成功。
    return [[UIApplication sharedApplication] openURL:url];
}

+ (NSArray<NSDictionary *> *)superscreenshotLaunchApps {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    NSArray *raw = [d arrayForKey:XZ_KEY_LAUNCH_APPS];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id o in raw) if ([o isKindOfClass:[NSDictionary class]]) [out addObject:o];
    }
    return out;
}

#pragma mark - 9. 分享

static UIWindow *_shareWin = nil;

// v6.20.20【截图分享不全 / 电脑打开出错 根因修复】：
//   旧实现直接把「内存 UIImage」喂给 UIActivityViewController。插件宿主是 SpringBoard，
//   iOS 对外分享是【异步】编码的（PNG/JPEG），用户点选目标 App 的瞬间就会起跳转，
//   跳转前后 activity item provider 常被取消 → 目标 App / 导出到电脑收到被截断、
//   只写了一半的损坏图片 —— 正是「照片不全 / 电脑上打开是坏的」。
//   修法：先把 UIImage 完整落盘为 PNG（原子写入，保证一整个完整文件），
//   再分享这份稳定文件的 URL，接收方拿到的就是全量原图。
+ (NSURL *)sharedTemporaryPNGForImage:(UIImage *)image {
    if (!image || !image.CGImage) return nil;
    NSData *png = UIImagePNGRepresentation(image);
    if (!png || !png.length) return nil;
    NSString *name = [NSString stringWithFormat:@"xzs_%.0f.png",
                      [[NSDate date] timeIntervalSince1970] * 1000.0];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    return ([png writeToFile:path atomically:YES]) ? [NSURL fileURLWithPath:path] : nil;
}

// v6.20.20【面板挡目标 App 根因修复】：
//   分享 / 打开 App 时把当前截图相关面板（窗口B 编辑工具栏、窗口A 局部工具栏、
//   截图历史查看器）一并收起，否则跳转进目标 App 后工具栏还浮在最上面，
//   目标界面点不到（“面板还在，不好选择”）。
+ (void)dismissScreenshotPanels {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [EditToolbarWindow dismiss]; } @catch (NSException *e) {}
        @try {
            MaskCropWindow *mc = [MaskCropWindow sharedInstance];
            if (mc && [MaskCropWindow isShowing]) [mc dismiss];
        } @catch (NSException *e) {}
        @try { [HistoryWindow dismiss]; } @catch (NSException *e) {}
    });
}

// 统一分享弹层：item 可为 UIImage 或文件 NSURL。UIImage 会先完整落盘 PNG 再分享。
+ (void)presentShareForItem:(id)item fromWindow:(UIWindow *)win {
    if (!item) return;
    [self dismissScreenshotPanels];   // 分享前先收起面板，别再挡住要打开的目标 App

    if (![item isKindOfClass:[UIImage class]]) {
        [self _showShareSheetWithItems:@[item] fromWindow:win cleanupURL:nil];
        return;
    }
    // 大图编码较费时，放后台线程写文件，避免 SpringBoard 卡死（watchdog）
    UIImage *img = item;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *tempURL = [self sharedTemporaryPNGForImage:img];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _showShareSheetWithItems:@[(tempURL ?: (id)img)] fromWindow:win cleanupURL:tempURL];
        });
    });
}

+ (void)_showShareSheetWithItems:(NSArray *)items fromWindow:(UIWindow *)win cleanupURL:(NSURL *)cleanupURL {
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                     applicationActivities:nil];
    if (_shareWin) { _shareWin.hidden = YES; _shareWin = nil; }
    UIWindow *sheetWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    sheetWin.windowLevel = UIWindowLevelAlert + 400;   // 高于编辑/截图工具栏(Alert-10≈1990)
    sheetWin.backgroundColor = [UIColor clearColor];
    if (@available(iOS 13.0, *)) sheetWin.windowScene = [Common activeWindowScene];
    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = [UIColor clearColor];
    sheetWin.rootViewController = host;
    sheetWin.hidden = NO;
    _shareWin = sheetWin;

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        // 分享后源窗口已收起，统一锚到弹层自身的 host 视图中心
        avc.popoverPresentationController.sourceView = host.view;
        avc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds),
                                                                  CGRectGetMidY(host.view.bounds), 0, 0);
    }
    avc.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *err) {
        _shareWin.hidden = YES;
        _shareWin.rootViewController = nil;
        _shareWin = nil;
        if (cleanupURL) [[NSFileManager defaultManager] removeItemAtURL:cleanupURL error:nil];   // 清理临时图
    };
    [host presentViewController:avc animated:YES completion:nil];
}

+ (void)share:(UIImage *)image fromWindow:(UIWindow *)win {
    if (!image) return;
    [self presentShareForItem:image fromWindow:win];
}

#pragma mark - 9b. 加手机壳

+ (UIImage *)phoneCase:(UIImage *)image {
    if (!image) return nil;
    NSString *caseId = [Common stringPref:XZ_KEY_PHONE_CASE default:@"none"];
    return [ImageUtils applyPhoneFrame:image caseId:caseId];
}

#pragma mark - 10a. 导出 PDF

+ (NSString *)exportPDF:(UIImage *)image {
    if (!image) return nil;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"supershot.pdf"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    CGRect page = CGRectMake(0, 0, image.size.width, image.size.height);
    UIGraphicsBeginPDFContextToFile(path, page, nil);
    UIGraphicsBeginPDFPageWithInfo(page, nil);
    [image drawInRect:page];
    UIGraphicsEndPDFContext();
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

#pragma mark - 10b. 压缩（CGImageDestination 改 JPEG 质量）

+ (UIImage *)compress:(UIImage *)image quality:(CGFloat)quality {
    if (!image.CGImage) return nil;
    CGFloat q = MAX(0.05, MIN(1.0, quality));

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    if (!dest) {
        NSData *d = UIImageJPEGRepresentation(image, q);
        return d ? [UIImage imageWithData:d] : nil;
    }
    NSDictionary *props = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(q)};
    CGImageDestinationAddImage(dest, image.CGImage, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return (ok && data.length) ? [UIImage imageWithData:data] : nil;
}

#pragma mark - 10c. 去状态栏

+ (UIImage *)stripStatusBar:(UIImage *)image {
    if (!image.CGImage) return nil;

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) return nil;
    // 图片自身坐标系里，1pt 对应多少单位
    CGFloat ratio = image.size.width / screenW;
    CGFloat statusH = [Common screenSafeInsets].top;
    if (statusH <= 0) statusH = 20.0;

    CGFloat cut = statusH * ratio;
    if (cut >= image.size.height * 0.5) return nil;   // 保护：别把整张图切没了

    CGRect r = CGRectMake(0, cut, image.size.width, image.size.height - cut);
    r = CGRectIntersection(r, CGRectMake(0, 0, image.size.width, image.size.height));
    if (CGRectIsNull(r) || r.size.height < 2) return nil;

    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, r);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return out;
}

#pragma mark - 10d. 取色器

+ (void)colorPicker:(UIImage *)image fromWindow:(UIWindow *)win {
    if (!image) return;
    [XZColorPicker show:image];
}

@end

#pragma mark - 画图编辑器（自定义 CoreGraphics，避免 PencilKit 在 SpringBoard 崩溃）

// 单条笔画
@interface XZDrawStroke : NSObject
@property (nonatomic, strong) UIBezierPath *path;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) BOOL eraser;   // 橡皮：用 clear 混合擦除，露出原图
@end
@implementation XZDrawStroke
@end

// 画布：按 stroke 列表实时绘制（橡皮用 kCGBlendModeClear）
@interface XZDrawCanvas : UIView
@property (nonatomic, strong) NSMutableArray<XZDrawStroke *> *strokes;
@property (nonatomic, strong) UIColor *inkColor;
@property (nonatomic, assign) CGFloat inkWidth;
@property (nonatomic, assign) CGFloat inkAlpha;   // v5.10：马克笔透明度（0~1，半透明~不透明）
@property (nonatomic, assign) BOOL eraser;
@property (nonatomic, assign) BOOL marker;
- (void)undoLast;
@end
@implementation XZDrawCanvas
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _strokes = [NSMutableArray array];
        _inkColor = [UIColor redColor];
        _inkWidth = 4.0;
        _inkAlpha = 0.45;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = NO;
    }
    return self;
}
- (void)undoLast { if (_strokes.count) { [_strokes removeLastObject]; [self setNeedsDisplay]; } }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    XZDrawStroke *s = [[XZDrawStroke alloc] init];
    s.path = [UIBezierPath bezierPath];
    CGFloat w = _eraser ? (_inkWidth * 3.0) : (_marker ? (_inkWidth * 4.0) : _inkWidth);
    s.width = w;
    s.path.lineWidth = w;
    s.path.lineCapStyle = kCGLineCapRound;
    s.path.lineJoinStyle = kCGLineJoinRound;
    [s.path moveToPoint:p];
    if (_eraser) { s.color = [UIColor clearColor]; s.eraser = YES; }
    else { s.color = _marker ? [_inkColor colorWithAlphaComponent:MAX(0.15, MIN(1.0, _inkAlpha))] : _inkColor; s.eraser = NO; }
    [_strokes addObject:s];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    [[[_strokes lastObject] path] addLineToPoint:[t locationInView:self]];
    [self setNeedsDisplay];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self setNeedsDisplay]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    for (XZDrawStroke *s in _strokes) {
        CGContextSetBlendMode(c, s.eraser ? kCGBlendModeClear : kCGBlendModeNormal);
        [s.color setStroke];
        s.path.lineWidth = s.width;
        s.path.lineCapStyle = kCGLineCapRound;
        s.path.lineJoinStyle = kCGLineJoinRound;
        [s.path stroke];
    }
    CGContextSetBlendMode(c, kCGBlendModeNormal);
}
@end

@implementation XZDrawEditor {
    UIWindow *_win;
    UIImageView *_iv;
    XZDrawCanvas *_canvas;
    UIImage *_source;
    NSMutableArray<XZDrawStroke *> *_strokes;
    UIColor *_inkColor;
    CGFloat _inkWidth;
    BOOL _eraser;
    BOOL _marker;
    UILabel *_tip;
    void (^_completion)(UIImage *);
    UISlider *_opacity;      // v5.10：透明度滑杆（马克笔半透明~不透明）
    UILabel *_opacityVal;    // v5.10：滑杆当前百分比
    UIView *_curView;        // v5.10：当前颜色预览圆
    UIButton *_lastDot;      // v5.10：最近选中的色块（高亮）
}

+ (void)edit:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    XZDrawEditor *ed = [[XZDrawEditor alloc] init];
    [ed buildWithImage:image completion:completion];
}

- (void)buildWithImage:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 260;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];
    _source = image;
    _strokes = [NSMutableArray array];
    _inkColor = [UIColor redColor];
    _inkWidth = 4.0;
    _eraser = NO;
    _completion = completion;

    // v5.10：工具条整体重排为 4 排，全部加在 bar 上（相对坐标）：
//   排1 画笔/马克笔/橡皮 ｜ 排2 颜色选择 ｜ 排3 透明度(马克笔) ｜ 排4 撤销/取消/完成
    CGFloat barH = 200.0;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - barH,
                                                           scr.size.width, barH)];
    bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    [_win addSubview:bar];

    CGRect fit = XZFitRect(image.size, CGRectMake(8, safe.top + 52, scr.size.width - 16,
                                                  scr.size.height - safe.top - safe.bottom - 252));
    _iv = [[UIImageView alloc] initWithFrame:fit];
    _iv.image = image;
    _iv.contentMode = UIViewContentModeScaleToFill;
    _iv.userInteractionEnabled = NO;
    [_win addSubview:_iv];

    _canvas = [[XZDrawCanvas alloc] initWithFrame:fit];
    _canvas.userInteractionEnabled = YES;
    [_win addSubview:_canvas];

    // 排1：画笔 / 马克笔 / 橡皮
    CGFloat rowW = (scr.size.width - 40 - 12) / 3.0;
    [self mkBtn:@"画笔"   frame:CGRectMake(20,          8, rowW, 42) sel:@selector(onPen)    color:[UIColor systemRedColor]    host:bar];
    [self mkBtn:@"马克笔" frame:CGRectMake(20 + rowW + 6, 8, rowW, 42) sel:@selector(onMarker) color:[UIColor systemOrangeColor] host:bar];
    [self mkBtn:@"橡皮"   frame:CGRectMake(20 + (rowW + 6) * 2, 8, rowW, 42) sel:@selector(onEraser) color:[UIColor systemGrayColor] host:bar];

    // 排2：颜色选择（8 色，替代原「换色」循环按钮）
    NSArray *palette = @[[UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
                         [UIColor greenColor], [UIColor systemBlueColor], [UIColor purpleColor],
                         [UIColor blackColor], [UIColor whiteColor]];
    CGFloat dotS = 26.0;
    CGFloat palW = scr.size.width - 40 - 64;      // 左侧色块区
    CGFloat gapP = (palW - dotS * palette.count) / (CGFloat)(palette.count - 1);
    for (NSInteger i = 0; i < palette.count; i++) {
        UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
        dot.frame = CGRectMake(20 + i * (dotS + gapP), 58, dotS, dotS);
        dot.backgroundColor = palette[i];
        dot.layer.cornerRadius = dotS / 2.0;
        dot.layer.borderWidth = 1;
        dot.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
        dot.tag = 500 + i;
        [dot addTarget:self action:@selector(onColorTap:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:dot];
        if (i == 0) { dot.layer.borderColor = [UIColor whiteColor].CGColor; dot.layer.borderWidth = 3; }
    }
    // 右侧当前色预览
    UIView *cur = [[UIView alloc] initWithFrame:CGRectMake(scr.size.width - 20 - 36, 58, 36, 36)];
    cur.backgroundColor = _canvas.inkColor;
    cur.layer.cornerRadius = 18;
    cur.layer.borderWidth = 1;
    cur.layer.borderColor = [UIColor whiteColor].CGColor;
    [bar addSubview:cur];
    _curView = cur;
    _lastDot = (UIButton *)[bar viewWithTag:500];

    // 排3：透明度（马克笔半透明~不透明）
    UILabel *al = [[UILabel alloc] initWithFrame:CGRectMake(20, 104, 58, 34)];
    al.text = @"透明度";
    al.textColor = [UIColor whiteColor];
    al.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [bar addSubview:al];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(82, 106, scr.size.width - 160, 30)];
    sl.minimumValue = 0.10;
    sl.maximumValue = 1.0;
    sl.value = 0.45;
    [sl addTarget:self action:@selector(onOpacity:) forControlEvents:UIControlEventValueChanged];
    [bar addSubview:sl];
    _opacity = sl;

    UILabel *pval = [[UILabel alloc] initWithFrame:CGRectMake(scr.size.width - 70, 104, 50, 34)];
    pval.text = @"45%";
    pval.textColor = [UIColor whiteColor];
    pval.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    pval.textAlignment = NSTextAlignmentRight;
    [bar addSubview:pval];
    _opacityVal = pval;

    // 排4：撤销 / 取消 / 完成
    [self mkBtn:@"撤销" frame:CGRectMake(20, 148, rowW, 46) sel:@selector(onUndo)   color:[UIColor systemGrayColor]  host:bar];
    [self mkBtn:@"取消" frame:CGRectMake(20 + rowW + 6, 148, rowW, 46) sel:@selector(onCancel) color:[UIColor systemGrayColor] host:bar];
    [self mkBtn:@"完成" frame:CGRectMake(20 + (rowW + 6) * 2, 148, rowW, 46) sel:@selector(onDone)   color:[UIColor systemGreenColor] host:bar];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(12, safe.top + 12, scr.size.width - 24, 30)];
    tip.text = @"画笔实线 / 马克笔半透明粗线，下方选色与调透明度，点「完成」合成";
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    tip.font = [UIFont systemFontOfSize:12];
    tip.adjustsFontSizeToFitWidth = YES;
    tip.textAlignment = NSTextAlignmentCenter;
    [_win addSubview:tip];
    _tip = tip;

    _win.hidden = NO;
    objc_setAssociatedObject(_win, "xz_draw_editor", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIButton *)mkBtn:(NSString *)title frame:(CGRect)f sel:(SEL)sel color:(UIColor *)color host:(UIView *)host {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = color;
    b.layer.cornerRadius = 8;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:b];
    return b;
}

#pragma mark - 工具（按钮仅切换画布状态；触摸由 XZDrawCanvas 自己捕获）

- (void)onPen    { _canvas.eraser = NO; _canvas.marker = NO; _tip.text = @"画笔：实线"; }
- (void)onMarker { _canvas.eraser = NO; _canvas.marker = YES; _tip.text = @"马克笔：半透明粗线（用下方透明度调）"; }
- (void)onEraser { _canvas.eraser = YES; _canvas.marker = NO; _tip.text = @"橡皮：擦除涂抹处"; }

// v5.10：色盘点选颜色（替代原「换色」循环）
- (void)onColorTap:(UIButton *)dot {
    NSInteger i = dot.tag - 500;
    NSArray *palette = @[[UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
                         [UIColor greenColor], [UIColor systemBlueColor], [UIColor purpleColor],
                         [UIColor blackColor], [UIColor whiteColor]];
    if (i < 0 || i >= (NSInteger)palette.count) return;
    _canvas.inkColor = palette[i];
    _canvas.eraser = NO; _canvas.marker = NO;   // 选色默认回到画笔
    _curView.backgroundColor = _canvas.inkColor;
    _lastDot.layer.borderWidth = 1; _lastDot.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    _lastDot = dot;
    dot.layer.borderWidth = 3; dot.layer.borderColor = [UIColor whiteColor].CGColor;
    _tip.text = @"已选画笔颜色";
}

// v5.10：透明度滑杆（马克笔半透明~不透明）
- (void)onOpacity:(UISlider *)sl {
    _canvas.inkAlpha = sl.value;
    _opacityVal.text = [NSString stringWithFormat:@"%d%%", (int)lround(sl.value * 100)];
    _canvas.marker = YES; _canvas.eraser = NO;   // 调透明度即切到马克笔
}
- (void)onUndo { [_canvas undoLast]; }

- (void)onCancel { [self finishWithImage:nil]; }

- (void)onDone {
    if (!_source) { [self finishWithImage:nil]; return; }
    // 把画布快照成透明叠层（橡皮处透明），再合成回原图
    UIImage *overlay = nil;
    @try {
        UIGraphicsBeginImageContextWithOptions(_canvas.bounds.size, NO, 0);
        [_canvas drawViewHierarchyInRect:_canvas.bounds afterScreenUpdates:YES];
        overlay = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    } @catch (NSException *e) { overlay = nil; }

    UIImage *result = _source;
    if (overlay) {
        UIGraphicsBeginImageContextWithOptions(_source.size, NO, _source.scale);
        [_source drawAtPoint:CGPointZero];
        // 画布 fit 尺寸已按图片宽高比，故直接拉伸到整图即可对齐
        [overlay drawInRect:CGRectMake(0, 0, _source.size.width, _source.size.height)];
        UIImage *merged = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (merged) result = merged;
    }
    [self finishWithImage:result];
}

- (void)finishWithImage:(UIImage *)img {
    void (^comp)(UIImage *) = _completion;
    if (_win) {
        _win.hidden = YES;
        objc_setAssociatedObject(_win, "xz_draw_editor", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _win = nil;
    }
    _iv = nil; _canvas = nil; _source = nil; _strokes = nil; _tip = nil; _completion = nil;
    if (comp) comp(img);
}

@end

#pragma mark - 涂鸦视图（打码用）

@interface XZPaintView : UIView
@property (nonatomic, strong) NSMutableArray<UIBezierPath *> *paths;
@property (nonatomic, assign) CGFloat strokeWidth;
@end

@implementation XZPaintView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _paths = [NSMutableArray array];
        _strokeWidth = 24.0;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = _strokeWidth;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path moveToPoint:p];
    [_paths addObject:path];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    [_paths.lastObject addLineToPoint:p];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self setNeedsDisplay];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    // v5.9：预览线条从 0.35 提到 0.92——原 alpha 太淡太透明，涂抹时几乎看不见，
    //       让用户误以为打码效果很弱。预览与最终合成应同样清晰可辨。
    [[UIColor colorWithWhite:1 alpha:0.92] setStroke];
    for (UIBezierPath *p in _paths) {
        p.lineWidth = _strokeWidth;
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [p stroke];
    }
}

@end

#pragma mark - 打码编辑器（窗口）

@implementation XZMosaicEditor {
    UIWindow *_win;
    XZPaintView *_paintView;
    UIImage *_source;
    NSMutableArray<NSValue *> *_smartRects;
    UILabel *_tipLabel;
    void (^_completion)(UIImage *);
    CGFloat _mosaicRatio;     // v5.8：像素化档位（块大小）
    BOOL   _mosaicBlur;       // v5.8：YES=模糊档（平滑缩放）
    CGFloat _blurRadius;      // v5.10：模糊档高斯半径（像素）
    UIButton *_activeStyle;   // v5.10：当前选中的档位按钮（高亮用）
}

+ (void)edit:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    XZMosaicEditor *editor = [[XZMosaicEditor alloc] init];
    [editor buildWithImage:image completion:completion];
}

- (void)buildWithImage:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 240;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];
    _source = image;
    _completion = completion;

    CGRect fit = XZFitRect(image.size, CGRectMake(8, safe.top + 52, scr.size.width - 16,
                                                  scr.size.height - safe.top - safe.bottom - 230));

    UIImageView *iv = [[UIImageView alloc] initWithFrame:fit];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleToFill;
    iv.layer.borderWidth = 1;
    iv.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    [_win addSubview:iv];

    _paintView = [[XZPaintView alloc] initWithFrame:fit];
    [_win addSubview:_paintView];

    // 智能脱敏命中的区域（像素坐标）
    _smartRects = [NSMutableArray array];

    // ---- 按钮区（v5.11：只保留 2 档，观感清晰：像素马赛克 / 高斯模糊）----
    CGFloat barH = 156.0;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - barH,
                                                           scr.size.width, barH)];
    bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    [_win addSubview:bar];

    _mosaicRatio = 22.0; _mosaicBlur = NO; _blurRadius = 0;   // 默认「像素马赛克」档

    // 排1：2 档（方形像素马赛克 / 高斯模糊）
    CGFloat sbw = (scr.size.width - 40 - 6) / 2.0;
    NSArray *styles = @[@"方形像素马赛克", @"高斯模糊"];
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *sb = [self mkBtn:styles[i] frame:CGRectMake(10 + i * (sbw + 6), 10, sbw, 38)
                               sel:@selector(onStyle:) color:[UIColor systemTealColor]];
        sb.tag = 100 + i;
        sb.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [bar addSubview:sb];
        if (i == 0) _activeStyle = sb;   // 默认「像素马赛克」高亮
    }

    CGFloat rowW = (scr.size.width - 40 - 12) / 2.0;

    UIButton *undo = [self mkBtn:@"撤销一笔" frame:CGRectMake(20, 58, rowW, 42) sel:@selector(onUndo)
                           color:[UIColor systemGrayColor]];
    [bar addSubview:undo];

    UIButton *clear = [self mkBtn:@"清除涂抹" frame:CGRectMake(32 + rowW, 58, rowW, 42) sel:@selector(onClear)
                             color:[UIColor systemGrayColor]];
    [bar addSubview:clear];

    UIButton *cancel = [self mkBtn:@"取消" frame:CGRectMake(20, 108, rowW, 44) sel:@selector(onCancel)
                             color:[UIColor systemGrayColor]];
    [bar addSubview:cancel];

    UIButton *done = [self mkBtn:@"完成打码" frame:CGRectMake(32 + rowW, 108, rowW, 44) sel:@selector(onDone)
                           color:[UIColor systemBlueColor]];
    [bar addSubview:done];

    [self refreshActiveStyle];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, safe.top + 12, scr.size.width - 40, 30)];
    tip.text = @"选一种效果，在要打码的地方涂抹；方形像素马赛克 / 高斯模糊柔化";
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    tip.font = [UIFont systemFontOfSize:13];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.numberOfLines = 2;
    [_win addSubview:tip];
    _tipLabel = tip;

    _win.hidden = NO;
    objc_setAssociatedObject(_win, "xz_mosaic_editor", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIButton *)mkBtn:(NSString *)title frame:(CGRect)f sel:(SEL)sel color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = color;
    b.layer.cornerRadius = 8;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)onStyle:(UIButton *)sender {
    NSInteger idx = sender.tag - 100;   // 0 方形像素马赛克 1 高斯模糊
    _activeStyle = sender;
    [self refreshActiveStyle];
    if (idx == 0) { _mosaicRatio = 22.0; _mosaicBlur = NO; _blurRadius = 0; _tipLabel.text = @"方块像素马赛克（涂抹处打码）"; }
    else           { _mosaicRatio = 0;   _mosaicBlur = YES; _blurRadius = 26; _tipLabel.text = @"高斯模糊（涂抹处平滑柔化）"; }
}

// v5.11：高亮当前选中的效果（白框 + 略亮），一眼能看出选的是哪个
- (void)refreshActiveStyle {
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *b = [_win viewWithTag:100 + i];
        if (!b) continue;
        if (b == _activeStyle) {
            b.layer.borderWidth = 2;
            b.layer.borderColor = [UIColor whiteColor].CGColor;
        } else {
            b.layer.borderWidth = 0;
        }
    }
}

- (void)onClear {
    if (_paintView.paths.count) {
        [_paintView.paths removeAllObjects];
        [_paintView setNeedsDisplay];
        [Common toast:@"已清除全部涂抹"];
    }
}

- (void)onUndo {
    if (_paintView.paths.count > 0) {
        [_paintView.paths removeLastObject];
        [_paintView setNeedsDisplay];
    }
}

- (void)onCancel {
    [self finishWithImage:nil];
}

- (void)onDone {
    CGImageRef cg = _source.CGImage;
    if (!cg) { [self finishWithImage:nil]; return; }
    CGFloat pxW = (CGFloat)CGImageGetWidth(cg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cg);

    // 显示区域(view 坐标) → 图片像素坐标 的比例
    CGRect fit = _paintView.frame;
    CGFloat k = (fit.size.width > 0) ? (pxW / fit.size.width) : 1.0;

    // 手动涂抹路径 → 像素坐标
    NSMutableArray<UIBezierPath *> *pixPaths = [NSMutableArray array];
    NSMutableArray<NSNumber *> *pixWidths = [NSMutableArray array];
    for (UIBezierPath *p in _paintView.paths) {
        UIBezierPath *cp = [UIBezierPath bezierPathWithCGPath:p.CGPath];
        CGAffineTransform t = CGAffineTransformMakeScale(k, k);
        t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(-fit.origin.x * k, -fit.origin.y * k));
        [cp applyTransform:t];
        [pixPaths addObject:cp];
        [pixWidths addObject:@(p.lineWidth * k)];
    }

    CGImageRef mask = [SuperTools createMaskWithSize:CGSizeMake(pxW, pxH)
                                              rects:_smartRects
                                              paths:pixPaths
                                         pathWidths:pixWidths];
    if (!mask) { [Common toast:@"打码失败"]; [self finishWithImage:nil]; return; }

    UIImage *processed = nil;
    if (_mosaicBlur) {
        processed = [SuperTools gaussianBlurImage:_source radius:(_blurRadius > 0 ? _blurRadius : 26)];
    } else {
        processed = [SuperTools pixelatedImage:_source ratio:_mosaicRatio];
    }
    UIImage *out = [SuperTools applyMask:mask toPixelated:(processed ?: _source) onImage:_source];
    CGImageRelease(mask);

    [self finishWithImage:out ?: _source];
}

- (void)finishWithImage:(UIImage *)img {
    void (^comp)(UIImage *) = _completion;
    if (_win) {
        _win.hidden = YES;
        objc_setAssociatedObject(_win, "xz_mosaic_editor", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _win = nil;
    }
    _paintView = nil;
    _source = nil;
    _smartRects = nil;
    _tipLabel = nil;
    _completion = nil;
    if (comp) comp(img);
}

@end

#pragma mark - 取色器窗口

@implementation XZColorPicker {
    UIWindow *_win;
    UIImageView *_imageView;
    UIImage *_source;
    UIView *_swatch;
    UILabel *_hexLabel;
    UIColor *_current;
}

+ (void)show:(UIImage *)image {
    XZColorPicker *cp = [[XZColorPicker alloc] init];
    [cp buildWithImage:image];
}

- (void)buildWithImage:(UIImage *)image {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 250;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    CGRect fit = XZFitRect(image.size, CGRectMake(8, safe.top + 52, scr.size.width - 16,
                                                  scr.size.height - safe.top - safe.bottom - 150));
    UIImageView *iv = [[UIImageView alloc] initWithFrame:fit];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleToFill;
    iv.userInteractionEnabled = YES;
    [_win addSubview:iv];
    _imageView = iv;
    _source = image;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(onTap:)];
    [iv addGestureRecognizer:tap];

    _swatch = [[UIView alloc] initWithFrame:CGRectMake(20, safe.top + 12, 34, 34)];
    _swatch.backgroundColor = [UIColor clearColor];
    _swatch.layer.cornerRadius = 6;
    _swatch.layer.borderWidth = 1;
    _swatch.layer.borderColor = [UIColor whiteColor].CGColor;
    [_win addSubview:_swatch];

    _hexLabel = [[UILabel alloc] initWithFrame:CGRectMake(64, safe.top + 12, scr.size.width - 150, 34)];
    _hexLabel.text = @"点一下图片上的任意位置取色";
    _hexLabel.textColor = [UIColor whiteColor];
    _hexLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_win addSubview:_hexLabel];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(scr.size.width - 84, safe.top + 12, 72, 34);
    copy.backgroundColor = [UIColor systemBlueColor];
    copy.layer.cornerRadius = 8;
    [copy setTitle:@"复制HEX" forState:UIControlStateNormal];
    [copy setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [copy addTarget:self action:@selector(onCopy) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:copy];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(20, scr.size.height - safe.bottom - 60, scr.size.width - 40, 46);
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    close.layer.cornerRadius = 10;
    [close setTitle:@"关闭取色器" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:close];

    _win.hidden = NO;
    objc_setAssociatedObject(_win, "xz_color_picker", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)onTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:_imageView];
    CGSize isz = _source.size;
    if (isz.width <= 0 || isz.height <= 0) return;
    // view 坐标 → 图片自身坐标系（点）
    CGPoint imgPt = CGPointMake(p.x / _imageView.bounds.size.width * isz.width,
                                p.y / _imageView.bounds.size.height * isz.height);
    UIColor *c = [ImageUtils pixelColorAtPoint:imgPt inImage:_source];
    if (!c) return;

    _current = c;
    _swatch.backgroundColor = c;

    CGFloat r = 0, gg = 0, b = 0, a = 0;
    [c getRed:&r green:&gg blue:&b alpha:&a];
    NSString *hex = [NSString stringWithFormat:@"#%02X%02X%02X",
                     (int)(r * 255), (int)(gg * 255), (int)(b * 255)];
    _hexLabel.text = [NSString stringWithFormat:@"%@   RGB(%d,%d,%d)",
                      hex, (int)(r * 255), (int)(gg * 255), (int)(b * 255)];
}

- (void)onCopy {
    if (!_hexLabel.text.length) return;
    NSString *hex = _hexLabel.text;
    NSRange sp = [hex rangeOfString:@" "];
    if (sp.location != NSNotFound) hex = [hex substringToIndex:sp.location];
    [UIPasteboard generalPasteboard].string = hex;
    [Common toast:[NSString stringWithFormat:@"已复制 %@", hex]];
}

- (void)onClose {
    if (_win) {
        _win.hidden = YES;
        objc_setAssociatedObject(_win, "xz_color_picker", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _win = nil;
    }
    _imageView = nil;
    _source = nil;
    _swatch = nil;
    _hexLabel = nil;
    _current = nil;
}

@end
