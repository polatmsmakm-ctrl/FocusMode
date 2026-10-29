// HTAds: hides ad views locally (BaseADView and its subclasses — moments feed, chat list, etc).
// Does not touch the network, does not alter any server response, does not unlock any paid
// feature. Rewritten from the original FocusMode.m to use the shared igdHook/Ra Menu pattern
// (toggle switch instead of always-on, diagnostics line shared with the other modules).
#import "igd_common.h"
#define BUILD @"ads4"

static NSInteger gHidden;

static void hideIfAd(id result) {
    if (!raOn(@"ht.ads")) return;
    if (![result isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)result;
    v.hidden = YES;
    v.frame = CGRectZero;
    gHidden++;
}

// The ad shown right at app launch (before the tab bar appears) is a separate pipeline from the
// in-feed BaseADView ads above — it goes through -[HTAppDelegate handleLaunchCompletion:adView:],
// called once the splash ad (if any) has finished loading, passing the ad view it's about to show.
// Forcing that adView argument to nil makes HelloTalk behave exactly as if no ad was available,
// so it skips straight to the tab bar — same approach used for Instagram's launch ad.
static void hookLaunchAd(void) {
    igdHook("HTAppDelegate", "handleLaunchCompletion:adView:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 2) return nil;
        return ^void(id self, id completion, id adView) {
            BOOL skip = raOn(@"ht.ads.splash");
            if (skip && adView) gHidden++;
            ((void (*)(id, SEL, id, id))orig)(self, s, completion, skip ? nil : adView);
        };
    });
}

static void hookBaseAD(void) {
    // the real runtime name pulled from the 6.3.51 binary itself (HelloAd module, BaseADView class)
    const char *C = "_TtC7HelloAd10BaseADView";
    igdHook(C, "initWithFrame:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^id(id self, CGRect frame) {
            id r = ((id (*)(id, SEL, CGRect))orig)(self, s, frame);
            hideIfAd(r);
            return r;
        };
    });
    igdHook(C, "initWithCoder:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^id(id self, id coder) {
            id r = ((id (*)(id, SEL, id))orig)(self, s, coder);
            hideIfAd(r);
            return r;
        };
    });
}

// --- Auto-closes VIP/subscription upsell popups (e.g. the "ترجمة ذكاء اصطناعي غير محدودة" promo) --
// Detected the same read-only way as HTLiveCaption/HTVoiceLog's Voice Room check: polling the
// top-most presented view controller's class name for keywords that only show up on paywall/VIP
// screens, then calling its own dismissViewControllerAnimated:completion: — no hooking into
// HelloTalk's own presentation code, so it can't break a screen it doesn't recognize. Off by
// default: the keyword match is a heuristic (best-effort from common naming patterns, not confirmed
// against the 6.3.51 binary's real class names), so a screen you open on purpose that happens to
// match could get closed too — turn it on only if that's an acceptable trade-off for you.
static NSArray<NSString *> *htAdsVipKeywords(void) {
    static NSArray *k;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ k = @[@"VIP", @"Privilege", @"Promotion", @"Benefit", @"Upsell", @"Paywall"]; });
    return k;
}
static UIViewController *htAdsTopmost(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController) return htAdsTopmost(vc.presentedViewController);
    return vc;
}
static void htAdsPollVipPopup(void) {
    [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *t) {
        if (!raOn(@"ht.ads.vippopup")) return;
        UIWindow *w = igdKeyWindow();
        if (!w || !w.rootViewController) return;
        UIViewController *top = htAdsTopmost(w.rootViewController);
        if (!top || top == w.rootViewController) return;   // nothing presented
        NSString *cls = NSStringFromClass(top.class);
        for (NSString *kw in htAdsVipKeywords()) {
            if ([cls rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [top dismissViewControllerAnimated:NO completion:nil];
                gHidden++;
                break;
            }
        }
    }];
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الإعلانات", @"ht.ads", @"إخفاء الإعلانات", @"يحجب أي عرض إعلان يرث من BaseADView محلياً فقط — ما يلمس الشبكة ولا يفعّل أي ميزة VIP");
    raRegisterD(@"الإعلانات", @"ht.ads.splash", @"إخفاء إعلان بداية التطبيق", @"يمنع ظهور الإعلان اللي يفتح وقت تشغيل التطبيق قبل الدخول للقائمة الرئيسية — محلياً فقط", YES);
    raRegisterD(@"الإعلانات", @"ht.ads.vippopup", @"إغلاق نوافذ ترقية VIP", @"يقفل تلقائياً أي نافذة ترويجية لاشتراك VIP (زي عرض \"ترجمة ذكاء اصطناعي غير محدودة\") فور ظهورها — تخمين بالاسم (مو مؤكد 100%)، فيه احتمال ضعيف يقفل شاشة فتحتها إنت بنفسك لو تشابه الاسم", YES);
    igdRun(@"HTAds", BUILD, ^{ hookBaseAD(); hookLaunchAd(); htAdsPollVipPopup(); });
}
