// HTLock: requires Face ID/Touch ID (or the iPhone passcode as fallback) every time HelloTalk
// comes back from the background — an extra lock layer independent of iOS's own lock screen, in
// case someone else picks up an already-unlocked phone. Pure public LocalAuthentication API, no
// hooking into any of HelloTalk's own classes.
#import "igd_common.h"
#import <LocalAuthentication/LocalAuthentication.h>
#define BUILD @"lock1"

static UIWindow *gLockWindow;
static BOOL gUnlocked = YES;
static BOOL gAuthInFlight = NO;

@interface HTLockVC : UIViewController
@end
@implementation HTLockVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = self.view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blur];

    UIImageView *icon = [[UIImageView alloc] initWithImage:htSymbolSized(@"lock.fill", @"lock", 44, UIImageSymbolWeightRegular)];
    icon.tintColor = UIColor.whiteColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"فتح القفل" forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [retry setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    retry.backgroundColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
    retry.layer.cornerRadius = 12;
    [retry addTarget:self action:@selector(unlock) forControlEvents:UIControlEventTouchUpInside];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:icon]; [self.view addSubview:retry];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [retry.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:24],
        [retry.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [retry.widthAnchor constraintEqualToConstant:180],
        [retry.heightAnchor constraintEqualToConstant:46],
    ]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self unlock];
}
- (void)unlock {
    if (gAuthInFlight) return;
    gAuthInFlight = YES;
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&err]) {
        gAuthInFlight = NO;
        return;   // no biometrics/passcode set up on this device at all — leave the lock screen up rather than silently bypass it
    }
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:@"افتح HelloTalk" reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gAuthInFlight = NO;
            if (success) { gUnlocked = YES; gLockWindow.hidden = YES; gLockWindow = nil; }
        });
    }];
}
@end

static void htLockPresent(void) {
    if (gLockWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [UIWindow new];
    w.windowLevel = UIWindowLevelAlert + 200;   // sits above HTFocus's overlays too
    w.rootViewController = [HTLockVC new];
    [w makeKeyAndVisible];
    gLockWindow = w;
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الخصوصية", @"ht.lock", @"قفل بالبصمة/الوجه", @"لازم تفتح ببصمتك أو رمز الآيفون كل ما ترجع للتطبيق من الخلفية", NO);
    igdRun(@"HTLock", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (raOn(@"ht.lock")) gUnlocked = NO;
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (raOn(@"ht.lock") && !gUnlocked) htLockPresent();
        }];
    });
}
