//
//  PluginBase.m
//
#import "PluginBase.h"
#import "Common.h"

@implementation PluginBase

#pragma mark - 供 SuperScreenshot 调用的协议方法

- (NSString *)pluginIdentifier { return @""; }

- (BOOL)shouldRegister { return YES; }
- (BOOL)isBottomPlugin { return NO; }
- (NSString *)urlSchemeForPlugin { return nil; }
- (void)setUrlSchemeForPlugin:(NSString *)s { }
- (UIImage *)imageForMenuAndSettings { return [Common systemIcon:@"doc.text.viewfinder"]; }

// SuperScreenshot 触发插件：选区 + 整张图 + 完成回调
- (void)wantsToSnapRect:(CGRect)rect inImage:(UIImage *)image thenDoPlugin:(void (^)(void))completion {
    [self deliverImage:image];
    if (completion) completion();
}

- (void)wantsToSnapRect:(CGRect)rect inImage:(UIImage *)image thenDo:(id)completion {
    [self deliverImage:image];
}
- (void)wantsToSnapRect:(CGRect)rect inImage:(UIImage *)image {
    [self deliverImage:image];
}
- (void)performPluginOnLatestSnap:(id)arg {
    // 拿不到图片时尝试从最新 Snapper 快照截取（见 Tweak.xm 里的兜底 hook）
    if (self.latestSnapImage) [self deliverImage:self.latestSnapImage];
}
- (void)sendForPlugin:(id)arg {
    if (self.latestSnapImage) [self deliverImage:self.latestSnapImage];
}

// 其它 SuperScreenshot 可能调用的生命周期/设置方法
- (void)snapSentToApplication { }
- (void)snapWillSave { }
- (void)snapChanged { }
- (void)snapClosed { }
- (void)snapMoved { }
- (void)email { }
- (void)twitter { }
- (void)website { }
- (void)info { }
- (NSString *)name { return NSStringFromClass(self.class); }
- (void)showInSettings { }

#pragma mark - 内部

@synthesize latestSnapImage = _latestSnapImage;

- (void)deliverImage:(UIImage *)image {
    if (image) {
        self.latestSnapImage = image;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self runWithImage:image];
        });
    }
}

- (void)runWithImage:(UIImage *)image { }

@end