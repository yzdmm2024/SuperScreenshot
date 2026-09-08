//
//  ZhOCRPlugin.m — 注册进 SuperScreenshot 动作菜单的“OCR”项，使用本地 Vision 中文识别
//
#import "ZhOCRPlugin.h"
#import "VisionOCR.h"
#import "OCRBoxWindow.h"
#import "Common.h"

@implementation ZhOCRPlugin

- (NSString *)pluginIdentifier { return XZ_ID_OCR; }

- (BOOL)shouldRegister { return YES; }

- (UIImage *)imageForMenuAndSettings { return [Common systemIcon:@"text.viewfinder"]; }

- (void)runWithImage:(UIImage *)image {
    if (!image) return;
    [Common toast:@"OCR识别中…"];
    [VisionOCR recognizeBlocks:image languages:[Common ocrLanguages] completion:^(NSArray<OCRBlock *> *blocks) {
        if (!blocks.count) {
            [Common toast:@"未识别到文字"];
            return;
        }
        [OCRBoxWindow showForImage:image blocks:blocks];
    }];
}

@end