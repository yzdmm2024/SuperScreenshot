//
//  EditToolbarWindow.m — 窗口B：截图编辑两排工具栏（超级截图 v4.1）
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.1 修复 / 增强
//   1) 【致命 v4.0 缺陷】窗口没有 rootViewController，导致 UIAlertController
//      (OCR 结果、二维码结果、更多菜单) 和 UIActivityViewController (分享)
//      只能拿 SpringBoard 的 keyWindow.rootViewController 去 present，
//      在 SpringBoard 里经常静默失败或抛异常 —— 表现为「点了没反应」。
//      现补上 XZEditRootVC，所有 present 一律走它。
//   2) 两排工具栏统一为 5 + 5，按钮尺寸按屏宽自适应，不再写死 62pt。
//   3) 顶部增加关闭按钮 + 图片尺寸标签；去掉「点任意空白处关闭」的手势
//      （v4.0 里这个手势经常误触，尤其 OCR 弹窗关闭时顺手把窗口也关了）。
//   4) 图片区按安全区 + 工具栏高度自适应，长图也能完整显示（aspectFit）。
//  ────────────────────────────────────────────────────────────────────────
//

#import "EditToolbarWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "SuperTools.h"
#import "AIChatWindow.h"

@interface EditToolbarWindow () <UIScrollViewDelegate>
@end

typedef NS_ENUM(NSInteger, ETBTag) {
    // 第 1 排：识别 / 编辑
    ETBTagOCR        = 1,
    ETBTagTranslate  = 2,
    ETBTagDraw       = 3,
    ETBTagCodeScan   = 4,
    ETBTagAIChat    = 18,   // AI 对话（小窗自由对话，可接豆包）
    ETBTagAIImage   = 20,   // 看图问 AI（把原图作为多模态内容发给视觉模型）
    ETBTagRotate    = 19,   // 旋转当前图（90°步进）
    // 第 2 排：输出操作
    ETBTagCopy       = 6,
    ETBTagFloating   = 7,
    ETBTagSave       = 8,
    ETBTagShare      = 9,
    ETBTagPhone      = 11,   // 加手机壳
    // 第 3 排：更多工具（直接平铺，不再进二级菜单）
    ETBTagPDF        = 12,   // 导出 PDF
    ETBTagCompress   = 13,   // 压缩
    ETBTagColorPick  = 15,   // 取色器
    ETBTagReset      = 16,   // 还原原图
    ETBTagLaunchApp  = 21,   // v6.20.9：快捷启动 App（弹层选微信/QQ/闲鱼/自选，秒开）
};

static const CGFloat kRowH    = 66.0;   // 单排按钮高
static const CGFloat kRowGap  = 8.0;
static const CGFloat kBarPad  = 10.0;

#pragma mark - 承载用 rootViewController

@interface XZEditRootVC : UIViewController
@property (nonatomic, weak) EditToolbarWindow *owner;
@end

@implementation XZEditRootVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return NO; }
@end

#pragma mark - EditToolbarWindow

@implementation EditToolbarWindow {
    UIWindow *_win;
    XZEditRootVC *_rootVC;
    UIImageView *_imageView;
    UIView *_toolbar;
    UILabel *_sizeLabel;
    UIImage *_originalImage;   // 还原用：保留最初传入的原图
    UIScrollView *_singleRowScroll;   // v5.25.5：单排循环滑动用
    CGFloat _singleRowBtnW;            // v5.25.5：单排按钮步距（宽+间距）
    CGFloat _singleRowSetW;            // v5.25.7：单排一组按钮的总跨度，用于无限制循环回绕
    BOOL    _rotateLongPressed;        // v5.25.7：区分「点按(90°)」与「长按(180°)」，避免两者同时触发
}

static EditToolbarWindow *_shared = nil;

#pragma mark - 生命周期

+ (void)showWithImage:(UIImage *)image {
    if (!image) { NSLog(@"[SuperScreenshot] EditToolbarWindow: nil image"); return; }
    if (_shared) [_shared destroyWindow];     // 重入先销毁，避免叠加

    EditToolbarWindow *w = [[EditToolbarWindow alloc] init];
    _shared = w;
    w->_originalImage = image;
    [w buildWindowWithImage:image];
}

+ (void)dismiss {
    if (_shared) {
        [_shared destroyWindow];
        _shared = nil;
    }
}

- (void)destroyWindow {
    if (_win) {
        _win.hidden = YES;
        _win.rootViewController = nil;
        _win = nil;
    }
    _rootVC.owner = nil;
    _rootVC = nil;
    _imageView = nil;
    _toolbar = nil;
    _sizeLabel = nil;
    NSLog(@"[SuperScreenshot] edit window B destroyed");
}

#pragma mark - 工具栏布局计算（installToolbar / buildWindowWithImage 共用）

// v5.25.5：统一计算「当前应显示的按钮顺序（去禁用、补缺失）」，单排/双排共用
- (NSArray<NSNumber *> *)resolveEnabledTags {
    NSArray<NSNumber *> *defOrder = @[ @(ETBTagOCR), @(ETBTagTranslate), @(ETBTagDraw), @(ETBTagCodeScan), @(ETBTagAIImage),
                                       @(ETBTagRotate), @(ETBTagCopy), @(ETBTagFloating), @(ETBTagSave),
                                       @(ETBTagShare), @(ETBTagPDF), @(ETBTagCompress), @(ETBTagAIImage),
                                       @(ETBTagColorPick), @(ETBTagReset), @(ETBTagLaunchApp) ];
    NSMutableArray<NSNumber *> *savedOrder = [NSMutableArray array];
    NSString *orderStr = [Common stringPref:XZ_KEY_TB_ORDER default:@""];
    if (orderStr.length) [savedOrder addObjectsFromArray:[orderStr componentsSeparatedByString:@","]];
    if (savedOrder.count == 0) [savedOrder addObjectsFromArray:defOrder];
    NSMutableSet<NSNumber *> *orderSet = [NSMutableSet setWithArray:savedOrder];
    for (NSNumber *t in defOrder) if (![orderSet containsObject:t]) [savedOrder addObject:t];
    for (NSNumber *t in [savedOrder copy]) {
        if (![defOrder containsObject:t]) [savedOrder removeObject:t];
    }
    NSSet<NSNumber *> *disabled = [NSSet setWithArray:[[Common stringPref:XZ_KEY_TB_DISABLED default:@""] componentsSeparatedByString:@","]];
    NSMutableArray<NSNumber *> *enabled = [NSMutableArray array];
    for (NSNumber *t in savedOrder) {
        if (![disabled containsObject:t]) [enabled addObject:t];
    }
    // v6.01：AI / 对话 / 旋转 三个按钮始终显示（不再受「启用问 AI」开关过滤），
    // 「启用问 AI」开关只作为 AI 对话是否走已配置接口的提示，不影响按钮可见性。
    return enabled;
}

- (CGFloat)toolbarBarHeight {
    BOOL singleRow = ([Common intPref:XZ_KEY_TB_LAYOUT default:0] == 1);
    if (singleRow) return kBarPad * 2 + kRowH;
    NSArray *enabled = [self resolveEnabledTags];
    NSInteger rows = (NSInteger)ceil((double)MAX(1, (NSInteger)enabled.count) / 5.0);
    return kBarPad * 2 + kRowH * rows + kRowGap * MAX(0, rows - 1);
}

- (void)buildWindowWithImage:(UIImage *)image {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    // v5.25.6: 层级从 Alert+200 降到 Alert-10。
    // 原 Alert+200(2200) 高于系统 UIAlertController 默认层级(Alert=2000),
    // 导致 OCR/翻译/识别结果弹窗被全屏遮罩盖住; v5.25.4 用「把弹窗窗口硬抬到 2250」的 hack 修复,
    // 但那个被抬高的 alert 窗口 dismiss 后残留 2250 盖住全屏, 使工具栏「关闭」按钮点不到, 界面关不掉。
    // 降到 Alert-10(1990): 仍高于所有 app 内容(盖住截图背景), 但低于系统 alert(2000),
    // 于是 OCR 弹窗由系统自然浮在工具栏之上, 且 dismiss 后正常清理, 无残留。
    _win.windowLevel = UIWindowLevelAlert - 10;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    _win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    // 关键：必须有 rootViewController，present 才有落点
    _rootVC = [[XZEditRootVC alloc] init];
    _rootVC.owner = self;
    _rootVC.view.backgroundColor = [UIColor clearColor];
    _rootVC.view.frame = scr;
    _win.rootViewController = _rootVC;

    // 图片显示区：上方留出关闭条，下方留给工具栏（高度随按钮数量/单双排动态计算）
    CGFloat barH = [self toolbarBarHeight];
    CGFloat topY = safe.top + 44;
    CGFloat botY = scr.size.height - safe.bottom - barH - 8;
    _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(8, topY, scr.size.width - 16, MAX(60, botY - topY))];
    _imageView.image = image;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.userInteractionEnabled = YES;
    _imageView.layer.borderWidth = 1;
    _imageView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    [_rootVC.view addSubview:_imageView];

    // 顶部：关闭 + 尺寸信息
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(12, safe.top + 4, 72, 34);
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    close.layer.cornerRadius = 8;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [_rootVC.view addSubview:close];

    _sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(96, safe.top + 4, scr.size.width - 108, 34)];
    _sizeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _sizeLabel.font = [UIFont systemFontOfSize:12];
    _sizeLabel.textAlignment = NSTextAlignmentRight;
    _sizeLabel.text = [NSString stringWithFormat:@"%.0f × %.0f px", image.size.width, image.size.height];
    [_rootVC.view addSubview:_sizeLabel];

    [self installToolbar];
    _win.hidden = NO;
    NSLog(@"[SuperScreenshot] edit window B shown, image=%.0fx%.0f", image.size.width, image.size.height);
}

- (void)onClose {
    [EditToolbarWindow dismiss];
}

#pragma mark - 两排工具栏

- (void)installToolbar {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    // v5.25.5：按钮顺序 / 禁用集合 / 单双排 由偏好决定（resolveEnabledTags 统一计算）。
    // 默认顺序：OCR 翻译 画图 识码 AI 打开豆包 旋转 复制 贴图 保存 分享 PDF 压缩 取色 还原。（v6.20.5：去状态栏已移除，由「打开豆包」替代；加壳移出手动按钮，改由「手机壳库」设置自动套壳）
    NSArray<NSNumber *> *enabledTags = [self resolveEnabledTags];

    // 按钮规格表（icon/label/tag）—— 整个工具栏统一从这里取，settings 排序也用这里
    NSDictionary<NSNumber *, NSDictionary *> *catalog = @{
        @(ETBTagOCR):       @{@"icon":@"text.viewfinder",             @"label":@"OCR"},
        @(ETBTagTranslate): @{@"icon":@"translate",                   @"label":@"翻译"},
        @(ETBTagDraw):      @{@"icon":@"pencil.tip",                  @"label":@"画图"},
        @(ETBTagCodeScan):  @{@"icon":@"qrcode.viewfinder",           @"label":@"识码"},
        @(ETBTagAIImage):   @{@"icon":@"bubble.left",                 @"label":@"豆包"},
        @(ETBTagRotate):    @{@"icon":@"rotate.right",                @"label":@"旋转"},
        @(ETBTagCopy):      @{@"icon":@"doc.on.doc",                  @"label":@"复制"},
        @(ETBTagFloating):  @{@"icon":@"pin",                         @"label":@"贴图"},
        @(ETBTagSave):      @{@"icon":@"square.and.arrow.down",       @"label":@"保存"},
        @(ETBTagShare):     @{@"icon":@"square.and.arrow.up",         @"label":@"分享"},
        @(ETBTagPDF):       @{@"icon":@"doc.richtext",                @"label":@"PDF"},
        @(ETBTagCompress):  @{@"icon":@"arrow.down.circle",           @"label":@"压缩"},
        @(ETBTagColorPick): @{@"icon":@"eyedropper",                  @"label":@"取色"},
        @(ETBTagReset):     @{@"icon":@"arrow.counterclockwise",      @"label":@"还原"},
        @(ETBTagLaunchApp): @{@"icon":@"app.fill",               @"label":@"启动"},
    };

    BOOL singleRow = ([Common intPref:XZ_KEY_TB_LAYOUT default:0] == 1);

    // v5.25.5：单排=1 行横向滑动；双排=每行 5 个自动折行（2 排即 10，更多则续行）
    const NSInteger kCols = 5;
    NSInteger rows = singleRow ? 1 : (NSInteger)ceil((double)MAX(1, (NSInteger)enabledTags.count) / (double)kCols);

    CGFloat barH = kBarPad * 2 + kRowH * rows + kRowGap * MAX(0, rows - 1);
    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - barH,
                                                        scr.size.width, barH)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_rootVC.view addSubview:_toolbar];

    if (singleRow) {
        // v5.25.7：真·无限制循环滑动。放 3 组相同按钮（前/中/后），初始停在中组，
        // 滚动越界即在 scrollViewDidScroll 里无感回绕到中组对应位置，左右都可无限滑。
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, kBarPad, scr.size.width, kRowH)];
        sv.showsHorizontalScrollIndicator = NO;
        sv.alwaysBounceHorizontal = YES;
        sv.delegate = self;
        sv.tag = 9901;   // 标记，用于循环滑动时识别
        [_toolbar addSubview:sv];
        CGFloat bw = 64.0, gap = 8.0;
        CGFloat stride = (bw + gap) * (CGFloat)enabledTags.count;   // 一组按钮的总跨度（相邻组同款按钮的间距）
        for (int copy = 0; copy < 3; copy++) {
            CGFloat baseX = copy * stride;
            CGFloat x = 10.0 + baseX;
            for (NSNumber *t in enabledTags) {
                NSDictionary *spec = catalog[t];
                NSMutableDictionary *full = [spec mutableCopy];
                full[@"tag"] = t;
                UIButton *b = [self makeToolButton:full width:bw];
                b.frame = CGRectMake(x, 0, bw, kRowH);
                [sv addSubview:b];
                x += bw + gap;
            }
        }
        sv.contentSize = CGSizeMake(stride * 3.0 + 20.0, kRowH);
        sv.contentOffset = CGPointMake(stride, 0);   // 停在中组，按钮排列与单组一致
        _singleRowScroll = sv;
        _singleRowSetW = stride;
        _singleRowBtnW = bw + gap;
    } else {
        // 双排：每行固定 5 个，自动折行（不再 5 + 余下，避免第二排被压成 10 个）
        CGFloat pad = 10.0, gap = 6.0;
        CGFloat bw = (scr.size.width - pad * 2 - gap * (kCols - 1)) / (CGFloat)kCols;
        for (NSInteger i = 0; i < (NSInteger)enabledTags.count; i++) {
            NSInteger r = i / kCols;
            NSInteger c = i % kCols;
            NSDictionary *spec = catalog[enabledTags[i]];
            NSMutableDictionary *full = [spec mutableCopy];
            full[@"tag"] = enabledTags[i];
            UIButton *b = [self makeToolButton:full width:bw];
            b.frame = CGRectMake(pad + c * (bw + gap), kBarPad + r * (kRowH + kRowGap), bw, kRowH);
            [_toolbar addSubview:b];
        }
    }
}

#pragma mark - 单排循环滑动（真·无限制）

// v5.25.7：3 组按钮首尾相接，滚动越界即无感回绕，左右都能无限循环滑。
// 始终把 offset 钳制在「中组」区间 [setW, 2*setW)，越界就平移一个 setW。
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView.tag != 9901) return;
    CGFloat setW = _singleRowSetW;
    if (setW <= 0) return;
    // 一组就能放下时无需循环，避免回绕把视图弹飞
    if (setW <= [UIScreen mainScreen].bounds.size.width) return;
    CGFloat off = scrollView.contentOffset.x;
    if (off < setW) {
        scrollView.contentOffset = CGPointMake(off + setW, 0);
    } else if (off >= 2.0 * setW) {
        scrollView.contentOffset = CGPointMake(off - setW, 0);
    }
}

- (UIButton *)makeToolButton:(NSDictionary *)spec width:(CGFloat)bw {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = [spec[@"tag"] integerValue];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:@selector(toolTapped:) forControlEvents:UIControlEventTouchUpInside];
    // v5.25.7：旋转按钮支持长按 = 旋转 180°（点按 = 旋转 90°，见 onRotateLongPress:）
    if ([spec[@"tag"] integerValue] == ETBTagRotate) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onRotateLongPress:)];
        lp.minimumPressDuration = 0.5;
        [b addGestureRecognizer:lp];
    }

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((bw - 24) / 2, 8, 24, 24)];
    iv.image = [Common systemIcon:spec[@"icon"]];
    if (!iv.image) iv.image = [Common systemIcon:@"circle"];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [b addSubview:iv];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 38, bw, 18)];
    lb.text = spec[@"label"];
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];
    return b;
}

#pragma mark - 分发
//
// ⚠️ 用 if/else 链而不是 switch：ObjC++ 下 switch case 内声明带 block 捕获的变量
//    会直接编译报错（v4.0 踩过：cannot jump from switch statement）。
//
// v6.09: 外层加异常兜底。tweak 跑在 SpringBoard 进程里，任何未捕获的 ObjC 异常
// 都会直接把 SpringBoard 打进安全模式。工具按钮是用户高频入口，必须兜住。
// （Makefile 已带 -fobjc-exceptions）
- (void)toolTapped:(UIButton *)btn {
    @try {
        [self _toolTappedInner:btn];
    } @catch (NSException *e) {
        NSLog(@"[SuperScreenshot] toolTapped 异常 tag=%ld: %@ / %@ / %@",
              (long)btn.tag, e.name, e.reason, e.callStackSymbols);
        [Common toast:[NSString stringWithFormat:@"操作失败：%@", e.reason ?: e.name]];
    }
}

- (void)_toolTappedInner:(UIButton *)btn {
    UIImage *img = _imageView.image;
    if (!img) return;
    NSInteger tag = btn.tag;

    if (tag == ETBTagOCR) {
        [Common toast:@"正在识别文字..."];
        [SuperTools ocr:img completion:^(NSString *text) {
            [self presentText:text title:@"OCR 识别结果"];
        }];
    } else if (tag == ETBTagTranslate) {
        [Common toast:@"正在识别并翻译..."];
        [SuperTools translate:img completion:^(NSString *src, NSString *dst, NSString *err) {
            [self presentTranslate:src dst:dst err:err];
        }];
    } else if (tag == ETBTagDraw) {
        [SuperTools draw:img completion:^(UIImage *edited) {
            if (edited) [self replaceImage:edited];
        }];
    } else if (tag == ETBTagCodeScan) {
        [Common toast:@"正在识别二维码..."];
        [SuperTools codeScan:img completion:^(NSString *code) {
            [self presentCodeAction:code];
        }];
    } else if (tag == ETBTagAIImage) {
        // v6.20.8：改为直接拉起「豆包」App 并把截图带进去（不再应用内发 API 对话）
        BOOL opened = [SuperTools openDoubaoWithImage:img];
        if (opened) {
            [EditToolbarWindow dismiss];   // v6.20.20：收起面板，别挡住已打开的豆包
            [Common toast:@"已打开豆包，截图已复制到剪贴板，长按输入框可粘贴"];
        } else {
            // 豆包未安装：回退系统分享面板（选豆包即带图）
            [SuperTools presentShareForItem:img fromWindow:_win];
            [Common toast:@"未检测到豆包，已用系统分享，请选择豆包"];
        }
    } else if (tag == ETBTagRotate) {
        // v5.25.7：区分点按(90°)与长按(180°)。长按已置 _rotateLongPressed，
        // 此处跳过以免 90° 与 180° 叠加（净转 270°）。
        if (_rotateLongPressed) { _rotateLongPressed = NO; return; }
        [self rotateCurrentImage];   // v5.25.5：旋转当前编辑图 90°（顺时针）
    } else if (tag == ETBTagCopy) {
        [SuperTools copy:img];
    } else if (tag == ETBTagFloating) {
        [SuperTools floating:img withScreenRect:_imageView.frame];
        [EditToolbarWindow dismiss];
    } else if (tag == ETBTagSave) {
        // v6.05：手机壳库 —— 正常截图保存时按设置自动套壳
        UIImage *toSave = img;
        if ([Common boolPref:XZ_KEY_PHONE_CASE_ON default:NO]) {
            NSString *caseId = [Common stringPref:XZ_KEY_PHONE_CASE default:@"none"];
            if (caseId.length && ![caseId isEqualToString:@"none"]) {
                UIImage *framed = [ImageUtils applyPhoneFrame:toSave caseId:caseId];
                if (framed) toSave = framed;
            }
        }
        [SuperTools save:toSave completion:^(BOOL ok) {
            [Common toast:ok ? @"已保存到相册" : @"保存失败"];
        }];
    } else if (tag == ETBTagShare) {
        [SuperTools share:img fromWindow:_win];
    } else if (tag == ETBTagPDF) {       // v6.05：加壳移出手动按钮，改由「手机壳库」设置对正常截图自动套壳
        NSString *p = [SuperTools exportPDF:img];
        if (p) {
            [SuperTools presentShareForItem:[NSURL fileURLWithPath:p] fromWindow:_win];
        } else {
            [Common toast:@"导出失败"];
        }
    } else if (tag == ETBTagCompress) {
        NSData *before = UIImagePNGRepresentation(img);
        UIImage *c = [SuperTools compress:img quality:0.6];
        if (c) {
            NSData *after = UIImageJPEGRepresentation(c, 0.6);
            [self replaceImage:c];
            [Common toast:[NSString stringWithFormat:@"已压缩：%.0fKB → %.0fKB",
                           before.length / 1024.0, after.length / 1024.0]];
        } else {
            [Common toast:@"压缩失败"];
        }
    } else if (tag == ETBTagColorPick) {
        [SuperTools colorPicker:img fromWindow:_win];
    } else if (tag == ETBTagReset) {
        if (_originalImage) { [self replaceImage:_originalImage]; [Common toast:@"已还原原图"]; }
        else [Common toast:@"无原图可还原"];
    } else if (tag == ETBTagLaunchApp) {
        // v6.20.9：一键秒开微信/QQ/闲鱼等任意 App（弹层选择，图同时入剪贴板可粘贴）
        [self launchAppWithImage:img];
    }
}

- (void)launchAppWithImage:(UIImage *)img {
    NSArray<NSDictionary *> *apps = [SuperTools superscreenshotLaunchApps];
    if (apps.count == 0) {
        [Common toast:@"请先到设置 → 快捷启动 里添加 App"];
        return;
    }
    if (apps.count == 1) {
        NSDictionary *a = apps.firstObject;
        BOOL opened = [SuperTools openAppScheme:a[@"scheme"] withImage:img];
        [self _launchResult:opened app:a];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"启动 App"
                                                               message:@"选一个要打开的 App"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *a in apps) {
        NSString *name = a[@"name"] ?: (a[@"scheme"] ?: @"App");
        [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
            BOOL opened = [SuperTools openAppScheme:a[@"scheme"] withImage:img];
            [self _launchResult:opened app:a];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

- (void)_launchResult:(BOOL)opened app:(NSDictionary *)a {
    NSString *nm = a[@"name"] ?: @"App";
    if (opened) {
        [EditToolbarWindow dismiss];   // v6.20.20：收起面板，别挡住已打开的 App
        [Common toast:[NSString stringWithFormat:@"已打开%@，截图已复制到剪贴板，长按输入框可粘贴", nm]];
    } else {
        [SuperTools presentShareForItem:_imageView.image fromWindow:_win];
        [Common toast:[NSString stringWithFormat:@"未检测到%@，已用系统分享，请选择%@", nm, nm]];
    }
}

#pragma mark - 展示辅助

- (void)presentText:(NSString *)text title:(NSString *)title {
    if (!text || text.length == 0) { [Common toast:@"没有识别到文字"]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = text;
        [Common toast:@"已复制文本"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

- (void)presentTranslate:(NSString *)src dst:(NSString *)dst err:(NSString *)err {
    if (err && err.length) {
        // v5.8：翻译失败给出明确原因（多因密钥/网络），不再只弹「翻译失败」
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"翻译失败"
                                                                   message:err
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [Common present:ac fromWindow:_win];
        return;
    }
    if (!dst || dst.length == 0) { [Common toast:@"翻译失败"]; return; }
    NSString *msg = [NSString stringWithFormat:@"原文：\n%@\n\n译文：\n%@",
                     src ?: @"", dst ?: @""];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"翻译结果"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制译文" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = dst;
        [Common toast:@"已复制译文"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制原文" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = src ?: @"";
        [Common toast:@"已复制原文"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

// 识码结果：复制链接 / 跳转 Safari
- (void)presentCodeAction:(NSString *)code {
    if (!code || code.length == 0) { [Common toast:@"未识别到二维码"]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"识别结果"
                                                               message:code
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = code;
        [Common toast:@"已复制"];
    }]];
    NSURL *url = [NSURL URLWithString:code];
    if (url && ([[code lowercaseString] hasPrefix:@"http://"] || [[code lowercaseString] hasPrefix:@"https://"])) {
        [ac addAction:[UIAlertAction actionWithTitle:@"用 Safari 打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

- (void)replaceImage:(UIImage *)img {
    if (!img) return;
    _imageView.image = img;
    _sizeLabel.text = [NSString stringWithFormat:@"%.0f × %.0f px", img.size.width, img.size.height];
}

// v5.25.7：统一旋转入口；rad=M_PI_2 转 90°(顺时针)，rad=M_PI 转 180°
- (void)rotateCurrentImageBy:(CGFloat)rad {
    UIImage *img = _imageView.image;
    if (!img) return;
    CGFloat w = img.size.width, h = img.size.height;
    BOOL swap = (fabs(fmod(rad, M_PI)) > 0.01);   // 90/270 交换宽高；180 不变
    CGSize outSize = swap ? CGSizeMake(h, w) : CGSizeMake(w, h);
    UIGraphicsBeginImageContextWithOptions(outSize, NO, img.scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, outSize.width / 2.0, outSize.height / 2.0);
    CGContextRotateCTM(ctx, rad);
    CGContextTranslateCTM(ctx, -w / 2.0, -h / 2.0);
    [img drawInRect:CGRectMake(0, 0, w, h)];
    UIImage *rot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (rot) {
        [self replaceImage:rot];
        [Common toast:swap ? @"已旋转 90°" : @"已旋转 180°"];
    }
}

// v5.25.5：点按旋转按钮 = 顺时针 90°
- (void)rotateCurrentImage {
    [self rotateCurrentImageBy:M_PI_2];
}

// v5.25.7：长按旋转按钮 = 旋转 180°
- (void)onRotateLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _rotateLongPressed = YES;
        [self rotateCurrentImageBy:M_PI];
    }
}

@end
