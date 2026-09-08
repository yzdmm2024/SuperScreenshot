//
//  SuperScreenshotModelStore.m — 大模型库 预置 bundle 侧共享工具实现
//
#import "SuperScreenshotModelStore.h"

NSUserDefaults *SuperScreenshotDefs(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:SuperScreenshot_DOMAIN];
        // v6.20.15 改名迁移：首次初始化时把旧包域名 com.axs.snapper3zhext 的设置
        // （模型库 / 密钥 / 工具栏排序等）搬到新域名，已存在的键不覆盖。
        @try {
            NSUserDefaults *legacy =
                [[NSUserDefaults alloc] initWithSuiteName:@"com.axs.snapper3zhext"];
            NSDictionary *legacyAll = [legacy dictionaryRepresentation];
            if (legacyAll.count) {
                for (NSString *k in legacyAll) {
                    if ([k hasPrefix:@"NS"] || [k hasPrefix:@"Apple"]) continue; // 跳过系统全局域键
                    if ([d objectForKey:k] == nil && [legacyAll[k] isKindOfClass:[NSObject class]]) {
                        [d setObject:legacyAll[k] forKey:k];
                    }
                }
                [d synchronize];
            }
        } @catch (NSException *ex) {
            NSLog(@"[SuperScreenshot] legacy prefs migration failed: %@", ex);
        }
    });
    return d;
}

NSString *SuperScreenshotNewUUID(void) {
    return [[NSUUID UUID] UUIDString];
}

NSArray<NSDictionary *> *SuperScreenshotLoadModels(void) {
    NSString *json = [SuperScreenshotDefs() stringForKey:SuperScreenshot_K_LIB];
    if (!json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return @[];
    NSError *e = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:&e];
    if (![obj isKindOfClass:[NSArray class]]) return @[];
    return obj;
}

void SuperScreenshotSaveModels(NSArray *models) {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:models ?: @[] options:0 error:&e];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    [SuperScreenshotDefs() setObject:json forKey:SuperScreenshot_K_LIB];
    [SuperScreenshotDefs() synchronize];
    // 通知 tweak 侧刷新（模型库变化即时生效）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.axs.superscreenshot.prefsChanged", NULL, NULL, YES);
}

NSString *SuperScreenshotModelField(NSDictionary *m, NSString *k, NSString *def) {
    id v = m[k];
    return (v && [v isKindOfClass:[NSString class]] && [v length]) ? v : def;
}

NSDictionary *SuperScreenshotModelById(NSArray *models, NSString *mid) {
    if (!mid.length) return nil;
    for (NSDictionary *m in models) if ([m[@"id"] isEqualToString:mid]) return m;
    return nil;
}

NSArray<NSDictionary *> *SuperScreenshotPresets(void) {
    return @[
        @{@"name":@"DeepSeek",        @"baseURL":@"https://api.deepseek.com/v1",            @"model":@"deepseek-chat",        @"vendor":@"deepseek"},
        @{@"name":@"OpenAI",          @"baseURL":@"https://api.openai.com/v1",             @"model":@"gpt-4o-mini",          @"vendor":@"openai"},
        @{@"name":@"智谱 BigModel",    @"baseURL":@"https://open.bigmodel.cn/api/paas/v4",   @"model":@"glm-4v-flash",        @"vendor":@"zhipu"},
        @{@"name":@"通义千问",         @"baseURL":@"https://dashscope.aliyuncs.com/compatible-mode/v1", @"model":@"qwen2.5-vl-72b-instruct", @"vendor":@"qwen"},
        @{@"name":@"火山方舟(豆包)",   @"baseURL":@"https://ark.cn-beijing.volces.com/api/v3", @"model":@"ep-xxxxxxxx",        @"vendor":@"volc"},
        @{@"name":@"Ollama 本地",      @"baseURL":@"http://127.0.0.1:11434/v1",             @"model":@"llama3",              @"vendor":@"ollama"},
        @{@"name":@"百度 PaddleOCR (免费)", @"baseURL":@"",                                  @"model":@"",                   @"vendor":@"paddleocr"},
    ];
}

void SuperScreenshotMigrateIfNeeded(void) {
    NSUserDefaults *d = SuperScreenshotDefs();
    if ([d boolForKey:SuperScreenshot_K_MIGRATED]) return;
    [d setBool:YES forKey:SuperScreenshot_K_MIGRATED];

    NSMutableArray *lib = [SuperScreenshotLoadModels() mutableCopy];
    BOOL changed = NO;

    NSString *aiKey = [d stringForKey:@"AskAI_APIKey"] ?: @"";
    NSString *aiURL = [d stringForKey:@"AskAI_BaseURL"] ?: @"";
    NSString *aiMdl = [d stringForKey:@"AskAI_Model"]   ?: @"";
    if (aiKey.length || aiURL.length || aiMdl.length) {
        if (!SuperScreenshotModelById(lib, @"mig_ai")) {
            [lib addObject:@{@"id":@"mig_ai", @"name":@"我的对话模型",
                             @"baseURL":aiURL.length?aiURL:@"https://api.deepseek.com/v1",
                             @"apiKey":aiKey, @"model":aiMdl.length?aiMdl:@"deepseek-chat",
                             @"vendor":@"openai"}];
            [d setObject:@"mig_ai" forKey:SuperScreenshot_K_AI];
            changed = YES;
        }
    }

    NSString *bmKey = [d stringForKey:@"BigModel_APIKey"] ?: @"";
    NSString *bmURL = [d stringForKey:@"BigModel_BaseURL"] ?: @"";
    NSString *bmMdl = [d stringForKey:@"BigModel_Model"]   ?: @"";
    if (bmKey.length || bmURL.length || bmMdl.length) {
        if (!SuperScreenshotModelById(lib, @"mig_ocr")) {
            [lib addObject:@{@"id":@"mig_ocr", @"name":@"智谱 BigModel (识别)",
                             @"baseURL":bmURL.length?bmURL:@"https://open.bigmodel.cn/api/paas/v4",
                             @"apiKey":bmKey, @"model":bmMdl.length?bmMdl:@"glm-4v-flash",
                             @"vendor":@"zhipu"}];
            [d setObject:@"mig_ocr" forKey:SuperScreenshot_K_OCR];
            changed = YES;
        }
    }

    if (changed) SuperScreenshotSaveModels(lib);
}
