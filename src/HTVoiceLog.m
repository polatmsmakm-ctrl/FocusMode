// HTVoiceLog: tracks how long you spend in HelloTalk Voice Rooms, per day, purely locally.
// Detection reuses the same read-only technique as HTLiveCaption — walking the live view-controller
// tree for a class name containing "VoiceRoom" (real names confirmed from the 6.3.51 binary's Swift
// symbols: VoiceRoomBusinessViewController / VoiceRoomAudioViewController / etc). This is pure
// inspection, no hooking into HelloTalk's own code, so it carries the same low-risk profile as the
// live-caption button rather than the private-chat-UI hooks that failed for HTSeen.
// A background timer polls every 5s; while in a Voice Room, those 5s are added to today's bucket in
// a small rolling history (last 14 days) kept in NSUserDefaults. "📞 سجل غرف الصوت" in Ra Menu's
// footer shows that history; HTWidget2 also reads the same storage for its "today" tile.
#import "igd_common.h"
#import "ht_bg.h"
#define BUILD @"voicelog1"

// shared storage key — also read directly by HTWidget2.m (each module compiles separately, so the
// key string is duplicated there rather than shared through a header, same convention as the rest
// of this project's small cross-module constants)
#define HT_VLOG_DAYS_KEY @"ht.voicelog.days"
#define HT_VLOG_POLL_SECONDS 5
#define HT_VLOG_KEEP_DAYS 14

static NSInteger htVLogTodayBucket(void) { return (NSInteger)floor(NSDate.date.timeIntervalSince1970 / 86400.0); }
static NSString *htVLogDayLabel(NSInteger bucket) {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:bucket * 86400.0 + 43200.0];   // noon, avoids DST edge cases
    static NSDateFormatter *f;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"ar"]; f.dateFormat = @"EEEE d MMM"; });
    return [f stringFromDate:d];
}

// ---- read-only Voice Room detection (duplicated from HTLiveCaption.m by design) -----------------
static BOOL htVLogVCTreeHasVoiceRoom(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 8) return NO;
    if ([NSStringFromClass(vc.class) containsString:@"VoiceRoom"]) return YES;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers) {
            if (htVLogVCTreeHasVoiceRoom(c, depth + 1)) return YES;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        if (htVLogVCTreeHasVoiceRoom(((UITabBarController *)vc).selectedViewController, depth + 1)) return YES;
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (htVLogVCTreeHasVoiceRoom(child, depth + 1)) return YES;
    }
    if (vc.presentedViewController) return htVLogVCTreeHasVoiceRoom(vc.presentedViewController, depth + 1);
    return NO;
}
static BOOL htVLogInVoiceRoom(void) { return htVLogVCTreeHasVoiceRoom(igdKeyWindow().rootViewController, 0); }

// ---- storage --------------------------------------------------------------------------------
static NSMutableDictionary<NSString *, NSNumber *> *htVLogLoad(void) {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:HT_VLOG_DAYS_KEY];
    return saved ? [saved mutableCopy] : [NSMutableDictionary new];
}
static void htVLogAddSeconds(NSInteger secs) {
    NSMutableDictionary *d = htVLogLoad();
    NSString *key = [@(htVLogTodayBucket()) stringValue];
    double total = [d[key] doubleValue] + secs;
    d[key] = @(total);
    // prune anything older than HT_VLOG_KEEP_DAYS so this never grows unbounded
    NSInteger cutoff = htVLogTodayBucket() - HT_VLOG_KEEP_DAYS;
    for (NSString *k in d.allKeys.copy) if (k.integerValue < cutoff) [d removeObjectForKey:k];
    [NSUserDefaults.standardUserDefaults setObject:d forKey:HT_VLOG_DAYS_KEY];
}
static NSInteger htVLogSecondsForBucket(NSInteger bucket) {
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:HT_VLOG_DAYS_KEY];
    return [d[[@(bucket) stringValue]] integerValue];
}

// ---- history screen ---------------------------------------------------------------------------
@interface HTVoiceLogCell : UITableViewCell
@end
@implementation HTVoiceLogCell
- (instancetype)initWithStyle:(UITableViewCellStyle)s reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.textLabel.font = [UIFont systemFontOfSize:15];
    self.detailTextLabel.font = [UIFont boldSystemFontOfSize:15];
    self.detailTextLabel.textColor = raAccent();
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    return self;
}
@end

@interface HTVoiceLogVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSNumber *> *buckets;   // last 7 days, newest first
@end
@implementation HTVoiceLogVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    htApplyBackground(self.view);
    self.title = @"سجل غرف الصوت";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    NSInteger today = htVLogTodayBucket();
    NSMutableArray *b = [NSMutableArray new];
    for (NSInteger i = 0; i < 7; i++) [b addObject:@(today - i)];
    self.buckets = b;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.table registerClass:[HTVoiceLogCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 1; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.buckets.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    NSInteger weekTotal = 0;
    for (NSNumber *b in self.buckets) weekTotal += htVLogSecondsForBucket(b.integerValue);
    return [NSString stringWithFormat:@"آخر 7 أيام — إجمالي %ld دقيقة", (long)(weekTotal / 60)];
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    HTVoiceLogCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSInteger bucket = self.buckets[ip.row].integerValue;
    NSInteger secs = htVLogSecondsForBucket(bucket);
    c.textLabel.text = (ip.row == 0) ? @"اليوم" : htVLogDayLabel(bucket);
    c.detailTextLabel.text = secs > 0 ? [NSString stringWithFormat:@"%ld د", (long)(secs / 60)] : @"—";
    return c;
}
@end

static void htVoiceLogOpen(void) {
    UIViewController *top = raTop();
    if (!top || [top isKindOfClass:[HTVoiceLogVC class]]) return;
    HTVoiceLogVC *vc = [HTVoiceLogVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الفوكس", @"ht.voicelog", @"تتبّع وقت غرف الصوت", @"يسجل محلياً كم دقيقة تقضي بغرف الصوت كل يوم — ما يطلع من جهازك، بس قراءة اسم الشاشة الحالية بدون أي تعديل", YES);
    igdRun(@"HTVoiceLog", BUILD, ^{
        [NSTimer scheduledTimerWithTimeInterval:HT_VLOG_POLL_SECONDS repeats:YES block:^(NSTimer *t) {
            if (!raOn(@"ht.voicelog")) return;
            if (htVLogInVoiceRoom()) htVLogAddSeconds(HT_VLOG_POLL_SECONDS);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.voicelog" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htVoiceLogOpen();
        }];
    });
}
