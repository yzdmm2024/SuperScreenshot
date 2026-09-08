//
//  SuperScreenshotLicense.h — 设备授权（UDID 解锁码验证）
//
//  算法（与「验证的逻辑/gen_license.py」「dylib_GC函数.m」完全一致）：
//    解锁码 = SHA256(UDID) → 取前 15 字节 → 映射到 56 字符集 → 15 位解锁码
//    字符集去除易混淆字符 0/O/1/l/I，共 56 个。
//  无需密钥、无需服务器：同设备 UDID 永远对应唯一解锁码。
//
//  设计要点：
//  · 完全自包含，不依赖 Common（prefs bundle 不编 Common.m，避免符号缺失）。
//  · 解锁状态存 NSUserDefaults(suite=com.axs.superscreenshot) 键 License_Unlocked，
//    与插件其它偏好同一域，tweak(SpringBoard) 与 prefs(设置) 可共享读写。
//  · 弹窗一律直接 present 在「调用方的 VC」上（presentVerificationInViewController:），
//    绝不自建抢 key 的 host 窗口 —— 彻底避开「自建 UIWindow + makeKeyAndVisible 导致
//    SpringBoard 触摸失效/点不动」的冻结坑（v6.20→v6.20.1 反复踩此坑）。
//  · 控制中心（SpringBoard）路径更保守：根本不弹模态，只给一条非阻塞提示横幅
//    （presentUnlockHint，window.userInteractionEnabled=NO，触摸完全穿透），
//    提示完直接退出本次截图动作 —— 既保住验证门槛，又百分百不会冻结手机。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SuperScreenshotLicense : NSObject

+ (NSString *)deviceUDID;                 // 真实设备 UDID（MGCopyAnswer + 降级）
+ (NSString *)expectedCode;               // SHA256(UDID) → 15 位解锁码
+ (BOOL)verifyCode:(NSString *)code;      // 去空白后比对
+ (BOOL)isUnlocked;
+ (void)setUnlocked:(BOOL)v;
+ (void)markUnlocked;
+ (void)revoke;

// 在「调用方 VC」上安全弹出验证框（复制 UDID / 输入解锁码验证 / 取消 / 已解锁时锁定本机）。
// 不做任何 key window 接管，弹窗关闭后 UIKit 自行恢复，不会冻结。
+ (void)presentVerificationInViewController:(UIViewController *)vc
                                 completion:(void (^)(BOOL nowUnlocked))completion;

// 兼容旧调用：在 keyWindow.rootViewController 上弹验证框。
+ (void)presentVerificationFromWindow:(UIWindow *)win
                           completion:(void (^)(BOOL nowUnlocked))completion;

// 非阻塞提示（用于控制中心路径）：一条会自动消失的提示横幅，绝不拦截触摸。
// 提示「去 设置 › 超级截图 › 设备授权 验证」，然后由调用方自行退出当前动作。
+ (void)presentUnlockHint;

@end
