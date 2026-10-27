//
//  FocusMode.m
//  وضع تركيز - يخفي فقط إطارات الإعلانات داخل شاشتك (لا يلمس الشبكة ولا يعدل أي
//  استجابة من السيرفر ولا يفعّل أي ميزة VIP). كل اللي يسويه: أي عرض إعلان
//  يرث من BaseADView (من HelloAd framework) ينحجب بمجرد ما ينشأ.
//
//  Rashid Al-Shammari — HelloTalk 6.3.51
//

#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// -------- التحقق من التفعيل --------
// تقدر تطفيه بدون إزالة الدايلب: عدّل هذا السطر لـ NO وأعد البناء،
// أو احفظ القيمة في NSUserDefaults إذا تبي زر تشغيل/إيقاف من داخل التطبيق لاحقاً.
static BOOL FocusModeEnabled(void) {
    return YES;
}

// -------- عداد الإعلانات المحجوبة (لإثبات إن الدايلب شغال باستمرار) --------
static NSInteger FocusModeHiddenCount = 0;

// -------- أداة التبديل (method swizzling) --------
static void ht_swizzle(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[FocusMode] تحذير: ما لقيت %@ أو %@ على %@",
              NSStringFromSelector(originalSelector),
              NSStringFromSelector(swizzledSelector),
              NSStringFromClass(cls));
        return;
    }
    BOOL added = class_addMethod(cls,
                                  originalSelector,
                                  method_getImplementation(swizzledMethod),
                                  method_getTypeEncoding(swizzledMethod));
    if (added) {
        class_replaceMethod(cls,
                             swizzledSelector,
                             method_getImplementation(originalMethod),
                             method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// -------- الفئة المستهدفة: BaseADView (من وحدة HelloAd) --------
// كل إعلانات الـ moments وقائمة المحادثات والشاشات الأخرى تظهر من خلال
// فئات ترث من هذا الكلاس (مثل InternalStyle1ADView، GDTChatListAdView...).
// حجبه هنا يغلق كل هذي الأماكن من نقطة واحدة.

@interface NSObject (FocusMode_BaseADView)
- (instancetype)focusMode_initWithFrame:(CGRect)frame;
- (instancetype)focusMode_initWithCoder:(NSCoder *)coder;
@end

@implementation NSObject (FocusMode_BaseADView)

- (instancetype)focusMode_initWithFrame:(CGRect)frame {
    id result = [self focusMode_initWithFrame:frame];
    if (FocusModeEnabled() && [result isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)result;
        v.hidden = YES;
        v.frame = CGRectZero;
        FocusModeHiddenCount++;
        NSLog(@"[FocusMode] حجبت إعلان #%ld (initWithFrame:) — %@",
              (long)FocusModeHiddenCount, NSStringFromClass([v class]));
    }
    return result;
}

- (instancetype)focusMode_initWithCoder:(NSCoder *)coder {
    id result = [self focusMode_initWithCoder:coder];
    if (FocusModeEnabled() && [result isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)result;
        v.hidden = YES;
        v.frame = CGRectZero;
        FocusModeHiddenCount++;
        NSLog(@"[FocusMode] حجبت إعلان #%ld (initWithCoder:) — %@",
              (long)FocusModeHiddenCount, NSStringFromClass([v class]));
    }
    return result;
}

@end

__attribute__((constructor))
static void FocusModeInit(void) {
    // الاسم الفعلي لهذا الكلاس بالـ Objective-C runtime (طلعته من تحليل الملف
    // التنفيذي مباشرة، وليس بالتخمين) — لا تغيّره بين أصدار وأصدار من التطبيق.
    Class baseADView = objc_getClass("_TtC7HelloAd10BaseADView");
    if (!baseADView) {
        NSLog(@"[FocusMode] ما لقيت BaseADView — تأكد من نسخة HelloTalk (مبني على 6.3.51)");
        return;
    }

    ht_swizzle(baseADView,
               @selector(initWithFrame:),
               @selector(focusMode_initWithFrame:));
    ht_swizzle(baseADView,
               @selector(initWithCoder:),
               @selector(focusMode_initWithCoder:));

    NSLog(@"[FocusMode] تم التفعيل — إعلانات BaseADView محجوبة محلياً.");

    // رسالة متكررة كل 10 ثواني تطبع إجمالي عدد الإعلانات المحجوبة لحد الآن.
    // هذا فقط لإثبات إن الدايلب لسا شغال طول فتح التطبيق، وما يسوي أي شي
    // غير الطباعة بسجل الجهاز (Console) — ما يضيف طلبات شبكة ولا يأثر
    // على البطارية بشكل يذكر.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *heartbeat = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                               repeats:YES
                                                                 block:^(NSTimer * _Nonnull timer) {
            NSLog(@"[FocusMode] 🟢 لسا شغال — إجمالي الإعلانات المحجوبة حتى الآن: %ld",
                  (long)FocusModeHiddenCount);
        }];
        // يضمن استمرار المؤقت حتى والتطبيق في وضعية التمرير (scroll)
        [[NSRunLoop mainRunLoop] addTimer:heartbeat forMode:NSRunLoopCommonModes];
    });
}
