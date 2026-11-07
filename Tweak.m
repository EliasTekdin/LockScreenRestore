// LockScreenRestore — iOS 15 lock screen look on iOS 16 (rootless):
// thin white clock, date below it as "Sunday, September 27", focus pill under the date, big
// padlock that stays open after Face ID, notifications listed top-down under the clock, no
// vibrancy tint, no depth effect, no widgets, iOS 15 music player, live wallpapers.
//
// Sizes and positions adapt to the device: they come from the per-device values SpringBoard
// still carries from iOS 15 (SBFLockScreenMetrics) plus ratios measured against Apple's iOS 15
// lock screen, and are converted with the real font metrics at runtime.
//
// Independently switchable groups (Settings > LockScreenRestore, all on by default), applied at
// SpringBoard launch — the settings page has a respring button. The music player part runs in
// MediaRemoteUI, which restarts with SpringBoard.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreText/CoreText.h>
#import <os/log.h>
#import <substrate.h>
#import <dlfcn.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <os/lock.h>
#import "LSRBokeh.h"
#import "LSRSim.h"

// Read straight from disk: NSUserDefaults in SpringBoard's constructor didn't see the values
// (cfprefsd). The settings page flushes to disk before its respring. Rootless jailbreaks
// (Dopamine) redirect tweak preferences under /var/jb, so look there first.
static NSString *const kLSRPrefsPaths[] = {
    @"/var/jb/var/mobile/Library/Preferences/com.aronsz26.lockscreenrestore.plist",
    @"/var/mobile/Library/Preferences/com.aronsz26.lockscreenrestore.plist",
};
static BOOL sLSRClockEnabled = YES;
// The notification list's vertical movement is applied to the Dynamic Island lock glyph so it
// travels with the list rather than remaining pinned to the status area.
static CGFloat sLSRNotificationScrollDisplacement = 0.0;
static __weak UIScrollView *sLSRNotificationScrollBaselineList = nil;
static CGFloat sLSRNotificationScrollBaseline = 0.0;

// Debug builds log to LockScreenRestoreDebug.log.
#ifdef DEBUG
static void LSRDebugLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LSRDebugLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [NSString stringWithFormat:@"%.2f %@\n", CACurrentMediaTime(), [[NSString alloc] initWithFormat:format arguments:args]];
    va_end(args);
    // MediaRemoteUI is sandboxed: its log goes to its own tmp folder.
    BOOL springBoard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"];
    NSString *path = [springBoard ? LSRDevicePath(@"/var/mobile/Documents") : NSTemporaryDirectory()
        stringByAppendingPathComponent:@"LockScreenRestoreDebug.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}
#else
#define LSRDebugLog(...) do {} while (0)
#endif

@interface SBFLockScreenDateView : UIView
+ (UIFont *)timeFont;
- (void)setCustomTimeFont:(UIFont *)font;
- (UIFont *)customTimeFont;
@end

@interface BSUIVibrancyEffectView : UIView
@property (nonatomic) BOOL isEnabled;
@end

@interface CSProminentTextElementView : UIView
@property (nonatomic, strong) NSDate *date;
@property (readonly, nonatomic) UILabel *textLabel;
@end

@interface CSProminentTimeView : CSProminentTextElementView
@end

@interface CSProminentSubtitleDateView : CSProminentTextElementView
@end

@interface CSProminentDisplayView : UIView
@property (readonly, nonatomic) BSUIVibrancyEffectView *vibrancyEffectView;
@property (nonatomic, strong) CSProminentTimeView *timeView;
@property (nonatomic, strong) CSProminentTextElementView *transientSubtitleView;
@property (nonatomic, strong) CSProminentTextElementView *customSubtitleView;
@end

@interface _UIAnimatingLabel : UILabel
@end

@interface SBUIProudLockIconView : UIView
@end

@interface PBUIPosterFloatingLayerReplica : UIView
@end

#pragma mark - Per-device layout

// Ratios measured on Apple's iOS 15 lock screen (both reference renders agree):
// - the iOS 15 clock is 0.8x the size of iOS 16's clock font on the same device (80 vs 100pt)
// - time baseline sits 0.441 x clock size above the date baseline (0.615 x digit height)
// - SF digits are 0.717em tall
// - the padlock's center sits 0.531 x clock size above the top of the digits
// - the date's descenders reach 0.21em below its baseline; content under the date (the Focus
//   pill, whose item has 10pt of built-in top padding) starts right there
static const CGFloat kIOS15ClockScale = 0.8;
// Settings > Clock Size (1 = iOS 15's size), for anyone who wants it bigger or smaller.
static CGFloat sLSRClockSizeFactor = 1.0;
// Weights on the system font's weight axis (Thin 111, Light 274, Regular 400, Medium 510).
// Clock: only the fallback when iOS 15's own font can't be built (see LSRIOS15ClockFont); Thin
// looked slightly too thin, 220 and 250 too thick, 170 matched. Date: Regular (170 looked too
// thin, Medium too heavy). UIFontWeight values between the named weights get rounded to the
// nearest one, so the axis is set directly.
static const CGFloat kIOS15ClockWeightAxis = 170.0;
// +[SBFLockScreenDateView timeFont] on iOS 15.0-15.8: CTFontCreateUIFontForLanguage(140, size)
// (".AppleSystemUIFontThinAlways") copied with the traits grade 2 and design "Soft". The same
// calls give the same glyphs and advances on iOS 16; the weight-axis font has the same strokes
// but a 3pt narrower colon and up to 1pt wider digits at 80pt.
static const uint32_t kIOS15ClockUIFontType = 140;
static const NSInteger kIOS15ClockGrade = 2;
static const CGFloat kIOS15DateWeightAxis = 400.0;
static const CGFloat kIOS15DateBaseFontSize = 22.0;
static const uint32_t kFontAxisWeight = 'wght';
static const CGFloat kIOS15TimeBaselineAboveDate = 0.441;
static const CGFloat kSFDigitHeight = 0.717;
static const CGFloat kIOS15PadlockCenterAboveDigits = 0.531;
static const CGFloat kSFDescender = 0.21;
// iOS 15's clock on iPhones (SpringBoardFoundation 15.6.1: SBFLockScreenDateView timeFont,
// SBFDashBoardViewMetrics timeLabelBaselineY/searchClippingLineMaxY; checked against an
// iPhone 13 Pro and XR): a fixed size per screen, the time baseline at the status area plus the
// clock size but not above a minimum, and the date 36pt below the time.
static const CGFloat kIOS15FaceIDTimeBaselineMin = 175.0;
static const CGFloat kIOS15PlusTimeBaselineMin = 154.0;
static const CGFloat kIOS15HomeButtonTimeBaselineMin = 140.0;
static const CGFloat kIOS15FaceIDStatusArea = 92.0;
static const CGFloat kIOS15HomeButtonStatusArea = 68.0;
static const CGFloat kIOS15TimeToDate = 36.0;
static const CGFloat kIOS15FaceIDPadlockCenter = 76.0;
static const CGFloat kIOS15DateBaselineToList = 29.0;

// 0 = a screen iOS 15 didn't have (Dynamic Island): then 0.8x iOS 16's size.
static CGFloat LSRIOS15ClockSize(CGFloat screenHeight) {
    if (screenHeight == 568.0 || screenHeight == 667.0) return 70.0;  // SE, 8
    if (screenHeight == 736.0) return 86.0;                           // 8 Plus (measured on iOS 15: 62pt digits)
    if (screenHeight == 812.0 || screenHeight == 844.0) return 80.0;  // X, XS, 11 Pro, 12/13 (mini, Pro)
    if (screenHeight == 896.0 || screenHeight == 926.0) return 90.0;  // XR, XS Max, 11, Pro Max, 14 Plus
    return 0;
}

typedef struct {
    CGFloat clockFontSize;
    CGFloat dateFontSize;
    CGFloat timeBaselineY;   // screen coordinates, lock screen at rest
    CGFloat dateBaselineY;
    CGFloat padlockScale;
    CGFloat padlockDrop;     // from iOS 16's padlock position to the iOS 15 one
} LSRLayout;

static CGFloat LSRClassMetric(NSString *className, NSString *selectorName, CGFloat fallback) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || ![cls respondsToSelector:sel]) return fallback;
    CGFloat value = ((CGFloat (*)(id, SEL))objc_msgSend)(cls, sel);
    return value > 0 ? value : fallback;
}

// Fallbacks are the values an iPhone 13 Pro reports.
static LSRLayout LSRCurrentLayout(void) {
    static LSRLayout layout;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class dateViewClass = NSClassFromString(@"SBFLockScreenDateView");
        UIFont *iOS16TimeFont = [dateViewClass respondsToSelector:@selector(timeFont)] ? [dateViewClass timeFont] : nil;
        CGFloat iOS16TimeSize = iOS16TimeFont.pointSize > 0 ? iOS16TimeFont.pointSize : 100.0;

        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGFloat screenHeight = MAX(screen.width, screen.height);
        BOOL phone = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        BOOL faceID = phone && screenHeight >= 812.0;
        CGFloat iOS15Size = phone ? LSRIOS15ClockSize(screenHeight) : 0;
        layout.clockFontSize = round((iOS15Size > 0 ? iOS15Size : iOS16TimeSize * kIOS15ClockScale) * sLSRClockSizeFactor);
        layout.dateFontSize = kIOS15DateBaseFontSize; // at the default text size; LSRDateFont() follows Text Size
        layout.padlockScale = 1.0 / LSRClassMetric(@"SBFLockScreenMetrics", @"proudLockScaleFactor", 0.5);

        CGFloat digitsTop, padlockCenter;
        if (phone) {
            // iOS 15's own placement (SBFDashBoardViewMetrics timeLabelBaselineY): below the
            // status area by the clock's size, but never above a per-device minimum. The metric
            // used on iPads below is off on some iPhones (iPhone X with 16.7) and missing on iOS 17.
            CGFloat minimum = faceID ? kIOS15FaceIDTimeBaselineMin
                : (screenHeight >= 736.0 ? kIOS15PlusTimeBaselineMin : kIOS15HomeButtonTimeBaselineMin);
            CGFloat statusArea = faceID ? kIOS15FaceIDStatusArea : kIOS15HomeButtonStatusArea;
            layout.timeBaselineY = MAX(minimum, statusArea + layout.clockFontSize);
            layout.dateBaselineY = layout.timeBaselineY + kIOS15TimeToDate * sLSRClockSizeFactor;
            digitsTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
            // Face ID iPhones: the padlock sits at the same height on all of them.
            padlockCenter = faceID ? kIOS15FaceIDPadlockCenter
                : digitsTop - kIOS15PadlockCenterAboveDigits * layout.clockFontSize;
        } else {
            layout.dateBaselineY = LSRClassMetric(@"SBFLockScreenMetrics", @"subtitleBaselineOffsetFromTopOfScreen", 211.0);
            layout.timeBaselineY = layout.dateBaselineY - kIOS15TimeBaselineAboveDate * layout.clockFontSize;
            digitsTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
            padlockCenter = digitsTop - kIOS15PadlockCenterAboveDigits * layout.clockFontSize;
        }
        CGFloat iOS16PadlockCenter = LSRClassMetric(@"SBFLockScreenMetrics", @"proudLockCenterFromTopOfScreen", 64.5);
        layout.padlockDrop = padlockCenter - iOS16PadlockCenter;
    });
    return layout;
}

static UIFont *LSRSystemFont(CGFloat size, CGFloat weightAxis) {
    UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
    UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorByAddingAttributes:@{
        (__bridge NSString *)kCTFontVariationAttribute: @{ @(kFontAxisWeight): @(weightAxis) },
    }];
    return [UIFont fontWithDescriptor:descriptor size:size];
}

static UIFont *LSRIOS15ClockFont(CGFloat size) {
    CFStringRef *gradeTrait = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCTFontGradeTrait");
    CFStringRef *designTrait = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCTFontUIFontDesignTrait");
    CFStringRef *designSoft = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCTFontUIFontDesignSoft");
    if (!gradeTrait || !designTrait || !designSoft) return nil;
    CTFontRef base = CTFontCreateUIFontForLanguage((CTFontUIFontType)kIOS15ClockUIFontType, size, NULL);
    if (!base) return nil;
    NSDictionary *attributes = @{ (__bridge NSString *)kCTFontTraitsAttribute: @{
        (__bridge NSString *)*gradeTrait: @(kIOS15ClockGrade),
        (__bridge NSString *)*designTrait: (__bridge NSString *)*designSoft,
    } };
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    CTFontRef font = CTFontCreateCopyWithAttributes(base, 0.0, NULL, descriptor);
    CFRelease(descriptor);
    CFRelease(base);
    return (__bridge_transfer UIFont *)font;
}

// Cached: compared with isEqual: on every layout pass, and building them isn't free.
static UIFont *LSRClockFont(void) {
    static UIFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat size = LSRCurrentLayout().clockFontSize;
        font = LSRIOS15ClockFont(size) ?: LSRSystemFont(size, kIOS15ClockWeightAxis);
    });
    return font;
}

// iOS 15's date follows Settings > Display & Brightness > Text Size: 22pt at the default size, scaled
// like body text, up to Accessibility XXL (XL on 4" screens); the clock doesn't
// (+[SBFLockScreenDateSubtitleView labelFont], still in iOS 16).
static CGFloat LSRIOS15DateFontSize(void) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    UIContentSizeCategory maximum = MAX(screen.width, screen.height) > 568.0
        ? UIContentSizeCategoryAccessibilityExtraExtraLarge : UIContentSizeCategoryAccessibilityExtraLarge;
    Class subtitleClass = NSClassFromString(@"SBFLockScreenDateSubtitleView");
    SEL scaled = NSSelectorFromString(@"scaledFontSize:withMaximumFontSizeCategory:");
    if ([subtitleClass respondsToSelector:scaled]) {
        CGFloat size = ((CGFloat (*)(id, SEL, CGFloat, NSString *))objc_msgSend)(subtitleClass, scaled, kIOS15DateBaseFontSize, maximum);
        if (size > 0) return size;
    }
    UIContentSizeCategory category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (UIContentSizeCategoryCompareToCategory(category, maximum) == NSOrderedDescending) category = maximum;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:category];
    return round([[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:kIOS15DateBaseFontSize
        compatibleWithTraitCollection:traits] * 2.0) / 2.0;
}

// Rebuilt when Text Size changes.
static UIFont *LSRDateFont(void) {
    static UIFont *font;
    static UIContentSizeCategory fontCategory;
    UIContentSizeCategory category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (!font || ![category isEqualToString:fontCategory]) {
        font = LSRSystemFont(LSRIOS15DateFontSize(), kIOS15DateWeightAxis);
        fontCategory = category;
    }
    return font;
}

static UIView *LSRFindSubview(UIView *root, Class cls) {
    if (!cls) return nil;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:cls]) return sub;
        UIView *found = LSRFindSubview(sub, cls);
        if (found) return found;
    }
    return nil;
}

static BOOL LSRHasDynamicIslandLayout(void) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    // iPhone 15 Pro Max reports a 430 × 932pt screen, not 950pt high. The old
    // 950pt cutoff missed it, so the lock fell back to the oversized legacy scale.
    return [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone
        && MAX(screen.width, screen.height) >= 900.0
        && MIN(screen.width, screen.height) >= 430.0;
}

static void LSRUpdateLockScrollPosition(UIScrollView *list) {
    if (!LSRHasDynamicIslandLayout()) return;
    Class listClass = NSClassFromString(@"NCNotificationListView");
    if (!list || (list.superview && [list.superview isKindOfClass:listClass])) return;

    CGFloat normalizedOffset = list.contentOffset.y + list.adjustedContentInset.top;
    if (sLSRNotificationScrollBaselineList != list) {
        sLSRNotificationScrollBaselineList = list;
        sLSRNotificationScrollBaseline = normalizedOffset;
    }
    sLSRNotificationScrollDisplacement = normalizedOffset - sLSRNotificationScrollBaseline;
    UIView *lockView = LSRFindSubview(list.window, NSClassFromString(@"SBUIProudLockIconView"));
    [lockView setNeedsLayout];
}

#pragma mark - Group: iOS 15 clock (padlock, time, date, colors, no depth effect)

static void LSRClock_SBFLockScreenDateView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_SBFLockScreenDateView_layoutSubviews;
static void LSRClock_SBFLockScreenDateView_layoutSubviews(id self, SEL _cmd) {
    if (fabs(((SBFLockScreenDateView *)self).customTimeFont.pointSize - LSRCurrentLayout().clockFontSize) > 0.5) {
        [(SBFLockScreenDateView *)self setCustomTimeFont:LSRClockFont()];
    }
    ((void (*)(id, SEL))LSRClock_orig_SBFLockScreenDateView_layoutSubviews)(self, _cmd);
}

#pragma mark - Time and date positions
//
// iOS positions CSProminentTimeView / CSProminentSubtitleDateView via setFrame:/setCenter:.
// Transforms on top of that get mis-compensated by UIKit, so we substitute the position
// instead. Targets are baselines in screen coordinates; the full-screen CSProminentDisplayView
// is the reference, so the math also holds while the lock screen is being swiped away. Each
// label is vertically centered in its view, and its baseline sits one ascender below its top.

// Set while we assign positions ourselves, so nested setFrame:/setCenter: calls pass through.
static BOOL sLSRApplying = NO;

// The full-screen view holding time and date; the focus pill measures itself against it.
static __weak UIView *sLSRDisplayView = nil;

// Top for a view whose centered label (in `font`) should have its baseline at `baselineY`.
static BOOL LSRTargetTopForBaseline(UIView *view, CGFloat baselineY, UIFont *font, CGFloat height, CGFloat *outTop) {
    UIView *container = view.superview;
    UIView *display = container;
    Class displayClass = NSClassFromString(@"CSProminentDisplayView");
    while (display && ![display isKindOfClass:displayClass]) display = display.superview;
    if (!container || !display || !font) return NO;

    CGFloat containerY = [container convertPoint:CGPointZero toView:display].y;
    *outTop = baselineY - containerY - ((height - font.lineHeight) / 2.0 + font.ascender);
    return YES;
}

static BOOL LSRTargetTop(UIView *view, BOOL isTime, CGFloat height, CGFloat *outTop) {
    LSRLayout layout = LSRCurrentLayout();
    return LSRTargetTopForBaseline(view, isTime ? layout.timeBaselineY : layout.dateBaselineY,
                                   isTime ? LSRClockFont() : LSRDateFont(), height, outTop);
}

static void LSRMoveTop(UIView *view, CGFloat top) {
    CGFloat currentTop = view.center.y - view.bounds.size.height / 2.0;
    if (fabs(currentTop - top) < 0.25) return;
    CGPoint center = view.center;
    center.y = top + view.bounds.size.height / 2.0;
    sLSRApplying = YES;
    view.center = center;
    sLSRApplying = NO;
}

static void LSRPlaceView(UIView *view, BOOL isTime) {
    CGFloat top;
    if (view && LSRTargetTop(view, isTime, view.bounds.size.height, &top)) LSRMoveTop(view, top);
}

static CGRect LSRAdjustedFrame(UIView *view, BOOL isTime, CGRect frame) {
    CGFloat top;
    if (LSRTargetTop(view, isTime, frame.size.height, &top)) frame.origin.y = top;
    return frame;
}

static CGPoint LSRAdjustedCenter(UIView *view, BOOL isTime, CGPoint center) {
    CGFloat height = view.bounds.size.height;
    CGFloat top;
    if (LSRTargetTop(view, isTime, height, &top)) center.y = top + height / 2.0;
    return center;
}

static void LSRClock_CSProminentTimeView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_CSProminentTimeView_layoutSubviews;
static void LSRClock_CSProminentTimeView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSProminentTimeView_layoutSubviews)(self, _cmd);
    UILabel *label = ((CSProminentTimeView *)self).textLabel;
    UIFont *font = LSRClockFont();
    if (label && ![label.font isEqual:font]) label.font = font;
}

static void LSRClock_CSProminentTimeView_setFrame(id self, SEL _cmd, CGRect frame);
static IMP LSRClock_orig_CSProminentTimeView_setFrame;
static void LSRClock_CSProminentTimeView_setFrame(id self, SEL _cmd, CGRect frame) {
    if (sLSRApplying) {
        ((void (*)(id, SEL, CGRect))LSRClock_orig_CSProminentTimeView_setFrame)(self, _cmd, frame);
        return;
    }
    sLSRApplying = YES;
    ((void (*)(id, SEL, CGRect))LSRClock_orig_CSProminentTimeView_setFrame)(self, _cmd, LSRAdjustedFrame((UIView *)self, YES, frame));
    sLSRApplying = NO;
}

static void LSRClock_CSProminentTimeView_setCenter(id self, SEL _cmd, CGPoint center);
static IMP LSRClock_orig_CSProminentTimeView_setCenter;
static void LSRClock_CSProminentTimeView_setCenter(id self, SEL _cmd, CGPoint center) {
    if (sLSRApplying) {
        ((void (*)(id, SEL, CGPoint))LSRClock_orig_CSProminentTimeView_setCenter)(self, _cmd, center);
        return;
    }
    sLSRApplying = YES;
    ((void (*)(id, SEL, CGPoint))LSRClock_orig_CSProminentTimeView_setCenter)(self, _cmd, LSRAdjustedCenter((UIView *)self, YES, center));
    sLSRApplying = NO;
}

#pragma mark - Date text: "Sunday, September 27", regular weight

static NSDateFormatter *LSRLongDateFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Fixed pattern rather than a localized template: English language + German region
        // would otherwise give "Sunday, 27. September".
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale autoupdatingCurrentLocale];
        formatter.dateFormat = @"EEEE, MMMM d";
    });
    return formatter;
}

// The view formats via its own _formatter ivar and writes the label directly, so we correct
// the label itself. Only assign when different, so the resulting relayout finds nothing to do.
static __weak CSProminentSubtitleDateView *sLSRDateView;

static void LSRApplyIOS15Date(CSProminentSubtitleDateView *view) {
    UILabel *label = view.textLabel;
    if (!label) return;
    sLSRDateView = view;
    NSString *wanted = [LSRLongDateFormatter() stringFromDate:view.date ?: [NSDate date]];
    if (![label.text isEqualToString:wanted]) label.text = wanted;
    UIFont *font = LSRDateFont();
    if (![label.font isEqual:font]) label.font = font;
}

// Something re-assigns the short "Sun Sep 27" text bypassing the view's own methods, so the
// label's setters are the one reliable choke point — scoped to the label inside the date view.
static NSString *LSRIOS15DateTextForLabel(UILabel *label, NSString *incoming) {
    Class dateViewClass = NSClassFromString(@"CSProminentSubtitleDateView");
    if (!incoming.length || ![label.superview isKindOfClass:dateViewClass]) return incoming;
    CSProminentSubtitleDateView *dateView = (CSProminentSubtitleDateView *)label.superview;
    return [LSRLongDateFormatter() stringFromDate:dateView.date ?: [NSDate date]];
}

static void LSRClock_UIAnimatingLabel_setText(id self, SEL _cmd, NSString *text);
static IMP LSRClock_orig_UIAnimatingLabel_setText;
static void LSRClock_UIAnimatingLabel_setText(id self, SEL _cmd, NSString *text) {
    ((void (*)(id, SEL, id))LSRClock_orig_UIAnimatingLabel_setText)(self, _cmd, LSRIOS15DateTextForLabel((UILabel *)self, text));
}

static void LSRClock_UIAnimatingLabel_setFont(id self, SEL _cmd, UIFont *font);
static IMP LSRClock_orig_UIAnimatingLabel_setFont;
static void LSRClock_UIAnimatingLabel_setFont(id self, SEL _cmd, UIFont *font) {
    if ([((UILabel *)self).superview isKindOfClass:NSClassFromString(@"CSProminentTimeView")]) font = LSRClockFont();
    else if ([((UILabel *)self).superview isKindOfClass:NSClassFromString(@"CSProminentSubtitleDateView")]) font = LSRDateFont();
    ((void (*)(id, SEL, id))LSRClock_orig_UIAnimatingLabel_setFont)(self, _cmd, font);
}

static void LSRClock_UIAnimatingLabel_setAttributedText(id self, SEL _cmd, NSAttributedString *attributedText);
static IMP LSRClock_orig_UIAnimatingLabel_setAttributedText;
static void LSRClock_UIAnimatingLabel_setAttributedText(id self, SEL _cmd, NSAttributedString *attributedText) {
    if (attributedText.length && [((UILabel *)self).superview isKindOfClass:NSClassFromString(@"CSProminentSubtitleDateView")]) {
        NSMutableDictionary *attributes = [[attributedText attributesAtIndex:0 effectiveRange:NULL] mutableCopy];
        attributes[NSFontAttributeName] = LSRDateFont();
        attributedText = [[NSAttributedString alloc] initWithString:LSRIOS15DateTextForLabel((UILabel *)self, attributedText.string)
            attributes:attributes];
    }
    ((void (*)(id, SEL, id))LSRClock_orig_UIAnimatingLabel_setAttributedText)(self, _cmd, attributedText);
}

static void LSRClock_CSProminentSubtitleDateView_setFrame(id self, SEL _cmd, CGRect frame);
static IMP LSRClock_orig_CSProminentSubtitleDateView_setFrame;
static void LSRClock_CSProminentSubtitleDateView_setFrame(id self, SEL _cmd, CGRect frame) {
    if (sLSRApplying) {
        ((void (*)(id, SEL, CGRect))LSRClock_orig_CSProminentSubtitleDateView_setFrame)(self, _cmd, frame);
        return;
    }
    sLSRApplying = YES;
    ((void (*)(id, SEL, CGRect))LSRClock_orig_CSProminentSubtitleDateView_setFrame)(self, _cmd, LSRAdjustedFrame((UIView *)self, NO, frame));
    sLSRApplying = NO;
}

static void LSRClock_CSProminentSubtitleDateView_setCenter(id self, SEL _cmd, CGPoint center);
static IMP LSRClock_orig_CSProminentSubtitleDateView_setCenter;
static void LSRClock_CSProminentSubtitleDateView_setCenter(id self, SEL _cmd, CGPoint center) {
    if (sLSRApplying) {
        ((void (*)(id, SEL, CGPoint))LSRClock_orig_CSProminentSubtitleDateView_setCenter)(self, _cmd, center);
        return;
    }
    sLSRApplying = YES;
    ((void (*)(id, SEL, CGPoint))LSRClock_orig_CSProminentSubtitleDateView_setCenter)(self, _cmd, LSRAdjustedCenter((UIView *)self, NO, center));
    sLSRApplying = NO;
}

static void LSRClock_CSProminentSubtitleDateView_setDate(id self, SEL _cmd, NSDate *date);
static IMP LSRClock_orig_CSProminentSubtitleDateView_setDate;
static void LSRClock_CSProminentSubtitleDateView_setDate(id self, SEL _cmd, NSDate *date) {
    ((void (*)(id, SEL, id))LSRClock_orig_CSProminentSubtitleDateView_setDate)(self, _cmd, date);
    LSRApplyIOS15Date((CSProminentSubtitleDateView *)self);
}

static void LSRClock_CSProminentSubtitleDateView_updateLabel(id self, SEL _cmd);
static IMP LSRClock_orig_CSProminentSubtitleDateView_updateLabel;
static void LSRClock_CSProminentSubtitleDateView_updateLabel(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSProminentSubtitleDateView_updateLabel)(self, _cmd);
    LSRApplyIOS15Date((CSProminentSubtitleDateView *)self);
}

static void LSRClock_CSProminentSubtitleDateView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_CSProminentSubtitleDateView_layoutSubviews;
static void LSRClock_CSProminentSubtitleDateView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSProminentSubtitleDateView_layoutSubviews)(self, _cmd);
    LSRApplyIOS15Date((CSProminentSubtitleDateView *)self);
}

static void LSRClock_CSProminentSubtitleDateView_didMoveToWindow(id self, SEL _cmd);
static IMP LSRClock_orig_CSProminentSubtitleDateView_didMoveToWindow;
static void LSRClock_CSProminentSubtitleDateView_didMoveToWindow(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSProminentSubtitleDateView_didMoveToWindow)(self, _cmd);
    LSRApplyIOS15Date((CSProminentSubtitleDateView *)self);
}

#pragma mark - Solid white time/date (no vibrancy tint)
//
// iOS 16 draws the time/date through a BSUIVibrancyEffectView (the labels themselves sit at
// alpha 0 behind a vibrancy portal), which makes them tinted and slightly see-through.

static void LSRClock_CSProminentDisplayView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_CSProminentDisplayView_layoutSubviews;
static void LSRClock_CSProminentDisplayView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSProminentDisplayView_layoutSubviews)(self, _cmd);
    CSProminentDisplayView *display = (CSProminentDisplayView *)self;
    sLSRDisplayView = display;
    BSUIVibrancyEffectView *vibrancy = display.vibrancyEffectView;
    if (vibrancy.isEnabled) vibrancy.isEnabled = NO;
    LSRPlaceView(display.timeView, YES);
    LSRPlaceView(LSRFindSubview(display, NSClassFromString(@"CSProminentSubtitleDateView")), NO);
    CGFloat dateBaselineY = LSRCurrentLayout().dateBaselineY;
    for (CSProminentTextElementView *subtitle in @[display.transientSubtitleView ?: [NSNull null],
                                                   display.customSubtitleView ?: [NSNull null]]) {
        if (![subtitle isKindOfClass:[UIView class]]) continue;
        CGFloat top;
        if (LSRTargetTopForBaseline(subtitle, dateBaselineY, subtitle.textLabel.font, subtitle.bounds.size.height, &top)) {
            LSRMoveTop(subtitle, top);
        }
    }
}

static void LSRClock_CSProminentDisplayViewController_setTextColor(id self, SEL _cmd, UIColor *color);
static IMP LSRClock_orig_CSProminentDisplayViewController_setTextColor;
static void LSRClock_CSProminentDisplayViewController_setTextColor(id self, SEL _cmd, UIColor *color) {
    ((void (*)(id, SEL, id))LSRClock_orig_CSProminentDisplayViewController_setTextColor)(self, _cmd, [UIColor whiteColor]);
}

static UIColor *LSRClock_CSProminentDisplayViewController_effectiveTextColor(id self, SEL _cmd);
static IMP LSRClock_orig_CSProminentDisplayViewController_effectiveTextColor;
static UIColor *LSRClock_CSProminentDisplayViewController_effectiveTextColor(id self, SEL _cmd) {
    return [UIColor whiteColor];
}

static UIEdgeInsets LSRClock_CSCombinedListViewController_listViewDefaultContentInsets(id self, SEL _cmd);
static IMP LSRClock_orig_CSCombinedListViewController_listViewDefaultContentInsets;
static UIEdgeInsets LSRClock_CSCombinedListViewController_listViewDefaultContentInsets(id self, SEL _cmd) {
    UIEdgeInsets insets = ((UIEdgeInsets (*)(id, SEL))LSRClock_orig_CSCombinedListViewController_listViewDefaultContentInsets)(self, _cmd);
    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPhone) return insets;
    CGFloat listTop = round(LSRCurrentLayout().dateBaselineY + kIOS15DateBaselineToList);
    if (insets.top < listTop) insets.top = listTop;
    return insets;
}

#pragma mark - Big padlock that stays open after Face ID

static void LSRClock_SBUIProudLockIconView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_SBUIProudLockIconView_layoutSubviews;
static void LSRClock_SBUIProudLockIconView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_SBUIProudLockIconView_layoutSubviews)(self, _cmd);
    UIView *lockView = (UIView *)self;
    UIView *glyph = LSRFindSubview(lockView, NSClassFromString(@"BSUICAPackageView"));
    if (!glyph) return;
    LSRLayout layout = LSRCurrentLayout();
    BOOL dynamicIslandFaceID = LSRHasDynamicIslandLayout();
    CGFloat scale = dynamicIslandFaceID ? 1.0 : layout.padlockScale;
    CGFloat ty = dynamicIslandFaceID ? 0.0 : layout.padlockDrop;
    if (dynamicIslandFaceID && lockView.superview && lockView.window) {
        UIWindow *window = lockView.window;
        CGFloat safeTop = window.safeAreaInsets.top > 0.0 ? window.safeAreaInsets.top : 56.0;
        CGFloat minY = safeTop + 6.0;
        CGFloat restingY = safeTop + 20.0;
        CGFloat clockDigitsTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
        CGFloat maxY = MAX(restingY, clockDigitsTop - 12.0);
        CGFloat targetY = MIN(maxY, MAX(minY, restingY - sLSRNotificationScrollDisplacement));
        CGPoint targetInWindow = CGPointMake(CGRectGetMidX(window.bounds), targetY);
        CGPoint targetCenter = [lockView.superview convertPoint:targetInWindow fromView:window];
        if (fabs(lockView.center.x - targetCenter.x) > 0.25 || fabs(lockView.center.y - targetCenter.y) > 0.25) {
            lockView.center = targetCenter;
        }
    }
    CGAffineTransform t = CGAffineTransformMake(scale, 0, 0, scale, 0, ty);
    if (!CGAffineTransformEqualToTransform(glyph.transform, t)) glyph.transform = t;
}

static void LSRClock_SBUIProudLockIconView_setAlpha(id self, SEL _cmd, CGFloat alpha);
static IMP LSRClock_orig_SBUIProudLockIconView_setAlpha;
static void LSRClock_SBUIProudLockIconView_setAlpha(id self, SEL _cmd, CGFloat alpha) {
    ((void (*)(id, SEL, CGFloat))LSRClock_orig_SBUIProudLockIconView_setAlpha)(self, _cmd, 1.0);
}

static void LSRClock_SBUIProudLockIconView_setTransform(id self, SEL _cmd, CGAffineTransform transform);
static IMP LSRClock_orig_SBUIProudLockIconView_setTransform;
static void LSRClock_SBUIProudLockIconView_setTransform(id self, SEL _cmd, CGAffineTransform transform) {
    ((void (*)(id, SEL, CGAffineTransform))LSRClock_orig_SBUIProudLockIconView_setTransform)(self, _cmd, CGAffineTransformIdentity);
}

static BOOL LSRClock_CSProudLockViewController_shouldApplyScaleAndBlurForAuthenticated(id self, SEL _cmd);
static IMP LSRClock_orig_CSProudLockViewController_shouldApplyScaleAndBlurForAuthenticated;
static BOOL LSRClock_CSProudLockViewController_shouldApplyScaleAndBlurForAuthenticated(id self, SEL _cmd) {
    return NO;
}

static void LSRClock_PBUIPosterFloatingLayerReplica_didMoveToWindow(id self, SEL _cmd);
static IMP LSRClock_orig_PBUIPosterFloatingLayerReplica_didMoveToWindow;
static void LSRClock_PBUIPosterFloatingLayerReplica_didMoveToWindow(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_PBUIPosterFloatingLayerReplica_didMoveToWindow)(self, _cmd);
    ((UIView *)self).hidden = YES;
}

static void LSRClock_PBUIPosterFloatingLayerReplica_setHidden(id self, SEL _cmd, BOOL hidden);
static IMP LSRClock_orig_PBUIPosterFloatingLayerReplica_setHidden;
static void LSRClock_PBUIPosterFloatingLayerReplica_setHidden(id self, SEL _cmd, BOOL hidden) {
    ((void (*)(id, SEL, BOOL))LSRClock_orig_PBUIPosterFloatingLayerReplica_setHidden)(self, _cmd, YES);
}

#pragma mark - Charging battery in place of the clock
//
// On plug-in iOS fades out time and date and shows "60% Charged" over a big battery. iOS 16
// centers that on its own clock, which puts the text right under our bigger padlock; iOS 15
// showed it where the clock was. Shift it so it's centered on our time + date block. A
// translation on the charging view (full-screen, clear) moves label and battery together
// without fighting their Auto Layout; the getter/setter pair keeps it out of iOS's own
// transforms.

@interface CSBatteryChargingView : UIView
@end

@interface _CSSingleBatteryChargingView : CSBatteryChargingView
@end

@interface _CSDoubleBatteryChargingView : CSBatteryChargingView
@end

static const void *kLSRChargingShiftKey = &kLSRChargingShiftKey;

static CGFloat LSRChargingShift(UIView *view) {
    return [objc_getAssociatedObject(view, kLSRChargingShiftKey) doubleValue];
}

static void LSRUpdateChargingShift(UIView *view) {
    CGRect content = CGRectNull;
    for (UIView *sub in view.subviews) {
        if (sub.hidden || CGRectIsEmpty(sub.frame)) continue;
        content = CGRectUnion(content, sub.frame);
    }
    if (CGRectIsNull(content)) return;

    LSRLayout layout = LSRCurrentLayout();
    CGFloat clockTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
    CGFloat dateBottom = layout.dateBaselineY + kSFDescender * layout.dateFontSize;
    CGFloat shift = round((clockTop + dateBottom) / 2.0 - CGRectGetMidY(content));
    if (fabs(shift - LSRChargingShift(view)) < 0.5) return;

    CGAffineTransform own = view.transform;
    objc_setAssociatedObject(view, kLSRChargingShiftKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.transform = own;
    LSRDebugLog(@"charging view %@ content %@ shift %.1f", NSStringFromClass([view class]),
        NSStringFromCGRect(content), shift);
}

static void LSRClock_CSBatteryChargingView_didMoveToWindow(id self, SEL _cmd);
static IMP LSRClock_orig_CSBatteryChargingView_didMoveToWindow;
static void LSRClock_CSBatteryChargingView_didMoveToWindow(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSBatteryChargingView_didMoveToWindow)(self, _cmd);
    LSRUpdateChargingShift((UIView *)self);
}

static void LSRClock_CSBatteryChargingView_setTransform(id self, SEL _cmd, CGAffineTransform transform);
static IMP LSRClock_orig_CSBatteryChargingView_setTransform;
static void LSRClock_CSBatteryChargingView_setTransform(id self, SEL _cmd, CGAffineTransform transform) {
    transform.ty += LSRChargingShift((UIView *)self);
    ((void (*)(id, SEL, CGAffineTransform))LSRClock_orig_CSBatteryChargingView_setTransform)(self, _cmd, transform);
}

static CGAffineTransform LSRClock_CSBatteryChargingView_transform(id self, SEL _cmd);
static IMP LSRClock_orig_CSBatteryChargingView_transform;
static CGAffineTransform LSRClock_CSBatteryChargingView_transform(id self, SEL _cmd) {
    CGAffineTransform t = ((CGAffineTransform (*)(id, SEL))LSRClock_orig_CSBatteryChargingView_transform)(self, _cmd);
    t.ty -= LSRChargingShift((UIView *)self);
    return t;
}

static void LSRClock_CSSingleBatteryChargingView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_CSSingleBatteryChargingView_layoutSubviews;
static void LSRClock_CSSingleBatteryChargingView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSSingleBatteryChargingView_layoutSubviews)(self, _cmd);
    LSRUpdateChargingShift((UIView *)self);
}

static void LSRClock_CSDoubleBatteryChargingView_layoutSubviews(id self, SEL _cmd);
static IMP LSRClock_orig_CSDoubleBatteryChargingView_layoutSubviews;
static void LSRClock_CSDoubleBatteryChargingView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRClock_orig_CSDoubleBatteryChargingView_layoutSubviews)(self, _cmd);
    LSRUpdateChargingShift((UIView *)self);
}

static void LSRInstallClockHooks(void) {
    Class cls = objc_getClass("SBFLockScreenDateView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_SBFLockScreenDateView_layoutSubviews, &LSRClock_orig_SBFLockScreenDateView_layoutSubviews);
    cls = objc_getClass("CSProminentTimeView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_CSProminentTimeView_layoutSubviews, &LSRClock_orig_CSProminentTimeView_layoutSubviews);
        MSHookMessageEx(cls, @selector(setFrame:), (IMP)LSRClock_CSProminentTimeView_setFrame, &LSRClock_orig_CSProminentTimeView_setFrame);
        MSHookMessageEx(cls, @selector(setCenter:), (IMP)LSRClock_CSProminentTimeView_setCenter, &LSRClock_orig_CSProminentTimeView_setCenter);
    }
    cls = objc_getClass("_UIAnimatingLabel");
    if (cls) {
        MSHookMessageEx(cls, @selector(setText:), (IMP)LSRClock_UIAnimatingLabel_setText, &LSRClock_orig_UIAnimatingLabel_setText);
        MSHookMessageEx(cls, @selector(setFont:), (IMP)LSRClock_UIAnimatingLabel_setFont, &LSRClock_orig_UIAnimatingLabel_setFont);
        MSHookMessageEx(cls, @selector(setAttributedText:), (IMP)LSRClock_UIAnimatingLabel_setAttributedText, &LSRClock_orig_UIAnimatingLabel_setAttributedText);
    }
    cls = objc_getClass("CSProminentSubtitleDateView");
    if (cls) {
        MSHookMessageEx(cls, @selector(setFrame:), (IMP)LSRClock_CSProminentSubtitleDateView_setFrame, &LSRClock_orig_CSProminentSubtitleDateView_setFrame);
        MSHookMessageEx(cls, @selector(setCenter:), (IMP)LSRClock_CSProminentSubtitleDateView_setCenter, &LSRClock_orig_CSProminentSubtitleDateView_setCenter);
        MSHookMessageEx(cls, @selector(setDate:), (IMP)LSRClock_CSProminentSubtitleDateView_setDate, &LSRClock_orig_CSProminentSubtitleDateView_setDate);
        MSHookMessageEx(cls, NSSelectorFromString(@"_updateLabel"), (IMP)LSRClock_CSProminentSubtitleDateView_updateLabel, &LSRClock_orig_CSProminentSubtitleDateView_updateLabel);
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_CSProminentSubtitleDateView_layoutSubviews, &LSRClock_orig_CSProminentSubtitleDateView_layoutSubviews);
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)LSRClock_CSProminentSubtitleDateView_didMoveToWindow, &LSRClock_orig_CSProminentSubtitleDateView_didMoveToWindow);
    }
    cls = objc_getClass("CSProminentDisplayView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_CSProminentDisplayView_layoutSubviews, &LSRClock_orig_CSProminentDisplayView_layoutSubviews);
    cls = objc_getClass("CSProminentDisplayViewController");
    if (cls) {
        MSHookMessageEx(cls, NSSelectorFromString(@"setTextColor:"), (IMP)LSRClock_CSProminentDisplayViewController_setTextColor, &LSRClock_orig_CSProminentDisplayViewController_setTextColor);
        MSHookMessageEx(cls, NSSelectorFromString(@"effectiveTextColor"), (IMP)LSRClock_CSProminentDisplayViewController_effectiveTextColor, &LSRClock_orig_CSProminentDisplayViewController_effectiveTextColor);
    }
    cls = objc_getClass("CSCombinedListViewController");
    if (cls) MSHookMessageEx(cls, NSSelectorFromString(@"_listViewDefaultContentInsets"), (IMP)LSRClock_CSCombinedListViewController_listViewDefaultContentInsets, &LSRClock_orig_CSCombinedListViewController_listViewDefaultContentInsets);
    cls = objc_getClass("SBUIProudLockIconView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_SBUIProudLockIconView_layoutSubviews, &LSRClock_orig_SBUIProudLockIconView_layoutSubviews);
        MSHookMessageEx(cls, @selector(setAlpha:), (IMP)LSRClock_SBUIProudLockIconView_setAlpha, &LSRClock_orig_SBUIProudLockIconView_setAlpha);
        MSHookMessageEx(cls, @selector(setTransform:), (IMP)LSRClock_SBUIProudLockIconView_setTransform, &LSRClock_orig_SBUIProudLockIconView_setTransform);
    }
    cls = objc_getClass("CSProudLockViewController");
    if (cls) MSHookMessageEx(cls, NSSelectorFromString(@"_shouldApplyScaleAndBlurForAuthenticated"), (IMP)LSRClock_CSProudLockViewController_shouldApplyScaleAndBlurForAuthenticated, &LSRClock_orig_CSProudLockViewController_shouldApplyScaleAndBlurForAuthenticated);
    cls = objc_getClass("PBUIPosterFloatingLayerReplica");
    if (cls) {
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)LSRClock_PBUIPosterFloatingLayerReplica_didMoveToWindow, &LSRClock_orig_PBUIPosterFloatingLayerReplica_didMoveToWindow);
        MSHookMessageEx(cls, @selector(setHidden:), (IMP)LSRClock_PBUIPosterFloatingLayerReplica_setHidden, &LSRClock_orig_PBUIPosterFloatingLayerReplica_setHidden);
    }
    cls = objc_getClass("CSBatteryChargingView");
    if (cls) {
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)LSRClock_CSBatteryChargingView_didMoveToWindow, &LSRClock_orig_CSBatteryChargingView_didMoveToWindow);
        MSHookMessageEx(cls, @selector(setTransform:), (IMP)LSRClock_CSBatteryChargingView_setTransform, &LSRClock_orig_CSBatteryChargingView_setTransform);
        MSHookMessageEx(cls, @selector(transform), (IMP)LSRClock_CSBatteryChargingView_transform, &LSRClock_orig_CSBatteryChargingView_transform);
    }
    cls = objc_getClass("_CSSingleBatteryChargingView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_CSSingleBatteryChargingView_layoutSubviews, &LSRClock_orig_CSSingleBatteryChargingView_layoutSubviews);
    cls = objc_getClass("_CSDoubleBatteryChargingView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRClock_CSDoubleBatteryChargingView_layoutSubviews, &LSRClock_orig_CSDoubleBatteryChargingView_layoutSubviews);
}


#pragma mark - Group: iOS 15 focus pill
//
// iOS 16 still ships the iOS 15 focus pill (CSFocusActivityView/-Indicator, added as an item of
// the adjunct list under the clock); CSFocusActivityManager just decides to hide it. Re-enable
// it, move it below our date, and remove iOS 16's replacement: the focus name + symbol at the
// bottom of the notification list. The notification count in that bottom view is left alone.
//
// Where the pill lands depends on where iOS starts the adjunct list, which differs per device.
// So the pill measures its real distance to our date on every layout. Its item keeps iOS's
// height: growing it through preferredContentSize fed back into itself (iOS writes the value it
// reads back), so instead the item stops clipping. iOS leaves 26pt below each adjunct item, far
// more than the few points the pill sticks out.


@interface CSFocusActivityView : UIView
- (UIView *)activityIndicator;
@end

@interface CSAdjunctItemView : UIView
@end

// The adjunct list starts 29pt below the date's baseline (kIOS15DateBaselineToList, right for the
// music player), which puts the pill 39pt below it; iOS 15's was 19pt below (iPhone 7 on iOS 15.8,
// iPhone 13 screenshots). Same on every iPhone, since the list start follows the date.
static const CGFloat kIOS15FocusPillLift = 20.0;

static UIView *LSRFocusIndicator(UIView *focusView) {
    UIView *indicator = [focusView respondsToSelector:@selector(activityIndicator)] ? [(CSFocusActivityView *)focusView activityIndicator] : nil;
    return [indicator isKindOfClass:[UIView class]] ? indicator : nil;
}

// Ordinary Objective-C hooks for the focus group.
static void LSRFocus_CSFocusActivityView_layoutSubviews(id self, SEL _cmd);
static IMP LSRFocus_orig_CSFocusActivityView_layoutSubviews;
static void LSRFocus_CSFocusActivityView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRFocus_orig_CSFocusActivityView_layoutSubviews)(self, _cmd);
    UIView *indicator = LSRFocusIndicator((UIView *)self);
    if (!indicator) return;
    indicator.center = CGPointMake(indicator.center.x, indicator.center.y - kIOS15FocusPillLift);
    for (UIView *view = self; view && ![view isKindOfClass:[UIStackView class]]; view = view.superview) {
        if (view.clipsToBounds) view.clipsToBounds = NO;
    }
}

static BOOL LSRFocus_CSFocusActivityView_pointInside(id self, SEL _cmd, CGPoint point, UIEvent *event);
static IMP LSRFocus_orig_CSFocusActivityView_pointInside;
static BOOL LSRFocus_CSFocusActivityView_pointInside(id self, SEL _cmd, CGPoint point, UIEvent *event) {
    BOOL inside = ((BOOL (*)(id, SEL, CGPoint, id))LSRFocus_orig_CSFocusActivityView_pointInside)(self, _cmd, point, event);
    if (inside) return YES;
    UIView *indicator = LSRFocusIndicator((UIView *)self);
    return indicator && CGRectContainsPoint(indicator.frame, point);
}

static BOOL LSRFocus_CSAdjunctItemView_pointInside(id self, SEL _cmd, CGPoint point, UIEvent *event);
static IMP LSRFocus_orig_CSAdjunctItemView_pointInside;
static BOOL LSRFocus_CSAdjunctItemView_pointInside(id self, SEL _cmd, CGPoint point, UIEvent *event) {
    BOOL inside = ((BOOL (*)(id, SEL, CGPoint, id))LSRFocus_orig_CSAdjunctItemView_pointInside)(self, _cmd, point, event);
    if (inside) return YES;
    for (UIView *view in ((UIView *)self).subviews) {
        if ([view pointInside:[((UIView *)self) convertPoint:point toView:view] withEvent:event]) return YES;
    }
    return NO;
}

static BOOL LSRFocus_CSFocusActivityManager_shouldHideFocusActivityIndicator(id self, SEL _cmd) {
    return NO;
}

static void LSRFocus_NCNotificationListCountIndicatorView_setTitleString(id self, SEL _cmd, NSString *titleString);
static IMP LSRFocus_orig_NCNotificationListCountIndicatorView_setTitleString;
static void LSRFocus_NCNotificationListCountIndicatorView_setTitleString(id self, SEL _cmd, NSString *titleString) {
    ((void (*)(id, SEL, id))LSRFocus_orig_NCNotificationListCountIndicatorView_setTitleString)(self, _cmd, nil);
}

static void LSRFocus_NCNotificationListCountIndicatorView_setSymbolImageName(id self, SEL _cmd, NSString *symbolImageName);
static IMP LSRFocus_orig_NCNotificationListCountIndicatorView_setSymbolImageName;
static void LSRFocus_NCNotificationListCountIndicatorView_setSymbolImageName(id self, SEL _cmd, NSString *symbolImageName) {
    ((void (*)(id, SEL, id))LSRFocus_orig_NCNotificationListCountIndicatorView_setSymbolImageName)(self, _cmd, nil);
}

static void LSRFocus_NCNotificationListCountIndicatorView_layoutSubviews(id self, SEL _cmd);
static IMP LSRFocus_orig_NCNotificationListCountIndicatorView_layoutSubviews;
static void LSRFocus_NCNotificationListCountIndicatorView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRFocus_orig_NCNotificationListCountIndicatorView_layoutSubviews)(self, _cmd);
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_symbolImageView");
    UIView *symbolView = ivar ? object_getIvar(self, ivar) : nil;
    if (symbolView && !symbolView.hidden) symbolView.hidden = YES;
}

static void LSRInstallFocusHooks(void) {
    Class cls = objc_getClass("CSFocusActivityView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRFocus_CSFocusActivityView_layoutSubviews, &LSRFocus_orig_CSFocusActivityView_layoutSubviews);
        MSHookMessageEx(cls, @selector(pointInside:withEvent:), (IMP)LSRFocus_CSFocusActivityView_pointInside, &LSRFocus_orig_CSFocusActivityView_pointInside);
    }
    cls = objc_getClass("CSAdjunctItemView");
    if (cls) MSHookMessageEx(cls, @selector(pointInside:withEvent:), (IMP)LSRFocus_CSAdjunctItemView_pointInside, &LSRFocus_orig_CSAdjunctItemView_pointInside);
    cls = objc_getClass("CSFocusActivityManager");
    if (cls) MSHookMessageEx(cls, NSSelectorFromString(@"_shouldHideFocusActivityIndicator"), (IMP)LSRFocus_CSFocusActivityManager_shouldHideFocusActivityIndicator, NULL);
    cls = objc_getClass("NCNotificationListCountIndicatorView");
    if (cls) {
        MSHookMessageEx(cls, NSSelectorFromString(@"setTitleString:"), (IMP)LSRFocus_NCNotificationListCountIndicatorView_setTitleString, &LSRFocus_orig_NCNotificationListCountIndicatorView_setTitleString);
        MSHookMessageEx(cls, NSSelectorFromString(@"setSymbolImageName:"), (IMP)LSRFocus_NCNotificationListCountIndicatorView_setSymbolImageName, &LSRFocus_orig_NCNotificationListCountIndicatorView_setSymbolImageName);
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRFocus_NCNotificationListCountIndicatorView_layoutSubviews, &LSRFocus_orig_NCNotificationListCountIndicatorView_layoutSubviews);
    }
}

#pragma mark - Group: iOS 15 notifications (listed from the top)
//
// iOS 16 lays the lock screen notification list out from the bottom up
// (NCNotificationListView.layoutFromBottom); iOS 15 listed them top-down under the date.

// iOS 15.0-15.8 (UserNotificationsUIKit): a card's corners are concentric with its icon,
// NCCornerRadiusConcentricWithProminentIcon() = the icon's 8.5pt + 10pt = 18.5pt, and the list
// keeps 10pt at the sides (insetHorizontalMarginForNotificationListComponent:), which is what
// iOS 16 does too: cards, the Focus pill and the music player all sit 10pt from the edges.
static const CGFloat kIOS15CardCornerRadius = 18.5;
static const CGFloat kIOS15CardInsetReduction = 4.0;
// The music player's platter (iOS 15.8: the material of CSMediaControlsView's platter).
static const CGFloat kIOS15PlatterCornerRadius = 18.0;

@interface NCNotificationShortLookView : UIView
- (CGFloat)_continuousCornerRadius;
- (void)_setContinuousCornerRadius:(CGFloat)radius;
@end

@interface NCNotificationSeamlessContentView : UIView
@end

@interface ACUISSizeDimensionRequest : NSObject
+ (instancetype)fixed:(CGFloat)value;
@property (readonly, nonatomic) CGFloat minimum;
@property (readonly, nonatomic) CGFloat maximum;
@end

@interface ACUISActivityItemMetricsRequest : NSObject <NSCopying>
@property (nonatomic, strong) ACUISSizeDimensionRequest *widthRequest;
@end

@interface ACUISActivityMetricsRequest : NSObject <NSCopying>
@property (nonatomic, copy) ACUISActivityItemMetricsRequest *lockScreenMetrics;
@end

@interface NCNotificationListSectionHeaderView : UIView
@property (nonatomic, weak) id delegate;
@end

@interface NCNotificationListView : UIScrollView
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic) CGFloat revealPercentage;
- (BOOL)isRevealed;
@end

@interface NCNotificationMasterList : NSObject
@property (nonatomic, strong) NCNotificationListView *masterListView;
@end

// The history section ("Notification Centre" + X) fades its notifications with the reveal but
// leaves its header at full alpha: on iOS 16 that header waits below the screen's bottom edge
// until you swipe up. Listed from the top it sits right under the clock, so give the header
// the same reveal alpha as the notifications below it (iOS 15 only showed it after a swipe up).
static BOOL LSRIsHistoryHeader(UIView *header) {
    if (![header isKindOfClass:NSClassFromString(@"NCNotificationListSectionHeaderView")]) return NO;
    id section = ((NCNotificationListSectionHeaderView *)header).delegate;
    return [section respondsToSelector:@selector(isHistorySection)]
        && ((BOOL (*)(id, SEL))objc_msgSend)(section, @selector(isHistorySection));
}

// Highest alpha the history header may have right now: its list's reveal progress. Views
// outside a history list aren't limited.
static CGFloat LSRHistoryHeaderMaxAlpha(UIView *header) {
    NCNotificationListView *list = (NCNotificationListView *)header.superview;
    if (![list isKindOfClass:NSClassFromString(@"NCNotificationListView")] || list.headerView != header
        || !LSRIsHistoryHeader(header)) return 1.0;
    return list.isRevealed ? 1.0 : MIN(MAX(list.revealPercentage, 0.0), 1.0);
}

static void LSRApplyHistoryHeaderReveal(NCNotificationListView *list) {
    UIView *header = list.headerView;
    if (!LSRIsHistoryHeader(header)) return;
    CGFloat alpha = LSRHistoryHeaderMaxAlpha(header);
    if (fabs(header.alpha - alpha) > 0.001) header.alpha = alpha;
}

// Pulling down past the list's top opens search (see isScrollingListContent below). iOS 16 lets
// the list's content (Focus pill, notifications) follow the finger meanwhile; on iOS 15 it stayed
// put. The offset itself has to move, since search reads it, so the content is shifted back by
// the overscroll when drawn (sublayerTransform leaves touches and the scroll view alone).
static void LSRHoldListAtTop(NCNotificationListView *list) {
    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPhone) return;
    if ([list.superview isKindOfClass:NSClassFromString(@"NCNotificationListView")]) return;  // only the outer list
    CGFloat overscroll = list.contentOffset.y + list.adjustedContentInset.top;
    CATransform3D hold = overscroll < 0 ? CATransform3DMakeTranslation(0, overscroll, 0) : CATransform3DIdentity;
    CALayer *layer = list.layer;
    if (CATransform3DEqualToTransform(layer.sublayerTransform, hold)) return;
    CATransform3D shown = (layer.presentationLayer ?: layer).sublayerTransform;
    layer.sublayerTransform = hold;
    // When iOS animates the offset back to the top (as search closes), the content still shows the
    // overscroll for the animation's length, so the shift follows along with the same timing.
    CAAnimation *boundsAnimation = nil;
    for (NSString *key in layer.animationKeys) {
        CAAnimation *animation = [layer animationForKey:key];
        if ([animation isKindOfClass:[CAPropertyAnimation class]]
            && [((CAPropertyAnimation *)animation).keyPath hasPrefix:@"bounds"]) boundsAnimation = animation;
    }
    if ([boundsAnimation isKindOfClass:[CABasicAnimation class]]) {
        CABasicAnimation *follow = [boundsAnimation copy];
        follow.keyPath = @"sublayerTransform";
        follow.additive = NO;
        follow.fromValue = [NSValue valueWithCATransform3D:shown];
        follow.toValue = [NSValue valueWithCATransform3D:hold];
        follow.byValue = nil;
        [layer addAnimation:follow forKey:@"LSRHoldListAtTop"];
    }
}

@interface CSCoverSheetView : UIView
@end

// Ordinary Objective-C hooks for notification layout and presentation.
static void LSRNotifications_CSCoverSheetView_setContentViewOffset(id self, SEL _cmd, CGPoint offset, CGFloat scale);
static IMP LSRNotifications_orig_CSCoverSheetView_setContentViewOffset;
static void LSRNotifications_CSCoverSheetView_setContentViewOffset(id self, SEL _cmd, CGPoint offset, CGFloat scale) {
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone && offset.y > 0) offset.y = 0;
    ((void (*)(id, SEL, CGPoint, CGFloat))LSRNotifications_orig_CSCoverSheetView_setContentViewOffset)(self, _cmd, offset, scale);
}

static BOOL LSRNotifications_NCNotificationListView_layoutFromBottom(id self, SEL _cmd) { return NO; }
static void LSRNotifications_NCNotificationListView_setLayoutFromBottom(id self, SEL _cmd, BOOL value);
static IMP LSRNotifications_orig_NCNotificationListView_setLayoutFromBottom;
static void LSRNotifications_NCNotificationListView_setLayoutFromBottom(id self, SEL _cmd, BOOL value) {
    ((void (*)(id, SEL, BOOL))LSRNotifications_orig_NCNotificationListView_setLayoutFromBottom)(self, _cmd, NO);
}
static void LSRNotifications_NCNotificationListView_layoutSubviews(id self, SEL _cmd);
static IMP LSRNotifications_orig_NCNotificationListView_layoutSubviews;
static void LSRNotifications_NCNotificationListView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRNotifications_orig_NCNotificationListView_layoutSubviews)(self, _cmd);
    LSRApplyHistoryHeaderReveal((NCNotificationListView *)self);
    LSRHoldListAtTop((NCNotificationListView *)self);
}
static void LSRNotifications_NCNotificationListView_setContentOffset(id self, SEL _cmd, CGPoint offset);
static IMP LSRNotifications_orig_NCNotificationListView_setContentOffset;
static void LSRNotifications_NCNotificationListView_setContentOffset(id self, SEL _cmd, CGPoint offset) {
    ((void (*)(id, SEL, CGPoint))LSRNotifications_orig_NCNotificationListView_setContentOffset)(self, _cmd, offset);
    NCNotificationListView *list = (NCNotificationListView *)self;
    LSRHoldListAtTop(list);
    LSRUpdateLockScrollPosition(list);
}
static void LSRNotifications_NCNotificationListView_setRevealPercentage(id self, SEL _cmd, CGFloat percentage);
static IMP LSRNotifications_orig_NCNotificationListView_setRevealPercentage;
static void LSRNotifications_NCNotificationListView_setRevealPercentage(id self, SEL _cmd, CGFloat percentage) {
    ((void (*)(id, SEL, CGFloat))LSRNotifications_orig_NCNotificationListView_setRevealPercentage)(self, _cmd, percentage);
    LSRApplyHistoryHeaderReveal((NCNotificationListView *)self);
}
static void LSRNotifications_NCNotificationListView_setRevealed(id self, SEL _cmd, BOOL revealed);
static IMP LSRNotifications_orig_NCNotificationListView_setRevealed;
static void LSRNotifications_NCNotificationListView_setRevealed(id self, SEL _cmd, BOOL revealed) {
    ((void (*)(id, SEL, BOOL))LSRNotifications_orig_NCNotificationListView_setRevealed)(self, _cmd, revealed);
    LSRApplyHistoryHeaderReveal((NCNotificationListView *)self);
}
static void LSRNotifications_NCNotificationListSectionHeaderView_setAlpha(id self, SEL _cmd, CGFloat alpha);
static IMP LSRNotifications_orig_NCNotificationListSectionHeaderView_setAlpha;
static void LSRNotifications_NCNotificationListSectionHeaderView_setAlpha(id self, SEL _cmd, CGFloat alpha) {
    ((void (*)(id, SEL, CGFloat))LSRNotifications_orig_NCNotificationListSectionHeaderView_setAlpha)(self, _cmd, MIN(alpha, LSRHistoryHeaderMaxAlpha((UIView *)self)));
}
static void LSRNotifications_NCNotificationSeamlessContentView_layoutSubviewInBounds(id self, SEL _cmd, CGRect bounds, CGSize *measuredSize);
static IMP LSRNotifications_orig_NCNotificationSeamlessContentView_layoutSubviewInBounds;
static void LSRNotifications_NCNotificationSeamlessContentView_layoutSubviewInBounds(id self, SEL _cmd, CGRect bounds, CGSize *measuredSize) {
    CGFloat reduction = kIOS15CardInsetReduction;
    CGRect enlarged = bounds;
    enlarged.size.width += 2.0 * reduction;
    enlarged.size.height += 2.0 * reduction;
    ((void (*)(id, SEL, CGRect, CGSize *))LSRNotifications_orig_NCNotificationSeamlessContentView_layoutSubviewInBounds)(self, _cmd, enlarged, measuredSize);
    if (measuredSize) {
        measuredSize->width = MAX(0.0, measuredSize->width - 2.0 * reduction);
        measuredSize->height = MAX(0.0, measuredSize->height - 2.0 * reduction);
        return;
    }
    UIView *view = (UIView *)self;
    CGRect viewBounds = view.bounds;
    if (!CGPointEqualToPoint(viewBounds.origin, CGPointMake(reduction, reduction))) {
        viewBounds.origin = CGPointMake(reduction, reduction);
        view.bounds = viewBounds;
    }
    CGFloat wantedCenterY = CGRectGetMidY(viewBounds);
    for (UIView *subview in view.subviews) {
        if (![NSStringFromClass([subview class]) containsString:@"BadgedIconView"]) continue;
        CGPoint center = subview.center;
        if (fabs(center.y - wantedCenterY) > 0.01) subview.center = CGPointMake(center.x, wantedCenterY);
    }
}
static void LSRNotifications_NCNotificationShortLookView_setContinuousCornerRadius(id self, SEL _cmd, CGFloat radius);
static IMP LSRNotifications_orig_NCNotificationShortLookView_setContinuousCornerRadius;
static void LSRNotifications_NCNotificationShortLookView_setContinuousCornerRadius(id self, SEL _cmd, CGFloat radius) {
    ((void (*)(id, SEL, CGFloat))LSRNotifications_orig_NCNotificationShortLookView_setContinuousCornerRadius)(self, _cmd, kIOS15CardCornerRadius);
}
static void LSRNotifications_NCNotificationShortLookView_layoutSubviews(id self, SEL _cmd);
static IMP LSRNotifications_orig_NCNotificationShortLookView_layoutSubviews;
static void LSRNotifications_NCNotificationShortLookView_layoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))LSRNotifications_orig_NCNotificationShortLookView_layoutSubviews)(self, _cmd);
    NCNotificationShortLookView *view = (NCNotificationShortLookView *)self;
    if (fabs(view._continuousCornerRadius - kIOS15CardCornerRadius) > 0.01) [view _setContinuousCornerRadius:kIOS15CardCornerRadius];
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_stackDimmingOverlayView");
    UIView *dimming = ivar ? object_getIvar(self, ivar) : nil;
    if (dimming && fabs(dimming.layer.cornerRadius - kIOS15CardCornerRadius) > 0.01) {
        dimming.layer.cornerRadius = kIOS15CardCornerRadius;
        dimming.layer.cornerCurve = kCACornerCurveContinuous;
    }
}
static void LSRNotifications_NCNotificationMasterList_setCurrentListDisplayStyleSetting(id self, SEL _cmd, NSUInteger setting);
static IMP LSRNotifications_orig_NCNotificationMasterList_setCurrentListDisplayStyleSetting;
static void LSRNotifications_NCNotificationMasterList_setCurrentListDisplayStyleSetting(id self, SEL _cmd, NSUInteger setting) {
    ((void (*)(id, SEL, NSUInteger))LSRNotifications_orig_NCNotificationMasterList_setCurrentListDisplayStyleSetting)(self, _cmd, 0);
}
static NSUInteger LSRNotifications_NCNotificationMasterList_currentListDisplayStyleSetting(id self, SEL _cmd) { return 0; }
static BOOL LSRNotifications_NCNotificationMasterList_isScrollingListContent(id self, SEL _cmd);
static IMP LSRNotifications_orig_NCNotificationMasterList_isScrollingListContent;
static BOOL LSRNotifications_NCNotificationMasterList_isScrollingListContent(id self, SEL _cmd) {
    BOOL scrolling = ((BOOL (*)(id, SEL))LSRNotifications_orig_NCNotificationMasterList_isScrollingListContent)(self, _cmd);
    if (!scrolling || [UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPhone) return scrolling;
    NCNotificationListView *list = ((NCNotificationMasterList *)self).masterListView;
    if (![list isKindOfClass:[UIScrollView class]]) return scrolling;
    if ([list.panGestureRecognizer velocityInView:list].y < 0) return scrolling;
    if (list.contentOffset.y + list.adjustedContentInset.top > 1.0) return scrolling;
    return NO;
}

static void LSRInstallNotificationHooks(void) {
    Class cls = objc_getClass("CSCoverSheetView");
    if (cls) MSHookMessageEx(cls, NSSelectorFromString(@"setContentViewOffset:scale:"), (IMP)LSRNotifications_CSCoverSheetView_setContentViewOffset, &LSRNotifications_orig_CSCoverSheetView_setContentViewOffset);
    cls = objc_getClass("NCNotificationListView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutFromBottom), (IMP)LSRNotifications_NCNotificationListView_layoutFromBottom, NULL);
        MSHookMessageEx(cls, @selector(setLayoutFromBottom:), (IMP)LSRNotifications_NCNotificationListView_setLayoutFromBottom, &LSRNotifications_orig_NCNotificationListView_setLayoutFromBottom);
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRNotifications_NCNotificationListView_layoutSubviews, &LSRNotifications_orig_NCNotificationListView_layoutSubviews);
        MSHookMessageEx(cls, @selector(setContentOffset:), (IMP)LSRNotifications_NCNotificationListView_setContentOffset, &LSRNotifications_orig_NCNotificationListView_setContentOffset);
        MSHookMessageEx(cls, @selector(setRevealPercentage:), (IMP)LSRNotifications_NCNotificationListView_setRevealPercentage, &LSRNotifications_orig_NCNotificationListView_setRevealPercentage);
        MSHookMessageEx(cls, @selector(setRevealed:), (IMP)LSRNotifications_NCNotificationListView_setRevealed, &LSRNotifications_orig_NCNotificationListView_setRevealed);
    }
    cls = objc_getClass("NCNotificationListSectionHeaderView");
    if (cls) MSHookMessageEx(cls, @selector(setAlpha:), (IMP)LSRNotifications_NCNotificationListSectionHeaderView_setAlpha, &LSRNotifications_orig_NCNotificationListSectionHeaderView_setAlpha);
    cls = objc_getClass("NCNotificationSeamlessContentView");
    if (cls) MSHookMessageEx(cls, NSSelectorFromString(@"_layoutSubviewInBounds:measuringOnly:"), (IMP)LSRNotifications_NCNotificationSeamlessContentView_layoutSubviewInBounds, &LSRNotifications_orig_NCNotificationSeamlessContentView_layoutSubviewInBounds);
    cls = objc_getClass("NCNotificationShortLookView");
    if (cls) {
        MSHookMessageEx(cls, NSSelectorFromString(@"_setContinuousCornerRadius:"), (IMP)LSRNotifications_NCNotificationShortLookView_setContinuousCornerRadius, &LSRNotifications_orig_NCNotificationShortLookView_setContinuousCornerRadius);
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRNotifications_NCNotificationShortLookView_layoutSubviews, &LSRNotifications_orig_NCNotificationShortLookView_layoutSubviews);
    }
    cls = objc_getClass("NCNotificationMasterList");
    if (cls) {
        MSHookMessageEx(cls, NSSelectorFromString(@"setCurrentListDisplayStyleSetting:"), (IMP)LSRNotifications_NCNotificationMasterList_setCurrentListDisplayStyleSetting, &LSRNotifications_orig_NCNotificationMasterList_setCurrentListDisplayStyleSetting);
        MSHookMessageEx(cls, NSSelectorFromString(@"currentListDisplayStyleSetting"), (IMP)LSRNotifications_NCNotificationMasterList_currentListDisplayStyleSetting, NULL);
        MSHookMessageEx(cls, NSSelectorFromString(@"isScrollingListContent"), (IMP)LSRNotifications_NCNotificationMasterList_isScrollingListContent, &LSRNotifications_orig_NCNotificationMasterList_isScrollingListContent);
    }
}

#pragma mark - Group: iOS 15 live wallpaper
//
// iOS 16 dropped live wallpapers. Apple's iOS 15 wallpapers come as a still plus a 3s video per
// appearance. We show them in our own view on top of iOS's wallpaper, inside the wallpaper
// window, switch between Light and Dark with the system appearance, and play the video while
// the lock screen is pressed (like iOS 15).
//
// The files aren't bundled (they're Apple's): <kLSRWallpapersDir>/<Design>/{Light,Dark}.{heic,mov}

#define kLSRWallpapersDir LSRDevicePath(@"/var/mobile/Library/LockScreenRestore/Wallpapers")
static NSString *sLSRWallpaperDesignDir = nil;
// Settings > Wallpaper "Set Home Screen"; nil = the home screen shows the lock screen's design.
static NSString *sLSRHomeDesignDir = nil;
// The wallpaper window serves both screens: the lock screen's design while the cover sheet is
// up, the home screen's once it goes away. (While it slides, the cover sheet carries its own
// copy of the lock screen wallpaper, see LSRCoverWithStill.)
static BOOL sLSRShowingLockScreen = YES;
// iOS 15's "Perspective Zoom": the wallpaper is drawn a bit larger and shifts as the iPhone
// tilts. Dynamic wallpapers move on their own and skip it.
static BOOL sLSRPerspectiveZoom = YES;
static const CGFloat kLSRPerspectiveMargin = 28.0;
// "Dark Appearance Dims Wallpaper" (Settings > Wallpaper).
static BOOL sLSRDimInDark = NO;
// Posted when the wallpaper window changes between the lock screen and the home screen.
static NSString *const kLSRShownScreenNotification = @"LSRShownScreen";
// Posted in SpringBoard after Settings picked another design or toggled dimming.
static NSString *const kLSRWallpaperReloadNotification = @"LSRWallpaperReload";
static NSMutableDictionary<NSString *, UIImage *> *sLSRStillCache;
// iOS 15 dimmed by roughly a quarter in the dark.
static const CGFloat kLSRDarkDimAlpha = 0.25;


static NSString *LSRWallpaperVariant(UITraitCollection *traits) {
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? @"Dark" : @"Light";
}

// Decoded once per variant: the same still is shown by several views (the wallpaper window and
// the copies iOS slides around during lock/unlock).
static UIImage *LSRWallpaperStillIn(NSString *dir, NSString *variant) {
    if (!dir) return nil;
    // Dynamic: a still of the bokeh (the lock screen's sliding copies can't animate).
    if (LSRIsBokehDesign(dir)) return LSRBokehImage(dir, [variant isEqualToString:@"Dark"], [UIScreen mainScreen].bounds.size);
    if (!sLSRStillCache) sLSRStillCache = [NSMutableDictionary new];
    NSString *path = [[dir stringByAppendingPathComponent:variant] stringByAppendingPathExtension:@"heic"];
    UIImage *image = sLSRStillCache[path];
    if (!image) {
        image = [UIImage imageWithContentsOfFile:path];
        if (image) sLSRStillCache[path] = image;
    }
    return image;
}

// The lock screen's still (what the cover sheet's own copies show).
static UIImage *LSRWallpaperStill(NSString *variant) {
    return LSRWallpaperStillIn(sLSRWallpaperDesignDir, variant);
}

// What the wallpaper window shows right now.
static NSString *LSRWindowDesignDir(void) {
    return !sLSRShowingLockScreen && sLSRHomeDesignDir ? sLSRHomeDesignDir : sLSRWallpaperDesignDir;
}

#pragma mark Dynamic wallpapers: iOS 15's motion

// iOS 15's bubbles drift with the device: SBFBokehWallpaperView kept an SBFMotionManager, fed
// gravity through a low-pass "inertia" filter 60 times a second and handed each bubble the
// filter's change since the previous sample (-[SBFInfiniteImpulseResponseFilter
// outputGradient]) as dx and dy. iOS 16's PBUIBokehWallpaperView dropped the manager and passes
// 0, 0. This is that manager again, with iOS 15.5's numbers; the hooks further down pass its
// values to the bubbles, whose own code still scales them (140x on the lock screen, 35x on the
// home screen).
typedef struct {
    double feedforward[5];
    double feedback[5];
    double inputs[5];
    double outputs[5];
} LSRInertiaFilter;

// +[SBFInfiniteImpulseResponseFilter lowpassInertiaFilterWithCoefficient:]
static void LSRInertiaFilterInit(LSRInertiaFilter *filter, double coefficient) {
    memset(filter, 0, sizeof(*filter));
    const double feedforward[5] = { 1.0, -0.3, 0.5, 0.3, 0.15 };
    for (int i = 0; i < 5; i++) filter->feedforward[i] = coefficient * feedforward[i];
    filter->feedback[0] = 1.0;
    filter->feedback[1] = coefficient - 1.0;
    filter->feedback[2] = coefficient * 0.4;
    filter->feedback[3] = coefficient * 0.15;
    filter->feedback[4] = coefficient * 0.1;
}

// -[SBFInfiniteImpulseResponseFilter filterWithInput:]
static void LSRInertiaFilterInput(LSRInertiaFilter *filter, double input) {
    memmove(&filter->inputs[1], &filter->inputs[0], 4 * sizeof(double));
    filter->inputs[0] = input;
    double fed = 0.0, back = 0.0;
    for (int i = 0; i < 5; i++) fed += filter->inputs[i] * filter->feedforward[i];
    for (int i = 0; i < 4; i++) back += filter->outputs[i] * filter->feedback[i + 1];
    double output = (fed - back) / filter->feedback[0];
    memmove(&filter->outputs[1], &filter->outputs[0], 4 * sizeof(double));
    filter->outputs[0] = output;
}

// SBFBokehWallpaperView made its manager with coefficient 0.99; device motion comes every 1/60s
// in the "x arbitrary, z vertical" frame, and every 10s while paused.
static const double kIOS15BokehMotionCoefficient = 0.99;
static const NSTimeInterval kIOS15BokehMotionInterval = 1.0 / 60.0;
static const NSTimeInterval kIOS15BokehMotionPausedInterval = 10.0;

static CMMotionManager *sLSRBokehMotion = nil;
static BOOL sLSRBokehMotionPaused = NO;
static os_unfair_lock sLSRBokehMotionLock = OS_UNFAIR_LOCK_INIT;
static LSRInertiaFilter sLSRBokehFilterX, sLSRBokehFilterY;
static CFTimeInterval sLSRBokehLastTick = 0;
// The values for the bubbles of the view being updated right now.
static BOOL sLSRBokehUpdating = NO;
static double sLSRBokehDX = 0.0, sLSRBokehDY = 0.0;

static void LSRBokehMotionStart(void) {
    if (sLSRBokehMotion) {
        if (sLSRBokehMotionPaused) {
            sLSRBokehMotion.deviceMotionUpdateInterval = kIOS15BokehMotionInterval;
            sLSRBokehMotionPaused = NO;
        }
        return;
    }
    CMMotionManager *manager = [CMMotionManager new];
    if (!manager.isDeviceMotionAvailable) return;
    LSRInertiaFilterInit(&sLSRBokehFilterX, kIOS15BokehMotionCoefficient);
    LSRInertiaFilterInit(&sLSRBokehFilterY, kIOS15BokehMotionCoefficient);
    manager.deviceMotionUpdateInterval = kIOS15BokehMotionInterval;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    [manager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical toQueue:queue
                                             withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion) return;
        CMAcceleration gravity = motion.gravity;
        os_unfair_lock_lock(&sLSRBokehMotionLock);
        LSRInertiaFilterInput(&sLSRBokehFilterX, gravity.x);
        LSRInertiaFilterInput(&sLSRBokehFilterY, gravity.y);
        os_unfair_lock_unlock(&sLSRBokehMotionLock);
    }];
    sLSRBokehMotion = manager;
    sLSRBokehMotionPaused = NO;
}

// No bubbles were updated for a while (screen off, Low Power Mode, another wallpaper).
static void LSRBokehMotionPauseIfIdle(void) {
    if (!sLSRBokehMotion || sLSRBokehMotionPaused || CACurrentMediaTime() - sLSRBokehLastTick < 1.0) return;
    sLSRBokehMotion.deviceMotionUpdateInterval = kIOS15BokehMotionPausedInterval;
    sLSRBokehMotionPaused = YES;
}

static void LSRBokehMotionGradient(double *dx, double *dy) {
    os_unfair_lock_lock(&sLSRBokehMotionLock);
    *dx = sLSRBokehFilterX.outputs[0] - sLSRBokehFilterX.outputs[1];
    *dy = sLSRBokehFilterY.outputs[0] - sLSRBokehFilterY.outputs[1];
    os_unfair_lock_unlock(&sLSRBokehMotionLock);
}

// iOS 15's own wallpaper view for a still. iOS 16 still has it, renamed (SBFStaticWallpaperView
// -> PBUIStaticWallpaperView): it shows the image at its own size, centered, and moves it with
// the device for Perspective Zoom (its parallax, with Apple's settings).
//
// iOS 15 stored a wallpaper already cut to the size it needs: the screen plus an overhang at
// each side for Perspective Zoom (+[PBUIWallpaperParallaxSettings minimumWallpaperSizeForCurrentDevice],
// 26 x 64pt on a 390 x 844pt screen), or just the screen without it. Same here: the design's
// still, filled into that size.
static CGSize LSRAppleWallpaperSize(BOOL perspective) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGSize size = CGSizeMake(MIN(screen.width, screen.height), MAX(screen.width, screen.height));
    if (!perspective) return size;
    dlopen("/System/Library/PrivateFrameworks/PaperBoardUI.framework/PaperBoardUI", RTLD_NOW);
    Class settings = NSClassFromString(@"PBUIWallpaperParallaxSettings");
    SEL minimum = NSSelectorFromString(@"minimumWallpaperSizeForCurrentDevice");
    if (![settings respondsToSelector:minimum]) return size;
    CGSize wanted = ((CGSize (*)(id, SEL))objc_msgSend)(settings, minimum);
    return wanted.width >= size.width && wanted.height >= size.height ? wanted : size;
}

static UIImage *LSRAppleSizedStill(UIImage *still, BOOL perspective) {
    if (!still || still.size.width <= 0 || still.size.height <= 0) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 4; });
    NSString *key = [NSString stringWithFormat:@"%p|%d", still, perspective];
    UIImage *sized = [cache objectForKey:key];
    if (sized) return sized;
    CGSize size = LSRAppleWallpaperSize(perspective);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    sized = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(size.width / still.size.width, size.height / still.size.height);
        CGSize drawn = CGSizeMake(still.size.width * scale, still.size.height * scale);
        [still drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
    if (sized) [cache setObject:sized forKey:key];
    return sized;
}

// iOS 16 kept the view's Perspective Zoom but switched its motion off:
// -[PBUIWallpaperView _isParallaxMotionEnabled] just returns NO there (iOS 15 had no such
// check), so the image has its overhang and never moves. Our views get it back.
static const void *const kLSRParallaxMotionKey = &kLSRParallaxMotionKey;
static BOOL sLSRBuildingStaticView = NO;

static UIView *LSRLegacyStaticView(UIImage *still, NSString *name, CGRect frame, BOOL perspective) {
    // Test switch: back to our own image view.
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/lsr-no-legacy-static"]) return nil;
    UIImage *sized = LSRAppleSizedStill(still, perspective);
    if (!sized.CGImage) return nil;
    Class imageClass = NSClassFromString(@"PBUIWallpaperImage");
    Class optionsClass = NSClassFromString(@"PBUIWallpaperOptions");
    Class configurationClass = NSClassFromString(@"PBUIWallpaperConfiguration");
    Class viewClass = NSClassFromString(@"PBUIStaticWallpaperView");
    SEL imageInit = NSSelectorFromString(@"initWithCGImage:scale:orientation:wallpaperFileURL:");
    SEL optionsMake = NSSelectorFromString(@"optionsWithName:parallaxFactor:zoomScale:supportsCropping:cropRect:portrait:");
    SEL viewInit = NSSelectorFromString(@"initWithFrame:configuration:variant:cacheGroup:delegate:options:");
    if (![imageClass instancesRespondToSelector:imageInit] || ![optionsClass respondsToSelector:optionsMake]
        || ![configurationClass instancesRespondToSelector:NSSelectorFromString(@"initWithVariant:type:")]
        || ![viewClass instancesRespondToSelector:viewInit]) return nil;
    id image = ((id (*)(id, SEL, CGImageRef, CGFloat, NSInteger, id))objc_msgSend)(
        [imageClass alloc], imageInit, sized.CGImage, sized.scale, UIImageOrientationUp, nil);
    id options = ((id (*)(id, SEL, id, double, double, BOOL, CGRect, BOOL))objc_msgSend)(
        optionsClass, optionsMake, name ?: @"LockScreenRestore", perspective ? 1.0 : 0.0, 1.0, NO, CGRectZero, YES);
    // Variant 0 is the lock screen, wallpaper type 1 a still image.
    id configuration = ((id (*)(id, SEL, long long, long long))objc_msgSend)(
        [configurationClass alloc], NSSelectorFromString(@"initWithVariant:type:"), 0, 1);
    ((void (*)(id, SEL, id))objc_msgSend)(configuration, NSSelectorFromString(@"setWallpaperImage:"), image);
    ((void (*)(id, SEL, id))objc_msgSend)(configuration, NSSelectorFromString(@"setWallpaperOptions:"), options);
    // The view keeps its treated image in iOS's wallpaper cache under this name, and takes
    // whatever is there: one name per image and size.
    NSString *cacheGroup = [NSString stringWithFormat:@"LockScreenRestore-%@-%.0fx%.0f", name, sized.size.width, sized.size.height];
    sLSRBuildingStaticView = YES;
    UIView *view = ((id (*)(id, SEL, CGRect, id, long long, id, id, unsigned long long))objc_msgSend)(
        [viewClass alloc], viewInit, frame, configuration, 0, cacheGroup, nil, 0);
    sLSRBuildingStaticView = NO;
    if (view) objc_setAssociatedObject(view, kLSRParallaxMotionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

@interface LSRLiveWallpaperView : UIView
- (void)playVideo;
- (void)stopVideo;
@end

@implementation LSRLiveWallpaperView {
    UIView *_contentView;   // image, video and bokeh; moves with the device for Perspective Zoom
    UIImageView *_imageView;
    UIView *_bokehView;
    UIView *_staticView;    // iOS 15's own view for the still, with its Perspective Zoom
    UIView *_dimView;
    AVPlayer *_player;
    AVPlayerLayer *_playerLayer;
    NSString *_loadedVariant;
    NSString *_loadedDir;
    NSURL *_videoURL;
    BOOL _wantsVideoVisible;
    NSInteger _effectQuarter;
}

static void *kLSRReadyForDisplayContext = &kLSRReadyForDisplayContext;

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.clipsToBounds = YES;
        _contentView = [[UIView alloc] initWithFrame:self.bounds];
        [self addSubview:_contentView];
        _imageView = [[UIImageView alloc] initWithFrame:_contentView.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_contentView addSubview:_imageView];

        _player = [AVPlayer new];
        _player.muted = YES;
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _playerLayer.opacity = 0.0;
        [_contentView.layer addSublayer:_playerLayer];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_videoDidEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [_playerLayer addObserver:self forKeyPath:@"readyForDisplay" options:0 context:kLSRReadyForDisplayContext];
        _dimView = [[UIView alloc] initWithFrame:self.bounds];
        _dimView.backgroundColor = [UIColor blackColor];
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_dimView];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                     name:kLSRWallpaperReloadNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applyShownScreen)
                                                     name:kLSRShownScreenNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_orientationChanged)
                                                     name:UIDeviceOrientationDidChangeNotification object:nil];
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [self _loadCurrentVariant];
        // iOS may set up its wallpaper content (and the dock's capture in it) after us.
        __weak LSRLiveWallpaperView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf.window setNeedsLayout];
        });
    }
    return self;
}

- (void)dealloc {
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    [_playerLayer removeObserver:self forKeyPath:@"readyForDisplay" context:kLSRReadyForDisplayContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Show the video layer only once it has a frame, so a fresh item never flashes black.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kLSRReadyForDisplayContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_wantsVideoVisible || !self->_playerLayer.isReadyForDisplay) return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self->_playerLayer.opacity = 1.0;
        [CATransaction commit];
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Our own Perspective Zoom only where Apple's view doesn't do it.
    BOOL perspective = sLSRPerspectiveZoom && !_bokehView && !_staticView;
    CGFloat margin = perspective ? kLSRPerspectiveMargin : 0.0;
    // Landscape (iPhone Plus models): iOS keeps the wallpaper window portrait-sized and turns it
    // with the interface, the way its own wallpaper view is a square that fits both. Counter-turn
    // our content by however far the view is turned on screen, and give it the turned size.
    CGFloat angle = [self _screenRotation];
    BOOL sideways = fabs(sin(angle)) > 0.5;
    CGSize size = sideways ? CGSizeMake(self.bounds.size.height, self.bounds.size.width) : self.bounds.size;
    // Set center/bounds, not frame: the motion effects offset the center.
    _contentView.transform = CGAffineTransformIdentity;
    _contentView.bounds = CGRectMake(0, 0, size.width + 2 * margin, size.height + 2 * margin);
    _contentView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _contentView.transform = CGAffineTransformMakeRotation(-angle);
    _bokehView.frame = _contentView.bounds;
    _staticView.frame = _contentView.bounds;
    // The video plays right on top of the still: inside Apple's view it lies in the image
    // view, so it has the image's size and moves with it.
    UIView *stillHost = [_staticView respondsToSelector:@selector(contentView)]
        ? ((id (*)(id, SEL))objc_msgSend)(_staticView, @selector(contentView)) : nil;
    CALayer *videoHost = stillHost ? stillHost.layer : _contentView.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_playerLayer.superlayer != videoHost) [videoHost addSublayer:_playerLayer];
    _playerLayer.frame = videoHost.bounds;
    [CATransaction commit];
    [self _updatePerspective:perspective angle:angle];
}

// How far this view's x axis is turned against the screen as the user sees it (0 in portrait).
- (CGFloat)_screenRotation {
    UIScreen *screen = self.window.screen;
    if (!screen) return 0.0;
    id<UICoordinateSpace> space = screen.coordinateSpace;
    CGPoint origin = [self convertPoint:CGPointZero toCoordinateSpace:space];
    CGPoint unitX = [self convertPoint:CGPointMake(1, 0) toCoordinateSpace:space];
    CGFloat angle = atan2(unitX.y - origin.y, unitX.x - origin.x);
    // Only quarter turns happen; snap away rounding noise.
    return round(angle / M_PI_2) * M_PI_2;
}

- (void)_orientationChanged {
    [self setNeedsLayout];
    [self.window setNeedsLayout];
    // The window may finish turning after the notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
    });
}

- (void)_updatePerspective:(BOOL)on angle:(CGFloat)angle {
    // Same state: nothing to rebuild (the angle is a quarter turn, compare as an integer).
    NSInteger quarter = (NSInteger)llround(angle / M_PI_2);
    if (on == (_contentView.motionEffects.count > 0) && (!on || quarter == _effectQuarter)) return;
    for (UIMotionEffect *effect in [_contentView.motionEffects copy]) [_contentView removeMotionEffect:effect];
    _effectQuarter = quarter;
    if (!on) return;
    // The tilt comes in screen directions, but the view's center moves in the window's, which
    // is turned on screen by `angle`: offset = R(-angle) * (tilt along x, tilt along y).
    CGFloat c = round(cos(angle)), sn = round(sin(angle));
    // center.x gets  x * c + y * sn,  center.y gets  -x * sn + y * c.
    // Like iOS: the wallpaper moves against the tilt, so it seems to lie behind the screen.
    UIInterpolatingMotionEffectType horizontal = UIInterpolatingMotionEffectTypeTiltAlongHorizontalAxis;
    UIInterpolatingMotionEffectType vertical = UIInterpolatingMotionEffectTypeTiltAlongVerticalAxis;
    BOOL sideways = c == 0;
    UIInterpolatingMotionEffect *x = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.x"
        type:sideways ? vertical : horizontal];
    UIInterpolatingMotionEffect *y = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.y"
        type:sideways ? horizontal : vertical];
    CGFloat xSign = sideways ? sn : c;
    CGFloat ySign = sideways ? -sn : c;
    x.minimumRelativeValue = @( xSign * kLSRPerspectiveMargin);
    x.maximumRelativeValue = @(-xSign * kLSRPerspectiveMargin);
    y.minimumRelativeValue = @( ySign * kLSRPerspectiveMargin);
    y.maximumRelativeValue = @(-ySign * kLSRPerspectiveMargin);
    UIMotionEffectGroup *group = [UIMotionEffectGroup new];
    group.motionEffects = @[x, y];
    [_contentView addMotionEffect:group];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self _loadCurrentVariant];
}

- (void)_reload {
    _loadedVariant = nil;
    _loadedDir = nil;
    [self _loadCurrentVariant];
}

// iOS 15's bubbles move four times as much on the lock screen as on the home screen: tell the
// view which one it's on (wallpaper variant 0 or 1).
- (void)_applyShownScreen {
    SEL setVariant = NSSelectorFromString(@"setVariant:");
    if (![_bokehView respondsToSelector:setVariant] || ![_bokehView respondsToSelector:NSSelectorFromString(@"variant")]) return;
    long long wanted = sLSRShowingLockScreen ? 0 : 1;
    long long current = ((long long (*)(id, SEL))objc_msgSend)(_bokehView, NSSelectorFromString(@"variant"));
    if (current != wanted) ((void (*)(id, SEL, long long))objc_msgSend)(_bokehView, setVariant, wanted);
}

- (void)_loadCurrentVariant {
    NSString *variant = LSRWallpaperVariant(self.traitCollection);
    // Above the video too, so a playing wallpaper stays dimmed.
    _dimView.alpha = sLSRDimInDark && [variant isEqualToString:@"Dark"] ? kLSRDarkDimAlpha : 0.0;
    [self bringSubviewToFront:_dimView];
    _dimView.layer.zPosition = 1;
    NSString *dir = LSRWindowDesignDir();
    if ([variant isEqualToString:_loadedVariant] && [dir isEqualToString:_loadedDir]) return;
    _loadedVariant = variant;
    _loadedDir = dir;
    [_bokehView removeFromSuperview];
    _bokehView = nil;
    // Keep the video layer: it moves back into Apple's view on the next layout.
    [_contentView.layer addSublayer:_playerLayer];
    if ([_staticView respondsToSelector:@selector(invalidate)]) ((void (*)(id, SEL))objc_msgSend)(_staticView, @selector(invalidate));
    [_staticView removeFromSuperview];
    _staticView = nil;
    if (LSRIsBokehDesign(dir)) {
        // Dynamic: Apple's animated bokeh, no video.
        _bokehView = LSRBokehView(dir, [variant isEqualToString:@"Dark"], _contentView.bounds);
        LSRDebugLog(@"bokeh view %@", _bokehView);
        if (_bokehView) [_contentView insertSubview:_bokehView aboveSubview:_imageView];
        LSRSetBokehAnimating(_bokehView, YES);
        [self _applyShownScreen];
        _imageView.image = _bokehView ? nil : LSRWallpaperStillIn(dir, variant);
        _videoURL = nil;
        [self setNeedsLayout];
        [self stopVideo];
        return;
    }
    [self setNeedsLayout];
    UIImage *still = LSRWallpaperStillIn(dir, variant);
    // Named after the design, the appearance and the file's date (a photo can be replaced).
    NSString *stillPath = [[dir stringByAppendingPathComponent:variant] stringByAppendingPathExtension:@"heic"];
    NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:stillPath error:nil].fileModificationDate;
    NSString *stillName = [NSString stringWithFormat:@"%@-%@-%.0f", dir.lastPathComponent, variant, modified.timeIntervalSince1970];
    _staticView = LSRLegacyStaticView(still, stillName, _contentView.bounds, sLSRPerspectiveZoom);
    LSRDebugLog(@"static view %@", _staticView);
    if (_staticView) [_contentView insertSubview:_staticView aboveSubview:_imageView];
    // Now that it's on screen and marked as ours: let it set up its motion.
    if ([_staticView respondsToSelector:NSSelectorFromString(@"_updateParallax")]) {
        ((void (*)(id, SEL))objc_msgSend)(_staticView, NSSelectorFromString(@"_updateParallax"));
    }
    _imageView.image = _staticView ? nil : still;
    _videoURL = dir ? [NSURL fileURLWithPath:[[dir stringByAppendingPathComponent:variant] stringByAppendingPathExtension:@"mov"]] : nil;
    [self stopVideo];
}

// A fresh item every time: an item created before media services were reset (e.g. by a
// respring) stays "ready" but never plays (AVFoundationErrorDomain -11819).
- (void)playVideo {
    if (!_videoURL) return;
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:_videoURL];
    [_player replaceCurrentItemWithPlayerItem:item];
    _wantsVideoVisible = YES;
    [_player play];
    LSRDebugLog(@"playVideo item=%@ status=%ld error=%@", item, (long)item.status, item.error);
}

- (void)stopVideo {
    _wantsVideoVisible = NO;
    [_player pause];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.3];
    _playerLayer.opacity = 0.0;
    [CATransaction commit];
}

- (void)_videoDidEnd:(NSNotification *)notification {
    if (notification.object == _player.currentItem) [self stopVideo];
}
@end

static __weak LSRLiveWallpaperView *sLSRWallpaperView = nil;

@interface _SBWallpaperSecureWindow : UIWindow
@end

@interface CSCoverSheetViewController : UIViewController
@end

// While the lock screen slides away or back (unlock, lock, notification center, camera/today
// swipes), iOS draws a portal copy of its real wallpaper inside the lock screen window
// (SBWallpaperEffectView > PBUIWallpaperView > PBUIPortalReplicaEffectView). That's the old
// wallpaper flashing; cover those copies with our still too.
@interface _UIPortalView : UIView
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic) BOOL hidesSourceView;
@property (nonatomic) BOOL matchesPosition;
@property (nonatomic) BOOL matchesTransform;
@property (nonatomic) BOOL matchesAlpha;
@end

@interface LSRStillCoverView : UIImageView
- (void)_reload;
- (void)updateLiveMirror;
@end

@implementation LSRStillCoverView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                     name:kLSRWallpaperReloadNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The still the way the wallpaper window shows it at rest: cut to Apple's size and centered
// (a Dynamic design's thumbnail just fills the screen).
- (void)_reload {
    UIImage *still = LSRWallpaperStill(LSRWallpaperVariant(self.traitCollection));
    BOOL bokeh = LSRIsBokehDesign(sLSRWallpaperDesignDir);
    UIImage *sized = bokeh ? nil : LSRAppleSizedStill(still, sLSRPerspectiveZoom);
    self.contentMode = sized ? UIViewContentModeCenter : UIViewContentModeScaleAspectFill;
    self.image = sized ?: still;
    [self updateLiveMirror];
}

// The wallpaper moves (bubbles, Perspective Zoom, a playing video), and a still of it would
// jump: the copy mirrors the wallpaper window's live view instead (a portal, like iOS's own
// copies), as long as that window shows the same design on both screens. The still stays
// underneath.
- (void)updateLiveMirror {
    LSRLiveWallpaperView *live = sLSRWallpaperView;
    BOOL sameDesign = !sLSRHomeDesignDir || [sLSRHomeDesignDir isEqualToString:sLSRWallpaperDesignDir];
    Class portalClass = NSClassFromString(@"_UIPortalView");
    BOOL wanted = live && sameDesign && portalClass;
    _UIPortalView *portal = nil;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:portalClass]) portal = (_UIPortalView *)sub;
    }
    if (!wanted) {
        [portal removeFromSuperview];
        return;
    }
    if (!portal) {
        portal = [[portalClass alloc] initWithFrame:self.bounds];
        portal.userInteractionEnabled = NO;
        portal.hidesSourceView = NO;
        portal.matchesPosition = NO;
        portal.matchesTransform = NO;
        portal.matchesAlpha = NO;
        [self addSubview:portal];
    }
    if (portal.sourceView != live) portal.sourceView = live;
    if (!CGRectEqualToRect(portal.frame, self.bounds)) portal.frame = self.bounds;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLiveMirror];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self _reload];
}
@end

static void LSRCoverWithStill(UIView *effectView) {
    // Only full-screen copies in the lock screen window: the same class also backs smaller
    // blurred surfaces elsewhere, which must keep their look.
    if (![effectView.window isKindOfClass:NSClassFromString(@"SBCoverSheetWindow")]) return;
    CGSize screen = [UIScreen mainScreen].bounds.size;
    // Full screen in either orientation.
    CGSize have = effectView.bounds.size;
    BOOL portraitSize = fabs(have.width - screen.width) <= 1 && fabs(have.height - screen.height) <= 1;
    BOOL landscapeSize = fabs(have.width - screen.height) <= 1 && fabs(have.height - screen.width) <= 1;
    if (!portraitSize && !landscapeSize) return;

    LSRStillCoverView *cover = nil;
    for (UIView *sub in effectView.subviews) {
        if ([sub isKindOfClass:[LSRStillCoverView class]]) cover = (LSRStillCoverView *)sub;
    }
    if (!cover) {
        cover = [[LSRStillCoverView alloc] initWithFrame:effectView.bounds];
        cover.clipsToBounds = YES;
        cover.userInteractionEnabled = NO;
        [cover _reload];
    }
    if (effectView.subviews.lastObject != cover) [effectView addSubview:cover];
    if (!CGRectEqualToRect(cover.frame, effectView.bounds)) cover.frame = effectView.bounds;
    [cover updateLiveMirror];
}

@interface SBWallpaperEffectView : UIView
@end

@interface SBDashBoardWallpaperEffectView : UIView
@end

@interface LSRWallpaperPressHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation LSRWallpaperPressHandler
+ (instancetype)shared {
    static LSRWallpaperPressHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handler = [LSRWallpaperPressHandler new]; });
    return handler;
}

- (void)handlePress:(UILongPressGestureRecognizer *)recognizer {
    LSRDebugLog(@"press state %ld, wallpaper view %@", (long)recognizer.state, sLSRWallpaperView);
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [sLSRWallpaperView playVideo];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [sLSRWallpaperView stopVideo];
            break;
        default:
            break;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

// Only presses on the wallpaper itself, not on something that has its own press behaviour.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view; view = view.superview) {
        NSString *name = NSStringFromClass([view class]);
        BOOL blocked = [view isKindOfClass:[UIControl class]];
        for (NSString *fragment in @[@"ShortLook", @"LongLook", @"ListCell", @"PlatterView", @"AdjunctItem", @"QuickActions"]) {
            if ([name containsString:fragment]) blocked = YES;
        }
        if (blocked) {
            LSRDebugLog(@"touch on %@ ignored (inside %@)", NSStringFromClass([touch.view class]), name);
            return NO;
        }
    }
    LSRDebugLog(@"touch on %@ accepted", NSStringFromClass([touch.view class]));
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    LSRDebugLog(@"press should begin");
    return YES;
}
@end

// iPhones with a home button (the dock goes from edge to edge): the dock doesn't blur what is
// behind it itself. iOS keeps a capture-only material inside its wallpaper content (group
// "WallpaperCaptureGroup") and the dock shows what that one sees: iOS's own wallpaper, not ours
// above it. A second copy of our wallpaper goes right under that capture, where only the capture
// sees it (our real one covers it on screen).
// While the home screen turns, iOS builds the wallpaper content for the new orientation next
// to the old one, each with its own capture: every capture gets a copy, as soon as it appears
// (waiting for the window's next layout let iOS's wallpaper show through the dock meanwhile).
static const void *const kLSRCaptureCopyKey = &kLSRCaptureCopyKey;

static BOOL LSRIsWallpaperCapture(UIView *view) {
    CALayer *layer = view.layer;
    if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return NO;
    @try {
        return [[layer valueForKey:@"groupName"] isEqual:@"WallpaperCaptureGroup"] && [[layer valueForKey:@"captureOnly"] boolValue];
    } @catch (id e) {
        return NO;
    }
}

static void LSRCollectWallpaperCaptures(UIView *view, NSUInteger depth, NSMutableArray<UIView *> *captures) {
    if ([view isKindOfClass:[LSRLiveWallpaperView class]]) return;
    if (LSRIsWallpaperCapture(view)) {
        [captures addObject:view];
        return;
    }
    if (depth == 0) return;
    for (UIView *sub in view.subviews) LSRCollectWallpaperCaptures(sub, depth - 1, captures);
}

static void LSRPlaceCaptureCopies(UIWindow *window) {
#ifdef DEBUG
    // Test switches for iPhones whose dock blurs by itself (no capture there): "lsr-fake-capture"
    // adds a capture like the one on home button iPhones, "lsr-no-capture-copy" leaves our copy out.
    NSFileManager *fm = [NSFileManager defaultManager];
    static __weak UIView *fakeCapture = nil;
    UIView *content = window.subviews.firstObject;
    if (!fakeCapture && content && ![content isKindOfClass:[LSRLiveWallpaperView class]]
        && [fm fileExistsAtPath:@"/var/mobile/Documents/lsr-fake-capture"]) {
        Class materialClass = NSClassFromString(@"MTMaterialView");
        UIView *fake = ((id (*)(id, SEL, NSInteger, NSUInteger, double))objc_msgSend)(materialClass,
            NSSelectorFromString(@"materialViewWithRecipe:options:initialWeighting:"), 19, 0, 1.0);
        fake.frame = content.bounds;
        fake.userInteractionEnabled = NO;
        ((void (*)(id, SEL, id))objc_msgSend)(fake, NSSelectorFromString(@"setGroupName:"), @"WallpaperCaptureGroup");
        [fake.layer setValue:@"global" forKey:@"groupNamespace"];
        [fake.layer setValue:@YES forKey:@"captureOnly"];
        [content addSubview:fake];
        fakeCapture = fake;
    }
    if ([fm fileExistsAtPath:@"/var/mobile/Documents/lsr-no-capture-copy"]) return;
#endif
    NSMutableArray<UIView *> *captures = [NSMutableArray new];
    for (UIView *sub in window.subviews) LSRCollectWallpaperCaptures(sub, 8, captures);
    static NSHashTable<LSRLiveWallpaperView *> *copies;
    if (!copies) copies = [NSHashTable weakObjectsHashTable];
    NSMutableSet<LSRLiveWallpaperView *> *used = [NSMutableSet new];
    for (UIView *capture in captures) {
        UIView *host = capture.superview;
        if (!host) continue;
        LSRLiveWallpaperView *copy = objc_getAssociatedObject(capture, kLSRCaptureCopyKey);
        if (!copy) {
            copy = [[LSRLiveWallpaperView alloc] initWithFrame:host.bounds];
            objc_setAssociatedObject(capture, kLSRCaptureCopyKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [copies addObject:copy];
        }
        [used addObject:copy];
        NSUInteger captureIndex = [host.subviews indexOfObject:capture];
        if (copy.superview != host || captureIndex == 0 || host.subviews[captureIndex - 1] != copy) {
            [host insertSubview:copy belowSubview:capture];
        }
        if (!CGRectEqualToRect(copy.frame, host.bounds)) copy.frame = host.bounds;
    }
    // A capture that left the window takes its copy along; one that only lost its capture goes.
    for (LSRLiveWallpaperView *copy in copies.allObjects) {
        if (![used containsObject:copy] && copy.window == window) [copy removeFromSuperview];
    }
}

static void LSRPlaceCaptureCopy(UIWindow *window) {
    // Adding a copy (or the test capture) moves views into the window, which asks again.
    static BOOL placing = NO;
    if (placing || !window) return;
    placing = YES;
    LSRPlaceCaptureCopies(window);
    placing = NO;
}

@interface MTMaterialView : UIView
@end

@interface PBUIWallpaperView : UIView
@end

@interface PBUIBokehWallpaperView : PBUIWallpaperView
@end

@interface PBUIBokehWallpaperCircle : CALayer
@end

// LSRWallpaper hooks are plain Objective-C; installed only when live wallpapers are enabled.
static void (*LSRWallpaper_orig_SecureWindow_layoutSubviews)(id, SEL);
static void LSRWallpaper_SecureWindow_layoutSubviews(id self, SEL _cmd) {
    LSRWallpaper_orig_SecureWindow_layoutSubviews(self, _cmd);
    // Directly above iOS's wallpaper content (the window's first subview), below anything iOS
    // layers on top of it.
    LSRLiveWallpaperView *view = sLSRWallpaperView;
    if (!view || view.superview != self) {
        view = [[LSRLiveWallpaperView alloc] initWithFrame:[(UIView *)self bounds]];
        sLSRWallpaperView = view;
    }
    UIView *window = (UIView *)self;
    UIView *wallpaperContent = window.subviews.firstObject;
    NSUInteger wantedIndex = wallpaperContent == view ? 0 : 1;
    if (view.superview != window || [window.subviews indexOfObject:view] != wantedIndex) {
        [window insertSubview:view aboveSubview:wallpaperContent];
    }
    if (!CGRectEqualToRect(view.frame, window.bounds)) view.frame = window.bounds;
    LSRPlaceCaptureCopy((UIWindow *)self);
}

// Each display link tick moves the view's bubbles: give them iOS 15's dx and dy for it
// (turned to the interface orientation by the view's own -_correctGyroValues:y:, and none
// while the view rotates, as on iOS 15).
static void (*LSRWallpaper_orig_BokehView_screenDidUpdate)(id, SEL, id);
static void LSRWallpaper_BokehView_screenDidUpdate(id self, SEL _cmd, id displayLink) {
    LSRBokehMotionStart();
    sLSRBokehLastTick = CACurrentMediaTime();
    double dx = 0.0, dy = 0.0;
    BOOL rotating = [self respondsToSelector:@selector(isRotating)] && ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isRotating));
    SEL correct = NSSelectorFromString(@"_correctGyroValues:y:");
    if (!rotating && [self respondsToSelector:correct]) {
        LSRBokehMotionGradient(&dx, &dy);
        ((void (*)(id, SEL, double *, double *))objc_msgSend)(self, correct, &dx, &dy);
    }
#ifdef DEBUG
    static NSUInteger ticks = 0;
    if (++ticks % 60 == 0) {
        LSRDebugLog(@"bokeh motion: dx %.5f dy %.5f, filtered gravity %.3f %.3f, variant %lld", dx, dy,
            sLSRBokehFilterX.outputs[0], sLSRBokehFilterY.outputs[0],
            ((long long (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"variant")));
    }
#endif
    sLSRBokehDX = dx;
    sLSRBokehDY = dy;
    sLSRBokehUpdating = YES;
    LSRWallpaper_orig_BokehView_screenDidUpdate(self, _cmd, displayLink);
    sLSRBokehUpdating = NO;
}

static void (*LSRWallpaper_orig_BokehView_destroyDisplayLink)(id, SEL);
static void LSRWallpaper_BokehView_destroyDisplayLink(id self, SEL _cmd) {
    LSRWallpaper_orig_BokehView_destroyDisplayLink(self, _cmd);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LSRBokehMotionPauseIfIdle();
    });
}

static void (*LSRWallpaper_orig_BokehCircle_updatePosition)(id, SEL, double, double, double, BOOL);
static void LSRWallpaper_BokehCircle_updatePosition(id self, SEL _cmd, double time, double dx, double dy, BOOL lockScreen) {
    if (sLSRBokehUpdating) {
        LSRWallpaper_orig_BokehCircle_updatePosition(self, _cmd, time, sLSRBokehDX, sLSRBokehDY, lockScreen);
        return;
    }
    LSRWallpaper_orig_BokehCircle_updatePosition(self, _cmd, time, dx, dy, lockScreen);
}

static BOOL (*LSRWallpaper_orig_WallpaperView_isParallaxMotionEnabled)(id, SEL);
static BOOL LSRWallpaper_WallpaperView_isParallaxMotionEnabled(id self, SEL _cmd) {
    if (sLSRBuildingStaticView || objc_getAssociatedObject(self, kLSRParallaxMotionKey)) return YES;
    return LSRWallpaper_orig_WallpaperView_isParallaxMotionEnabled(self, _cmd);
}

static void (*LSRWallpaper_orig_MaterialView_didMoveToWindow)(id, SEL);
static void LSRWallpaper_MaterialView_didMoveToWindow(id self, SEL _cmd) {
    LSRWallpaper_orig_MaterialView_didMoveToWindow(self, _cmd);
    UIWindow *window = [(UIView *)self window];
    if ([window isKindOfClass:objc_getClass("_SBWallpaperSecureWindow")] && LSRIsWallpaperCapture(self)) LSRPlaceCaptureCopy(window);
}

static void (*LSRWallpaper_orig_MaterialView_setGroupName)(id, SEL, NSString *);
static void LSRWallpaper_MaterialView_setGroupName(id self, SEL _cmd, NSString *name) {
    LSRWallpaper_orig_MaterialView_setGroupName(self, _cmd, name);
    UIWindow *window = [(UIView *)self window];
    if ([window isKindOfClass:objc_getClass("_SBWallpaperSecureWindow")] && LSRIsWallpaperCapture(self)) LSRPlaceCaptureCopy(window);
}

// iOS 16's lock screen long press opens the poster (lock screen) editor; on iOS 15 it played the
// live wallpaper. Replace it with our own press recognizer: play while held, back to the still
// on release. Presses on notifications and controls (flashlight, camera, ...) are left alone.
static void (*LSRWallpaper_orig_CoverSheet_viewDidLoad)(id, SEL);
static void LSRWallpaper_CoverSheet_viewDidLoad(id self, SEL _cmd) {
    LSRWallpaper_orig_CoverSheet_viewDidLoad(self, _cmd);
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[LSRWallpaperPressHandler shared] action:@selector(handlePress:)];
    press.minimumPressDuration = 0.35;
    press.cancelsTouchesInView = NO;
    press.delegate = [LSRWallpaperPressHandler shared];
    [[(UIViewController *)self view] addGestureRecognizer:press];
}

// Lock screen fully up: its design. Starting to go away: the home screen's design underneath.
static void (*LSRWallpaper_orig_CoverSheet_viewDidAppear)(id, SEL, BOOL);
static void LSRWallpaper_CoverSheet_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    LSRWallpaper_orig_CoverSheet_viewDidAppear(self, _cmd, animated);
    if (sLSRShowingLockScreen) return;
    sLSRShowingLockScreen = YES;
    if (sLSRHomeDesignDir) [[NSNotificationCenter defaultCenter] postNotificationName:kLSRWallpaperReloadNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLSRShownScreenNotification object:nil];
}

static void (*LSRWallpaper_orig_CoverSheet_viewWillDisappear)(id, SEL, BOOL);
static void LSRWallpaper_CoverSheet_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    LSRWallpaper_orig_CoverSheet_viewWillDisappear(self, _cmd, animated);
    if (!sLSRShowingLockScreen) return;
    sLSRShowingLockScreen = NO;
    if (sLSRHomeDesignDir) [[NSNotificationCenter defaultCenter] postNotificationName:kLSRWallpaperReloadNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLSRShownScreenNotification object:nil];
}

static void LSRWallpaper_CoverSheet_setupPosterSwitcherGestureRecognizer(id self, SEL _cmd) {}
static void LSRWallpaper_CoverSheet_handlePosterSwitcherActivation(id self, SEL _cmd, id sender) {}

static void (*LSRWallpaper_orig_EffectView_layoutSubviews)(id, SEL);
static void LSRWallpaper_EffectView_layoutSubviews(id self, SEL _cmd) {
    LSRWallpaper_orig_EffectView_layoutSubviews(self, _cmd);
    LSRCoverWithStill(self);
}
static void (*LSRWallpaper_orig_EffectView_didMoveToWindow)(id, SEL);
static void LSRWallpaper_EffectView_didMoveToWindow(id self, SEL _cmd) {
    LSRWallpaper_orig_EffectView_didMoveToWindow(self, _cmd);
    LSRCoverWithStill(self);
}
static void (*LSRWallpaper_orig_DashboardEffectView_layoutSubviews)(id, SEL);
static void LSRWallpaper_DashboardEffectView_layoutSubviews(id self, SEL _cmd) {
    LSRWallpaper_orig_DashboardEffectView_layoutSubviews(self, _cmd);
    LSRCoverWithStill(self);
}
static void (*LSRWallpaper_orig_DashboardEffectView_didMoveToWindow)(id, SEL);
static void LSRWallpaper_DashboardEffectView_didMoveToWindow(id self, SEL _cmd) {
    LSRWallpaper_orig_DashboardEffectView_didMoveToWindow(self, _cmd);
    LSRCoverWithStill(self);
}

static void LSRInstallWallpaperHooks(void) {
    Class cls = objc_getClass("_SBWallpaperSecureWindow");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRWallpaper_SecureWindow_layoutSubviews, (IMP *)&LSRWallpaper_orig_SecureWindow_layoutSubviews);
    cls = objc_getClass("PBUIBokehWallpaperView");
    if (cls) {
        MSHookMessageEx(cls, NSSelectorFromString(@"_screenDidUpdate:"), (IMP)LSRWallpaper_BokehView_screenDidUpdate, (IMP *)&LSRWallpaper_orig_BokehView_screenDidUpdate);
        MSHookMessageEx(cls, NSSelectorFromString(@"_destroyDisplayLink"), (IMP)LSRWallpaper_BokehView_destroyDisplayLink, (IMP *)&LSRWallpaper_orig_BokehView_destroyDisplayLink);
    }
    cls = objc_getClass("PBUIBokehWallpaperCircle");
    if (cls) MSHookMessageEx(cls, @selector(updatePositionWithTime:dx:dy:lockScreen:), (IMP)LSRWallpaper_BokehCircle_updatePosition, (IMP *)&LSRWallpaper_orig_BokehCircle_updatePosition);
    cls = objc_getClass("PBUIWallpaperView");
    if (cls) MSHookMessageEx(cls, NSSelectorFromString(@"_isParallaxMotionEnabled"), (IMP)LSRWallpaper_WallpaperView_isParallaxMotionEnabled, (IMP *)&LSRWallpaper_orig_WallpaperView_isParallaxMotionEnabled);
    cls = objc_getClass("MTMaterialView");
    if (cls) {
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)LSRWallpaper_MaterialView_didMoveToWindow, (IMP *)&LSRWallpaper_orig_MaterialView_didMoveToWindow);
        MSHookMessageEx(cls, @selector(setGroupName:), (IMP)LSRWallpaper_MaterialView_setGroupName, (IMP *)&LSRWallpaper_orig_MaterialView_setGroupName);
    }
    cls = objc_getClass("CSCoverSheetViewController");
    if (cls) {
        MSHookMessageEx(cls, @selector(viewDidLoad), (IMP)LSRWallpaper_CoverSheet_viewDidLoad, (IMP *)&LSRWallpaper_orig_CoverSheet_viewDidLoad);
        MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)LSRWallpaper_CoverSheet_viewDidAppear, (IMP *)&LSRWallpaper_orig_CoverSheet_viewDidAppear);
        MSHookMessageEx(cls, @selector(viewWillDisappear:), (IMP)LSRWallpaper_CoverSheet_viewWillDisappear, (IMP *)&LSRWallpaper_orig_CoverSheet_viewWillDisappear);
        MSHookMessageEx(cls, NSSelectorFromString(@"_setupPosterSwitcherGestureRecognizer"), (IMP)LSRWallpaper_CoverSheet_setupPosterSwitcherGestureRecognizer, NULL);
        MSHookMessageEx(cls, NSSelectorFromString(@"_handlePosterSwitcherActivation:"), (IMP)LSRWallpaper_CoverSheet_handlePosterSwitcherActivation, NULL);
    }
    cls = objc_getClass("SBWallpaperEffectView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRWallpaper_EffectView_layoutSubviews, (IMP *)&LSRWallpaper_orig_EffectView_layoutSubviews);
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)LSRWallpaper_EffectView_didMoveToWindow, (IMP *)&LSRWallpaper_orig_EffectView_didMoveToWindow);
    }
    cls = objc_getClass("SBDashBoardWallpaperEffectView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRWallpaper_DashboardEffectView_layoutSubviews, (IMP *)&LSRWallpaper_orig_DashboardEffectView_layoutSubviews);
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)LSRWallpaper_DashboardEffectView_didMoveToWindow, (IMP *)&LSRWallpaper_orig_DashboardEffectView_didMoveToWindow);
    }
}



// The home screen's design folder, nil when none was picked (then it shows the lock screen's).
static NSString *LSRResolveHomeDesignDir(NSDictionary *prefs) {
    NSString *chosen = prefs[@"homeWallpaperDesign"];
    if (LSRIsBokehDesign(chosen)) return chosen;
    if (![chosen isKindOfClass:[NSString class]] || !chosen.length) return nil;
    NSString *dir = [kLSRWallpapersDir stringByAppendingPathComponent:chosen];
    return [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"Light.heic"]] ? dir : nil;
}

// The chosen design's folder, or the first one available; nil if there are none.
static NSString *LSRResolveWallpaperDesignDir(NSDictionary *prefs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *chosen = prefs[@"wallpaperDesign"];
    if (LSRIsBokehDesign(chosen)) return chosen;  // a Dynamic wallpaper
    if ([chosen isKindOfClass:[NSString class]] && chosen.length) {
        NSString *dir = [kLSRWallpapersDir stringByAppendingPathComponent:chosen];
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Light.heic"]]) return dir;
    }
    NSArray *designs = [[fm contentsOfDirectoryAtPath:kLSRWallpapersDir error:nil]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *design in designs) {
        if ([design hasPrefix:@"."]) continue;  // .Photo only when picked
        NSString *dir = [kLSRWallpapersDir stringByAppendingPathComponent:design];
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Light.heic"]]) return dir;
    }
    return nil;
}

static NSDictionary *LSRReadPrefs(void) {
    NSDictionary *prefs = nil;
    for (size_t i = 0; i < sizeof(kLSRPrefsPaths) / sizeof(kLSRPrefsPaths[0]) && !prefs; i++) {
        prefs = [NSDictionary dictionaryWithContentsOfFile:LSRDevicePath(kLSRPrefsPaths[i])];
    }
    return prefs;
}

// Settings > Wallpaper picked another design or toggled dimming: swap it in without a respring.
static void LSRWallpaperPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                     const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *prefs = LSRReadPrefs();
        NSString *dir = LSRResolveWallpaperDesignDir(prefs);
        if (dir) sLSRWallpaperDesignDir = dir;
        sLSRHomeDesignDir = LSRResolveHomeDesignDir(prefs);
        sLSRDimInDark = [prefs[@"dimWallpaperInDark"] boolValue];
        sLSRPerspectiveZoom = prefs[@"perspectiveZoom"] ? [prefs[@"perspectiveZoom"] boolValue] : YES;
        [sLSRStillCache removeAllObjects];
        [[NSNotificationCenter defaultCenter] postNotificationName:kLSRWallpaperReloadNotification object:nil];
    });
}

#pragma mark - Group: iOS 15 music player (runs in MediaRemoteUI)

// On iOS 16 the lock screen player is a Live Activity: MediaRemoteUI draws it in its own scene
// and SpringBoard only shows that scene inside a notification-list platter. MRUNowPlayingView
// has context 2 there. Its iOS 16 layout (artwork + title in one row, time labels beside the
// bar, AirPlay among the buttons, no volume) is replaced with iOS 15's. iOS 16 no longer has
// iOS 15's layout code (MRUNowPlayingControlsView is gone), so these are the frames of the
// real thing: a view dump of the playing lock screen on iOS 15.8 (355pt wide platter), all in
// pt from the platter's top left:
//   platter 282 tall, content 16 in from every edge
//   artwork 100x100 at 16,16 (corner radius 4), app icon 16x16, 8 in from its bottom right
//   text column from x 128: route ("iPhone", Semibold 12) top 38, title (Semibold 17) top 52.5,
//   subtitle (Regular 17) top 73; a label's baseline is its top plus the font's ascender
//   AirPlay button 36x36, right edge 16 in, level with the artwork's center
//   progress bar center y 138, 4 thick, 8pt knob; times Medium 11, top 147
//   buttons 44x44, center y 191; five slots from 22 left of the content to 22 right of it
//   (the outer two empty), so (content width + 44) / 4 apart
//   volume bar center y 244 from x 60 to 60 before the right edge, 24pt knob; speaker icons
//   20x20, centered 38 from the edges
static const NSInteger kMRUContextCoverSheet = 2;
static const CGFloat kIOS15PlayerHeight = 282.0;
static const CGFloat kIOS15PlayerInset = 16.0;
static const CGFloat kIOS15ArtworkSize = 100.0;
static const CGFloat kIOS15ArtworkCornerRadius = 4.0;
// The playing app's icon in the artwork's corner (MediaControls 15.6.1, MRUArtworkView
// layoutSubviews, style 1): 16pt, 8pt in from the bottom right. iOS 16 dropped the icon view.
static const CGFloat kIOS15AppIconSize = 16.0;
static const CGFloat kIOS15AppIconInset = 8.0;
static const CGFloat kIOS15TextLeft = 128.0;
static const CGFloat kIOS15HeaderTop = 40.0;
static const CGFloat kIOS15HeaderHeight = 54.0;
static const CGFloat kIOS15RoutingCenterFromRight = 34.0;
static const CGFloat kIOS15RouteBaseline = 49.4;
static const CGFloat kIOS15TitleBaseline = 68.7;
static const CGFloat kIOS15SubtitleBaseline = 89.2;
static const CGFloat kIOS15TimeBarCenterY = 138.0;
static const CGFloat kIOS15TimeLabelBaseline = 157.5;
static const CGFloat kIOS15TimeLabelFontSize = 11.0;
static const CGFloat kIOS15TransportCenterY = 191.0;
// Button slots: (content width + this) / 4 apart.
static const CGFloat kIOS15TransportSlotWidth = 44.0;
static const CGFloat kIOS15VolumeCenterY = 244.0;
static const CGFloat kIOS15VolumeBarLeft = 60.0;
static const CGFloat kIOS15VolumeBarRightInset = 60.0;
static const CGFloat kIOS15VolumeMinIconCenter = 38.0;
static const CGFloat kIOS15VolumeMaxIconCenterFromRight = 38.0;
static const CGFloat kIOS15SliderThickness = 4.0;
static const CGFloat kIOS15TimeKnobSize = 8.0;
static const CGFloat kIOS15VolumeKnobSize = 24.0;
// iOS 15's glyphs were bigger: play/pause 34pt tall (iOS 16: 27.4), previous/next 35pt wide (32).
static const CGFloat kIOS15PlayGlyphScale = 1.25;
static const CGFloat kIOS15SkipGlyphScale = 1.1;

@interface MRUSlider : UIControl
@property (nonatomic, strong) UIView *minTrack;
@property (nonatomic) float value;
@property (nonatomic) float minimumValue;
@property (nonatomic) float maximumValue;
@end

@interface MRUArtworkView : UIControl
@property (nonatomic, strong) UIImage *iconImage;
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UIView *artworkShadowView;
@property (nonatomic, strong) UIView *placeholderBackground;
@end

@interface MRUNowPlayingLabelView : UIControl
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) UIView *routeLabel;
@property (nonatomic, strong) UIView *titleMarqueeView;
@property (nonatomic, strong) UIView *subtitleMarqueeView;
@property (nonatomic, strong) UIView *placeholderMarqueeView;
@end

@interface MRUNowPlayingHeaderView : UIView
@property (nonatomic, strong) MRUNowPlayingLabelView *labelView;
@property (nonatomic, strong) UIView *routingButton;
@property (nonatomic, strong) UIView *waveformView;
@property (nonatomic) BOOL showRoutingButton;
@property (nonatomic) BOOL showTransportButton;
@property (nonatomic) BOOL showWaveform;
@end

@interface MRUNowPlayingTimeControlsView : UIView
@property (nonatomic, strong) MRUSlider *slider;
@property (nonatomic, strong) UILabel *elapsedTimeLabel;
@property (nonatomic, strong) UILabel *remainingTimeLabel;
@property (nonatomic, strong) UILabel *liveLabel;
@end

@interface MRUNowPlayingTransportControlsView : UIView
@property (nonatomic, strong) UIView *leftButton;
@property (nonatomic, strong) UIView *centerButton;
@property (nonatomic, strong) UIView *rightButton;
@property (nonatomic) BOOL showRoutingButton;
@end

@interface MRUNowPlayingVolumeControlsView : UIView
@property (nonatomic, strong) MRUSlider *slider;
@property (nonatomic, strong) UIImageView *minImageView;
@property (nonatomic, strong) UIImageView *maxImageView;
@end

@interface MRUNowPlayingView : UIView
@property (nonatomic) NSInteger context;
@property (nonatomic) BOOL showVolumeControlsView;
@property (nonatomic, strong) MRUArtworkView *artworkView;
@property (nonatomic, strong) MRUNowPlayingHeaderView *headerView;
@property (nonatomic, strong) MRUNowPlayingTimeControlsView *timeControlsView;
@property (nonatomic, strong) MRUNowPlayingTransportControlsView *transportControlsView;
@property (nonatomic, strong) MRUNowPlayingVolumeControlsView *volumeControlsView;
@end

@interface MRUNowPlayingInfo : NSObject
@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *album;
@end

@interface MRUMetadataController : NSObject
@property (readonly, nonatomic) MRUNowPlayingInfo *nowPlayingInfo;
@property (readonly, copy, nonatomic) NSString *bundleID;
@end

@interface MRUNowPlayingController : NSObject
@property (readonly, nonatomic) MRUMetadataController *metadataController;
@end

@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic) NSInteger context;
@property (nonatomic, strong) MRUNowPlayingController *controller;
@property (nonatomic) BOOL showArtworkView;
- (void)launchNowPlayingApp;
@end

static BOOL LSRIsLockScreenPlayer(MRUNowPlayingView *view) {
    return view.context == kMRUContextCoverSheet;
}

// The lock screen player a view belongs to, or nil.
static MRUNowPlayingView *LSRLockScreenPlayerFor(UIView *view) {
    static Class playerClass;
    if (!playerClass) playerClass = NSClassFromString(@"MRUNowPlayingView");
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:playerClass]) return LSRIsLockScreenPlayer((MRUNowPlayingView *)v) ? (MRUNowPlayingView *)v : nil;
    }
    return nil;
}

// Only touch frames that differ, so our layout never re-triggers a layout pass.
static void LSRSetFrame(UIView *view, CGRect frame) {
    if (!view) return;
    CGRect current = view.frame;
    if (fabs(current.origin.x - frame.origin.x) > 0.01 || fabs(current.origin.y - frame.origin.y) > 0.01
        || fabs(current.size.width - frame.size.width) > 0.01 || fabs(current.size.height - frame.size.height) > 0.01) {
        view.frame = frame;
    }
}

static void LSRSetCenter(UIView *view, CGPoint center) {
    if (!view) return;
    CGSize size = view.bounds.size;
    LSRSetFrame(view, CGRectMake(center.x - size.width / 2.0, center.y - size.height / 2.0, size.width, size.height));
}

// Top of a label (or a view holding one) whose text baseline should sit at `baseline`.
static CGFloat LSRTopForBaseline(CGFloat baseline, UIFont *font) {
    return baseline - (font ? font.ascender : 0.0);
}

static UILabel *LSRFirstLabelIn(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return (UILabel *)view;
    for (UIView *sub in view.subviews) {
        UILabel *found = LSRFirstLabelIn(sub);
        if (found) return found;
    }
    return nil;
}

// iOS 15's white round knob on the progress and volume bars (iOS 16 has none).
static const void *kLSRKnobKey = &kLSRKnobKey;

static void LSRUpdateKnob(MRUSlider *slider) {
    UIView *knob = objc_getAssociatedObject(slider, kLSRKnobKey);
    MRUNowPlayingView *player = LSRLockScreenPlayerFor(slider);
    if (!player) {
        knob.hidden = YES;
        return;
    }
    BOOL volume = [slider.superview isKindOfClass:NSClassFromString(@"MRUNowPlayingVolumeControlsView")];
    CGFloat size = volume ? kIOS15VolumeKnobSize : kIOS15TimeKnobSize;
    if (!knob) {
        knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
        knob.userInteractionEnabled = NO;
        knob.backgroundColor = [UIColor whiteColor];
        knob.layer.cornerRadius = size / 2.0;
        if (volume) {
            knob.layer.shadowColor = [UIColor blackColor].CGColor;
            knob.layer.shadowOpacity = 0.2f;
            knob.layer.shadowRadius = 4.0;
            knob.layer.shadowOffset = CGSizeMake(0, 1);
        }
        objc_setAssociatedObject(slider, kLSRKnobKey, knob, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (knob.superview != slider) [slider addSubview:knob];
    if (slider.subviews.lastObject != knob) [slider bringSubviewToFront:knob];
    knob.hidden = NO;

    CGFloat range = slider.maximumValue - slider.minimumValue;
    CGFloat fraction = range > 0 ? (slider.value - slider.minimumValue) / range : 0.0;
    fraction = MIN(MAX(fraction, 0.0), 1.0);
    CGRect bounds = slider.bounds;
    // The knob stays inside the bar's ends, like iOS 15's.
    CGFloat x = size / 2.0 + fraction * MAX(0.0, bounds.size.width - size);
    LSRSetCenter(knob, CGPointMake(x, CGRectGetMidY(bounds)));
}

static void LSRUpdateSliderTouchTarget(MRUSlider *slider) {
    // The bar is thinner than iOS 16's; keep it easy to grab.
    if (slider.bounds.size.height < 20.0) {
        CGFloat pad = -(22.0 - slider.bounds.size.height / 2.0);
        UIEdgeInsets insets = UIEdgeInsetsMake(pad, -8.0, pad, -8.0);
        if ([slider respondsToSelector:@selector(setHitRectInset:)]) {
            ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(slider, @selector(setHitRectInset:), insets);
        }
    }
}

// What iOS 15 showed that iOS 16's lock screen layout hides: volume slider, route label
// ("iPhone"), AirPlay in the header instead of among the buttons, no waveform/mini play button.
static void LSREnforcePlayerVisibility(MRUNowPlayingView *player) {
    if (!player.showVolumeControlsView) player.showVolumeControlsView = YES;
    MRUNowPlayingHeaderView *header = player.headerView;
    if (!header.showRoutingButton) header.showRoutingButton = YES;
    if (header.showTransportButton) header.showTransportButton = NO;
    if (header.showWaveform) header.showWaveform = NO;
    MRUNowPlayingTransportControlsView *transport = player.transportControlsView;
    if (transport.showRoutingButton) transport.showRoutingButton = NO;
}


@interface MRUAssetsProvider : NSObject
+ (instancetype)sharedAssetsProvider;
- (UIImage *)applicationIconForBundleIdentifier:(NSString *)bundleID;
@end

static const void *kLSRAppIconViewKey = &kLSRAppIconViewKey;

// Hands the playing app's icon to the artwork view, which iOS 16 still has a property for.
static void LSRUpdateAppIcon(MRUNowPlayingViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    if (![view isKindOfClass:NSClassFromString(@"MRUNowPlayingView")]) return;
    MRUArtworkView *artworkView = ((MRUNowPlayingView *)view).artworkView;
    if (![artworkView respondsToSelector:@selector(setIconImage:)]) return;
    NSString *bundleID = [controller.controller.metadataController respondsToSelector:@selector(bundleID)]
        ? controller.controller.metadataController.bundleID : nil;
    static NSString *lastBundleID;
    static UIImage *lastIcon;
    if (bundleID.length && ![bundleID isEqualToString:lastBundleID]) {
        UIImage *icon = nil;
        Class provider = NSClassFromString(@"MRUAssetsProvider");
        @try {
            if ([provider respondsToSelector:@selector(sharedAssetsProvider)]) {
                id shared = [provider sharedAssetsProvider];
                if ([shared respondsToSelector:@selector(applicationIconForBundleIdentifier:)]) {
                    icon = [shared applicationIconForBundleIdentifier:bundleID];
                }
            }
        } @catch (NSException *e) {
            icon = nil;
        }
        if (![icon isKindOfClass:[UIImage class]]) icon = nil;
        lastBundleID = [bundleID copy];
        lastIcon = icon;
    }
    UIImage *icon = bundleID.length ? lastIcon : nil;
    if (artworkView.iconImage != icon) {
        artworkView.iconImage = icon;
        [artworkView setNeedsLayout];
    }
}

static BOOL (*LSRMediaPlayer_orig_showRouteLabel)(id, SEL);
static void (*LSRMediaPlayer_orig_updateNowPlayingInfo)(id, SEL);
static void (*LSRMediaPlayer_orig_didSelectArtworkView)(id, SEL, id);
static CGSize (*LSRMediaPlayer_orig_sizeThatFits)(id, SEL, CGSize);
static void (*LSRMediaPlayer_orig_nowPlayingView_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_artworkView_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_headerView_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_headerView_updateVisibility)(id, SEL);

static BOOL LSRMediaPlayer_showRouteLabel(id self, SEL _cmd) {
    if ([self context] == kMRUContextCoverSheet) return YES;
    return LSRMediaPlayer_orig_showRouteLabel(self, _cmd);
}

static void LSRMediaPlayer_updateNowPlayingInfo(id self, SEL _cmd) {
    LSRMediaPlayer_orig_updateNowPlayingInfo(self, _cmd);
    if ([self context] != kMRUContextCoverSheet) return;
    LSRUpdateAppIcon(self);
    MRUNowPlayingInfo *info = [self controller].metadataController.nowPlayingInfo;
    if (!info.artist.length || !info.album.length) return;
    UIView *view = [self viewIfLoaded];
    if (![view isKindOfClass:NSClassFromString(@"MRUNowPlayingView")]) return;
    MRUNowPlayingLabelView *labelView = ((MRUNowPlayingView *)view).headerView.labelView;
    if (![labelView.subtitle isEqualToString:info.artist]) return;
    labelView.subtitle = [NSString stringWithFormat:@"%@ \u2014 %@", info.artist, info.album];
}

static void LSRMediaPlayer_didSelectArtworkView(id self, SEL _cmd, id artworkView) {
    if ([self context] != kMRUContextCoverSheet || ![self respondsToSelector:@selector(launchNowPlayingApp)]) {
        LSRMediaPlayer_orig_didSelectArtworkView(self, _cmd, artworkView);
        return;
    }
    [self launchNowPlayingApp];
}

static CGSize LSRMediaPlayer_sizeThatFits(id self, SEL _cmd, CGSize size) {
    CGSize fitting = LSRMediaPlayer_orig_sizeThatFits(self, _cmd, size);
    if (!LSRIsLockScreenPlayer(self)) return fitting;
    return CGSizeMake(fitting.width, kIOS15PlayerHeight);
}

static void LSRMediaPlayer_nowPlayingView_layoutSubviews(id self, SEL _cmd) {
    if (LSRIsLockScreenPlayer(self)) LSREnforcePlayerVisibility(self);
    LSRMediaPlayer_orig_nowPlayingView_layoutSubviews(self, _cmd);
    if (!LSRIsLockScreenPlayer(self)) return;

    MRUNowPlayingView *player = self;
    CGFloat width = player.bounds.size.width;
    CGFloat inset = kIOS15PlayerInset;
    LSRSetFrame(player.artworkView, CGRectMake(inset, inset, kIOS15ArtworkSize, kIOS15ArtworkSize));
    CGFloat headerRight = width - kIOS15RoutingCenterFromRight + 22.0;
    LSRSetFrame(player.headerView, CGRectMake(kIOS15TextLeft, kIOS15HeaderTop,
        headerRight - kIOS15TextLeft, kIOS15HeaderHeight));
    LSRSetFrame(player.timeControlsView, CGRectMake(inset, kIOS15TimeBarCenterY - 22.0, width - 2.0 * inset, 44.0));
    LSRSetFrame(player.transportControlsView, CGRectMake(0, kIOS15TransportCenterY - 22.0, width, 44.0));
    LSRSetFrame(player.volumeControlsView, CGRectMake(0, kIOS15VolumeCenterY - 22.0, width, 44.0));
    player.volumeControlsView.alpha = 1.0;
}

static void LSRMediaPlayer_artworkView_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_artworkView_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    MRUArtworkView *artworkView = self;
    for (UIView *view in @[artworkView.artworkImageView ?: [NSNull null], artworkView.artworkShadowView ?: [NSNull null],
                           artworkView.placeholderBackground ?: [NSNull null]]) {
        if (![view isKindOfClass:[UIView class]]) continue;
        if (fabs(view.layer.cornerRadius - kIOS15ArtworkCornerRadius) > 0.01) view.layer.cornerRadius = kIOS15ArtworkCornerRadius;
    }

    UIImageView *iconView = objc_getAssociatedObject(artworkView, kLSRAppIconViewKey);
    UIImage *icon = [artworkView respondsToSelector:@selector(iconImage)] ? artworkView.iconImage : nil;
    if (!iconView && icon) {
        iconView = [UIImageView new];
        iconView.contentMode = UIViewContentModeScaleAspectFill;
        iconView.clipsToBounds = YES;
        iconView.layer.cornerRadius = round(kIOS15AppIconSize * 0.225 * 3.0) / 3.0;
        iconView.layer.cornerCurve = kCACornerCurveContinuous;
        iconView.accessibilityIgnoresInvertColors = YES;
        objc_setAssociatedObject(artworkView, kLSRAppIconViewKey, iconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [artworkView addSubview:iconView];
    }
    if (!iconView) return;
    if (iconView.image != icon) iconView.image = icon;
    UIImageView *artwork = artworkView.artworkImageView;
    BOOL showsArtwork = artwork && !artwork.hidden && artwork.image;
    iconView.hidden = !icon || !showsArtwork;
    CGRect frame = showsArtwork ? artwork.frame : artworkView.bounds;
    LSRSetFrame(iconView, CGRectMake(CGRectGetMaxX(frame) - kIOS15AppIconSize - kIOS15AppIconInset,
                                     CGRectGetMaxY(frame) - kIOS15AppIconSize - kIOS15AppIconInset,
                                     kIOS15AppIconSize, kIOS15AppIconSize));
    [artworkView bringSubviewToFront:iconView];
}

static void LSRMediaPlayer_headerView_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_headerView_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    MRUNowPlayingHeaderView *header = self;
    CGSize size = header.bounds.size;
    CGFloat artworkCenterY = kIOS15PlayerInset + kIOS15ArtworkSize / 2.0 - kIOS15HeaderTop;
    LSRSetFrame(header.routingButton, CGRectMake(size.width - 44.0, artworkCenterY - 22.0, 44.0, 44.0));
    LSRSetFrame(header.labelView, CGRectMake(0, 0, size.width - 52.0, size.height));
    if (header.routingButton.alpha < 1.0) header.routingButton.alpha = 1.0;
    if (!header.waveformView.hidden) header.waveformView.hidden = YES;
}

static void LSRMediaPlayer_headerView_updateVisibility(id self, SEL _cmd) {
    LSRMediaPlayer_orig_headerView_updateVisibility(self, _cmd);
    MRUNowPlayingHeaderView *header = self;
    if (LSRLockScreenPlayerFor(header) && header.routingButton.alpha < 1.0) header.routingButton.alpha = 1.0;
}

static void LSRInstallMediaPlayerFirstHalfHooks(void) {
    Class cls = objc_getClass("MRUNowPlayingViewController");
    if (cls) {
        MSHookMessageEx(cls, @selector(showRouteLabel), (IMP)LSRMediaPlayer_showRouteLabel, (IMP *)&LSRMediaPlayer_orig_showRouteLabel);
        MSHookMessageEx(cls, @selector(updateNowPlayingInfo), (IMP)LSRMediaPlayer_updateNowPlayingInfo, (IMP *)&LSRMediaPlayer_orig_updateNowPlayingInfo);
        MSHookMessageEx(cls, @selector(didSelectArtworkView:), (IMP)LSRMediaPlayer_didSelectArtworkView, (IMP *)&LSRMediaPlayer_orig_didSelectArtworkView);
    }
    cls = objc_getClass("MRUNowPlayingView");
    if (cls) {
        MSHookMessageEx(cls, @selector(sizeThatFits:), (IMP)LSRMediaPlayer_sizeThatFits, (IMP *)&LSRMediaPlayer_orig_sizeThatFits);
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_nowPlayingView_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_nowPlayingView_layoutSubviews);
    }
    cls = objc_getClass("MRUArtworkView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_artworkView_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_artworkView_layoutSubviews);
    cls = objc_getClass("MRUNowPlayingHeaderView");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_headerView_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_headerView_layoutSubviews);
        MSHookMessageEx(cls, @selector(updateVisibility), (IMP)LSRMediaPlayer_headerView_updateVisibility, (IMP *)&LSRMediaPlayer_orig_headerView_updateVisibility);
    }
}

// Remaining media-player hooks, installed only alongside the first-half hooks in MediaRemoteUI.
static void (*LSRMediaPlayer_orig_labelView_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_timeControls_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_transportControls_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_volumeControls_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_slider_layoutSubviews)(id, SEL);
static void (*LSRMediaPlayer_orig_slider_updateVisualStyling)(id, SEL);
static void (*LSRMediaPlayer_orig_slider_setValue)(id, SEL, float);
static void (*LSRMediaPlayer_orig_slider_setValueAnimated)(id, SEL, float, BOOL);

static void LSRMediaPlayer_labelView_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_labelView_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    MRUNowPlayingLabelView *view = self;
    CGFloat width = view.bounds.size.width;
    UIView *route = view.routeLabel;
    if (route) {
        UILabel *label = LSRFirstLabelIn(route);
        CGFloat height = route.bounds.size.height > 0 ? route.bounds.size.height : 13.33;
        LSRSetFrame(route, CGRectMake(0, LSRTopForBaseline(kIOS15RouteBaseline - kIOS15HeaderTop, label.font),
            MIN(width, MAX(route.bounds.size.width, [route sizeThatFits:CGSizeMake(width, height)].width)), height));
        if (route.alpha < 1.0) route.alpha = 1.0;
    }
    for (UIView *line in @[view.titleMarqueeView ?: [NSNull null], view.placeholderMarqueeView ?: [NSNull null]]) {
        if (![line isKindOfClass:[UIView class]]) continue;
        LSRSetFrame(line, CGRectMake(0, LSRTopForBaseline(kIOS15TitleBaseline - kIOS15HeaderTop, LSRFirstLabelIn(line).font),
            width, line.bounds.size.height));
    }
    UIView *subtitle = view.subtitleMarqueeView;
    if (subtitle) {
        LSRSetFrame(subtitle, CGRectMake(0, LSRTopForBaseline(kIOS15SubtitleBaseline - kIOS15HeaderTop, LSRFirstLabelIn(subtitle).font),
            width, subtitle.bounds.size.height));
    }
}

static void LSRMediaPlayer_timeControls_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_timeControls_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    MRUNowPlayingTimeControlsView *view = self;
    CGSize size = view.bounds.size;
    CGFloat barCenterY = size.height / 2.0;
    LSRSetFrame(view.slider, CGRectMake(0, barCenterY - kIOS15SliderThickness / 2.0, size.width, kIOS15SliderThickness));
    CGFloat baseline = barCenterY + (kIOS15TimeLabelBaseline - kIOS15TimeBarCenterY);
    for (UILabel *label in @[view.elapsedTimeLabel ?: [NSNull null], view.remainingTimeLabel ?: [NSNull null],
                             view.liveLabel ?: [NSNull null]]) {
        if (![label isKindOfClass:[UILabel class]]) continue;
        if (fabs(label.font.pointSize - kIOS15TimeLabelFontSize) > 0.01) {
            label.font = [label.font fontWithSize:kIOS15TimeLabelFontSize];
        }
        CGSize fit = [label sizeThatFits:CGSizeMake(size.width, CGFLOAT_MAX)];
        CGFloat x = 0;
        if (label == view.remainingTimeLabel) x = size.width - fit.width;
        else if (label == view.liveLabel) x = (size.width - fit.width) / 2.0;
        LSRSetFrame(label, CGRectMake(x, LSRTopForBaseline(baseline, label.font), fit.width, fit.height));
    }
}

static void LSRMediaPlayer_transportControls_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_transportControls_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    MRUNowPlayingTransportControlsView *view = self;
    CGSize size = view.bounds.size;
    CGFloat centerX = size.width / 2.0, centerY = size.height / 2.0;
    CGFloat spacing = (size.width - 2.0 * kIOS15PlayerInset + kIOS15TransportSlotWidth) / 4.0;
    LSRSetCenter(view.leftButton, CGPointMake(centerX - spacing, centerY));
    LSRSetCenter(view.centerButton, CGPointMake(centerX, centerY));
    LSRSetCenter(view.rightButton, CGPointMake(centerX + spacing, centerY));
    NSArray *buttons = @[view.leftButton ?: [NSNull null], view.centerButton ?: [NSNull null], view.rightButton ?: [NSNull null]];
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIView *button = buttons[i];
        if (![button isKindOfClass:[UIView class]]) continue;
        CGFloat scale = i == 1 ? kIOS15PlayGlyphScale : kIOS15SkipGlyphScale;
        CATransform3D wanted = CATransform3DMakeScale(scale, scale, 1.0);
        if (!CATransform3DEqualToTransform(button.layer.sublayerTransform, wanted)) button.layer.sublayerTransform = wanted;
    }
}

static void LSRMediaPlayer_volumeControls_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_volumeControls_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    MRUNowPlayingVolumeControlsView *view = self;
    CGSize size = view.bounds.size;
    CGFloat centerY = size.height / 2.0;
    LSRSetCenter(view.minImageView, CGPointMake(kIOS15VolumeMinIconCenter, centerY));
    LSRSetCenter(view.maxImageView, CGPointMake(size.width - kIOS15VolumeMaxIconCenterFromRight, centerY));
    LSRSetFrame(view.slider, CGRectMake(kIOS15VolumeBarLeft, centerY - kIOS15SliderThickness / 2.0,
        size.width - kIOS15VolumeBarLeft - kIOS15VolumeBarRightInset, kIOS15SliderThickness));
}

// iOS 15's played part of the bar is solid white (iOS 16: half transparent).
static void LSRBrightenSliderFill(MRUSlider *slider) {
    UIView *fill = slider.minTrack;
    if (fill && fill.alpha < 1.0) fill.alpha = 1.0;
}

static void LSRMediaPlayer_slider_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlayer_orig_slider_layoutSubviews(self, _cmd);
    if (!LSRLockScreenPlayerFor(self)) return;
    LSRUpdateSliderTouchTarget(self);
    LSRBrightenSliderFill(self);
    LSRUpdateKnob(self);
}

static void LSRMediaPlayer_slider_updateVisualStyling(id self, SEL _cmd) {
    LSRMediaPlayer_orig_slider_updateVisualStyling(self, _cmd);
    if (LSRLockScreenPlayerFor(self)) LSRBrightenSliderFill(self);
}

static void LSRMediaPlayer_slider_setValue(id self, SEL _cmd, float value) {
    LSRMediaPlayer_orig_slider_setValue(self, _cmd, value);
    if (LSRLockScreenPlayerFor(self)) LSRUpdateKnob(self);
}

static void LSRMediaPlayer_slider_setValueAnimated(id self, SEL _cmd, float value, BOOL animated) {
    LSRMediaPlayer_orig_slider_setValueAnimated(self, _cmd, value, animated);
    if (LSRLockScreenPlayerFor(self)) LSRUpdateKnob(self);
}

static void LSRInstallMediaPlayerRemainingHooks(void) {
    Class cls = objc_getClass("MRUNowPlayingLabelView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_labelView_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_labelView_layoutSubviews);
    cls = objc_getClass("MRUNowPlayingTimeControlsView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_timeControls_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_timeControls_layoutSubviews);
    cls = objc_getClass("MRUNowPlayingTransportControlsView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_transportControls_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_transportControls_layoutSubviews);
    cls = objc_getClass("MRUNowPlayingVolumeControlsView");
    if (cls) MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_volumeControls_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_volumeControls_layoutSubviews);
    cls = objc_getClass("MRUSlider");
    if (cls) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlayer_slider_layoutSubviews, (IMP *)&LSRMediaPlayer_orig_slider_layoutSubviews);
        MSHookMessageEx(cls, @selector(updateVisualStyling), (IMP)LSRMediaPlayer_slider_updateVisualStyling, (IMP *)&LSRMediaPlayer_orig_slider_updateVisualStyling);
        MSHookMessageEx(cls, @selector(setValue:), (IMP)LSRMediaPlayer_slider_setValue, (IMP *)&LSRMediaPlayer_orig_slider_setValue);
        MSHookMessageEx(cls, @selector(setValue:animated:), (IMP)LSRMediaPlayer_slider_setValueAnimated, (IMP *)&LSRMediaPlayer_orig_slider_setValueAnimated);
    }
}

// SpringBoard side: the platter around the player (and any other Live Activity) gets 18pt
// corners; iOS 16 uses 23.5 for the platter, its material
// and the hosted scene view inside it.
@interface NCNotificationListSupplementaryHostingView : UIView
@end

static void LSRRoundActivityPlatter(UIView *view, NSUInteger depth) {
    CGFloat radius = view.layer.cornerRadius;
    if (radius > kIOS15PlatterCornerRadius + 0.01 && radius < 30.0) {
        view.layer.cornerRadius = kIOS15PlatterCornerRadius;
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
    if (depth >= 10) return;
    for (UIView *sub in view.subviews) LSRRoundActivityPlatter(sub, depth + 1);
}

static void (*LSRMediaPlatter_orig_setContinuousCornerRadius)(id, SEL, CGFloat);
static void (*LSRMediaPlatter_orig_layoutSubviews)(id, SEL);

static void LSRMediaPlatter_setContinuousCornerRadius(id self, SEL _cmd, CGFloat radius) {
    LSRMediaPlatter_orig_setContinuousCornerRadius(self, _cmd, kIOS15PlatterCornerRadius);
}

static void LSRMediaPlatter_layoutSubviews(id self, SEL _cmd) {
    LSRMediaPlatter_orig_layoutSubviews(self, _cmd);
    LSRRoundActivityPlatter(self, 0);
}

static void LSRInstallMediaPlatterHooks(void) {
    Class cls = objc_getClass("NCNotificationListSupplementaryHostingView");
    if (!cls) return;
    MSHookMessageEx(cls, @selector(_setContinuousCornerRadius:), (IMP)LSRMediaPlatter_setContinuousCornerRadius, (IMP *)&LSRMediaPlatter_orig_setContinuousCornerRadius);
    MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)LSRMediaPlatter_layoutSubviews, (IMP *)&LSRMediaPlatter_orig_layoutSubviews);
}


#pragma mark - Unlock animation

// iOS 15's unlock transition. Both versions drive it from CSCoverSheetTransitionsSettings, one
// block of settings per case (same or different lock/home wallpaper, first or later swipe, over
// an app). These are iOS 15.6.1's defaults (CoverSheet's setDefaultValues and
// setDefaultValuesForParallaxAndBlur): the home screen wallpaper follows the swipe with
// parallax, and the sheet only blurs when the wallpapers differ. (iOS 16's getters hide some
// of these again where its own transition doesn't use them.)
static void LSRSetTransitionValue(id settings, NSString *key, id value) {
    if (!settings) return;
    // Straight to the setter: BOOL or double, depending on the key.
    SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
        [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]]);
    NSMethodSignature *signature = [settings methodSignatureForSelector:setter];
    if (!signature || signature.numberOfArguments != 3) return; // A key iOS 16 doesn't have.
    const char *type = [signature getArgumentTypeAtIndex:2];
    if (type[0] == 'd') {
        ((void (*)(id, SEL, double))objc_msgSend)(settings, setter, [value doubleValue]);
    } else if (type[0] == 'B' || type[0] == 'c') {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setter, [value boolValue]);
    }
}

static void LSRApplyIOS15TransitionBase(id t) {
    NSDictionary *base = @{
        @"blursPanel": @YES, @"blurRadius": @20.0, @"blurStart": @0.0, @"blurEnd": @0.4,
        @"blurEndReducedTransparency": @0.275,
        @"fadesContent": @YES, @"maxContentAlpha": @1.0, @"contentFadeStart": @0.2, @"contentFadeEnd": @0.7,
        @"darkensContent": @YES, @"darkeningColorWhite": @0.0, @"darkeningColorAlpha": @0.2,
        @"darkeningStart": @0.0, @"darkeningEnd": @0.5,
        @"panelWallpaper": @NO, @"trackingWallpaper": @YES, @"trackingWallpaperParallaxFactor": @0.5,
        @"revealWallpaper": @NO, @"fadePanelWallpaper": @NO, @"fadePanelWallpaperStart": @0.0,
        @"fadePanelWallpaperEnd": @1.0, @"iconsFlyIn": @YES,
        // iOS 16 only: iOS 15 never zoomed the wallpaper here.
        @"scaleWallpaper": @NO,
    };
    [base enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        LSRSetTransitionValue(t, key, value);
    }];
}

// Different wallpapers: the lock screen wallpaper travels with the sheet, fades and blurs.
static void LSRApplyIOS15DifferentWallpaper(id t) {
    NSDictionary *values = @{
        @"blursPanel": @YES, @"panelWallpaper": @YES, @"trackingWallpaper": @YES,
        @"trackingWallpaperParallaxFactor": @0.3, @"fadePanelWallpaper": @YES,
        @"fadePanelWallpaperStart": @0.2, @"fadePanelWallpaperEnd": @1.0,
        @"fadesContent": @YES, @"contentFadeStart": @0.2, @"contentFadeEnd": @0.7,
    };
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        LSRSetTransitionValue(t, key, value);
    }];
}

static void LSRApplyIOS15Transitions(id settings) {
    SEL sels[] = {
        @selector(sameWallpaperInitialTransitionSettings), @selector(differentWallpaperInitialTransitionSettings),
        @selector(sameWallpaperSubsequentTransitionSettings), @selector(differentWallpaperSubsequentTransitionSettings),
        @selector(overAppTransitionSettings),
    };
    id t[5] = {nil};
    for (int i = 0; i < 5; i++) {
        if ([settings respondsToSelector:sels[i]]) t[i] = ((id (*)(id, SEL))objc_msgSend)(settings, sels[i]);
        LSRApplyIOS15TransitionBase(t[i]);
    }
    LSRSetTransitionValue(settings, @"tension", @300.0);
    LSRSetTransitionValue(settings, @"friction", @34.0);

    // Same wallpaper, first swipe: no blur.
    LSRSetTransitionValue(t[0], @"blursPanel", @NO);
    // Different wallpapers, first swipe.
    LSRApplyIOS15DifferentWallpaper(t[1]);
    // Same wallpaper, later swipes.
    LSRSetTransitionValue(t[2], @"blursPanel", @NO);
    LSRSetTransitionValue(t[2], @"panelWallpaper", @YES);
    // Different wallpapers later, and over an app (one shared block on iOS 15): the home
    // wallpaper is revealed underneath, the icons don't fly in, the content doesn't fade.
    for (int i = 3; i < 5; i++) {
        LSRApplyIOS15DifferentWallpaper(t[i]);
        LSRSetTransitionValue(t[i], @"revealWallpaper", @YES);
        LSRSetTransitionValue(t[i], @"iconsFlyIn", @NO);
        LSRSetTransitionValue(t[i], @"fadesContent", @NO);
    }
}

static void (*LSRUnlock_orig_setDefaultValues)(id, SEL);
static void LSRUnlock_setDefaultValues(id self, SEL _cmd) {
    LSRUnlock_orig_setDefaultValues(self, _cmd);
    LSRApplyIOS15Transitions(self);
}

static void LSRInstallUnlockHooks(void) {
    Class cls = objc_getClass("CSCoverSheetTransitionsSettings");
    if (cls) MSHookMessageEx(cls, @selector(setDefaultValues), (IMP)LSRUnlock_setDefaultValues, (IMP *)&LSRUnlock_orig_setDefaultValues);
}

#pragma mark - Icon label shadows (iOS 15)

// iOS 16 draws the shadow under the home screen icon names with a new SpringBoard engine
// (SBUILegibilityDefaultEngine), which comes out much darker than iOS 15's. iOS 15 made it in
// +[SBIconLabelImage legibilityImageForIconLabelImage:parameters:pool:]: UIKit's
// -_drawImageForLegibilitySettings:strength:size:alphaOnly: with a white-shadow settings object,
// at scale 1, in an image of +[UIImage _legibilityImageSizeForSize:style:]. iOS 16 dropped that
// method but kept everything it calls, and the strength (0.3) is the same. When iOS 16 hands an
// icon label its shadow, it gets the one iOS 15's way makes instead.
@interface UIImage (LSRLegibility)
+ (CGSize)_legibilityImageSizeForSize:(CGSize)size style:(long long)style;
- (void)_drawImageForLegibilitySettings:(id)settings strength:(double)strength size:(CGSize)size alphaOnly:(BOOL)alphaOnly;
@end

@interface _UILegibilitySettings : NSObject
- (instancetype)initWithStyle:(long long)style primaryColor:(UIColor *)primary secondaryColor:(UIColor *)secondary shadowColor:(UIColor *)shadow;
@end

@interface SBIconLabelImageParameters : NSObject
@property (readonly, nonatomic) long long legibilityStyle;
@end

@interface SBIconLegibilityLabelView : UIView
@property (retain, nonatomic) SBIconLabelImageParameters *imageParameters;
@property (retain, nonatomic) UIImage *image;
@end

@interface SBUILegibilityShadowView : UIView
@end

static const void *const kLSRIOS15LabelShadowKey = &kLSRIOS15LabelShadowKey;

static UIImage *LSRIOS15LabelShadow(UIView *shadowView) {
    UIView *label = shadowView.superview;
    while (label && ![label isKindOfClass:NSClassFromString(@"SBIconLegibilityLabelView")]) label = label.superview;
    if (!label) return nil;
    UIImage *text = ((SBIconLegibilityLabelView *)label).image;
    SBIconLabelImageParameters *parameters = ((SBIconLegibilityLabelView *)label).imageParameters;
    if (!text || !parameters) return nil;
    long long style = parameters.legibilityStyle;
    // Made once per label image (iOS 15 kept it on the label image too).
    NSString *cacheKey = [NSString stringWithFormat:@"%lld", style];
    NSDictionary *cached = objc_getAssociatedObject(text, kLSRIOS15LabelShadowKey);
    if (cached[cacheKey]) return cached[cacheKey];
    Class labelImageClass = NSClassFromString(@"SBIconLabelImage");
    SEL strengthSel = NSSelectorFromString(@"legibilityStrengthForLegibilityStyle:");
    SEL drawSel = @selector(_drawImageForLegibilitySettings:strength:size:alphaOnly:);
    SEL contextSel = NSSelectorFromString(@"sbf_imageFromContextWithSize:scale:type:pool:drawing:");
    if (![labelImageClass respondsToSelector:strengthSel] || ![text respondsToSelector:drawSel]
        || ![UIImage respondsToSelector:@selector(_legibilityImageSizeForSize:style:)] || ![UIImage respondsToSelector:contextSel]) {
        return nil;
    }
    double strength = ((double (*)(id, SEL, long long))objc_msgSend)(labelImageClass, strengthSel, style);
    // iOS 15 had no shadow at all for this style (strength 0): leave iOS 16's.
    if (strength <= 0.0) return nil;
    CGSize size = [UIImage _legibilityImageSizeForSize:text.size style:style];
    if (size.width <= 0.0 || size.height <= 0.0) return nil;
    _UILegibilitySettings *settings = [[NSClassFromString(@"_UILegibilitySettings") alloc] initWithStyle:style
        primaryColor:nil secondaryColor:nil shadowColor:[UIColor whiteColor]];
    void (^drawing)(void) = ^{
        [text _drawImageForLegibilitySettings:settings strength:strength size:size alphaOnly:YES];
    };
    UIImage *shadow = ((UIImage *(*)(id, SEL, CGSize, double, long long, id, id))objc_msgSend)([UIImage class], contextSel,
        size, 1.0, 4, nil, drawing);
    if (!shadow) return nil;
    NSMutableDictionary *store = cached ? [cached mutableCopy] : [NSMutableDictionary new];
    store[cacheKey] = shadow;
    objc_setAssociatedObject(text, kLSRIOS15LabelShadowKey, store, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return shadow;
}

static void (*LSRIconLabels_orig_setImage)(id, SEL, UIImage *, UIImage *, double);
static void LSRIconLabels_setImage(id self, SEL _cmd, UIImage *image, UIImage *strengthenedImage, double strength) {
    UIImage *ios15 = image ? LSRIOS15LabelShadow(self) : nil;
    if (ios15) {
        LSRIconLabels_orig_setImage(self, _cmd, ios15, ios15, strength);
        return;
    }
    LSRIconLabels_orig_setImage(self, _cmd, image, strengthenedImage, strength);
}

static void LSRInstallIconLabelHooks(void) {
    Class cls = objc_getClass("SBUILegibilityShadowView");
    if (cls) MSHookMessageEx(cls, @selector(setImage:strengthenedImage:strength:), (IMP)LSRIconLabels_setImage, (IMP *)&LSRIconLabels_orig_setImage);
}

#pragma mark - Settings

// Missing file/key = never touched in Settings = on (the default).
static BOOL LSRPrefEnabled(NSDictionary *prefs, NSString *key) {
    id value = prefs[key];
    return value ? [value boolValue] : YES;
}

__attribute__((constructor)) static void LSRInitialize(void) {
    os_log_t lsrLogger = os_log_create("com.aronsz26.lockscreenrestore", "runtime");
    os_log(lsrLogger, "ApelinLoaded %{public}s", APELIN_BUILD_ID);
    NSDictionary *prefs = nil;
    for (size_t i = 0; i < sizeof(kLSRPrefsPaths) / sizeof(kLSRPrefsPaths[0]) && !prefs; i++) {
        prefs = [NSDictionary dictionaryWithContentsOfFile:LSRDevicePath(kLSRPrefsPaths[i])];
    }

    // Also loaded into MediaRemoteUI, which draws the lock screen music player on iOS 16.
    NSString *process = [NSProcessInfo processInfo].processName;
    if ([process isEqualToString:@"MediaRemoteUI"]) {
        LSRDebugLog(@"MediaRemoteUI prefs readable: %d", prefs != nil);
        if (LSRPrefEnabled(prefs, @"mediaPlayerEnabled")) {
            LSRInstallMediaPlayerFirstHalfHooks();
            LSRInstallMediaPlayerRemainingHooks();
        }
        return;
    }
    if (![process isEqualToString:@"SpringBoard"]) return;
    sLSRClockEnabled = LSRPrefEnabled(prefs, @"clockEnabled");
    id clockSize = prefs[@"clockSize"];
    if ([clockSize isKindOfClass:[NSNumber class]]) sLSRClockSizeFactor = MIN(MAX([clockSize doubleValue], 0.7), 1.5);
    if (sLSRClockEnabled) {
        LSRInstallClockHooks();
        // Text Size changed in Settings: the date gets its new size right away.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIContentSizeCategoryDidChangeNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            CSProminentSubtitleDateView *view = sLSRDateView;
            if (!view) return;
            LSRApplyIOS15Date(view);
            [view setNeedsLayout];
            [view.superview setNeedsLayout];
        }];
    }
    if (LSRPrefEnabled(prefs, @"focusEnabled")) LSRInstallFocusHooks();
    if (LSRPrefEnabled(prefs, @"notificationsEnabled")) LSRInstallNotificationHooks();
    if (LSRPrefEnabled(prefs, @"mediaPlayerEnabled")) LSRInstallMediaPlatterHooks();
    if (LSRPrefEnabled(prefs, @"unlockAnimationEnabled") && NSClassFromString(@"CSCoverSheetTransitionsSettings")) LSRInstallUnlockHooks();
    if (LSRPrefEnabled(prefs, @"iconLabelShadowEnabled") && NSClassFromString(@"SBUILegibilityShadowView")) LSRInstallIconLabelHooks();
    if (LSRPrefEnabled(prefs, @"liveWallpaperEnabled")) {
        sLSRWallpaperDesignDir = LSRResolveWallpaperDesignDir(prefs);
        sLSRHomeDesignDir = LSRResolveHomeDesignDir(prefs);
        sLSRDimInDark = [prefs[@"dimWallpaperInDark"] boolValue];
        sLSRPerspectiveZoom = prefs[@"perspectiveZoom"] ? [prefs[@"perspectiveZoom"] boolValue] : YES;
        // Also without any wallpaper yet: one picked in Settings > Wallpaper (a design or a
        // photo) then shows right away. Until then our views have no image and stay see-through.
        LSRInstallWallpaperHooks();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            LSRWallpaperPrefsChanged, CFSTR("com.aronsz26.lockscreenrestore/wallpaper"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }

#ifdef DEBUG
    // Debug builds: write the computed per-device layout for checking over SSH.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LSRLayout l = LSRCurrentLayout();
        NSString *summary = [NSString stringWithFormat:
            @"clockFontSize %.2f\ndateFontSize %.2f\ntimeBaselineY %.2f\ndateBaselineY %.2f\n"
            @"padlockScale %.2f\npadlockDrop %.2f\nscreen %@\n",
            l.clockFontSize, l.dateFontSize, l.timeBaselineY, l.dateBaselineY, l.padlockScale,
            l.padlockDrop, NSStringFromCGRect([UIScreen mainScreen].bounds)];
        [summary writeToFile:LSRDevicePath(@"/var/mobile/Documents/LockScreenRestoreLayout-now.log") atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
    });
#endif
}
