//
//  AppScrollReporter.m — 精确长截图 · App 侧【自动滚动】驱动（超级截图 v5.4）
//
//  原理（方案 A：自动滚动，用户完全不用手动滑）：
//    SpringBoard 长截图「自动滚动」模式点【开始采集】时 notify_post(arm)，并把采集区域
//    高度(点)写入 notify 状态 SuperScreenshot_LS_REGIONH。本类收到 arm 后：
//      1. 在 keyWindow 视图树里找 contentSize 最大的 UIScrollView（聊天消息列表）；
//      2. 先把当前屏作为第 1 帧：write offset、notify_post(capture)；
//      3. 启动定时循环：每次把 scrollView 的 contentOffset 向下推「约一屏高×90%（快速 94%）」
//         （setContentOffset:animated:NO，确定性、无惯性），等 ~0.55s 渲染后把新屏作为
//         下一帧：write offset、notify_post(capture)；
//      4. 当 contentOffset 到达底部(maxY)时，发最后一屏（底部剩余部分）后 notify_post(done)
//         通知 SpringBoard 自动采集结束。
//    SpringBoard 收到每帧时读取精确 offset，重叠 = 采集区域高 − 滚动增量（点），100% 准确，
//    不靠任何像素比对猜测，从根本上消除聊天重复纹理导致的叠影。
//
//  为什么用「App 自己滚」而不是「SpringBoard 合成触摸」：
//    iOS16 上 SpringBoard 合成的触摸事件能否真的驱动前台 App 滚动不可验证（风险高）；
//    而直接驱动 App 自身的 UIScrollView.contentOffset 是确定性可靠的，且滚动量精确可知。
//    注入范围仅 QQ/微信（见 plist），非全局。
//
//  为什么不用 KVO：arm 后用户可能退出聊天（滚动视图释放），KVO 在 dealloc 时会崩溃；
//    改为轮询并在 _sv 变 nil 时自动 finishAuto，安全。
//

#include <notify.h>
#import "AppScrollReporter.h"
#import "SuperScreenshotNotify.h"
#import "Common.h"

static AppScrollReporter *g_inst = nil;
static int g_armTok = 0, g_disarmTok = 0, g_offsetTok = 0, g_regionTok = 0, g_doneTok = 0;

@implementation AppScrollReporter {
    __weak UIScrollView *_sv;        // 主滚动视图（弱引用，释放即失效）
    CGFloat _regionH;                // 采集区域高（点），来自 SB
    BOOL   _armed;
    BOOL   _autoStarted;             // 是否已经发出过第1帧并做过第一次滚动
    NSTimer *_timer;
    NSTimeInterval _tickInterval;    // 每帧采集间隔（秒）
    CGFloat _stepRatio;              // 每帧滚动步进占区域高比例（越大重叠越小、越快）
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_inst = [[AppScrollReporter alloc] init]; });
    return g_inst;
}

+ (void)setup {
    notify_register_dispatch(SuperScreenshot_LS_ARM, &g_armTok, dispatch_get_main_queue(), ^(int t) {
        [[AppScrollReporter shared] arm];
    });
    notify_register_dispatch(SuperScreenshot_LS_DISARM, &g_disarmTok, dispatch_get_main_queue(), ^(int t) {
        [[AppScrollReporter shared] disarm];
    });
    notify_register_check(SuperScreenshot_LS_OFFSET, &g_offsetTok);
    notify_register_check(SuperScreenshot_LS_REGIONH, &g_regionTok);
    NSLog(@"[SuperScreenshot] AppScrollReporter registered (arm/disarm/offset/regionh)");
}

// 在视图树里找 contentSize 最高的可见 UIScrollView（聊天消息列表通常是最大的那个）
- (UIScrollView *)findMainScrollView {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) win = [UIApplication sharedApplication].windows.lastObject;
    if (!win) return nil;

    UIView *root = win.rootViewController ? win.rootViewController.view : win;
    UIScrollView *best = nil;
    CGFloat bestH = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat ch = sv.contentSize.height;
            if (ch > bestH && ch > 300.0f) { bestH = ch; best = sv; }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return best;
}

- (CGFloat)maxOffsetY {
    if (!_sv) return 0;
    CGFloat maxY = _sv.contentSize.height - _sv.bounds.size.height;
    return maxY < 0 ? 0 : maxY;
}

- (void)arm {
    [self disarm];                 // 先清掉残留
    _sv = [self findMainScrollView];
    if (!_sv) {
        NSLog(@"[SuperScreenshot] app: 未找到可滚动视图，自动滚动无效（SB 看门狗将回退 SAD）");
        return;
    }
    uint64_t rh = 0;
    notify_get_state(g_regionTok, &rh);
    _regionH = (CGFloat)rh / 100.0f;
    if (_regionH < 100.0f) _regionH = [UIScreen mainScreen].bounds.size.height;

    _armed = YES;
    _autoStarted = NO;

    // v5.18：步进比例改为偏好可调（默认 0.82，即 18% 重叠）。用户在设置 → 长截图 → 步进比例可调。
    //        滑大 → 每帧新内容多、速度快，但重叠过小时画面会跳；滑小 → 更稳但帧数多。
    BOOL quick = [Common boolPref:@"LongShot_Quick" default:NO];
    CGFloat stepPct = [Common intPref:@"LongShot_StepRatio" default:82] / 100.0f;
    if (stepPct < 0.60f) stepPct = 0.60f; else if (stepPct > 0.95f) stepPct = 0.95f;
    _tickInterval = quick ? 0.28 : 0.42;
    _stepRatio    = stepPct;

    // 第 1 帧：当前滚动位置作为基准
    [self sendCaptureAt:_sv.contentOffset.y];

    // 滚动 + 采集循环
    _timer = [NSTimer scheduledTimerWithTimeInterval:_tickInterval
                                             target:self
                                           selector:@selector(tick)
                                           userInfo:nil
                                            repeats:YES];
    NSLog(@"[SuperScreenshot] app: 自动滚动开始(quick=%d), regionH=%.0f, contentSize=%.0f, maxY=%.0f",
          quick, _regionH, _sv.contentSize.height, [self maxOffsetY]);
}

- (void)disarm {
    _armed = NO;
    [_timer invalidate]; _timer = nil;
    _sv = nil;
    NSLog(@"[SuperScreenshot] app: 自动滚动已停止");
}

// 把 scrollView 向下推「约一屏高 × _stepRatio」；返回实际滚动增量（点）
- (CGFloat)scrollOneStep {
    if (!_sv) return 0;
    CGFloat step = MAX(40.0f, _regionH * _stepRatio);   // 每次滚 ~90% 区域高 → 相邻帧重叠 ~10%（遮接缝）
    CGFloat cur = _sv.contentOffset.y;
    CGFloat maxY = [self maxOffsetY];
    CGFloat newOff = cur + step;
    if (newOff > maxY) newOff = maxY;
    [_sv setContentOffset:CGPointMake(_sv.contentOffset.x, newOff) animated:NO];
    return newOff - cur;
}

- (void)tick {
    if (!_armed) return;
    if (!_sv) { [self finishAuto]; return; }        // 滚动视图已释放，安全退出

    if (!_autoStarted) {
        // 第 1 帧已发，这里做第一次滚动，下一次 tick 再抓滚动后的屏
        _autoStarted = YES;
        [self scrollOneStep];
        return;
    }

    // 抓当前屏（上一轮滚动已渲染完毕）
    [self sendCaptureAt:_sv.contentOffset.y];

    CGFloat maxY = [self maxOffsetY];
    if (_sv.contentOffset.y >= maxY - 1.0f) {
        // 已滚到底：最后一屏（底部剩余部分）已发出，通知 SB 结束
        [self finishAuto];
        return;
    }
    // 继续向下滚
    [self scrollOneStep];
}

- (void)finishAuto {
    _armed = NO;
    [_timer invalidate]; _timer = nil;
    _sv = nil;
    notify_post(SuperScreenshot_LS_DONE);          // 通知 SB：自动采集结束，可拼接/保存
    NSLog(@"[SuperScreenshot] app: 自动滚动采集完成（已到底）");
}

- (void)sendCaptureAt:(CGFloat)offset {
    uint64_t enc = (uint64_t)(round(offset * 100.0));
    notify_set_state(g_offsetTok, enc);     // 写精确偏移（点*100），SB 读取
    notify_post(SuperScreenshot_LS_CAPTURE);            // 触发 SB 抓当前屏
}

@end
