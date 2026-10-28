// HTFocus: genuine "focus" features — the part of the FocusMode name this project hadn't
// actually built yet. Three independent pieces, each toggleable on its own from Ra Menu:
//   - ht.focus.usage : tracks today's time spent inside HelloTalk and nudges with a toast every
//                      30 minutes of accumulated use — local only, nothing leaves the device, no
//                      account/server involved, resets at local midnight.
//   - ht.focus.night : once a night (00:00–05:00 local time), a small math question has to be
//                      answered before the app can be used — a soft speed bump against mindless
//                      late-night scrolling, shown at most once per day.
//   - break mode     : "⏸️ استراحة" button in Ra Menu's footer — locks the app behind a
//                      countdown timer you pick yourself, with a genuine two-tap confirm to end
//                      it early so it isn't trivial to bypass by accident.
// All three are a full-screen UIWindow overlay above everything else, not a swizzle into any of
// HelloTalk's own view controllers — so unlike HTSeen, none of this needs HelloTalk's private
// class names, which this project has no reliable way to find.
#import "igd_common.h"
#define BUILD @"focus1"

#define HT_FOCUS_DAY_KEY @"ht.focus.day"
#define HT_FOCUS_SECONDS_KEY @"ht.focus.seconds"
#define HT_FOCUS_LASTBUCKET_KEY @"ht.focus.lastbucket"
#define HT_FOCUS_NIGHT_SHOWN_KEY @"ht.focus.night.shownday"
#define HT_FOCUS_QUIET_START_KEY @"ht.focus.quiet.start"
#define HT_FOCUS_QUIET_END_KEY @"ht.focus.quiet.end"
#define HT_FOCUS_BUCKET_MIN 30

static NSInteger htTodayBucket(void) { return (NSInteger)floor(NSDate.date.timeIntervalSince1970 / 86400.0); }

// ---- shared full-screen overlay window (used by both night-challenge and break mode) -----------
static UIWindow *gFocusWindow;
static void htFocusPresent(UIViewController *vc) {
    if (gFocusWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [UIWindow new];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.rootViewController = vc;
    w.backgroundColor = UIColor.blackColor;
    [w makeKeyAndVisible];
    gFocusWindow = w;
}
static void htFocusDismiss(void) {
    gFocusWindow.hidden = YES;
    gFocusWindow = nil;
}

// ---- usage tracking -------------------------------------------------------------------------
static NSTimeInterval gActiveStart = 0;
static void htFocusFlush(void) {
    if (!gActiveStart) return;
    NSTimeInterval elapsed = NSDate.date.timeIntervalSince1970 - gActiveStart;
    gActiveStart = 0;
    if (elapsed <= 0) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger today = htTodayBucket();
    NSInteger storedDay = [d integerForKey:HT_FOCUS_DAY_KEY];
    double secs = (storedDay == today) ? [d doubleForKey:HT_FOCUS_SECONDS_KEY] : 0;
    secs += elapsed;
    [d setInteger:today forKey:HT_FOCUS_DAY_KEY];
    [d setDouble:secs forKey:HT_FOCUS_SECONDS_KEY];
    NSInteger bucket = (NSInteger)(secs / 60.0 / HT_FOCUS_BUCKET_MIN);
    NSInteger lastBucket = (storedDay == today) ? [d integerForKey:HT_FOCUS_LASTBUCKET_KEY] : 0;
    if (bucket > lastBucket && raOn(@"ht.focus.usage")) {
        [d setInteger:bucket forKey:HT_FOCUS_LASTBUCKET_KEY];
        NSInteger mins = (NSInteger)(secs / 60.0);
        igdToast([NSString stringWithFormat:@"⏳ استخدمت HelloTalk %ld دقيقة اليوم", (long)mins]);
    } else if (storedDay != today) {
        [d setInteger:0 forKey:HT_FOCUS_LASTBUCKET_KEY];
    }
}

// ---- night challenge -------------------------------------------------------------------------
@interface HTChallengeVC : UIViewController
@property (nonatomic, assign) NSInteger answer;
@end
@implementation HTChallengeVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1];
    NSInteger a = arc4random_uniform(40) + 10, b = arc4random_uniform(20) + 1;
    BOOL plus = arc4random_uniform(2) == 0;
    self.answer = plus ? a + b : a - b;

    UILabel *moon = [UILabel new];
    moon.text = @"🌙";
    moon.font = [UIFont systemFontOfSize:52];
    moon.textAlignment = NSTextAlignmentCenter;
    moon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [UILabel new];
    title.text = @"وقفة قبل ما تكمل السهر";
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *q = [UILabel new];
    q.text = [NSString stringWithFormat:@"%ld %@ %ld = ?", (long)a, plus ? @"+" : @"−", (long)b];
    q.font = [UIFont boldSystemFontOfSize:34];
    q.textColor = [UIColor colorWithRed:0.55 green:0.58 blue:1.0 alpha:1];
    q.textAlignment = NSTextAlignmentCenter;
    q.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:moon]; [self.view addSubview:title]; [self.view addSubview:q];

    NSMutableArray<NSNumber *> *choices = [NSMutableArray arrayWithObject:@(self.answer)];
    while (choices.count < 4) {
        NSInteger fake = self.answer + (NSInteger)(arc4random_uniform(10) + 1) * (arc4random_uniform(2) == 0 ? 1 : -1);
        if (![choices containsObject:@(fake)]) [choices addObject:@(fake)];
    }
    for (NSInteger i = (NSInteger)choices.count - 1; i > 0; i--) {   // Fisher-Yates shuffle
        NSInteger j = arc4random_uniform((uint32_t)(i + 1));
        [choices exchangeObjectAtIndex:i withObjectAtIndex:j];
    }
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSNumber *c in choices) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:c.stringValue forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        b.layer.cornerRadius = 12;
        b.tag = c.integerValue;
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [b.heightAnchor constraintEqualToConstant:50].active = YES;
        [stack addArrangedSubview:b];
    }
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [moon.topAnchor constraintEqualToAnchor:safe.topAnchor constant:60],
        [moon.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:moon.bottomAnchor constant:10],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [q.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:30],
        [q.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:q.bottomAnchor constant:40],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:40],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-40],
    ]];
}
- (void)tap:(UIButton *)b {
    if (b.tag == self.answer) {
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
        htFocusDismiss();
    } else {
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
        [UIView animateWithDuration:0.08 animations:^{ b.transform = CGAffineTransformMakeTranslation(10, 0); }
            completion:^(BOOL f) { [UIView animateWithDuration:0.08 animations:^{ b.transform = CGAffineTransformIdentity; }]; }];
    }
}
@end

static void htFocusMaybeShowNightChallenge(void) {
    if (!raOn(@"ht.focus.night")) return;
    NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:NSDate.date];
    if (hour >= 5) return;   // night window is 00:00–05:00 local time
    NSInteger today = htTodayBucket();
    if ([NSUserDefaults.standardUserDefaults integerForKey:HT_FOCUS_NIGHT_SHOWN_KEY] == today) return;
    [NSUserDefaults.standardUserDefaults setInteger:today forKey:HT_FOCUS_NIGHT_SHOWN_KEY];
    htFocusPresent([HTChallengeVC new]);
}

// ---- break mode -------------------------------------------------------------------------------
@interface HTBreakVC : UIViewController
@property (nonatomic, assign) NSInteger secondsLeft;
@property (nonatomic, strong) UILabel *clock;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL confirming;
@end
@implementation HTBreakVC
- (instancetype)initWithMinutes:(NSInteger)mins {
    self = [super init];
    self.secondsLeft = mins * 60;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1];
    UILabel *icon = [UILabel new];
    icon.text = @"⏸️";
    icon.font = [UIFont systemFontOfSize:52];
    icon.textAlignment = NSTextAlignmentCenter;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [UILabel new];
    title.text = @"وضع الاستراحة شغّال";
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    self.clock = [UILabel new];
    self.clock.font = [UIFont monospacedDigitSystemFontOfSize:48 weight:UIFontWeightBold];
    self.clock.textColor = [UIColor colorWithRed:0.55 green:0.58 blue:1.0 alpha:1];
    self.clock.textAlignment = NSTextAlignmentCenter;
    self.clock.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *end = [UIButton buttonWithType:UIButtonTypeSystem];
    [end setTitle:@"إنهاء الاستراحة مبكراً" forState:UIControlStateNormal];
    end.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [end setTitleColor:[UIColor colorWithWhite:1 alpha:0.5] forState:UIControlStateNormal];
    [end addTarget:self action:@selector(endTapped:) forControlEvents:UIControlEventTouchUpInside];
    end.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:icon]; [self.view addSubview:title]; [self.view addSubview:self.clock]; [self.view addSubview:end];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-80],
        [icon.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:10],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.clock.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24],
        [self.clock.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [end.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-30],
        [end.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
    [self tick];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [self tick]; }];
}
- (void)tick {
    if (self.secondsLeft <= 0) { [self.timer invalidate]; htFocusDismiss(); return; }
    self.clock.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)(self.secondsLeft / 60), (long)(self.secondsLeft % 60)];
    self.secondsLeft--;
}
- (void)endTapped:(UIButton *)b {
    if (!self.confirming) {
        self.confirming = YES;
        [b setTitle:@"متأكد؟ اضغط مرة ثانية لإنهائها" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
        __weak UIButton *weakB = b;
        __weak HTBreakVC *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.confirming) {
                weakSelf.confirming = NO;
                [weakB setTitle:@"إنهاء الاستراحة مبكراً" forState:UIControlStateNormal];
                [weakB setTitleColor:[UIColor colorWithWhite:1 alpha:0.5] forState:UIControlStateNormal];
            }
        });
        return;
    }
    [self.timer invalidate];
    htFocusDismiss();
}
@end

static void htFocusStartBreak(NSInteger minutes) {
    htFocusPresent([[HTBreakVC alloc] initWithMinutes:minutes]);
}
static void htFocusAskQuietHours(void) {
    UIViewController *top = raTop();
    if (!top) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ساعات هدوء تلقائية"
        message:@"يقفل HelloTalk تلقائياً كل يوم بين الساعتين اللي تحددهم (0-23، بصيغة 24 ساعة — مثلاً من 23 إلى 6 يعني طول الليل)"
        preferredStyle:UIAlertControllerStyleAlert];
    NSInteger savedStart = [NSUserDefaults.standardUserDefaults integerForKey:HT_FOCUS_QUIET_START_KEY];
    NSInteger savedEnd = [NSUserDefaults.standardUserDefaults integerForKey:HT_FOCUS_QUIET_END_KEY];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"من (0-23)"; tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = savedStart ? [NSString stringWithFormat:@"%ld", (long)savedStart] : @""; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"إلى (0-23)"; tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = savedEnd ? [NSString stringWithFormat:@"%ld", (long)savedEnd] : @""; }];
    __weak UIAlertController *weakA = a;
    [a addAction:[UIAlertAction actionWithTitle:@"حفظ وتفعيل" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSInteger start = [weakA.textFields[0].text integerValue];
        NSInteger end = [weakA.textFields[1].text integerValue];
        if (start < 0 || start > 23 || end < 0 || end > 23 || start == end) { igdToast(@"أدخل ساعتين صحيحتين ومختلفتين"); return; }
        [NSUserDefaults.standardUserDefaults setInteger:start forKey:HT_FOCUS_QUIET_START_KEY];
        [NSUserDefaults.standardUserDefaults setInteger:end forKey:HT_FOCUS_QUIET_END_KEY];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"ra.ht.focus.quiet"];
        igdToast(@"تم — فعّال من الآن");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}
static void htFocusAskBreak(void) {
    UIViewController *top = raTop();
    if (!top) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"وضع الاستراحة" message:@"يقفل HelloTalk مؤقتاً لين تنتهي المدة" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *m in @[@10, @20, @30, @60]) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ دقيقة", m] style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { htFocusStartBreak(m.integerValue); }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"🤫 ضبط ساعات هدوء تلقائية" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { htFocusAskQuietHours(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = top.view;
    [top presentViewController:a animated:YES completion:nil];
}
static void htFocusMaybeShowQuietHours(void) {
    if (!raOn(@"ht.focus.quiet")) return;
    NSInteger start = [NSUserDefaults.standardUserDefaults integerForKey:HT_FOCUS_QUIET_START_KEY];
    NSInteger end = [NSUserDefaults.standardUserDefaults integerForKey:HT_FOCUS_QUIET_END_KEY];
    if (start == end) return;   // never configured
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSInteger hour = [cal component:NSCalendarUnitHour fromDate:NSDate.date];
    NSInteger minute = [cal component:NSCalendarUnitMinute fromDate:NSDate.date];
    BOOL inWindow = (start < end) ? (hour >= start && hour < end) : (hour >= start || hour < end);   // handles overnight windows
    if (!inWindow) return;
    NSInteger minutesNow = hour * 60 + minute;
    NSInteger endMinutes = end * 60;
    NSInteger remain = (start < end) ? (endMinutes - minutesNow) : (((endMinutes + 24 * 60) - minutesNow) % (24 * 60));
    if (remain <= 0) remain = 1;
    htFocusPresent([[HTBreakVC alloc] initWithMinutes:remain]);
}

// ---- pomodoro (25 min work / 5 min locked break, repeating until the toggle is switched off) ----
static NSTimeInterval gPomoPhaseEnd = 0;
static BOOL gPomoBreak = NO;
static void htPomodoroTick(void) {
    if (!raOn(@"ht.focus.pomodoro")) { gPomoPhaseEnd = 0; return; }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (gPomoPhaseEnd == 0) {
        gPomoBreak = NO;
        gPomoPhaseEnd = now + 25 * 60;
        igdToast(@"🍅 بدأ بومودورو — 25 دقيقة شغل");
        return;
    }
    if (now < gPomoPhaseEnd) return;
    if (!gPomoBreak) {
        gPomoBreak = YES;
        gPomoPhaseEnd = now + 5 * 60;
        igdToast(@"⏸️ وقت الاستراحة — 5 دقايق");
        htFocusStartBreak(5);
    } else {
        gPomoBreak = NO;
        gPomoPhaseEnd = now + 25 * 60;
        igdToast(@"🍅 جولة شغل جديدة — 25 دقيقة");
    }
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الفوكس", @"ht.focus.usage", @"عداد وقت الاستخدام اليومي", @"تنبيه بسيط كل 30 دقيقة استخدام متراكم — محلي بالكامل، ما يطلع من جهازك", YES);
    raRegisterD(@"الفوكس", @"ht.focus.night", @"تحدي قبل الفتح بالليل", @"بين 12 والـ5 فجراً، لازم تحل مسألة بسيطة أول ما تفتح HelloTalk — مرة وحدة باليوم", NO);
    raRegisterD(@"الفوكس", @"ht.focus.quiet", @"ساعات هدوء تلقائية", @"يقفل HelloTalk تلقائياً خلال الفترة اللي تحددها (اضبطها من زر ⏸️ استراحة بالقائمة)", NO);
    raRegisterD(@"الفوكس", @"ht.focus.pomodoro", @"بومودورو (25/5)", @"يبدّل تلقائياً بين 25 دقيقة استخدام و5 دقائق استراحة مقفلة، يتكرر لين توقفه", NO);
    igdRun(@"HTFocus", BUILD, ^{
        gActiveStart = NSDate.date.timeIntervalSince1970;
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            gActiveStart = NSDate.date.timeIntervalSince1970;
            htFocusMaybeShowNightChallenge();
            htFocusMaybeShowQuietHours();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htFocusFlush();
        }];
        [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *t) {
            if (gActiveStart) { htFocusFlush(); gActiveStart = NSDate.date.timeIntervalSince1970; }
            htPomodoroTick();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.break" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htFocusAskBreak();
        }];
    });
}
