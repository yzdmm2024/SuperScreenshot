//
//  ToolbarOrderController.m — 工具栏排序 / 自定义（超级截图 v6.01）
//
//  设计约束：本文件只依赖 UIKit / Foundation + NSUserDefaults，
//  不调用任何 Common / EditToolbarWindow / AskAIEngine 的方法或类，
//  否则 prefs bundle 会出现「只存在于 tweak dylib 的自有类」未定义符号，
//  CI 的 check_undef_symbols 守卫会失败（表现：设置面板空白/打不开）。
//  偏好键名与 EditToolbarWindow 读取端保持一致，写死在这里避免引入 Common.h。
//

#import "ToolbarOrderController.h"

// 与 EditToolbarWindow 所用的偏好域 / 键 完全一致（rootless 越狱，写在默认域）
#define kDomain      @"com.axs.superscreenshot"
#define kOrderKey    @"Toolbar_Order"     // 逗号分隔的 tag 顺序
#define kDisabledKey @"Toolbar_Disabled"  // 逗号分隔的 禁用 tag

// 工具栏全部按钮（tag 与 EditToolbarWindow 的 ETBTag 枚举一一对应）
static NSArray<NSNumber *> *kAllTags(void) {
    return @[ @1, @2, @3, @4, @19, @6, @7, @8, @9, @12, @13, @20, @15, @16, @21 ];
}
static NSDictionary<NSNumber *, NSString *> *kTagNames(void) {
    return @{
        @1 : @"OCR",     @2 : @"翻译",    @3 : @"画图",    @4 : @"识码",
        @20: @"打开豆包", @19: @"旋转",
        @6 : @"复制",    @7 : @"贴图",    @8 : @"保存",    @9 : @"分享",
        @12: @"PDF",     @13: @"压缩",    @20: @"打开豆包",
        @15: @"取色",    @16: @"还原",    @21: @"启动",
    };
}

@interface SuperScreenshotToolbarOrderController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray<NSNumber *> *order;     // 完整有序 tag 列表
@property (nonatomic, strong) NSMutableSet<NSNumber *>   *disabled; // 被禁用的 tag
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UILabel *tip;
@end

@implementation SuperScreenshotToolbarOrderController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // —— 读取已保存顺序（无则回退默认全序）——
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *orderStr = [d stringForKey:kOrderKey] ?: @"";
    NSMutableArray<NSNumber *> *ord = [NSMutableArray array];
    if (orderStr.length) {
        for (NSString *p in [orderStr componentsSeparatedByString:@","]) {
            NSNumber *t = @([p integerValue]);
            if ([kAllTags() containsObject:t] && ![ord containsObject:t]) [ord addObject:t];
        }
    }
    for (NSNumber *t in kAllTags()) if (![ord containsObject:t]) [ord addObject:t];
    _order = ord;

    // —— 读取禁用集合 ——
    NSString *disStr = [d stringForKey:kDisabledKey] ?: @"";
    NSMutableSet<NSNumber *> *dis = [NSMutableSet set];
    if (disStr.length) {
        for (NSString *p in [disStr componentsSeparatedByString:@","]) {
            NSNumber *t = @([p integerValue]);
            if ([kAllTags() containsObject:t]) [dis addObject:t];
        }
    }
    _disabled = dis;

    // —— 顶部说明 ——
    _tip = [[UILabel alloc] initWithFrame:CGRectZero];
    _tip.text = @"点右上角「编辑」拖动排序；每行开关控制按钮是否显示。轻点某行可改它的「显示名称 / 图标(SF Symbol 名)」。改动即时生效。";
    _tip.font = [UIFont systemFontOfSize:13];
    _tip.textColor = [UIColor secondaryLabelColor];
    _tip.numberOfLines = 2;
    [self.view addSubview:_tip];

    // —— 列表 ——
    _tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tv.dataSource = self;
    _tv.delegate = self;
    _tv.editing = NO;
    [self.view addSubview:_tv];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"编辑"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleEdit)];

    [self _layout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self _layout];
}

- (void)_layout {
    CGFloat top = 0;
    if (@available(iOS 11.0, *)) {
        top = self.view.safeAreaInsets.top;
    } else {
        top = self.topLayoutGuide.length;
    }
    CGFloat w = self.view.bounds.size.width;
    CGFloat tipH = 44;
    _tip.frame = CGRectMake(16, top + 8, w - 32, tipH);
    _tv.frame = CGRectMake(0, top + 8 + tipH, w, self.view.bounds.size.height - (top + 8 + tipH));
}

- (void)toggleEdit {
    BOOL editing = !_tv.editing;
    [_tv setEditing:editing animated:YES];
    self.navigationItem.rightBarButtonItem.title = editing ? @"完成" : @"编辑";
}

#pragma mark - 持久化

- (void)save {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setObject:[_order componentsJoinedByString:@","] forKey:kOrderKey];
    NSMutableArray<NSString *> *dis = [NSMutableArray array];
    for (NSNumber *t in _disabled) [dis addObject:[t stringValue]];
    [d setObject:[dis componentsJoinedByString:@","] forKey:kDisabledKey];
    [d synchronize];
    // 通知 tweak 进程重新读取偏好
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.axs.superscreenshot.prefsChanged",
                                         NULL, NULL, YES);
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _order.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"superscreenshotrow"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"superscreenshotrow"];
    NSNumber *t = _order[ip.row];

    // v6.06：行文字显示「已自定义的名称」，否则用默认名
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *custom = [d stringForKey:[NSString stringWithFormat:@"Toolbar_Name_%ld", (long)t.integerValue]];
    NSString *display = (custom && custom.length)
        ? custom
        : (kTagNames()[t] ?: [NSString stringWithFormat:@"按钮 %@", t]);
    c.textLabel.text = display;
    c.showsReorderControl = YES;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = ![_disabled containsObject:t];
    sw.tag = [t integerValue];   // 借 tag 记住是哪个按钮
    [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

// v6.06：非编辑模式下轻点某行 → 弹窗改「显示名称 / 图标(SF Symbol 名)」
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (tv.editing) return;   // 编辑模式用于排序，不弹窗
    NSNumber *t = _order[ip.row];
    [self editCustomForTag:t];
}

// v6.06：自定义某按钮的名称 / 图标（写 Toolbar_Name_<tag> / Toolbar_Icon_<tag>，与读取端一致）
- (void)editCustomForTag:(NSNumber *)tag {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *defName = kTagNames()[tag] ?: [NSString stringWithFormat:@"按钮 %@", tag];
    NSString *curName = [d stringForKey:[NSString stringWithFormat:@"Toolbar_Name_%ld", (long)tag.integerValue]] ?: defName;
    NSString *curIcon = [d stringForKey:[NSString stringWithFormat:@"Toolbar_Icon_%ld", (long)tag.integerValue]] ?: @"";

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自定义名称 / 图标"
                                                                message:[NSString stringWithFormat:@"按钮「%@」", defName]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.placeholder = @"显示名称（留空用默认）";
        tf.text = curName;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.placeholder = @"SF Symbol 图标名（留空用默认，如 xmark.circle）";
        tf.text = curIcon;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *nm = [ac.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *ic = [ac.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *dd = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
        NSString *kNm = [NSString stringWithFormat:@"Toolbar_Name_%ld", (long)tag.integerValue];
        NSString *kIc = [NSString stringWithFormat:@"Toolbar_Icon_%ld", (long)tag.integerValue];
        if (nm.length) [dd setObject:nm forKey:kNm]; else [dd removeObjectForKey:kNm];
        if (ic.length) [dd setObject:ic forKey:kIc]; else [dd removeObjectForKey:kIc];
        [dd synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (CFStringRef)@"com.axs.superscreenshot.prefsChanged", NULL, NULL, YES);
        // 刷新本行（显示最新自定义名）
        NSUInteger idx = [_order indexOfObject:tag];
        if (idx != NSNotFound) {
            [self.tv reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:idx inSection:0] ]
                           withRowAnimation:UITableViewRowAnimationNone];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onSwitch:(UISwitch *)sw {
    NSNumber *t = @(sw.tag);
    if (sw.on) [_disabled removeObject:t];
    else       [_disabled addObject:t];
    [self save];
}

// 编辑模式下允许拖动排序
- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return YES; }
- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip { return NO; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleNone;   // 只排序，不删除
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
    NSNumber *t = _order[src.row];
    [_order removeObjectAtIndex:src.row];
    [_order insertObject:t atIndex:dst.row];
    [self save];
}

@end
