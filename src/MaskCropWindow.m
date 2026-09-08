//
//  MaskCropWindow.m — 窗口A：遮罩框选 + 长截图实时预览框（超级截图 v5.0）
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.7 交互重设计（依据用户实测反馈）：
//    · 框选（遮罩）模式：
//        - 进入即局部截图模式，直接拖框；松手【立即】裁出选区 → 销毁窗口A → 弹窗口B
//          两排编辑工具栏（OCR/翻译/画图/识码/打码/复制/贴图/保存/分享/更多）。
//        - 底部常驻三个按钮：【正常截图】【长截图】【取消】。
//        - 正常截图：仿系统电源+音量键，截整屏直接存相册「超级截图」，不弹编辑。
//    · 长截图 = 全屏宽「实时预览框」：
//        - 点【长截图】直接弹出全屏宽截取框；框外区域不参与输出。
//        - 框内触摸穿透，底层 App（微信群聊/单聊/朋友圈/公众号等）可上下滑动，
//          框内实时显示长截图内容预览；框内滚动的【最高点→最低点】即长截图起止范围。
//        - 框外【只保留 2 个按钮】：【保存长图】【复制】；方框右上角增加【关闭】按钮。
//        - 不出现双排编辑功能区；拼接完成后直接存相册 / 复制到剪贴板，不弹窗口B。
//        - 进入即启动自动抓帧定时器(~0.4s)：框内滑动期间逐帧采集、重叠去重；
//          建议从目标内容顶部开始向下滑动，松手静止即停采。
//    · 抓帧前临时隐藏边框，裁剪框内区域（已 inset 排除描边），绝不把暗色/控件截进图片。
//    · 退出时完整销毁窗口并置空，防 SpringBoard 泄漏 / respring。
//

#import "MaskCropWindow.h"
#import "XZPassThroughWindow.h"
#import "Common.h"
#import <objc/runtime.h>
#import "ImageUtils.h"
#import "EditToolbarWindow.h"
#import "AIChatWindow.h"
#import "LongShotCapture.h"
#import "SuperTools.h"
#import "ResultWindow.h"
#import "HistoryWindow.h"
#include <math.h>
#include <notify.h>
#import "SuperScreenshotNotify.h"

// ---------- 布局常量（pt） ----------
static const CGFloat kButtonH  = 46.0;   // 按钮高
static const CGFloat kMinCrop  = 16.0;   // 有效选区最小边长

// 长截图截取框留白（框全屏宽；上下留白给关闭按钮 / 底部两按钮）
static const CGFloat kFrameTopInset  = 54.0;   // 框顶距安全区上沿：仅避状态栏；导航条由大重叠在拼接时丢弃（长图顶部导航条只出现一次）
static const CGFloat kFrameBotInset  = 140.0;  // 框底距屏幕底：避开底部固定输入条/标签栏（防止长截图重复）

// ---- v5.3：精确模式跨进程 notify token（进程级，仅注册一次）----
static int g_capTok = 0, g_offTok = 0, g_regionTok = 0, g_doneTok = 0;
static BOOL g_lsReg = NO;

typedef NS_ENUM(NSInteger, XZDragTarget) {
    XZDragNone       = 0,
    XZDragDraw,          // 框选：画新矩形
    XZDragMove,          // 框选：整体拖动（宽高不变、不旋转）
    XZDragResize,        // 框选：拖手柄缩放（边/角）
};

// 缩放手柄位掩码：组合表示被拖的是哪条边/角
typedef NS_OPTIONS(NSInteger, XZResizeMask) {
    XZResizeNone  = 0,
    XZResizeLeft  = 1 << 0,
    XZResizeRight = 1 << 1,
    XZResizeTop   = 1 << 2,
    XZResizeBottom= 1 << 3,
};

static const CGFloat kHandleHit = 30.0;   // 手柄命中半边长（pt）—— v5.21:加大到 30, 让四边四角的"上下左右"调整更容易命中

@interface MaskCropWindow () <UIGestureRecognizerDelegate, UIScrollViewDelegate>
- (void)setWindowHidden:(BOOL)hidden;
- (void)presentLocalPanelForRect:(CGRect)rect;     // 局部截图 → 选区下方原地面板（不跳转窗口B）
- (void)captureFullScreenAndSave;                  // 正常截图 → 相册（无编辑）
- (void)refreshChrome;                             // 强制刷新 UI
@end

// v5.21: 单排滑动循环用的 KVO context
static int SuperScreenshot_LoopKVOContext = 0;

@implementation MaskCropWindow {
    XZPassThroughWindow *_win;      // 窗口A（可穿透）
    UIView      *_contentView;      // 全屏容器（承载遮罩/边框图层）
    CAShapeLayer *_dimLayer;        // 半透明黑遮罩（evenOdd 镂空）
    CAShapeLayer *_borderLayer;     // 描边（局部选区 / 长截图框）
    CAShapeLayer *_handleLayer;     // v5.6：缩放手柄（4 角 + 4 边中点的小方块）

    // ---- 框选模式：顶部提示 + 底部三按钮 ----
    UILabel  *_hintLabel;           // 顶部提示
    UIButton *_btnNormal;           // 正常截图
    UIButton *_btnLong;             // 长截图
    UIButton *_btnCancel;           // 取消
    UIButton *_confirmBtn;          // v5.6：✓完成（确认选区、弹出功能面板）

    // ---- 长截图：框外 2 按钮 + 关闭 + 计数 ----
    UIButton *_saveLongBtn;         // 保存长图
    UIButton *_copyLongBtn;         // 复制
    UIButton *_closeBtn;            // 关闭（框右上角）
    UILabel  *_longCountLabel;      // 已采集帧数

    // ---- v5.3：长截图算法（精确读offset / 自动SAD；v5.11 移除手动模式）----
    NSInteger _lsAlgo;              // 0=自动滚动(驱动App滚动) 1=自动(SAD)
    UIButton *_modeToggleBtn;       // 框左上角「模式:自动滚动/自动(SAD)」切换
    UIButton *_nextBtn;             // 框左下「下一屏」（仅手动模式显示）
    UIButton *_startBtn;            // 框顶部「▶开始采集」（仅精确模式显示）
    BOOL     _lsActive;             // 自动滚动模式已 arm、正在接收 App 偏移抓帧
    CGFloat  _lsPrevOffsetY;        // 上一帧 contentOffset.y（点），首帧为 NAN
    NSTimer *_lsWatchdog;           // 精确模式无响应→回退自动的看门狗

    // v5.13：SAD 自动抓帧自适应间隔（随滚动速度调节，慢滚多等、快滚抓紧）
    NSTimeInterval _lsInterval;
    NSTimeInterval _lsLastCastTime;
    BOOL          _forceTick;       // 外部强制立即抓一帧（保存/复制前补末屏）

    // ---- 状态 ----
    XZMaskMode   _mode;
    XZDragTarget _drag;
    CGRect  _cropRect;              // 当前选区（屏幕点坐标）
    BOOL    _hasCrop;
    CGPoint _panStart;              // 画框起点
    CGPoint _panGrab;               // 拖动时手指在框内的相对偏移
    XZResizeMask _resizeMask;       // v5.6：当前缩放手柄位掩码
    BOOL     _didDrawSelection;     // v5.8：本次手势从空白拖出新选区（松手即弹面板用）

    CGRect   _longFrameRect;        // 长截图截取框（屏幕坐标，全屏宽）
    NSTimer *_captureTimer;         // 自动抓帧定时器
    BOOL     _capturing;            // 抓帧防重入

    // ---- v4.8：长截图滑动检测 ----
    UIImage  *_entryTile;           // 进入长截图时的基准帧（未滑动前的画面）
    UIImage  *_lastAddedTile;       // 最近一次已采集的帧（用于检测是否真的滑动了）
    UIImage  *_lastLsTile;          // v5.8：精确模式上一帧（SAD 核对真实重叠用）

    // ---- v4.8：局部截图原地面板 ----
    UIImage  *_cropImage;           // 局部截图裁剪结果
    UIView   *_localPanel;          // 选区下方原地弹出的两排功能面板
    BOOL      _editingPanel;        // 面板已弹出（禁用框选手势 / 隐藏三按钮）
    UIViewController *_hostVC;      // 承载 OCR/翻译等结果弹窗的 rootVC（挂在窗口A）

    // ---- v4.9：面板独立窗口（同步渲染，消除闪现/延迟）----
    XZPassThroughWindow *_panelWin;  // 承载功能面板的独立 UIWindow（抓屏隐藏窗口A时面板不受影响）
    UIViewController *_panelVC;     // 面板窗口的 rootVC（结果弹窗 present 落点）
    UILabel  *_snapCountLabel;       // v6.06：面板顶部「已截 N 张」标签（实时刷新）
    BOOL     _showing;               // v6.06：是否正在显示（供音量+电源键钩子去重）
    CGRect          _cropScreenRect; // 当前选区屏幕坐标（后台抓屏裁剪用）
    UIScrollView    *_panelScroll;   // 本地面板循环滑动（delegate 方式，tag=9902）
    UIImage         *_originalCropImage; // 首次裁剪原图，供「还原」用
    CGFloat         _localSetW;      // 单排循环：一组按钮总跨度
    BOOL            _rotateLongPressed; // 区分旋转点按(90°)/长按(180°)
    UIImageView     *_previewIV;    // v6.05：左侧预览缩略图（旋转/还原/压缩后实时更新）
}

#pragma mark - 单例 / 生命周期

+ (instancetype)sharedInstance {
    static MaskCropWindow *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[MaskCropWindow alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = XZMaskModeCrop;
        _drag = XZDragNone;
        _cropRect = CGRectZero;
        _hasCrop = NO;
        _capturing = NO;
        _lsAlgo = 0;                // v5.17：默认自动滚动(精确)模式 —— 微信/QQ 0 重叠；其它 App 可切「自动(SAD)」
    }
    return self;
}

#pragma mark - 建窗

- (void)show {
    // 重复点按控制中心：先完整销毁旧窗口，避免叠加泄漏
    if (_win) [self dismiss];
    [[LongShotCapture sharedInstance] reset];
    _showing = YES;   // v6.06：标记正在显示，供音量+电源键钩子去重

    CGRect scr = [UIScreen mainScreen].bounds;

    _win = [[XZPassThroughWindow alloc] initWithFrame:scr];
    // v5.25.6: 同 EditToolbarWindow, 降到 Alert-10, 避免 OCR/弹窗被遮罩盖住 + 抬层 hack 残留关不掉
    _win.windowLevel = UIWindowLevelAlert - 10;
    _win.backgroundColor = [UIColor clearColor];
    _win.userInteractionEnabled = YES;
    _win.passthrough = NO;                       // 框选阶段要吃下全屏拖拽
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    // v4.8：挂一个透明 rootViewController，供 OCR/翻译/识别结果弹窗 present 落点
    //       （userInteractionEnabled=NO 不拦截手势，仍由 _contentView 接收拖拽）
    _hostVC = [[UIViewController alloc] init];
    _hostVC.view.backgroundColor = [UIColor clearColor];
    _hostVC.view.userInteractionEnabled = NO;
    _win.rootViewController = _hostVC;

    _contentView = [[UIView alloc] initWithFrame:_win.bounds];
    _contentView.backgroundColor = [UIColor clearColor];
    [_win addSubview:_contentView];

    // 镂空遮罩：全屏路径 + 选区路径，evenOdd → 选区内透出底层真实 App 画面
    _dimLayer = [CAShapeLayer layer];
    _dimLayer.fillColor = [UIColor colorWithWhite:0 alpha:0.5].CGColor;
    _dimLayer.fillRule = kCAFillRuleEvenOdd;
    _dimLayer.frame = _win.bounds;
    [_contentView.layer addSublayer:_dimLayer];

    // 描边
    _borderLayer = [CAShapeLayer layer];
    _borderLayer.strokeColor = [UIColor systemBlueColor].CGColor;
    _borderLayer.lineWidth = 2.0;
    _borderLayer.fillColor = [UIColor clearColor].CGColor;
    _borderLayer.frame = _win.bounds;
    [_contentView.layer addSublayer:_borderLayer];

    // v5.6：缩放手柄图层（8 个小方块，覆盖在描边之上）
    _handleLayer = [CAShapeLayer layer];
    _handleLayer.fillColor = [UIColor whiteColor].CGColor;
    _handleLayer.strokeColor = [UIColor systemBlueColor].CGColor;
    _handleLayer.lineWidth = 1.5;
    _handleLayer.frame = _win.bounds;
    _handleLayer.hidden = YES;
    [_contentView.layer addSublayer:_handleLayer];

    // 框选手势：框外 = 重画，框内 = 整体移动（不限指数，配合 pinch 同时识别）
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleCropPan:)];
    pan.delegate = self;
    [_contentView addGestureRecognizer:pan];

    // v5.15 / v5.19：双指捏合等比缩放选区（围绕选区中心）。
    //               关键是让 pan 与 pinch 同时识别 —— pan 处理单指移动/拖角，pinch 接管双指缩放。
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(pinchCrop:)];
    pinch.delegate = self;
    [_contentView addGestureRecognizer:pinch];

    [self installCropUI];
    [self installLongControls];
    [self registerLsCapture];
    [self setMode:XZMaskModeCrop];
    [self refreshChrome];

    _win.hidden = NO;
    // v6.21：呼出截图时的一次性引导 toast 已取消（用户反馈不需要）
    NSLog(@"[SuperScreenshot] mask window A shown (v4.8)");
}

// v5.19：允许 pan 与 pinch 同时识别 —— 单指走 pan（拖框/拉角），双指走 pinch（缩放）。
//         没有这一句时，UIGestureRecognizer 默认让先识别的手势独占，会出现"双指不缩放"或"单指也跑缩放"的问题。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)refreshChrome {
    if (!_win) return;

    if (_mode == XZMaskModeCrop) {
        if (_editingPanel) {
            // v4.8：局部截图原地面板模式 —— 隐藏框选三按钮，仅保留选区边框 + 面板
            _hintLabel.hidden   = YES;
            _btnNormal.hidden   = YES;
            _btnLong.hidden     = YES;
            _btnCancel.hidden   = YES;
            _confirmBtn.hidden  = YES;           // v5.6：面板阶段隐藏完成按钮
            _saveLongBtn.hidden = YES;
            _copyLongBtn.hidden = YES;
            _closeBtn.hidden    = YES;
            _longCountLabel.hidden = YES;
            _modeToggleBtn.hidden = YES;
            _nextBtn.hidden      = YES;
            _startBtn.hidden     = YES;
            _win.passthrough      = NO;          // 面板阶段吃下全屏触摸
            _contentView.userInteractionEnabled = YES;
            _borderLayer.hidden = NO;            // 选区边框仍然可见
            [self updateMask];
        } else {
            _hintLabel.hidden   = NO;
            _btnNormal.hidden   = NO;
            _btnLong.hidden     = NO;
            _btnCancel.hidden   = NO;
            _confirmBtn.hidden  = YES;     // v5.12：拖选松手直接弹面板，「✓完成」已冗余，永远隐藏
            _saveLongBtn.hidden = YES;
            _copyLongBtn.hidden = YES;
            _closeBtn.hidden    = YES;
            _longCountLabel.hidden = YES;
            _modeToggleBtn.hidden = YES;
            _nextBtn.hidden      = YES;
            _startBtn.hidden     = YES;
            _win.passthrough      = NO;          // 框选阶段吃下全屏拖拽
            _contentView.userInteractionEnabled = YES;
            _borderLayer.hidden = !_hasCrop;
            [self updateMask];
            [_win bringSubviewToFront:_hintLabel];
            [_win bringSubviewToFront:_btnNormal];
            [_win bringSubviewToFront:_btnLong];
            [_win bringSubviewToFront:_btnCancel];
            [_win bringSubviewToFront:_confirmBtn];   // v5.6
        }
    } else {
        _hintLabel.hidden   = YES;
        _btnNormal.hidden   = YES;
        _btnLong.hidden     = YES;
        _btnCancel.hidden   = YES;
        _confirmBtn.hidden  = YES;   // v5.6
        _saveLongBtn.hidden = NO;
        _copyLongBtn.hidden = NO;
        _closeBtn.hidden    = NO;
        _longCountLabel.hidden = NO;
        _modeToggleBtn.hidden = NO;             // v5.3：模式切换常驻
        [_modeToggleBtn setTitle:(_lsAlgo == 1 ? @"模式:自动(SAD)" : @"模式:自动滚动")
                         forState:UIControlStateNormal];
        _nextBtn.hidden      = YES;   // v5.11：已移除「手动」模式，下一屏按钮永不再显示
        _startBtn.hidden     = (_lsAlgo != 0); // 仅精确模式显示
        _win.passthrough      = YES;             // 长截图：框内穿透、框外吞咽
        _win.passRect        = _longFrameRect;   // 框内坐标 → 穿透给 App
        _contentView.userInteractionEnabled = NO; // 不拦截手势，交给 hitTest 决定
        _borderLayer.hidden = NO;
        [self updateMask];
        [self updateLongCounter];
        [_win bringSubviewToFront:_saveLongBtn];
        [_win bringSubviewToFront:_copyLongBtn];
        [_win bringSubviewToFront:_closeBtn];
        [_win bringSubviewToFront:_longCountLabel];
        [_win bringSubviewToFront:_modeToggleBtn];
        [_win bringSubviewToFront:_nextBtn];
        [_win bringSubviewToFront:_startBtn];
    }
    [_win layoutIfNeeded];
}

- (void)dismiss {
    _showing = NO;    // v6.06：清除显示标记
    _mode = XZMaskModeCrop;
    _drag = XZDragNone;
    _hasCrop = NO;
    _cropRect = CGRectZero;
    _capturing = NO;
    _editingPanel = NO;
    _entryTile = nil;
    _lastAddedTile = nil;
    if (_lsActive) { _lsActive = NO; [self stopLsWatchdog]; notify_post(SuperScreenshot_LS_DISARM); }
    _lsAlgo = 0;               // v5.17：退出长截图复位为自动滚动(精确)模式
    _modeToggleBtn = nil;      // v5.2
    _nextBtn = nil;            // v5.2
    _startBtn = nil;           // v5.3
    _cropImage = nil;
    _cropScreenRect = CGRectZero;
    _localPanel = nil;
    if (_closeBtn) { [_closeBtn removeFromSuperview]; _closeBtn = nil; }
    if (_panelWin) {
        _panelWin.hidden = YES;
        _panelWin.rootViewController = nil;
        _panelWin = nil;          // 交还内存（防 SpringBoard 泄漏 / respring）
    }
    _panelVC = nil;

    [self stopCaptureTimer];

    if (_win) {
        _win.hidden = YES;          // UIWindow 必须先隐藏再从视图树摘除，直接置 nil 会留下可见层
        _win.rootViewController = nil;
        _win = nil;                 // 置空，交还内存（防 SpringBoard 泄漏 / respring）
    }
    _hostVC = nil;
    _contentView = nil;
    _dimLayer = nil;
    _borderLayer = nil;
    _handleLayer = nil;          // v5.6

    _hintLabel = nil;
    _btnNormal = _btnLong = _btnCancel = nil;
    _confirmBtn = nil;           // v5.6
    _saveLongBtn = _copyLongBtn = _closeBtn = nil;
    _longCountLabel = nil;

    [[LongShotCapture sharedInstance] reset];
    NSLog(@"[SuperScreenshot] mask window A destroyed");
}

- (CGRect)cropRect { return _cropRect; }
- (BOOL)hasSelection { return _hasCrop && _cropRect.size.width >= kMinCrop && _cropRect.size.height >= kMinCrop; }

#pragma mark - 框选模式 UI（顶部提示 + 底部三按钮）

// v5.25.5：图标 + 文字 紧凑按钮（用于底部操作条：缩小、图标化、居中）
- (UIButton *)makeIconButton:(NSString *)title icon:(NSString *)iconName bg:(UIColor *)bg action:(SEL)sel {
    static const CGFloat bw = 84.0, bh = 58.0;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 14;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((bw - 26) / 2, 7, 26, 26)];
    UIImage *ic = [Common systemIcon:iconName];
    if (!ic) ic = [Common systemIcon:@"circle"];
    iv.image = ic;
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [b addSubview:iv];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 37, bw, 16)];
    lb.text = title;
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];

    [_win addSubview:b];
    [_win addInteractiveView:b];
    return b;
}

- (UIButton *)makeBarButton:(NSString *)title bg:(UIColor *)bg action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.8;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:b];
    [_win addInteractiveView:b];
    return b;
}

- (void)installCropUI {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safe.top, scr.size.width, 22)];
    _hintLabel.textColor = [UIColor whiteColor];
    _hintLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.backgroundColor = [UIColor clearColor];
    _hintLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    _hintLabel.shadowOffset = CGSizeMake(0, 1);
    _hintLabel.text = @"拖框选区域，可拖动/缩放调整，点「✓完成」编辑 · 底部可切「正常/长截图」";
    [_win addSubview:_hintLabel];
    [_win addInteractiveView:_hintLabel];

    // v5.25.5：底部三按钮改为紧凑图标按钮，居中排列（不再全宽拉满、不再超大字）
    CGFloat bw = 84.0, gap = 14.0, bh = 58.0;
    CGFloat by = scr.size.height - safe.bottom - bh - 10;
    CGFloat totalW = bw * 3 + gap * 2;
    CGFloat x = (scr.size.width - totalW) / 2.0;   // 居中
    _btnNormal = [self makeIconButton:@"正常截图" icon:@"camera.viewfinder" bg:[UIColor systemBlueColor]   action:@selector(onNormalShot)];
    _btnNormal.frame = CGRectMake(x, by, bw, bh); x += bw + gap;
    _btnLong   = [self makeIconButton:@"长截图"   icon:@"doc.richtext"      bg:[UIColor systemYellowColor] action:@selector(onLongShot)];
    _btnLong.frame = CGRectMake(x, by, bw, bh); x += bw + gap;
    _btnCancel = [self makeIconButton:@"取消"     icon:@"xmark.circle.fill" bg:[UIColor systemGrayColor]   action:@selector(onCancel)];
    _btnCancel.frame = CGRectMake(x, by, bw, bh);

    // v5.6：✓完成 —— 确认当前选区并弹出功能面板（之前是松手即弹，无法调整选框）
    _confirmBtn = [self makeBarButton:@"✓ 完成" bg:[UIColor systemGreenColor] action:@selector(onConfirmCrop)];
    _confirmBtn.frame = CGRectMake(scr.size.width - 12 - 72, safe.top + 4, 72, 36);
    _confirmBtn.hidden = YES;   // 有选区后才显示
}

#pragma mark - 长截图 UI（全屏宽框 + 框外 2 按钮 + 关闭）

- (void)installLongControls {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    // 长截图截取框（全屏宽，上下留白给关闭按钮 / 底部两按钮）
    CGFloat top = safe.top + kFrameTopInset;
    CGFloat bot = safe.bottom + kFrameBotInset;
    _longFrameRect = CGRectMake(0, top,
                                scr.size.width,
                                MAX(60, scr.size.height - top - bot));

    // 关闭按钮：框右上角，置于框【上方暗色区】，保证可点（不落入 passRect）
    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(scr.size.width - 52, top - 38, 40, 40);
    [_closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    _closeBtn.tintColor = [UIColor whiteColor];
    _closeBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    _closeBtn.layer.cornerRadius = 20;
    [_closeBtn addTarget:self action:@selector(onLongClose) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:_closeBtn];
    [_win addInteractiveView:_closeBtn];

    // 框外底部两按钮：保存长图 / 复制
    CGFloat pad = 16.0, gap = 12.0;
    CGFloat by = scr.size.height - safe.bottom - 76;
    CGFloat bw = (scr.size.width - pad * 2 - gap) / 2.0;
    _saveLongBtn = [self makeBarButton:@"保存长图" bg:[UIColor systemGreenColor] action:@selector(onSaveLong)];
    _saveLongBtn.frame = CGRectMake(pad, by, bw, kButtonH);
    _copyLongBtn = [self makeBarButton:@"复制"     bg:[UIColor systemBlueColor]   action:@selector(onCopyLong)];
    _copyLongBtn.frame = CGRectMake(pad + bw + gap, by, bw, kButtonH);

    // 计数提示（框底下方暗色区）
    _longCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, _longFrameRect.origin.y + _longFrameRect.size.height + 8,
                                                                scr.size.width, 18)];
    _longCountLabel.textColor = [UIColor whiteColor];
    _longCountLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _longCountLabel.textAlignment = NSTextAlignmentCenter;
    _longCountLabel.text = @"已采集 0 屏";
    [_win addSubview:_longCountLabel];
    [_win addInteractiveView:_longCountLabel];

    // v5.2：模式切换（框左上角暗色区）—— 自动 / 手动
    _modeToggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _modeToggleBtn.frame = CGRectMake(12, top - 38, 100, 40);
    _modeToggleBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    _modeToggleBtn.layer.cornerRadius = 10;
    [_modeToggleBtn setTitle:@"模式:自动滚动" forState:UIControlStateNormal];
    [_modeToggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _modeToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_modeToggleBtn addTarget:self action:@selector(onToggleMode) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:_modeToggleBtn];
    [_win addInteractiveView:_modeToggleBtn];

    // v5.2：手动模式「下一屏」按钮（底部保存/复制上方一行，仅手动模式显示）
    _nextBtn = [self makeBarButton:@"下一屏 ▼" bg:[UIColor systemOrangeColor] action:@selector(onNextScreen)];
    _nextBtn.frame = CGRectMake(pad, by - (kButtonH + 10), scr.size.width - pad * 2, kButtonH);
    _nextBtn.hidden = YES;   // 默认精确模式隐藏
    [_win addSubview:_nextBtn];
    [_win addInteractiveView:_nextBtn];

    // v5.3：精确模式「开始采集」按钮（框顶部，模式切换右侧；仅精确模式显示）
    _startBtn = [self makeBarButton:@"▶ 开始采集" bg:[UIColor systemGreenColor] action:@selector(onStartLs)];
    _startBtn.frame = CGRectMake(120, top - 38, scr.size.width - 120 - 52 - 8, 40);
    _startBtn.hidden = YES;   // 由 refreshChrome 按算法控制
    [_win addSubview:_startBtn];
    [_win addInteractiveView:_startBtn];
}

#pragma mark - v5.2：自动 / 手动模式切换

// v5.11：只保留两种自动模式（0 自动滚动 / 1 自动SAD），移除了「手动」模式
- (void)onToggleMode {
    _lsAlgo = (_lsAlgo + 1) % 2;   // 0 自动滚动 → 1 自动(SAD) → 0
    [self refreshChrome];
    if (_lsAlgo == 0) {
        [self stopCaptureTimer];
        [_startBtn setTitle:@"▶ 开始采集" forState:UIControlStateNormal];
        _startBtn.enabled = YES;
        [Common toast:@"自动滚动：框好区域后点【开始采集】，自动逐屏滚到底"];
    } else if (_lsAlgo == 1) {
        [self stopCaptureTimer];
        [self startCaptureTimer];
        [Common toast:@"自动(SAD)模式：框内手动滑动自动采集"];
    }
}

// v5.2：手动采集一屏（用户主动点【下一屏】）
- (void)onNextScreen {
    if (!_win || _mode != XZMaskModeLong) return;
    BOOL borderHidden = _borderLayer.hidden;
    _borderLayer.hidden = YES;                 // 抓帧时去掉边框，避免截进长图
    UIImage *screen = [ImageUtils captureScreen];
    _borderLayer.hidden = borderHidden;
    if (!screen) { [Common toast:@"抓屏失败"]; return; }

    CGRect clip = CGRectInset(_longFrameRect, 3, 3);
    UIImage *tile = [ImageUtils cropImage:screen screenRect:clip];
    if (!tile) { [Common toast:@"裁剪失败"]; return; }

    // 与上一屏完全相同（手滑连点没动）→ 忽略
    if (_lastAddedTile && ![self tile:tile differsFrom:_lastAddedTile]) {
        [Common toast:@"和上一屏一样，未采集"];
        return;
    }
    BOOL accepted = [[LongShotCapture sharedInstance] addManualFrame:tile];
    if (accepted) {
        _lastAddedTile = tile;
        [self updateLongCounter];
        [Common toast:@"已采集一屏"];
    } else {
        [Common toast:@"这屏和上一屏重叠太多，跳过"];
    }
}

#pragma mark - v5.3：精确模式（注入 App 读真实 contentOffset）

- (void)registerLsCapture {
    if (g_lsReg) return;
    notify_register_check(SuperScreenshot_LS_OFFSET, &g_offTok);
    notify_register_check(SuperScreenshot_LS_REGIONH, &g_regionTok);
    notify_register_dispatch(SuperScreenshot_LS_CAPTURE, &g_capTok, dispatch_get_main_queue(), ^(int t) {
        [[MaskCropWindow sharedInstance] onLsCapture];
    });
    notify_register_dispatch(SuperScreenshot_LS_DONE, &g_doneTok, dispatch_get_main_queue(), ^(int t) {
        [[MaskCropWindow sharedInstance] onLsDone];
    });
    g_lsReg = YES;
    NSLog(@"[SuperScreenshot] SB 自动滚动模式 capture/done 通知已注册");
}

- (void)stopLsWatchdog {
    if (_lsWatchdog) { [_lsWatchdog invalidate]; _lsWatchdog = nil; }
}

// 用户点【开始采集】：arm 前台 App，开始按真实滚动量逐屏精确采集
- (void)onStartLs {
    if (!_win || _mode != XZMaskModeLong || _lsActive) return;
    _lsActive = YES;
    _lsPrevOffsetY = (CGFloat)NAN;
    _lastLsTile = nil;                           // v5.8：新采集，清空上一帧
    [self stopCaptureTimer];
    [[LongShotCapture sharedInstance] reset];
    [self updateLongCounter];

    // 把采集区域高度(点)告诉 App
    CGFloat regionH = _longFrameRect.size.height;
    uint64_t rh = (uint64_t)(round(regionH * 100.0));
    notify_set_state(g_regionTok, rh);
    notify_post(SuperScreenshot_LS_ARM);

    [_startBtn setTitle:@"采集中…" forState:UIControlStateNormal];
    _startBtn.enabled = NO;

    // 看门狗：2.5s 内未收到任何帧（非注入 App）→ 回退自动(SAD)
    [self stopLsWatchdog];
    _lsWatchdog = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                 target:self
                                               selector:@selector(lsWatchdogFired)
                                               userInfo:nil
                                                repeats:NO];
    [Common toast:@"自动滚动采集中…（你不用动手）"];
}

- (void)lsWatchdogFired {
    if (!_lsActive) return;
    if ([[LongShotCapture sharedInstance] frameCount] == 0) {
        // v5.11：当前 App 未注入时静默回退自动(SAD)，不再弹警告提示打断用户
        _lsActive = NO;
        _lsAlgo = 1;
        [_startBtn setTitle:@"▶ 开始采集" forState:UIControlStateNormal];
        _startBtn.enabled = YES;
        [self refreshChrome];
        [self startCaptureTimer];
    }
}

// App 通知：抓一帧（偏移已写入 notify 状态）
- (void)onLsCapture {
    if (!_win || _mode != XZMaskModeLong || !_lsActive) return;

    uint64_t st = 0;
    notify_get_state(g_offTok, &st);
    CGFloat offset = (CGFloat)st / 100.0;

    BOOL borderHidden = _borderLayer.hidden;
    _borderLayer.hidden = YES;                 // 抓帧时去掉边框，避免被截进长图
    UIImage *screen = [ImageUtils captureScreen];
    _borderLayer.hidden = borderHidden;
    if (!screen) return;

    CGRect clip = CGRectInset(_longFrameRect, 3, 3);
    UIImage *tile = [ImageUtils cropImage:screen screenRect:clip];
    if (!tile) return;

    if (isnan(_lsPrevOffsetY)) {
        // 第 1 屏：无增量，作为基准
        [[LongShotCapture sharedInstance] addExactFrame:tile overlapPoints:0];
        _lsPrevOffsetY = offset;
        _lastLsTile = tile;
        [self stopLsWatchdog];
        _startBtn.hidden = YES;                 // 已开工，隐藏开始按钮
        [self updateLongCounter];
        [Common toast:@"已采第1屏，继续下滑"];
        return;
    }

    CGFloat delta = offset - _lsPrevOffsetY;    // 真实滚动增量（点，来自 App contentOffset）
    _lsPrevOffsetY = offset;
    if (delta <= 1.0f) return;                  // 基本没滑，仅更新基准

    CGFloat regionH = tile.size.height;         // 采集区域高（点）
    CGFloat offsetOv = regionH - delta;         // 偏移派生重叠（点）

    // v5.9：重叠取值优先信任「像素级 SAD 真实重叠」而不取 MAX。
    //        取 MAX 会让重叠被高估 → 过度去重 → 中间缺内容/留白带；
    //        SAD 是两帧实际像素一致区域，最接近真实重叠。
    //        聊天 App 上滑预载会夸大 contentOffset 增量 → offsetOv 偏小，
    //        SAD 恰好纠正这一点。仅当 SAD 不可靠时才回退 offsetOv。
    CGFloat scale = (tile.scale > 0) ? tile.scale : ([UIScreen mainScreen].scale > 0 ? [UIScreen mainScreen].scale : 2.0);
    CGFloat chosenOv = offsetOv;
    if (_lastLsTile && _lastLsTile.CGImage) {
        BOOL conf = NO;
        CGFloat sadPx = [[LongShotCapture sharedInstance] sadOverlapPxFromLast:_lastLsTile cur:tile confident:&conf];
        if (conf) {
            CGFloat sadOv = sadPx / scale;      // 像素→点
            chosenOv = sadOv;
        }
    }
    // 下限改为极小的 3%（不再强制吃掉 18% 造成丢内容），上限 90%
    CGFloat lo = regionH * 0.03f, hi = regionH * 0.90f;
    if (chosenOv < lo) chosenOv = lo;
    if (chosenOv > hi) chosenOv = hi;
    NSLog(@"[SuperScreenshot] 精确帧重叠核对：offsetOv=%.1fpt chosen=%.1fpt", offsetOv, chosenOv);

    BOOL accepted = [[LongShotCapture sharedInstance] addExactFrame:tile overlapPoints:chosenOv];
    if (accepted) {
        _lastLsTile = tile;                      // v5.8：接受帧后更新上一帧供下轮 SAD 核对
        [self updateLongCounter];
    }
}

// App 通知：已自动滚到底，采集结束。标记完成，等待用户点保存。
- (void)onLsDone {
    if (!_win || _mode != XZMaskModeLong) return;
    if (!_lsActive) return;
    _lsActive = NO;
    [self stopLsWatchdog];
    [Common toast:@"已到底，可点【保存长图】"];
    NSLog(@"[SuperScreenshot] SB：自动滚动采集结束，共 %ld 屏", (long)[[LongShotCapture sharedInstance] frameCount]);
}

// 保存/复制前：若精确模式仍激活，先 disarm 让 App 补抓末屏，再拼接
- (void)lsDisarmAndProceed:(void (^)(void))block {
    if (_lsActive) {
        _lsActive = NO;
        [self stopLsWatchdog];
        notify_post(SuperScreenshot_LS_DISARM);
        // 等待 App 补抓最后一屏（~0.35s）后再拼接
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), block);
    } else {
        block();
    }
}

#pragma mark - 模式切换

- (void)setMode:(XZMaskMode)mode {
    _mode = mode;
    if (mode == XZMaskModeLong) {
        _entryTile = nil;
        _lastAddedTile = nil;
        [self refreshChrome];
        if (_lsAlgo == 1) {
            [self startCaptureTimer];
            [Common toast:@"长截图·自动(SAD)：框内从顶部向下滑动，自动采集"];
        } else {
            [self stopCaptureTimer];   // 精确模式：等用户点【开始采集】再 arm
            [Common toast:@"长截图·自动滚动：先滚到顶，框好区域点【开始采集】，再下滑"];
        }
    } else {
        [self stopCaptureTimer];
        [self refreshChrome];
    }
}

- (void)startCaptureTimer {
    [self stopCaptureTimer];
    // v5.17：以设置里的「每帧间隔」为起点（限 0.1~1.0s，避免 0.05 帧过密造成大量重叠重复），
    //        随后仍随滚动速度自适应（重叠过大自动拉长、过小自动收紧）。
    CGFloat iv = [[Common stringPref:XZ_KEY_LONG_INTERVAL default:@"0.15"] doubleValue];
    if (!(iv >= 0.1)) iv = 0.15; else if (iv > 1.0) iv = 1.0;
    _lsInterval = iv;
    _lsLastCastTime = 0;
    _forceTick = NO;
    _captureTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                    target:self
                                                  selector:@selector(longCaptureTick)
                                                  userInfo:nil
                                                   repeats:YES];
    _forceTick = YES;
    [self longCaptureTick];   // 立即采一帧作为「顶部基准帧」
}

- (void)stopCaptureTimer {
    if (_captureTimer) { [_captureTimer invalidate]; _captureTimer = nil; }
}

- (void)updateLongCounter {
    NSInteger n = [[LongShotCapture sharedInstance] frameCount];
    if (n == 0) {
        // v4.8：未滑动时不显示屏数 / 预计 PT，仅提示
        _longCountLabel.text = @"未滑动，未开始采集";
        return;
    }
    CGFloat est = [[LongShotCapture sharedInstance] estimatedHeight];
    _longCountLabel.text = [NSString stringWithFormat:@"已采集 %ld 屏 · 预计长图约 %.0f pt", (long)n, est];
}

#pragma mark - 手势（框选）

- (void)handleCropPan:(UIPanGestureRecognizer *)pan {
    if (_mode != XZMaskModeCrop) return;
    // v5.10：面板弹出后【不禁用】框选手势——允许用户拖动选框进行整体移动/缩放，
    //        移动后同步面板位置并重新裁剪。只有拖画新框时才重建面板。

    CGPoint loc = [pan locationInView:_contentView];
    CGRect b = _contentView.bounds;
    // v6.05：局部截图允许选区一直拖到屏幕最顶端(y=0)，从而能框选到状态栏/刘海上方
    //        的信号、电量区域（captureScreen 抓的是整屏，含状态栏，裁剪自然包含）。
    CGFloat topLimit = 0;

    // v5.20：当用户用 ≥2 指时让位给 pinch（缩放），避免 pan 的 loc 退化成双指质心后
    //         把 _cropRect 重置成 0,0 让 pinch 拿到 hasSelection=NO 而失效。
    if (pan.numberOfTouches > 1) {
        if (pan.state == UIGestureRecognizerStateBegan) _drag = XZDragNone;
        return;
    }

    if (pan.state == UIGestureRecognizerStateBegan) {
        _didDrawSelection = NO;
        XZResizeMask m = [self hasSelection] ? [self resizeMaskAtPoint:loc inRect:_cropRect] : XZResizeNone;
        if (m) {
            _drag = XZDragResize;
            _resizeMask = m;          // v5.6：拖手柄缩放
        } else {
            // v5.24.0: 任意点拖动都视为「整体平移」, 框外/框内空白统一行为. 不再有「框外重选」分支.
            if ([self hasSelection]) {
                _drag = XZDragMove;
                // v5.24.0: 以「框中心」为锚点 (而不是框左上角), 框外点拖时框中心跟随手指,
                // 不会出现「框跳到手指位置」; 框内点拖时也跟手指走, 跟旧版行为等价.
                CGPoint center = CGPointMake(CGRectGetMidX(_cropRect), CGRectGetMidY(_cropRect));
                _panGrab = CGPointMake(loc.x - center.x, loc.y - center.y);
            } else {
                // 还没选过任何区: 第一次拖动才进入「画框」模式, 画完保持选区, 之后所有拖动都平移
                _drag = XZDragDraw;
                _panStart = loc;
                _cropRect = CGRectMake(loc.x, loc.y, 0, 0);
                _hasCrop = YES;
                _didDrawSelection = YES;
            }
        }
        NSLog(@"[SuperScreenshot] handleCropPan begin loc=(%.1f,%.1f) sel=%d rect=%@ drag=%@ panel=%d",
              loc.x, loc.y, [self hasSelection], NSStringFromCGRect(_cropRect),
              @(_drag), _editingPanel ? 1 : 0);
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (_drag == XZDragDraw) {
            CGFloat x = MIN(_panStart.x, loc.x);
            CGFloat y = MIN(_panStart.y, loc.y);
            CGFloat w = fabs(loc.x - _panStart.x);
            CGFloat h = fabs(loc.y - _panStart.y);
            x = MAX(0, x); y = MAX(topLimit, y);
            w = MIN(w, b.size.width - x);
            h = MIN(h, b.size.height - y);
            _cropRect = CGRectMake(x, y, MAX(0, w), MAX(0, h));
        } else if (_drag == XZDragMove) {
            // v5.24.0: 框中心跟随手指. newCenter = loc - _panGrab (即 oldCenter), 再夹边.
            CGFloat cx = loc.x - _panGrab.x;
            CGFloat cy = loc.y - _panGrab.y;
            CGFloat w = _cropRect.size.width, h = _cropRect.size.height;
            CGFloat nx = cx - w / 2.0;
            CGFloat ny = cy - h / 2.0;
            nx = MAX(0, MIN(nx, b.size.width - w));
            ny = MAX(topLimit, MIN(ny, b.size.height - h));
            _cropRect = CGRectMake(nx, ny, w, h);
        } else if (_drag == XZDragResize) {   // v5.6：拖边/角缩放
            CGFloat left  = _cropRect.origin.x, top = _cropRect.origin.y;
            CGFloat right = left + _cropRect.size.width, bot = top + _cropRect.size.height;
            CGFloat minS = kMinCrop;
            if (_resizeMask & XZResizeLeft)   left  = MIN(loc.x, right - minS);
            if (_resizeMask & XZResizeRight)  right = MAX(loc.x, left + minS);
            if (_resizeMask & XZResizeTop)    top   = MIN(loc.y, bot - minS);
            if (_resizeMask & XZResizeBottom) bot   = MAX(loc.y, top + minS);
            left  = MAX(0, left);
            right = MIN(b.size.width, right);
            top   = MAX(0, top);
            bot   = MIN(b.size.height, bot);
            if (right - left < minS) { if (left <= 0) right = minS; else left = right - minS; }
            if (bot - top  < minS) { if (top  <= 0) bot  = minS; else top  = bot  - minS; }
            _cropRect = CGRectMake(left, top, right - left, bot - top);
        }
        [self updateMask];
        // v5.12：拖选过程中【实时】把功能面板跟着平移，实现「选区与面板一起移动」
        if (_editingPanel && (_drag == XZDragMove || _drag == XZDragResize)) {
            [self layoutLocalPanelForCropLive];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        _drag = XZDragNone;
        // v5.10：拖选完成【直接】弹出功能面板（无需再点「✓完成」）；
        //        若是在面板模式下重新画新框也一并重建面板；只是移动/缩放选框则同步面板并重裁。
        if (_didDrawSelection && [self hasSelection]) {
            _didDrawSelection = NO;
            [self presentLocalPanelForRect:_cropRect];
        } else {
            if (_cropRect.size.width < kMinCrop || _cropRect.size.height < kMinCrop) {
                _hasCrop = NO;
                _cropRect = CGRectZero;
            }
            _didDrawSelection = NO;
            [self updateMask];
            [self refreshChrome];
            if (_editingPanel) [self syncPanelAfterCropRectChange];
        }
    }
}

// v5.15：双指捏合 —— 围绕选区中心等比缩放选区尺寸（最小 kMinCrop、夹在屏幕内）。
//        框选/面板阶段均生效；面板阶段缩放后同步上移面板位置并重新预裁剪，选区实时跟随。
- (void)pinchCrop:(UIPinchGestureRecognizer *)g {
    if (_mode != XZMaskModeCrop || ![self hasSelection]) { return; }
    static CGFloat _cropPinchLast = 1.0;
    if (g.state == UIGestureRecognizerStateBegan) {
        _cropPinchLast = 1.0;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat d = g.scale / MAX(0.01, _cropPinchLast);
        _cropPinchLast = g.scale;
        if (!isfinite(d) || d <= 0) return;

        CGRect b = _contentView.bounds;
        CGFloat topLimit = 0;        // v6.05：局部截图选区可到屏幕顶端(含状态栏)
        CGRect r = _cropRect;
        CGFloat cx = r.origin.x + r.size.width / 2.0;
        CGFloat cy = r.origin.y + r.size.height / 2.0;
        CGFloat nw = MIN(MAX(r.size.width  * d, kMinCrop), b.size.width);
        CGFloat nh = MIN(MAX(r.size.height * d, kMinCrop), b.size.height);
        CGFloat x = MAX(0, MIN(cx - nw / 2.0, b.size.width  - nw));
        CGFloat y = MAX(topLimit, MIN(cy - nh / 2.0, b.size.height - nh));
        _cropRect = CGRectMake(x, y, nw, nh);
        [self updateMask];
        if (_editingPanel) [self layoutLocalPanelForCropLive];
        else if (_hasCrop) [self refreshChrome];
    }
}

#pragma mark - 遮罩重绘

- (void)updateMask {
    CGRect full = _contentView ? _contentView.bounds : [UIScreen mainScreen].bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:full];
    CGRect hole = (_mode == XZMaskModeLong) ? _longFrameRect : (_hasCrop ? _cropRect : CGRectZero);
    if (!CGRectIsEmpty(hole)) {
        [path appendPath:[UIBezierPath bezierPathWithRect:hole]];
    }
    _dimLayer.path = path.CGPath;

    if (!CGRectIsEmpty(hole)) {
        _borderLayer.path = [UIBezierPath bezierPathWithRect:hole].CGPath;
        _borderLayer.hidden = NO;
    } else {
        _borderLayer.hidden = YES;
    }

    // v5.6：缩放手柄（仅局部框选、有选区、未弹面板时显示）
    if (_mode == XZMaskModeCrop && _hasCrop && !_editingPanel && !CGRectIsEmpty(_cropRect)) {
        _handleLayer.hidden = NO;
        _handleLayer.path = [self handlePathForRect:_cropRect].CGPath;
    } else {
        _handleLayer.hidden = YES;
    }
}

// v5.6：8 个缩放手柄的小方块路径（4 角 + 4 边中点）
- (UIBezierPath *)handlePathForRect:(CGRect)r {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat s = 9.0;   // 手柄方块半边长
    CGFloat hw = r.size.width, hh = r.size.height;
    // 四角
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x - s,        r.origin.y - s,        s*2, s*2)]];
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x + hw - s,   r.origin.y - s,        s*2, s*2)]];
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x - s,        r.origin.y + hh - s,   s*2, s*2)]];
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x + hw - s,   r.origin.y + hh - s,   s*2, s*2)]];
    // 四边中点
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x + hw/2 - s, r.origin.y - s,        s*2, s*2)]];
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x + hw/2 - s, r.origin.y + hh - s,   s*2, s*2)]];
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x - s,        r.origin.y + hh/2 - s, s*2, s*2)]];
    [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(r.origin.x + hw - s,   r.origin.y + hh/2 - s, s*2, s*2)]];
    return p;
}

// v5.6：判断点 p 落在哪个缩放手柄上（返回位掩码；0=不在手柄上）
- (XZResizeMask)resizeMaskAtPoint:(CGPoint)p inRect:(CGRect)r {
    CGFloat ha = kHandleHit;
    CGFloat right = r.origin.x + r.size.width, bot = r.origin.y + r.size.height;
    CGFloat midX = r.origin.x + r.size.width / 2.0, midY = r.origin.y + r.size.height / 2.0;
    // 四角（优先，命中范围更大）
    if (fabs(p.x - r.origin.x) <= ha && fabs(p.y - r.origin.y) <= ha) return XZResizeLeft | XZResizeTop;
    if (fabs(p.x - right)       <= ha && fabs(p.y - r.origin.y) <= ha) return XZResizeRight | XZResizeTop;
    if (fabs(p.x - r.origin.x) <= ha && fabs(p.y - bot)       <= ha) return XZResizeLeft | XZResizeBottom;
    if (fabs(p.x - right)       <= ha && fabs(p.y - bot)       <= ha) return XZResizeRight | XZResizeBottom;
    // 四边中点
    if (fabs(p.x - midX) <= ha && fabs(p.y - r.origin.y) <= ha) return XZResizeTop;
    if (fabs(p.x - midX) <= ha && fabs(p.y - bot)       <= ha) return XZResizeBottom;
    if (fabs(p.x - r.origin.x) <= ha && fabs(p.y - midY) <= ha) return XZResizeLeft;
    if (fabs(p.x - right)     <= ha && fabs(p.y - midY) <= ha) return XZResizeRight;
    return XZResizeNone;
}

#pragma mark - 按钮动作（框选模式）

// 正常截图：仿系统电源+音量键，截整屏直接存相册，不弹编辑工具栏
- (void)onNormalShot {
    [self captureFullScreenAndSave];
}

- (void)onCancel {
    [self dismiss];
}

// v5.6：确认选区 → 弹出功能面板（不再松手即弹，先让用户在选框上自由拖动/缩放）
- (void)onConfirmCrop {
    if (![self hasSelection]) { [Common toast:@"请先拖出要截取的区域"]; return; }
    [self presentLocalPanelForRect:_cropRect];
}

#pragma mark - 按钮动作（长截图）

// 长截图：直接弹全屏宽截取框（框外区域不参与输出）
- (void)onLongShot {
    [self setMode:XZMaskModeLong];
}

// 关闭长截图框：清空已采集帧，回到框选模式（可重新选择）
- (void)onLongClose {
    [[LongShotCapture sharedInstance] reset];
    [self setMode:XZMaskModeCrop];
    [Common toast:@"已退出长截图"];
}

// 保存长图：拼接 → 直接存相册「超级截图」→ 销毁窗口A（不弹编辑）
- (void)onSaveLong {
    if ([[LongShotCapture sharedInstance] frameCount] < 1) {
        [Common toast:@"请先在框内滑动页面采集内容"];
        return;
    }
    // v5.12：SAD 模式补抓末屏，避免底部/结尾内容被裁掉
    if (_lsAlgo == 1) { _forceTick = YES; [self longCaptureTick]; }
    [Common toast:@"正在拼接长图..."];
    [self lsDisarmAndProceed:^{
        [self stopCaptureTimer];
        __weak typeof(self) ws = self;
        [[LongShotCapture sharedInstance] stitchWithCompletion:^(UIImage *result) {
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            UIImage *img = result ?: [[LongShotCapture sharedInstance] stitchFallback];
            [ss dismiss];
            if (img) {
                [ImageUtils saveToCustomAlbum:img completion:^(BOOL ok, NSError *e) {
                    [Common toast: ok ? @"长图已保存到相册「超级截图」" : @"保存失败，请检查相册权限"];
                }];
            } else {
                [Common toast:@"拼接失败，请重试"];
            }
        }];
    }];
}

// 复制长图：拼接 → 复制到剪贴板 → 销毁窗口A（不弹编辑）
- (void)onCopyLong {
    if ([[LongShotCapture sharedInstance] frameCount] < 1) {
        [Common toast:@"请先在框内滑动页面采集内容"];
        return;
    }
    // v5.12：SAD 模式补抓末屏，避免底部/结尾内容被裁掉
    if (_lsAlgo == 1) { _forceTick = YES; [self longCaptureTick]; }
    [Common toast:@"正在拼接长图..."];
    [self lsDisarmAndProceed:^{
        [self stopCaptureTimer];
        __weak typeof(self) ws = self;
        [[LongShotCapture sharedInstance] stitchWithCompletion:^(UIImage *result) {
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            UIImage *img = result ?: [[LongShotCapture sharedInstance] stitchFallback];
            [ss dismiss];
            if (img) {
                [[UIPasteboard generalPasteboard] setImage:img];
                [Common toast:@"长图已复制到剪贴板"];
            } else {
                [Common toast:@"拼接失败，请重试"];
            }
        }];
    }];
}

// 自动抓帧：隐藏边框 → 抓屏 → 按截取框内区域裁剪(inset 排除描边) → 滑动检测后入队（重叠去重）
// v4.8：未滑动绝不采集、不计数。
//   · 第一帧仅作为「未滑动基准」(_entryTile)，不计入、不显示屏数；
//   · 之后每帧与基准/上一已采集帧做像素差，仅当用户真的滑动了（内容变化）才 addFrame。
- (void)longCaptureTick {
    if (!_win || _mode != XZMaskModeLong || _capturing) return;
    _capturing = YES;

    // v5.13：自适应间隔门——不到点就轻量跳过，只有滚动速度变化时实际抓帧。
    //        强制标记(_forceTick)用于「保存/复制前补末屏」立即抓。
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (_lsLastCastTime > 0 && !_forceTick && (now - _lsLastCastTime) < _lsInterval) {
        _capturing = NO;
        return;
    }
    _forceTick = NO;
    _lsLastCastTime = now;

    BOOL borderHidden = _borderLayer.hidden;
    _borderLayer.hidden = YES;                 // 抓帧时去掉边框，避免被截进长图

    UIImage *screen = [ImageUtils captureScreen];
    _borderLayer.hidden = borderHidden;

    if (!screen) { _capturing = NO; return; }
    // 框内裁剪：inset 3pt 排除描边；框外暗色区本就不在裁剪范围内（框外不参与输出）
    CGRect clip = CGRectInset(_longFrameRect, 3, 3);
    UIImage *tile = [ImageUtils cropImage:screen screenRect:clip];
    if (tile) {
        if ([[LongShotCapture sharedInstance] frameCount] == 0) {
            if (!_entryTile) {
                _entryTile = tile;             // 顶部基准帧（首屏）
            } else if ([self tile:tile differsFrom:_entryTile]) {
                // 用户开始滑动 → 先把「顶部基准帧」写入为第 0 帧，再采集当前帧。
                // 否则首屏顶部会被整体丢弃 → 长图起始不完整。
                [[LongShotCapture sharedInstance] addFrame:_entryTile];
                _lastAddedTile = _entryTile;
                BOOL accepted = [[LongShotCapture sharedInstance] addFrame:tile];
                if (accepted) _lastAddedTile = tile;
                [self updateLongCounter];
            }
        } else {
            if (_lastAddedTile && ![self tile:tile differsFrom:_lastAddedTile]) {
                // 内容没变（没滑动）→ 不采集、不计数
            } else {
                BOOL accepted = [[LongShotCapture sharedInstance] addFrame:tile];
                if (accepted) {
                    _lastAddedTile = tile;     // v5.0：只有真正被接受的帧才更新比较基准
                    [self updateLongCounter];
                }
            }
        }
    }
    // v5.13：据最近重叠比例自适应抓帧间隔——
    //        重叠过大(>80%，滚太慢/帧太密)→多等；过小(<15%，太快)→抓紧；
    //        中档→轻微上调以稳在中段，让 SAD 始终落在可靠重叠，减少丢帧与强制补帧的重复。
    CGFloat op = [[LongShotCapture sharedInstance] lastOverlapRatio];
    if (!isnan(op)) {
        if (op > 0.80)      _lsInterval = MIN(0.85, _lsInterval * 1.7);
        else if (op < 0.15) _lsInterval = MAX(0.06, _lsInterval * 0.55);
        else                _lsInterval = MAX(0.06, MIN(0.5, _lsInterval * 1.25));
    }
    _capturing = NO;
}

#pragma mark - v4.8：滑动检测（低分辨率灰度平均差）

- (NSData *)grayData:(UIImage *)img width:(NSInteger)W h:(NSInteger *)outH {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    CGFloat w = (CGFloat)CGImageGetWidth(cg);
    CGFloat h = (CGFloat)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0) return nil;
    NSInteger dsH = (NSInteger)lround(W * h / w);
    if (dsH < 2) dsH = 2;
    if (outH) *outH = dsH;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, dsH, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, dsH), cg);
    unsigned char *src = CGBitmapContextGetData(ctx);
    if (!src) { CGContextRelease(ctx); return nil; }
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(dsH * W)];
    unsigned char *dst = d.mutableBytes;
    for (NSInteger r = 0; r < dsH; r++) {
        const unsigned char *row = src + r * W * 4;
        for (NSInteger c = 0; c < W; c++) {
            const unsigned char *p = row + c * 4;
            NSInteger lum = (p[0] * 299 + p[1] * 587 + p[2] * 114) / 1000;
            dst[r * W + c] = (unsigned char)lum;
        }
    }
    CGContextRelease(ctx);
    return d;
}

// 两帧是否「明显不同」（用户滑动了页面）。平均亮度差 > 5/255 视为变化。
- (BOOL)tile:(UIImage *)a differsFrom:(UIImage *)b {
    if (!a.CGImage || !b.CGImage) return YES;
    NSInteger W = 32, ha = 0, hb = 0;
    NSData *ga = [self grayData:a width:W h:&ha];
    NSData *gb = [self grayData:b width:W h:&hb];
    if (!ga || !gb || ha < 2 || hb < 2) return YES;
    NSInteger n = MIN(ha, hb);
    long long diff = 0;
    const unsigned char *pa = ga.bytes;
    const unsigned char *pb = gb.bytes;
    NSInteger total = n * W;
    for (NSInteger i = 0; i < total; i++) {
        NSInteger dv = pa[i] - pb[i];
        diff += dv < 0 ? -dv : dv;
    }
    CGFloat mean = (CGFloat)diff / (CGFloat)total;
    return mean > 5.0f;
}

#pragma mark - 抓屏 + 裁剪 公共路径

- (void)setWindowHidden:(BOOL)hidden {
    _win.hidden = hidden;
}

// 框选确认 → 选区下方弹出【紧凑工具栏】（不进全屏编辑窗）。
// 工具栏含全部功能（含 AI/旋转/加壳/PDF/压缩/打开豆包/取色/还原），并读「工具栏排序」设置。
// 这是用户要的形态：框选下方出单排/双排工具栏，最右侧有关闭按钮，不占满全屏。
- (void)presentLocalPanelForRect:(CGRect)rect {
    if (!_win) return;
    _cropScreenRect = [_contentView convertRect:rect toView:nil];
    _editingPanel = YES;                       // 隐藏框选三按钮、保留选框，进入面板模式
    [self buildLocalPanelOnOwnWindowWithRect:_cropScreenRect];
    [self refreshChrome];
    NSLog(@"[SuperScreenshot] local panel requested screenRect=(%.0f,%.0f,%.0f,%.0f)",
          _cropScreenRect.origin.x, _cropScreenRect.origin.y,
          _cropScreenRect.size.width, _cropScreenRect.size.height);
}

// 面板动作需要 _cropImage 但后台抓屏尚未完成时，立即同步补抓一次
- (UIImage *)ensureCropImage {
    if (_cropImage) return _cropImage;
    if (!_win) return nil;
    _win.hidden = YES;
    UIImage *screen = [ImageUtils captureScreen];
    _win.hidden = NO;
    UIImage *r = screen ? [ImageUtils cropImage:screen screenRect:_cropScreenRect] : nil;
    if (r) { _cropImage = r; if (!_originalCropImage) _originalCropImage = r; }
    return r;
}

// v5.12：功能面板应放置的 Y 坐标（默认选区下方，溢出则上方，都放不下贴顶部）
- (CGFloat)localPanelYForScreenRect:(CGRect)rect panelHeight:(CGFloat)panelH {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];
    CGFloat belowY = rect.origin.y + rect.size.height + 12.0;
    CGFloat aboveY = rect.origin.y - panelH - 12.0;
    CGFloat y = belowY;
    if (belowY + panelH > scr.size.height - safe.bottom - 8.0) y = aboveY;
    if (y < safe.top + 4.0) y = safe.top + 4.0;
    return y;
}

// v5.12：拖动选框时【实时】把功能面板跟着挪到新选区旁（选区与面板一起移动，跟手无延迟）
- (void)layoutLocalPanelForCropLive {
    if (!_panelWin || !_localPanel || !_contentView) return;
    CGRect screenRect = [_contentView convertRect:_cropRect toView:nil];
    CGRect pf = _localPanel.frame;
    pf.origin.y = [self localPanelYForScreenRect:screenRect panelHeight:pf.size.height];
    _localPanel.frame = pf;
}

// v5.10：面板弹出后用户拖动/缩放选框 —— 选区变了要把功能面板跟着挪到新选框下方，
//        并异步重新裁剪选区图片，确保后续 OCR/打码等用的是新位置内容。
- (void)syncPanelAfterCropRectChange {
    if (!_editingPanel || !_panelWin || !_localPanel || !_contentView) return;
    CGRect screenRect = [_contentView convertRect:_cropRect toView:nil];
    _cropScreenRect = screenRect;

    CGRect pf = _localPanel.frame;
    pf.origin.y = [self localPanelYForScreenRect:screenRect panelHeight:pf.size.height];
    _localPanel.frame = pf;                    // v5.12：去掉动画，跟手不延迟

    [self recropOnPanelMove];
}

// 异步重新裁剪（隐藏窗口A，面板在独立窗口不受影响）
- (void)recropOnPanelMove {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss || !ss->_win || !ss->_editingPanel) return;
        ss->_win.hidden = YES;
        UIImage *screen = [ImageUtils captureScreen];
        ss->_win.hidden = NO;
        if (screen) {
            UIImage *r = [ImageUtils cropImage:screen screenRect:ss->_cropScreenRect];
            if (r) ss->_cropImage = r;
        }
    });
}

#pragma mark - v4.8：局部截图原地面板

typedef NS_ENUM(NSInteger, XZLocalTag) {
    XZLocalOCR      = 1,
    XZLocalTranslate= 2,
    XZLocalDraw     = 3,
    XZLocalCode     = 4,
    XZLocalAIImage  = 20,   // 打开豆包（直接拉起豆包 App 并把裁剪图带进去）—— v6.20.6 由主工具栏补齐，v6.20.8 改为打开豆包
    XZLocalRotate   = 19,
    XZLocalCopy     = 6,
    XZLocalFloating = 7,
    XZLocalSave     = 8,
    XZLocalShare    = 9,
    XZLocalPhone    = 11,
    XZLocalPDF      = 12,
    XZLocalCompress = 13,
    XZLocalColorPick= 15,
    XZLocalReset    = 16,
    XZLocalLaunchApp= 21,   // v6.20.9：快捷启动 App（弹层选微信/QQ/闲鱼/自选，秒开）
};

// 构建功能面板视图（给定已定位好的 frame）
- (UIView *)makeLocalPanelViewWithFrame:(CGRect)pf
                                iconSize:(CGFloat)iconS labelH:(CGFloat)labelH
                                    rowH:(CGFloat)rowH rowGap:(CGFloat)rowGap vPad:(CGFloat)vPad {
    UIView *panel = [[UIView alloc] initWithFrame:pf];
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    panel.layer.cornerRadius = 14;
    panel.userInteractionEnabled = YES;

    CGFloat panelW = pf.size.width;
    NSArray *row1 = @[
        @{@"icon":@"text.viewfinder",   @"label":@"OCR",  @"tag":@(XZLocalOCR)},
        @{@"icon":@"translate",         @"label":@"翻译", @"tag":@(XZLocalTranslate)},
        @{@"icon":@"pencil.tip",        @"label":@"画图", @"tag":@(XZLocalDraw)},
        @{@"icon":@"qrcode.viewfinder", @"label":@"识码", @"tag":@(XZLocalCode)},
    ];
    NSArray *row2 = @[
        @{@"icon":@"doc.on.doc",             @"label":@"复制", @"tag":@(XZLocalCopy)},
        @{@"icon":@"pin",                    @"label":@"贴图", @"tag":@(XZLocalFloating)},
        @{@"icon":@"square.and.arrow.down",  @"label":@"保存", @"tag":@(XZLocalSave)},
        @{@"icon":@"square.and.arrow.up",    @"label":@"分享", @"tag":@(XZLocalShare)},
    ];

    CGFloat gap = 6.0;
    CGFloat bw = (panelW - gap * 3) / 4.0;   // 去打码后两排均为 4 列
    for (NSInteger i = 0; i < row1.count; i++) {
        UIButton *b = [self makeLocalButton:row1[i] iconSize:iconS labelH:labelH width:bw];
        b.frame = CGRectMake(gap + i * (bw + gap), vPad, bw, rowH);
        [panel addSubview:b];
    }
    for (NSInteger i = 0; i < row2.count; i++) {
        UIButton *b = [self makeLocalButton:row2[i] iconSize:iconS labelH:labelH width:bw];
        b.frame = CGRectMake(gap + i * (bw + gap), vPad + rowH + rowGap, bw, rowH);
        [panel addSubview:b];
    }

    // 面板右上角关闭（✕/取消）：v5.25.0 改在 _panelWin 上 (不在 panel 子树内), 位置在 panel 右侧外面
    //       加大到 44x44, 不与 sv 抢 pan 事件, 永远不与 panel 内的循环滚动打架.
    if (_closeBtn) { [_closeBtn removeFromSuperview]; _closeBtn = nil; }
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    // 形参 pf 就是 panel 的 frame, 不重新定义
    close.frame = CGRectMake(CGRectGetMaxX(pf) - 6, CGRectGetMidY(pf) - 22, 44, 44);
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1.0];
    [close addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [_panelWin addSubview:close];
    _closeBtn = close;
    [_panelWin addInteractiveView:close]; // v5.25.0: 让 _panelWin 把它当白名单
    return panel;
}

// v4.9 / v6.05：在【独立窗口】上、选区下方同步弹出紧凑功能面板（不进全屏编辑窗）。
//   · 含全部功能（OCR/翻译/画图/识码/AI/旋转/复制/贴图/保存/分享/PDF/压缩/打开豆包/取色/还原），
//     与 EditToolbarWindow 用同一套 tag 值，故「工具栏排序」设置对它直接生效。
//     （「加壳」已移出局部工具栏 —— 改到「设置→手机壳库」，仅对「正常截图」生效。）
//   · 左侧常驻一张当前裁剪图预览缩略图，旋转/还原/压缩后实时刷新，让操作看得见。
//   · 单排=横向循环滑动；双排=每行 5 个自动折行。最右侧固定一个红色 X 关闭按钮。
- (void)buildLocalPanelOnOwnWindowWithRect:(CGRect)rect {
    if (!_win) return;
    CGRect scr = [UIScreen mainScreen].bounds;

    // v6.06：横向间距收紧（更紧凑），但文字不再被压缩——字号回到 12，按钮最小 54 保证 4 字标签完整显示
    CGFloat iconS = 18.0;
    CGFloat labelH = 13.0;                    // 标签行高（承载 12pt 文字）
    CGFloat rowH  = iconS + labelH + 7.0;     // 单行高
    CGFloat rowGap = 4.0;                     // 横向间距收紧
    CGFloat vPad  = 7.0;
    CGFloat pad   = 8.0;
    CGFloat closeW = 36.0;                    // 最右侧红色关闭（明显、一指可点）
    CGFloat prevW  = 52.0;                    // 左侧预览缩略图宽
    CGFloat headerH = 30.0;                   // 顶部统计条（已截 N 张 + 历史入口 + 关闭✕）
    CGFloat panelW = scr.size.width - pad * 2;
    CGFloat areaW  = panelW - closeW - prevW - 16.0;  // 按钮区可用宽（左预览、右关闭、顶统计）

    BOOL singleRow = ([Common intPref:XZ_KEY_TB_LAYOUT default:0] == 1);

    // 局部工具栏目录（tag 值与 EditToolbarWindow 一致；不含「加壳」，加壳走正常截图）
    NSDictionary<NSNumber *, NSDictionary *> *catalog = @{
        @(XZLocalOCR):      @{@"icon":@"text.viewfinder",              @"label":@"OCR"},
        @(XZLocalTranslate):@{@"icon":@"translate",                    @"label":@"翻译"},
        @(XZLocalDraw):     @{@"icon":@"pencil.tip",                  @"label":@"画图"},
        @(XZLocalCode):     @{@"icon":@"qrcode.viewfinder",           @"label":@"识码"},
        @(XZLocalAIImage):  @{@"icon":@"bubble.left",                 @"label":@"打开豆包"},
        @(XZLocalRotate):   @{@"icon":@"rotate.right",                @"label":@"旋转"},
        @(XZLocalCopy):     @{@"icon":@"doc.on.doc",                  @"label":@"复制"},
        @(XZLocalFloating): @{@"icon":@"pin",                         @"label":@"贴图"},
        @(XZLocalSave):     @{@"icon":@"square.and.arrow.down",        @"label":@"保存"},
        @(XZLocalShare):    @{@"icon":@"square.and.arrow.up",          @"label":@"分享"},
        @(XZLocalPDF):      @{@"icon":@"doc.richtext",                @"label":@"PDF"},
        @(XZLocalCompress): @{@"icon":@"arrow.down.circle",           @"label":@"压缩"},
        @(XZLocalColorPick):@{@"icon":@"eyedropper",                  @"label":@"取色"},
        @(XZLocalReset):    @{@"icon":@"arrow.counterclockwise",       @"label":@"还原"},
        @(XZLocalLaunchApp):@{@"icon":@"app.fill",                     @"label":@"启动"},
    };

    // 读「工具栏排序」+ 禁用集合，得到当前应显示的按钮顺序
    NSArray<NSNumber *> *enabled = [self resolveLocalTags];
    NSMutableArray<NSMutableDictionary *> *all = [NSMutableArray array];
    for (NSNumber *t in enabled) {
        NSDictionary *spec = catalog[t];
        if (spec) {
            NSMutableDictionary *d = [spec mutableCopy];
            d[@"tag"] = t;
            // v6.06：工具栏排序页可自定义名称/图标（仅本机生效）
            NSString *nm = [Common stringPref:[NSString stringWithFormat:@"Toolbar_Name_%ld", (long)t.integerValue] default:@""];
            if (nm.length) d[@"label"] = nm;
            NSString *ic = [Common stringPref:[NSString stringWithFormat:@"Toolbar_Icon_%ld", (long)t.integerValue] default:@""];
            if (ic.length) d[@"icon"] = ic;
            [all addObject:d];
        }
    }
    if (all.count == 0) { [Common toast:@"工具栏为空，请到设置→工具栏排序开启功能"]; [self dismiss]; return; }

    NSInteger kCols = 5;
    NSInteger rows = singleRow ? 1 : (NSInteger)ceil((double)all.count / (double)kCols);
    CGFloat panelH = headerH + vPad * 2 + rowH * rows + rowGap * MAX(0, rows - 1);

    // 复用 _panelWin：移除旧面板/旧滚动视图
    if (_localPanel) { [_localPanel removeFromSuperview]; _localPanel = nil; }
    if (_panelScroll) { _panelScroll.delegate = nil; _panelScroll = nil; }
    if (_panelWin) { _panelWin.gateInteractive = YES; }
    if (!_panelWin) {
        _panelWin = [[XZPassThroughWindow alloc] initWithFrame:scr];
        _panelWin.windowLevel = _win.windowLevel + 10;
        _panelWin.backgroundColor = [UIColor clearColor];
        _panelWin.userInteractionEnabled = YES;
        _panelWin.passthrough = YES;            // 面板外触摸穿透给遮罩窗口
        _panelWin.gateInteractive = YES;
        _panelVC = [[UIViewController alloc] init];
        _panelVC.view.backgroundColor = [UIColor clearColor];
        _panelVC.view.userInteractionEnabled = NO;
        _panelWin.rootViewController = _panelVC;
        if (@available(iOS 13.0, *)) _panelWin.windowScene = [Common activeWindowScene];
    }
    _panelWin.hidden = NO;

    CGFloat y = [self localPanelYForScreenRect:rect panelHeight:panelH];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, y, panelW, panelH)];
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    panel.layer.cornerRadius = 14;
    panel.userInteractionEnabled = YES;
    _localPanel = panel;

    // v6.07：顶部统计条 —— 已截 N 张（左） + 历史入口（右） + 关闭✕（最右，常驻可见）
    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, panelW - 150, headerH)];
    hdr.text = [NSString stringWithFormat:@"已截 %ld 张", (long)[Common intPref:XZ_KEY_SNAP_COUNT default:0]];
    hdr.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    hdr.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    hdr.userInteractionEnabled = NO;
    [hdr setCenter:CGPointMake(hdr.center.x, headerH/2.0)];
    _snapCountLabel = hdr;
    [panel addSubview:hdr];

    UIButton *histBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    histBtn.frame = CGRectMake(panelW - 104, 0, 56, headerH);
    [histBtn setTitle:@"历史" forState:UIControlStateNormal];
    histBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [histBtn setTitleColor:[UIColor systemYellowColor] forState:UIControlStateNormal];
    [histBtn addTarget:self action:@selector(openHistory) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:histBtn];

    // 关闭✕（最右上角，跟随顶栏，永远可见，不用移动选取框）
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(panelW - 40, 0, 40, headerH);
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor = [UIColor systemRedColor];
    close.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [close addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    // 左侧预览缩略图：显示当前裁剪图，旋转/还原/压缩后实时更新（让操作看得见）
    if (!_previewIV) {
        _previewIV = [[UIImageView alloc] init];
        _previewIV.contentMode = UIViewContentModeScaleAspectFit;
        _previewIV.layer.cornerRadius = 6;
        _previewIV.clipsToBounds = YES;
        _previewIV.layer.borderWidth = 1;
        _previewIV.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        _previewIV.userInteractionEnabled = NO;
    }
    CGFloat contentTop = headerH;
    CGFloat prevH = panelH - contentTop - vPad * 2;
    _previewIV.frame = CGRectMake(8, contentTop + vPad, prevW, prevH);
    [panel addSubview:_previewIV];

    CGFloat btnAreaX = 8 + prevW + 8;   // 按钮区起点（预览右侧）
    CGFloat bw, gap = 4.0;
    if (singleRow) {
        // 单排 + 横向循环滑动（3 组首尾相接，越界无感回绕）
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(btnAreaX, contentTop + vPad, areaW, rowH)];
        sv.showsHorizontalScrollIndicator = NO;
        sv.alwaysBounceHorizontal = YES;
        sv.delegate = self;
        sv.tag = 9902;                 // 本地面板循环滑动标记
        [panel addSubview:sv];
        bw = 54.0;
        CGFloat stride = (bw + gap) * (CGFloat)all.count;
        for (int copy = 0; copy < 3; copy++) {
            CGFloat x = (CGFloat)copy * stride + 6.0;
            for (NSDictionary *d in all) {
                UIButton *b = [self makeLocalButton:d iconSize:iconS labelH:labelH width:bw];
                b.frame = CGRectMake(x, 0, bw, rowH);
                [sv addSubview:b];
                x += bw + gap;
            }
        }
        sv.contentSize = CGSizeMake(stride * 3.0 + 12.0, rowH);
        sv.contentOffset = CGPointMake(stride, 0);   // 停在中组
        _panelScroll = sv;
        _localSetW = stride;
    } else {
        // 双排：每行 5 个自动折行（左侧留预览、右侧留关闭）
        bw = (areaW - gap * (kCols - 1)) / (CGFloat)kCols;
        if (bw < 54.0) bw = 54.0;     // 保证最小可点 + 4 字标签完整显示
        for (NSInteger i = 0; i < (NSInteger)all.count; i++) {
            NSInteger r = i / kCols, c = i % kCols;
            UIButton *b = [self makeLocalButton:all[i] iconSize:iconS labelH:labelH width:bw];
            b.frame = CGRectMake(btnAreaX + c * (bw + gap), contentTop + vPad + r * (rowH + rowGap), bw, rowH);
            [panel addSubview:b];
        }
    }

    [_panelWin addSubview:_localPanel];
    [_panelWin addInteractiveView:_localPanel];   // 面板本身作为交互白名单
    [_panelWin bringSubviewToFront:_localPanel];

    [self ensureCropImage];        // v6.05：进面板即裁好图，预览立刻有内容
    [self updateLocalPreview];
}

// v6.05：把当前裁剪图刷新到左侧预览缩略图
- (void)updateLocalPreview {
    if (_previewIV) _previewIV.image = _cropImage;
}

#pragma mark - v6.06：截图统计 + 历史记录

+ (BOOL)isShowing {
    return ((MaskCropWindow *)[self sharedInstance])->_showing;
}

- (void)openHistory {
    [HistoryWindow show];
}

// 把一张截图写入历史目录（缩略图），并裁剪到上限条数
- (void)saveHistoryThumb:(UIImage *)image {
    if (![Common boolPref:XZ_KEY_HISTORY_ENABLED default:YES]) return;
    if (!image) return;
    @try {
        NSString *dir = XZ_HISTORY_DIR;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        // 缩略图：长边缩到 360
        CGFloat maxSide = 360.0 * (image.scale > 0 ? image.scale : 1.0);
        CGFloat w = image.size.width, h = image.size.height;
        CGFloat scale = MIN(1.0, maxSide / MAX(w, h));
        CGSize ts = CGSizeMake(w * scale, h * scale);
        UIGraphicsBeginImageContextWithOptions(ts, NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, ts.width, ts.height)];
        UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!thumb) return;
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *name = [NSString stringWithFormat:@"%@.jpg", [df stringFromDate:[NSDate date]]];
        NSString *path = [dir stringByAppendingPathComponent:name];
        [UIImageJPEGRepresentation(thumb, 0.8) writeToFile:path atomically:YES];

        // 裁剪到上限：保留最新 N 张
        NSInteger maxN = [Common intPref:XZ_KEY_HISTORY_MAX default:50];
        if (maxN < 1) maxN = 1;
        NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]
                           sortedArrayUsingSelector:@selector(compare:)];
        files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.jpg'"]];
        if ((NSInteger)files.count > maxN) {
            for (NSInteger i = 0; i < (NSInteger)files.count - maxN; i++) {
                NSString *old = [dir stringByAppendingPathComponent:files[i]];
                [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
            }
        }
    } @catch (NSException *e) { NSLog(@"[SuperScreenshot] save history failed: %@", e.reason); }
}

// 记录一次截图：计数 +1，并写入历史缩略图，刷新面板顶部计数
- (void)recordSnap:(UIImage *)image {
    NSInteger n = [Common intPref:XZ_KEY_SNAP_COUNT default:0] + 1;
    [Common setPref:XZ_KEY_SNAP_COUNT value:@(n)];
    [self saveHistoryThumb:image];
    if (_snapCountLabel) {
        _snapCountLabel.text = [NSString stringWithFormat:@"已截 %ld 张", (long)n];
    }
}

// 与 EditToolbarWindow.resolveEnabledTags 同算法：读「工具栏排序」+ 禁用集合，返回启用按钮 tag 顺序
- (NSArray<NSNumber *> *)resolveLocalTags {
    NSArray<NSNumber *> *defOrder = @[ @(XZLocalOCR), @(XZLocalTranslate), @(XZLocalDraw), @(XZLocalCode),
                                       @(XZLocalAIImage), @(XZLocalRotate), @(XZLocalCopy), @(XZLocalFloating),
                                       @(XZLocalSave), @(XZLocalShare), @(XZLocalPDF),
                                       @(XZLocalCompress), @(XZLocalColorPick), @(XZLocalReset), @(XZLocalLaunchApp) ];
    NSMutableArray<NSNumber *> *saved = [NSMutableArray array];
    NSString *orderStr = [Common stringPref:XZ_KEY_TB_ORDER default:@""];
    if (orderStr.length) [saved addObjectsFromArray:[orderStr componentsSeparatedByString:@","]];
    if (saved.count == 0) [saved addObjectsFromArray:defOrder];
    NSMutableSet<NSNumber *> *orderSet = [NSMutableSet setWithArray:saved];
    for (NSNumber *t in defOrder) if (![orderSet containsObject:t]) [saved addObject:t];
    for (NSNumber *t in [saved copy]) if (![defOrder containsObject:t]) [saved removeObject:t];
    NSSet<NSNumber *> *disabled = [NSSet setWithArray:[[Common stringPref:XZ_KEY_TB_DISABLED default:@""] componentsSeparatedByString:@","]];
    NSMutableArray<NSNumber *> *enabled = [NSMutableArray array];
    for (NSNumber *t in saved) if (![disabled containsObject:t]) [enabled addObject:t];
    return enabled;
}

// 单排循环滑动：把 offset 钳制在「中组」区间，越界无感回绕（tag=9902 仅本地面板）
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView.tag != 9902) return;
    CGFloat setW = _localSetW;
    if (setW <= 0) return;
    if (setW <= [UIScreen mainScreen].bounds.size.width) return;   // 一组就能放下则无需循环
    CGFloat off = scrollView.contentOffset.x;
    if (off < setW) {
        scrollView.contentOffset = CGPointMake(off + setW, 0);
    } else if (off >= 2.0 * setW) {
        scrollView.contentOffset = CGPointMake(off - setW, 0);
    }
}

// 旋转裁剪图（点按 90° / 长按 180°）
- (void)rotateCropImageBy:(CGFloat)rad {
    UIImage *img = _cropImage;
    if (!img) return;
    CGFloat w = img.size.width, h = img.size.height;
    BOOL swap = (fabs(fmod(rad, M_PI)) > 0.01);
    CGSize outSize = swap ? CGSizeMake(h, w) : CGSizeMake(w, h);
    UIGraphicsBeginImageContextWithOptions(outSize, NO, img.scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, outSize.width / 2.0, outSize.height / 2.0);
    CGContextRotateCTM(ctx, rad);
    CGContextTranslateCTM(ctx, -w / 2.0, -h / 2.0);
    [img drawInRect:CGRectMake(0, 0, w, h)];
    UIImage *rot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (rot) { _cropImage = rot; [Common toast: swap ? @"已旋转 90°" : @"已旋转 180°"]; }
}

- (void)onLocalRotateLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _rotateLongPressed = YES;
        [self rotateCropImageBy:M_PI];
    }
}

- (UIButton *)makeLocalButton:(NSDictionary *)spec iconSize:(CGFloat)iconS labelH:(CGFloat)labelH width:(CGFloat)bw {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = [spec[@"tag"] integerValue];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    b.layer.cornerRadius = 9;
    [b addTarget:self action:@selector(localToolTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((bw - iconS) / 2, 6, iconS, iconS)];
    iv.image = [Common systemIcon:spec[@"icon"]];
    if (!iv.image) iv.image = [Common systemIcon:@"circle"];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [b addSubview:iv];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 6 + iconS + 1, bw, labelH)];
    lb.text = spec[@"label"];
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];   // v6.06：回到 12pt，默认名不再被压缩
    lb.textAlignment = NSTextAlignmentCenter;
    lb.adjustsFontSizeToFitWidth = YES;        // 仅当名字过长(自定义)才缩放，默认名保持 12pt
    lb.minimumScaleFactor = 0.6;
    lb.lineBreakMode = NSLineBreakByClipping;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];

    // 旋转按钮支持长按 = 旋转 180°（点按 = 旋转 90°）
    if ([spec[@"tag"] integerValue] == XZLocalRotate) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLocalRotateLongPress:)];
        lp.minimumPressDuration = 0.5;
        [b addGestureRecognizer:lp];
    }
    return b;
}

// 面板动作分发（作用于 _cropImage）
- (void)localToolTapped:(UIButton *)btn {
    NSInteger tag = btn.tag;
    UIImage *img = [self ensureCropImage];     // 后台抓屏未完成时同步补抓
    if (!img && tag != XZLocalReset) { [Common toast:@"裁剪图为空，请重选"]; return; }

    if (tag == XZLocalOCR) {
        [Common toast:@"正在识别文字..."];
        [SuperTools ocr:img completion:^(NSString *text) {
            [self presentLocalText:text title:@"OCR 识别结果"];
        }];
    } else if (tag == XZLocalTranslate) {
        [Common toast:@"正在识别并翻译..."];
        [SuperTools translate:img completion:^(NSString *src, NSString *dst, NSString *err) {
            [self presentLocalTranslate:src dst:dst err:err];
        }];
    } else if (tag == XZLocalDraw) {
        // 画图需要画布，唤起编辑窗口（仅此动作需要画板，属于用户主动进入）
        [SuperTools draw:img completion:^(UIImage *edited) {
            if (edited) { self->_cropImage = edited; [Common toast:@"已应用，可继续操作"]; }
        }];
    } else if (tag == XZLocalCode) {
        [Common toast:@"正在识别二维码..."];
        [SuperTools codeScan:img completion:^(NSString *code) {
            [self presentLocalCode:code];
        }];
    } else if (tag == XZLocalAIImage) {
        // v6.20.8：改为直接拉起「豆包」App 并把截图带进去（不再应用内发 API 对话）
        BOOL opened = [SuperTools openDoubaoWithImage:img];
        if (opened) {
            [Common toast:@"已打开豆包，截图已复制到剪贴板，长按输入框可粘贴"];
            [self dismiss];
        } else {
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[img] applicationActivities:nil];
            [Common present:avc fromWindow:_win];
            [Common toast:@"未检测到豆包，已用系统分享，请选择豆包"];
            [self dismiss];
        }
    } else if (tag == XZLocalRotate) {
        // 点按 90°；长按 180°（_rotateLongPressed 避免两者叠加）
        if (_rotateLongPressed) { _rotateLongPressed = NO; return; }
        [self rotateCropImageBy:M_PI_2];
        [self updateLocalPreview];      // v6.05：旋转后立刻刷新左侧预览，让用户看到结果
    } else if (tag == XZLocalCopy) {
        // v6.20.16：去掉这里的重复提示——SuperTools copy: 内部已 toast「已复制图片到剪贴板」，
        // 之前再 toast 一条「已复制到剪贴板」，两条叠在一起根本读不清。
        [SuperTools copy:img];
        [self dismiss];
    } else if (tag == XZLocalFloating) {
        [SuperTools floating:img withScreenRect:_cropRect];
        [self dismiss];
    } else if (tag == XZLocalSave) {
        [self recordSnap:img];
        [SuperTools save:img completion:^(BOOL ok) {
            [Common toast: ok ? @"已保存到相册「超级截图」" : @"保存失败，请检查相册权限"];
            [self dismiss];
        }];
    } else if (tag == XZLocalShare) {
        // v5.22：分享面板也是 UIKit 弹窗, 同样不能用穿透窗口
        [self recordSnap:img];
        [SuperTools share:img fromWindow:_win];
    } else if (tag == XZLocalPDF) {       // v6.05：加壳已移出局部工具栏，改为「手机壳库」设置，仅作用于正常截图
        [self recordSnap:img];
        NSString *p = [SuperTools exportPDF:img];
        if (p) {
            NSURL *url = [NSURL fileURLWithPath:p];
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                             applicationActivities:nil];
            [Common present:avc fromWindow:_win];
        } else { [Common toast:@"导出失败"]; }
    } else if (tag == XZLocalCompress) {
        NSData *before = UIImagePNGRepresentation(img);
        UIImage *c = [SuperTools compress:img quality:0.6];
        if (c) {
            NSData *after = UIImageJPEGRepresentation(c, 0.6);
            self->_cropImage = c;
            [Common toast:[NSString stringWithFormat:@"已压缩：%.0fKB → %.0fKB",
                           before.length / 1024.0, after.length / 1024.0]];
        } else { [Common toast:@"压缩失败"]; }
        [self updateLocalPreview];      // v6.05：压缩后刷新预览
    } else if (tag == XZLocalColorPick) {
        [SuperTools colorPicker:img fromWindow:_win];
    } else if (tag == XZLocalReset) {
        if (_originalCropImage) { self->_cropImage = _originalCropImage; [Common toast:@"已还原原图"]; }
        else [Common toast:@"无原图可还原"];
        [self updateLocalPreview];      // v6.05：还原后刷新预览
    } else if (tag == XZLocalLaunchApp) {
        // v6.20.9：一键秒开微信/QQ/闲鱼等任意 App（弹层选择，图同时入剪贴板可粘贴）
        [self launchLocalAppWithImage:img];
    }
}

- (void)launchLocalAppWithImage:(UIImage *)img {
    NSArray<NSDictionary *> *apps = [SuperTools superscreenshotLaunchApps];
    if (apps.count == 0) {
        [Common toast:@"请先到设置 → 快捷启动 里添加 App"];
        return;
    }
    void (^doOpen)(NSDictionary *) = ^(NSDictionary *a){
        BOOL opened = [SuperTools openAppScheme:a[@"scheme"] withImage:img];
        NSString *nm = a[@"name"] ?: @"App";
        if (opened) {
            [Common toast:[NSString stringWithFormat:@"已打开%@，截图已复制到剪贴板，长按输入框可粘贴", nm]];
        } else {
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[img] applicationActivities:nil];
            [Common present:avc fromWindow:_win];
            [Common toast:[NSString stringWithFormat:@"未检测到%@，已用系统分享，请选择%@", nm, nm]];
        }
        [self dismiss];
    };
    if (apps.count == 1) { doOpen(apps.firstObject); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"启动 App"
                                                               message:@"选一个要打开的 App"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *a in apps) {
        NSString *name = a[@"name"] ?: (a[@"scheme"] ?: @"App");
        [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){ doOpen(a); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

// 退出原地面板，回到框选模式（v5.6：保留选区，可直接拖动/缩放调整，不必重新截图）
- (void)exitLocalPanel {
    if (_localPanel) { [_localPanel removeFromSuperview]; _localPanel = nil; }
    if (_panelScroll) {
        @try { [_panelScroll removeObserver:self forKeyPath:@"contentOffset" context:(void *)&SuperScreenshot_LoopKVOContext]; }
        @catch (__unused NSException *e) {}
        _panelScroll = nil;
    }
    if (_panelWin) { _panelWin.hidden = YES; }   // 隐藏独立面板窗口（保留以便复用）
    _editingPanel = NO;
    _cropImage = nil;
    _cropScreenRect = CGRectZero;
    // 注意：不再清空 _cropRect / _hasCrop —— 保留选区，用户可继续微调或点✓完成
    [self updateMask];
    [self refreshChrome];
    [Common toast:@"已退出编辑，可拖动选框调整或点「✓完成」"];
}

// v5.21: 单排滑动循环监听 —— 滚过"第二份开头"就跳回第一份; 反之亦然.
// v5.25.0: 改为只在 scrollViewDidEndDecelerating/drag-end 时做对齐, 不在 KVO 中重设 contentOffset
//          (因为 KVO 改 contentOffset 会触发 _contentView 的 pan 状态混乱, 导致选区调范围失效).
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == &SuperScreenshot_LoopKVOContext) {
        // v5.25.0: 拖动中不再对齐, 让 sv 自由滚动; 对齐改到 scrollViewDidScroll/didEndDecelerating 中
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark - 原地面板结果展示（复用窗口A 的 hostVC 弹窗）

- (void)presentLocalText:(NSString *)text title:(NSString *)title {
    if (!text || text.length == 0) { [Common toast:@"没有识别到文字"]; return; }
    // v6.06：改用 ResultWindow（层级 Alert+600），稳盖过工具栏面板，不再被挡住
    [ResultWindow showWithTitle:title text:text image:nil];
}

- (void)presentLocalTranslate:(NSString *)src dst:(NSString *)dst err:(NSString *)err {
    if (err && err.length) { [ResultWindow showWithTitle:@"翻译失败" text:err image:nil]; return; }
    if (!dst || dst.length == 0) { [Common toast:@"翻译失败"]; return; }
    NSString *msg = [NSString stringWithFormat:@"原文：\n%@\n\n译文：\n%@", src ?: @"", dst ?: @""];
    // v6.06：改用 ResultWindow（层级 Alert+600），稳盖过工具栏面板，不再被挡住
    [ResultWindow showWithTitle:@"翻译结果" text:msg image:nil];
}

- (void)presentLocalCode:(NSString *)code {
    if (!code || code.length == 0) { [Common toast:@"未识别到二维码"]; return; }
    // v6.06：改用 ResultWindow（层级 Alert+600），稳盖过工具栏面板，不再被挡住
    [ResultWindow showWithTitle:@"识别结果" text:code image:nil];
}

// 正常截图：整屏 → 保存到相册「超级截图」→ 直接结束（不弹编辑，仿原生）
- (void)captureFullScreenAndSave {
    if (!_win) return;
    [self setWindowHidden:YES];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        UIImage *screen = [ImageUtils captureScreen];
        [ss dismiss];                            // 先销毁窗口A
        if (!screen) { [Common toast:@"截图失败"]; return; }
        // v6.05：手机壳库 —— 正常截图按设置自动套壳（局部截图不走这里）
        if ([Common boolPref:XZ_KEY_PHONE_CASE_ON default:NO]) {
            NSString *caseId = [Common stringPref:XZ_KEY_PHONE_CASE default:@"none"];
            if (caseId.length && ![caseId isEqualToString:@"none"]) {
                UIImage *framed = [ImageUtils applyPhoneFrame:screen caseId:caseId];
                if (framed) screen = framed;
            }
        }
        [ImageUtils saveToCustomAlbum:screen completion:^(BOOL ok, NSError *e) {
            [Common toast: ok ? @"已截图，已保存到相册「超级截图」" : @"保存失败，请检查相册权限"];
            if (ok) [self recordSnap:screen];   // v6.06：正常截图也计入统计 + 历史
        }];
    });
}

@end
