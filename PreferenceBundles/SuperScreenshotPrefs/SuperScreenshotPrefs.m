#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>

// 设置面板主控制器：iOS 设置 → SuperScreenshot延伸板
@interface SuperScreenshotPrefsController : PSListController
@end

@implementation SuperScreenshotPrefsController

// 用框架自带的 setSpecifiers: 把 Root.plist 解析出的 specifiers 写入框架内部存储，
// 避免子类重复声明 _specifiers 与 PSListController 父类 ivar 冲突（那个冲突会让面板空白）。
- (void)viewDidLoad {
    [super viewDidLoad];
    self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
}

@end
