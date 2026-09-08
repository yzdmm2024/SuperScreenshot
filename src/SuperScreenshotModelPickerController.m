//
//  SuperScreenshotModelPickerController.m — 为某个功能(问AI/识别引擎/翻译)选择「使用模型」(radio)
//
#import "SuperScreenshotModelStore.h"
#import "Common.h"

@interface SuperScreenshotModelPickerController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *featureKey;
@property (nonatomic, strong) NSString *selId;
@property (nonatomic, strong) NSArray<NSDictionary *> *models;     // 库里的模型
@property (nonatomic, strong) NSArray<NSDictionary *> *dispModels; // 实际展示（OCR 时末尾追加内置 PaddleOCR）
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, assign) BOOL isOCR;
@property (nonatomic, assign) BOOL hasBuiltin; // 是否追加了内置 PaddleOCR 行
@end

@implementation SuperScreenshotModelPickerController

- (instancetype)initWithFeatureKey:(NSString *)key title:(NSString *)title {
    if (self = [super init]) {
        _featureKey = key;
        self.title = title;
    }
    return self;
}

- (BOOL)_libraryHasPaddleOCR {
    for (NSDictionary *m in self.models) {
        if ([[SuperScreenshotModelField(m, @"vendor", @"") lowercaseString] isEqualToString:@"paddleocr"]) return YES;
    }
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    SuperScreenshotMigrateIfNeeded();
    self.models = SuperScreenshotLoadModels();
    self.selId  = [SuperScreenshotDefs() stringForKey:self.featureKey] ?: @"";
    self.isOCR  = [self.featureKey isEqualToString:SuperScreenshot_K_OCR];

    // OCR 选择器：若库里还没 PaddleOCR，则在末尾追加一个「内置 PaddleOCR」选项，选中即走免费通道
    NSMutableArray *disp = [self.models mutableCopy];
    self.hasBuiltin = NO;
    if (self.isOCR && ![self _libraryHasPaddleOCR]) {
        self.hasBuiltin = YES;
        [disp addObject:@{ @"id": XZ_PPOCR_SENTINEL,
                           @"name": @"百度 PaddleOCR (免费)",
                           @"model": @"AI Studio 免费 OCR",
                           @"vendor": @"paddleocr",
                           @"__builtin": @YES }];
    }
    self.dispModels = disp;

    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tv.delegate = self;
    self.tv.dataSource = self;
    [self.view addSubview:self.tv];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.dispModels.count + 1; // +1 = 不使用(关闭)
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"p"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"p"];
    c.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row == 0) {
        c.textLabel.text = @"不使用（关闭该功能）";
        c.detailTextLabel.text = @"选这个等于关闭 AI / 识别 / 翻译";
        if (self.selId.length == 0) c.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        NSDictionary *m = self.dispModels[ip.row-1];
        c.textLabel.text = SuperScreenshotModelField(m, @"name", @"(未命名)");
        c.detailTextLabel.text = SuperScreenshotModelField(m, @"model", @"未设模型");
        if ([self.selId isEqualToString:m[@"id"]]) c.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *pick = nil;
    BOOL syncPPOCR_ON = NO;          // 是否同步把 PPOCR_Enabled 拉到 ON
    BOOL isPaddleOCRRow = NO;        // picker 选中的行是 PPOCR（内置行 / vendor=paddleocr）？
    if (ip.row == 0) {
        pick = @"";
    } else {
        NSDictionary *m = self.dispModels[ip.row-1];
        id mid = m[@"id"];
        pick = [mid isKindOfClass:[NSString class]] ? (NSString *)mid : @"";
        BOOL isBuiltin = [m[@"__builtin"] boolValue];
        NSString *vendor = SuperScreenshotModelField(m, @"vendor", @"");
        isPaddleOCRRow = isBuiltin || [vendor isEqualToString:@"paddleocr"];
    }
    self.selId = pick;

    // v6.16: 识别引擎 picker 选中后自动同步 PPOCR_Enabled，避免「开关开着选大模型
    //          → 仍走 PP-OCR」的虚假「切换没差别」。
    //   - 选「不使用」 / 选非 paddleocr 的普通大模型 → PPOCR_Enabled = NO
    //   - 选内置 PaddleOCR / vendor=paddleocr → PPOCR_Enabled = YES
    // （仅对 OCR 选择器生效；问AI / 翻译 选择器不动这个键）
    if (self.isOCR) {
        [SuperScreenshotDefs() setBool:isPaddleOCRRow forKey:@"PPOCR_Enabled"];
        syncPPOCR_ON = YES;
    }

    [SuperScreenshotDefs() setObject:pick forKey:self.featureKey];
    [SuperScreenshotDefs() synchronize];
    if (syncPPOCR_ON) {
        // 不必再发一次 darwin notify:同一组 setObject:synchronize 后面的统一一次 post
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.axs.superscreenshot.prefsChanged", NULL, NULL, YES);
    [self.tv reloadData];
    // 延迟返回，让用户看到勾选
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self.navigationController popViewControllerAnimated:YES]; });
}

@end
