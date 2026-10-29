// HTWidget2: "📊 اليوم بنظرة" — one screen that pulls together stats this project already tracks
// in separate places, instead of making you hop between HTFocus/HTDict/HTVoiceLog to see them:
// today's usage minutes, today's Voice Room minutes, how many words you've saved in the dictionary,
// and a daily-open streak (new — tracked right here). Pure read of each module's own NSUserDefaults
// storage, same convention this project already uses for small cross-module keys (e.g. HTVocabTools
// reading HTDict's HT_DICT_RECENT_KEY) — nothing is hooked, nothing leaves the device.
#import "igd_common.h"
#import "ht_bg.h"
#define BUILD @"widget1"

#define HT_FOCUS_DAY_KEY @"ht.focus.day"
#define HT_FOCUS_SECONDS_KEY @"ht.focus.seconds"
#define HT_DICT_RECENT_KEY @"ht.dict.recent"
#define HT_VLOG_DAYS_KEY @"ht.voicelog.days"
#define HT_STREAK_DAYS_KEY @"ht.widget.streak.days"

static NSInteger htWidgetTodayBucket(void) { return (NSInteger)floor(NSDate.date.timeIntervalSince1970 / 86400.0); }

// ---- streak: a set of day-buckets the app was opened on, pruned to the last 400 days -----------
static void htWidgetMarkTodayOpened(void) {
    NSInteger today = htWidgetTodayBucket();
    NSArray<NSNumber *> *saved = [NSUserDefaults.standardUserDefaults arrayForKey:HT_STREAK_DAYS_KEY];
    NSMutableOrderedSet<NSNumber *> *days = saved ? [NSMutableOrderedSet orderedSetWithArray:saved] : [NSMutableOrderedSet new];
    if (![days containsObject:@(today)]) [days addObject:@(today)];
    while (days.count > 400) [days removeObjectAtIndex:0];
    [NSUserDefaults.standardUserDefaults setObject:days.array forKey:HT_STREAK_DAYS_KEY];
}
static NSInteger htWidgetStreak(void) {
    NSArray<NSNumber *> *saved = [NSUserDefaults.standardUserDefaults arrayForKey:HT_STREAK_DAYS_KEY];
    NSSet<NSNumber *> *days = [NSSet setWithArray:saved ?: @[]];
    NSInteger today = htWidgetTodayBucket();
    NSInteger streak = 0;
    NSInteger cursor = today;
    // today not opened yet (e.g. this screen somehow opened before the mark ran) still counts from
    // yesterday backward so the number doesn't flicker to 0 mid-session
    if (![days containsObject:@(today)]) cursor = today - 1;
    while ([days containsObject:@(cursor)]) { streak++; cursor--; }
    return streak;
}

// ---- readers for the other modules' own storage -------------------------------------------------
static NSInteger htWidgetUsageMinutes(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d integerForKey:HT_FOCUS_DAY_KEY] != htWidgetTodayBucket()) return 0;
    return (NSInteger)([d doubleForKey:HT_FOCUS_SECONDS_KEY] / 60.0);
}
static NSInteger htWidgetVoiceMinutes(void) {
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:HT_VLOG_DAYS_KEY];
    NSInteger secs = [d[[@(htWidgetTodayBucket()) stringValue]] integerValue];
    return secs / 60;
}
static NSInteger htWidgetSavedWords(void) {
    NSArray *recent = [NSUserDefaults.standardUserDefaults arrayForKey:HT_DICT_RECENT_KEY];
    return recent.count;
}

// ---- one stat card ------------------------------------------------------------------------------
@interface HTStatCard : UIView
+ (instancetype)cardWithIcon:(NSString *)icon fallback:(NSString *)fb value:(NSString *)value label:(NSString *)label;
@end
@implementation HTStatCard
+ (instancetype)cardWithIcon:(NSString *)icon fallback:(NSString *)fb value:(NSString *)value label:(NSString *)label {
    HTStatCard *v = [HTStatCard new];
    v.backgroundColor = UIColor.secondarySystemBackgroundColor;
    v.layer.cornerRadius = 16;
    v.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iv = [[UIImageView alloc] initWithImage:htSymbolSized(icon, fb, 22, UIImageSymbolWeightSemibold)];
    iv.tintColor = raAccent();
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *val = [UILabel new];
    val.text = value;
    val.font = [UIFont boldSystemFontOfSize:30];
    val.textColor = UIColor.labelColor;
    val.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *lbl = [UILabel new];
    lbl.text = label;
    lbl.font = [UIFont systemFontOfSize:13];
    lbl.textColor = UIColor.secondaryLabelColor;
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:iv]; [v addSubview:val]; [v addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [iv.topAnchor constraintEqualToAnchor:v.topAnchor constant:16],
        [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
        [val.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:10],
        [val.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
        [val.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-12],
        [lbl.topAnchor constraintEqualToAnchor:val.bottomAnchor constant:2],
        [lbl.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-12],
        [lbl.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-14],
    ]];
    return v;
}
@end

@interface HTWidgetVC : UIViewController
@end
@implementation HTWidgetVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    htApplyBackground(self.view);
    self.title = @"اليوم بنظرة";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    NSInteger streak = htWidgetStreak();
    HTStatCard *c1 = [HTStatCard cardWithIcon:@"hourglass" fallback:@"clock.fill" value:[NSString stringWithFormat:@"%ld", (long)htWidgetUsageMinutes()] label:@"دقيقة استخدام اليوم"];
    HTStatCard *c2 = [HTStatCard cardWithIcon:@"waveform.circle.fill" fallback:@"waveform" value:[NSString stringWithFormat:@"%ld", (long)htWidgetVoiceMinutes()] label:@"دقيقة صوت اليوم"];
    HTStatCard *c3 = [HTStatCard cardWithIcon:@"book.fill" fallback:@"book" value:[NSString stringWithFormat:@"%ld", (long)htWidgetSavedWords()] label:@"كلمة محفوظة بالقاموس"];
    HTStatCard *c4 = [HTStatCard cardWithIcon:@"flame.fill" fallback:@"flame" value:[NSString stringWithFormat:@"%ld", (long)streak] label:streak == 1 ? @"يوم متتالي 🔥" : @"أيام متتالية 🔥"];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[c1, c2]];
    row1.axis = UILayoutConstraintAxisHorizontal; row1.spacing = 12; row1.distribution = UIStackViewDistributionFillEqually;
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[c3, c4]];
    row2.axis = UILayoutConstraintAxisHorizontal; row2.spacing = 12; row2.distribution = UIStackViewDistributionFillEqually;
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    col.axis = UILayoutConstraintAxisVertical; col.spacing = 12;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:col];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [col.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
        [col.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [col.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    ]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static void htWidgetOpen(void) {
    UIViewController *top = raTop();
    if (!top || [top isKindOfClass:[HTWidgetVC class]]) return;
    HTWidgetVC *vc = [HTWidgetVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الفوكس", @"ht.widget", @"اليوم بنظرة", @"شاشة وحدة تجمع إحصائياتك (استخدام، غرف صوت، كلمات محفوظة، أيام متتالية) محلياً", YES);
    igdRun(@"HTWidget2", BUILD, ^{
        htWidgetMarkTodayOpened();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htWidgetMarkTodayOpened();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.widget" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htWidgetOpen();
        }];
    });
}
