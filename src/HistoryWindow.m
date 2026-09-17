//
//  HistoryWindow.m — 截图历史记录查看器（v6.06）
//  从 XZ_HISTORY_DIR 读取缩略图，网格展示；点按查看大图，可分享/删除/清空。
//
#import "HistoryWindow.h"
#import "Common.h"
#import "SuperTools.h"
#import <objc/runtime.h>   // v6.06：objc_setAssociatedObject / OBJC_ASSOCIATION_RETAIN

@interface HistoryWindow ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;   // 当前缩略图路径（新→旧）
@property (nonatomic, strong) UIView *viewer;                      // 大图查看层
@end

@implementation HistoryWindow

+ (instancetype)shared {
    static HistoryWindow *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [HistoryWindow new]; });
    return c;
}

+ (void)show { [[self shared] show]; }
+ (void)dismiss { [[self shared] hide]; }

- (NSArray<NSString *> *)historyFiles {
    NSString *dir = XZ_HISTORY_DIR;
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (!all) return @[];
    NSArray *jpg = [all filteredArrayUsingPredicate:
                    [NSPredicate predicateWithFormat:@"self ENDSWITH '.jpg'"]];
    return [jpg sortedArrayUsingSelector:@selector(compare:)];   // 文件名含时间戳，升序=旧→新
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideWithoutAnimation];
        NSArray *files = [self historyFiles];
        if (files.count == 0) { [Common toast:@"还没有截图记录"]; return; }
        self.paths = [NSMutableArray array];
        for (NSString *f in files) [self.paths addObject:[XZ_HISTORY_DIR stringByAppendingPathComponent:f]];

        UIWindow *base = [Common topWindow];
        CGRect b = base.bounds;
        UIWindow *w = [[UIWindow alloc] initWithFrame:b];
        w.windowLevel = UIWindowLevelAlert + 600;   // 同 OCR/结果窗，盖过工具栏面板
        w.hidden = NO;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
                if ([sc isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)sc; break; }
            }
        }
        UIView *v = [[UIView alloc] initWithFrame:b];
        v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        w.rootViewController = [UIViewController new];
        [w.rootViewController.view addSubview:v];
        self.window = w;

        CGFloat sh = b.size.height * 0.82;
        UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height, b.size.width, sh)];
        sheet.backgroundColor = [UIColor systemBackgroundColor];
        sheet.layer.cornerRadius = 20;
        sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [v addSubview:sheet];
        self.sheet = sheet;

        // 顶栏
        CGFloat y = 12;
        UIView *grip = [[UIView alloc] initWithFrame:CGRectMake(b.size.width/2-24, 8, 48, 5)];
        grip.backgroundColor = [UIColor systemGray3Color];
        grip.layer.cornerRadius = 2.5;
        [sheet addSubview:grip];

        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 160, 26)];
        tl.text = [NSString stringWithFormat:@"截图历史（%lu）", (unsigned long)self.paths.count];
        tl.font = [UIFont boldSystemFontOfSize:17];
        tl.textColor = [UIColor labelColor];
        [sheet addSubview:tl];

        UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
        clear.frame = CGRectMake(b.size.width-150, y, 60, 28);
        [clear setTitle:@"清空" forState:UIControlStateNormal];
        [clear setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        [clear addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:clear];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(b.size.width-80, y, 64, 28);
        [close setTitle:@"关闭" forState:UIControlStateNormal];
        [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:close];

        y += 42;

        // 网格
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, y, b.size.width, sh - y - 20)];
        sv.backgroundColor = [UIColor clearColor];
        [sheet addSubview:sv];
        self.scroll = sv;

        NSInteger cols = 4;
        CGFloat pad = 10, gap = 8;
        CGFloat cw = (b.size.width - pad*2 - gap*(cols-1)) / (CGFloat)cols;
        CGFloat chh = cw * 1.6;   // 缩略图按屏比略高
        for (NSInteger i = 0; i < (NSInteger)self.paths.count; i++) {
            NSInteger r = i / cols, c = i % cols;
            UIButton *cell = [UIButton buttonWithType:UIButtonTypeCustom];
            cell.frame = CGRectMake(pad + c*(cw+gap), pad + r*(chh+gap), cw, chh);
            cell.layer.cornerRadius = 8;
            cell.clipsToBounds = YES;
            cell.backgroundColor = [UIColor systemGray6Color];
            [cell setImage:[UIImage imageWithContentsOfFile:self.paths[i]] forState:UIControlStateNormal];
            [cell.imageView setContentMode:UIViewContentModeScaleAspectFill];
            cell.tag = i;
            [cell addTarget:self action:@selector(cellTapped:) forControlEvents:UIControlEventTouchUpInside];
            [sv addSubview:cell];
        }
        sv.contentSize = CGSizeMake(b.size.width, pad*2 + ((self.paths.count + cols - 1)/cols) * (chh+gap));

        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ sheet.frame = CGRectMake(0, b.size.height-sh, b.size.width, sh); }
                         completion:nil];
    });
}

- (void)cellTapped:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.paths.count) return;
    [self openViewerForPath:self.paths[idx]];
}

- (void)openViewerForPath:(NSString *)path {
    if (!self.window) return;
    CGRect b = self.window.bounds;
    UIView *viewer = [[UIView alloc] initWithFrame:b];
    viewer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.92];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectInset(b, 24, 80)];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.image = [UIImage imageWithContentsOfFile:path];
    [viewer addSubview:iv];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.frame = CGRectMake(20, 40, 64, 40);
    [back setTitle:@"返回" forState:UIControlStateNormal];
    [back setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [back addTarget:self action:@selector(closeViewer) forControlEvents:UIControlEventTouchUpInside];
    [viewer addSubview:back];

    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    share.frame = CGRectMake(b.size.width/2-90, b.size.height-70, 80, 46);
    share.backgroundColor = [Common accentColor];
    [share setTitle:@"分享" forState:UIControlStateNormal];
    [share setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    share.layer.cornerRadius = 12;
    share.tag = 1;
    [share addTarget:self action:@selector(viewerAction:) forControlEvents:UIControlEventTouchUpInside];
    [viewer addSubview:share];

    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    del.frame = CGRectMake(b.size.width/2+10, b.size.height-70, 80, 46);
    del.backgroundColor = [UIColor systemRedColor];
    [del setTitle:@"删除" forState:UIControlStateNormal];
    [del setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    del.layer.cornerRadius = 12;
    del.tag = 2;
    [del addTarget:self action:@selector(viewerAction:) forControlEvents:UIControlEventTouchUpInside];
    [viewer addSubview:del];

    viewer.tag = 9909;   // 存 path
    objc_setAssociatedObject(viewer, "superscreenshot_path", path, OBJC_ASSOCIATION_RETAIN);
    [self.window addSubview:viewer];
    self.viewer = viewer;
}

- (void)closeViewer {
    if (self.viewer) { [self.viewer removeFromSuperview]; self.viewer = nil; }
    [self reloadGrid];
}

- (void)viewerAction:(UIButton *)sender {
    NSString *path = objc_getAssociatedObject(self.viewer, "superscreenshot_path");
    if (!path) return;
    if (sender.tag == 1) {
        // 分享（v6.20.20：走统一分享入口，分享完自动收起查看器，不再挡目标 App）
        [SuperTools presentShareForItem:[NSURL fileURLWithPath:path] fromWindow:self.window];
    } else {
        // 删除
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [Common toast:@"已删除"];
        [self closeViewer];
    }
}

- (void)clearAll {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空历史"
                                                               message:@"确定删除全部截图历史记录？"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSString *dir = XZ_HISTORY_DIR;
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
            if ([f hasSuffix:@".jpg"]) [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
        [self reloadGrid];
        [Common toast:@"已清空"];
    }]];
    if (self.window) [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)reloadGrid {
    [self hideWithoutAnimation];
    [self show];
}

- (void)hideWithoutAnimation {
    if (self.viewer) { [self.viewer removeFromSuperview]; self.viewer = nil; }
    if (self.window) {
        [self.window.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        self.window.hidden = YES;
        self.window = nil;
    }
    self.sheet = nil; self.scroll = nil; self.paths = nil;
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.sheet) { [self hideWithoutAnimation]; return; }
        UIView *sheet = self.sheet;
        CGRect b = self.window.bounds;
        [UIView animateWithDuration:0.25 animations:^{
            sheet.frame = CGRectMake(0, b.size.height, b.size.width, sheet.bounds.size.height);
            sheet.alpha = 0;
        } completion:^(BOOL f){ [self hideWithoutAnimation]; }];
    });
}

@end
