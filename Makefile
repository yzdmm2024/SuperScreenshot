export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_DEVICE_IP_OVERRIDE = 127.0.0.1

# v4.1：theos 默认开 -Werror，本地无法预编译验证时很容易被一条无害 warning 卡住 CI。
# GO_EASY_ON_ME=1 是 theos 官方用来关掉 -Werror 的开关（未知变量时无害）。
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SuperScreenshot

SuperScreenshot_FILES = Tweak.xm \
    src/Common.m \
    src/SuperScreenshotLicense.m \
    src/ImageUtils.m \
    src/XZPassThroughWindow.m \
    src/MaskCropWindow.m \
    src/LongShotCapture.m \
    src/EditToolbarWindow.m \
    src/SuperTools.m \
    src/AppScrollReporter.m \
    src/AIChatWindow.m \
    src/AskAIEngine.m \
    src/HistoryWindow.m \
    src/ResultWindow.m \
    src/OCRBoxWindow.m
SuperScreenshot_FRAMEWORKS = UIKit Foundation Vision PDFKit CoreImage
SuperScreenshot_WEAK_FRAMEWORKS = Photos
SuperScreenshot_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-error -Isrc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = SuperScreenshotPrefs SuperScreenshotCCModule

# v5.25.2：必须把 AskAIEngine.m 一起编进来。
# SuperScreenshotPrefs.m 的「测试连接」按钮会用到 AskAIEngine，而 AskAIEngine.m 原先只编进 tweak
# dylib。prefs bundle 靠 -undefined,dynamic_lookup 把解析推到运行时，但 tweak 的 Filter 里没有
# com.apple.Preferences，设置进程里根本不存在这个类 → dlopen 直接失败：
#   symbol not found in flat namespace '_OBJC_CLASS_$_AskAIEngine'
# 表现就是「设置 → 超级截图」不显示 / 空白。prefs bundle 必须自包含。
SuperScreenshotPrefs_FILES = src/SuperScreenshotPrefs.m src/SuperScreenshotLicense.m src/AskAIEngine.m src/ToolbarOrderController.m \
    src/SuperScreenshotModelStore.m src/SuperScreenshotModelLibController.m src/SuperScreenshotModelPickerController.m
SuperScreenshotPrefs_INSTALL_PATH = /Library/PreferenceBundles
SuperScreenshotPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
SuperScreenshotPrefs_FRAMEWORKS = UIKit Foundation
SuperScreenshotPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

SuperScreenshotCCModule_FILES = src/SuperScreenshotCCModule.m
SuperScreenshotCCModule_INSTALL_PATH = /Library/ControlCenter/Bundles
SuperScreenshotCCModule_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
SuperScreenshotCCModule_FRAMEWORKS = UIKit Foundation
# 不显式链接 ControlCenterUIKit：该私有框架不一定在 CI 的 theos SDK 里，
# 且本模块靠 -undefined,dynamic_lookup 运行时解析父类（CCSupport 载入时
# ControlCenterUIKit 已在控制中心进程内，符号必然可用）。
SuperScreenshotCCModule_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

# v6.18：已移除套壳 companion App（按用户要求，撤销 v6.17 的套壳方案）。