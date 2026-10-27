// HTAds: hides ad views locally (BaseADView and its subclasses — moments feed, chat list, etc).
// Does not touch the network, does not alter any server response, does not unlock any paid
// feature. Rewritten from the original FocusMode.m to use the shared igdHook/Ra Menu pattern
// (toggle switch instead of always-on, diagnostics line shared with the other modules).
#import "igd_common.h"
#define BUILD @"ads1"

static NSInteger gHidden;

static void hideIfAd(id result) {
    if (!raOn(@"ht.ads")) return;
    if (![result isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)result;
    v.hidden = YES;
    v.frame = CGRectZero;
    gHidden++;
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

__attribute__((constructor)) static void init(void) {
    raRegister(@"الإعلانات", @"ht.ads", @"إخفاء الإعلانات", @"يحجب أي عرض إعلان يرث من BaseADView محلياً فقط — ما يلمس الشبكة ولا يفعّل أي ميزة VIP");
    igdRun(@"HTAds", BUILD, ^{ hookBaseAD(); });
}
