// HTSeen: read DMs without sending "seen" to your partner — ported from IGSeen (the same idea in
// the Instagram tweak), rebuilt from HelloTalk's own binary since the two apps are unrelated code.
//
// What's confirmed from static analysis of HelloTalk_Binary 6.3.51:
//   - There's a real, settable BOOL property `dontReadStatusSwitch` / `setDontReadStatusSwitch:`
//     sitting in the same ivar table as other known privacy toggles (dontShowHisMoments,
//     dontShowMyMoments). Its name and company strongly suggest it's exactly "don't send my read
//     status" — but which class owns it couldn't be pinned down from strings alone (Swift ivar
//     metadata is stored in one global alphabetical table, not grouped by class).
//   - The actual "mark read" network call (`markMessageRead`) looks like a Moya-style API-enum
//     case name, not an Objective-C selector — so it can't be swizzled directly the way IGSeen's
//     markLastMessageAsSeen could.
// So instead of guessing the owning class, this hooks the GETTER by selector name across every
// class in the runtime that implements it directly (there's normally only one). When the switch
// is on, that getter always reports "privacy is on" to whichever code asks it — which, if
// HelloTalk's own code checks this property before calling sendReadReceiptToServer (plausible
// given the string "[UnreadTrace] sendReadReceiptToServer..." sits right next to this logic), is
// the same mechanism VIP's own hide-read-status feature would use.
//
// HONEST LIMIT: this is the strongest lead from static analysis, not a confirmed working feature.
// Test it with two accounts: open a chat with the switch on, read a message, and check from the
// OTHER account whether it still shows as read. If it doesn't work, the real check happens
// somewhere this hook doesn't reach, and the toggle should stay off.
//
// The eye button: works the same as IGSeen's — tap it to send "seen" for the open chat on
// purpose. Since there's no known callable "send seen now" method, it works by temporarily
// lifting the override and re-running the chat screen's own on-appear logic (which is what
// normally triggers the real mark-as-read flow), then re-arming the override after a couple
// of seconds.
#import "igd_common.h"
#define BUILD @"seen1"

static BOOL gBypassSeen = NO;      // YES only while the eye button is letting a real "seen" through
static __weak UIViewController *gThread;
static UIButton *gEye;

// ---- force dontReadStatusSwitch's getter, wherever it actually lives ------------------------
static void hookDontReadStatusSwitch(void) {
    SEL getSel = sel_registerName("dontReadStatusSwitch");
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    NSUInteger hooked = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class c = classes[i];
        unsigned int mc = 0;
        Method *list = class_copyMethodList(c, &mc);   // only methods THIS class declares itself
        BOOL direct = NO;
        for (unsigned int j = 0; j < mc; j++) if (sel_isEqual(method_getName(list[j]), getSel)) { direct = YES; break; }
        free(list);
        if (!direct) continue;
        Method m = class_getInstanceMethod(c, getSel);
        char *rt = method_copyReturnType(m);
        char ret = rt ? rt[0] : 'v';
        free(rt);
        if (ret != 'B' && ret != 'c') continue;       // only take it if it's really a BOOL getter
        IMP orig = method_getImplementation(m);
        IMP blk = imp_implementationWithBlock(^BOOL(id self) {
            if (raOn(@"ht.seen") && !gBypassSeen) return YES;
            return ((BOOL (*)(id, SEL))orig)(self, getSel);
        });
        method_setImplementation(m, blk);
        hooked++;
        [igdStatus() addObject:[NSString stringWithFormat:@"✓ %s dontReadStatusSwitch (forced)", class_getName(c)]];
    }
    free(classes);
    if (!hooked) [igdStatus() addObject:@"✗ dontReadStatusSwitch (no class implements it — feature likely inert)"];
}

// ---- eye button: lift the override briefly and let the real appear-logic run ----------------
@interface HTSeenEye : NSObject
+ (void)tap;
@end
@implementation HTSeenEye
+ (void)tap {
    UIViewController *t = gThread;
    if (!t) return;
    gBypassSeen = YES;
    if ([t respondsToSelector:@selector(viewDidAppear:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(t, @selector(viewDidAppear:), NO);
    igdToast(@"تم رفع الإخفاء مؤقتاً — إذا الشات مفتوحة قدامك، لازم يرسل Seen الحين");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gBypassSeen = NO; });
}
@end

static void styleEye(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
    [gEye setImage:[UIImage systemImageNamed:@"eye.slash" withConfiguration:cfg] forState:UIControlStateNormal];
    gEye.tintColor = UIColor.whiteColor;
}

static void placeEye(void) {
    UIWindow *w = igdKeyWindow();
    if (!raOn(@"ht.seen") || !gThread || !w || !gThread.viewIfLoaded.window) { gEye.hidden = YES; return; }
    if (!gEye) {
        gEye = [UIButton buttonWithType:UIButtonTypeCustom];
        gEye.bounds = CGRectMake(0, 0, 40, 40);
        gEye.layer.cornerRadius = 20;
        gEye.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        gEye.accessibilityIdentifier = @"htseen.eye";
        styleEye();
        [gEye addAction:[UIAction actionWithHandler:^(UIAction *a) { [HTSeenEye tap]; }] forControlEvents:UIControlEventTouchUpInside];
    }
    if (gEye.superview != w) [w addSubview:gEye];
    [w bringSubviewToFront:gEye];
    gEye.center = CGPointMake(w.bounds.size.width * 0.5625, w.safeAreaInsets.top + 22);
    gEye.hidden = NO;
}

static void schedulePlace(void) {
    for (NSNumber *d in @[@0.05, @0.4, @1.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ placeEye(); });
    }
}

static void hookThreadVC(void) {
    const char *C = "_TtC6HTChat21SessionViewController";
    igdHook(C, "viewDidAppear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 1) return nil;
        return ^(id self, BOOL a) { ((void (*)(id, SEL, BOOL))orig)(self, s, a); gThread = self; schedulePlace(); };
    });
    igdHook(C, "viewDidDisappear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 1) return nil;
        return ^(id self, BOOL a) {
            ((void (*)(id, SEL, BOOL))orig)(self, s, a);
            if (gThread == self) { gThread = nil; gEye.hidden = YES; }
        };
    });
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الرسائل", @"ht.seen", @"إخفاء حالة القراءة (تجريبي)",
                @"يحاول يمنع إرسال Seen لشريكك تلقائياً — زر العين يرسلها يدوياً. تجريبي: جرّبه بحسابين وتأكد إنه يشتغل فعلياً قبل ما تعتمد عليه",
                NO);
    igdRun(@"HTSeen", BUILD, ^{ hookDontReadStatusSwitch(); hookThreadVC(); });
}
