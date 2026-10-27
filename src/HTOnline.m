// HTOnline: notifies you the moment a partner's "online" badge appears on screen, written from
// scratch. HelloTalk's OnlineStatusView (LanguagePartner module) exposes no online/offline
// property to the Objective-C runtime — it's set through a pure-Swift internal method this
// runtime-hooking technique can't reach, so there's no reliable push-style hook for it.
// What IS reachable: once the view is on screen, it's a normal UIView with a normal UILabel
// inside it showing the status text. So this tags every OnlineStatusView as it's created, and a
// short repeating timer reads that label's text and fires a local notification the moment it
// reads as online.
//
// Honest limit: this only sees a status badge while its view is actually on screen (a chat header,
// a profile). It is not a background "tell me when so-and-so comes online" — iOS doesn't let a
// sideloaded app poll a server in the background like that, and building a fake version of it
// would just mislead you.
#import "igd_common.h"
#import <UserNotifications/UserNotifications.h>
#define BUILD @"onl1"

static NSHashTable<UIView *> *gTracked;
static const void *kLastKey = &kLastKey;

static NSString *firstLabelText(UIView *v, int depth) {
    if (depth > 4) return nil;
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UILabel class]] && [(UILabel *)s text].length) return [(UILabel *)s text];
        NSString *r = firstLabelText(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

static BOOL looksOnline(NSString *t) {
    if (!t) return NO;
    NSString *l = t.lowercaseString;
    return [l containsString:@"online"] || [t containsString:@"متصل"] || [t containsString:@"نشط"] || [l containsString:@"active now"];
}

static void notifyOnline(NSString *text) {
    igdToast([NSString stringWithFormat:@"🟢 صار متصل الآن: %@", text]);
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
        if (s.authorizationStatus != UNAuthorizationStatusAuthorized) return;
        UNMutableNotificationContent *c = [UNMutableNotificationContent new];
        c.title = @"HelloTalk";
        c.body = [NSString stringWithFormat:@"صار متصل الآن: %@", text];
        c.sound = UNNotificationSound.defaultSound;
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString content:c trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:req withCompletionHandler:nil];
    }];
}

static void poll(void) {
    if (!raOn(@"ht.online")) return;
    for (UIView *v in gTracked.allObjects) {
        NSString *txt = firstLabelText(v, 0);
        NSString *prev = objc_getAssociatedObject(v, kLastKey);
        if (txt && looksOnline(txt) && !(prev && looksOnline(prev))) notifyOnline(txt);
        objc_setAssociatedObject(v, kLastKey, txt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void hookOnlineStatusView(void) {
    const char *C = "_TtC15LanguagePartner16OnlineStatusView";
    gTracked = [NSHashTable weakObjectsHashTable];
    igdHook(C, "initWithFrame:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^id(id self, CGRect f) { id r = ((id (*)(id, SEL, CGRect))orig)(self, s, f); [gTracked addObject:r]; return r; };
    });
    igdHook(C, "initWithCoder:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^id(id self, id coder) { id r = ((id (*)(id, SEL, id))orig)(self, s, coder); [gTracked addObject:r]; return r; };
    });
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الإضافات", @"ht.online", @"تنبيه لما شريكك يصير أونلاين",
                @"يشتغل بس إذا شارة الحالة ظاهرة على شاشتك حالياً (شات/بروفايل) — ما يراقب بالخلفية وقت التطبيق مقفول", NO);
    igdRun(@"HTOnline", BUILD, ^{
        [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:nil];
        hookOnlineStatusView();
        NSTimer *timer = [NSTimer timerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) { poll(); }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
