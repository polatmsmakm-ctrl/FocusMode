// HTWorldClock: look up the current time in your language-exchange partner's city, using iOS's
// own built-in timezone database (NSTimeZone) — no network call, always accurate. "🕐 توقيت
// شريكك" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"worldclock1"

@interface HTWorldClockVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *resultCard;
@property (nonatomic, strong) UILabel *resultCity, *resultTime, *resultDiff;
@property (nonatomic, strong) NSArray<NSString *> *allZones;
@property (nonatomic, strong) NSArray<NSString *> *filtered;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, copy) NSString *selectedZone;
@end
@implementation HTWorldClockVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"توقيت شريكك";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.allZones = [NSTimeZone.knownTimeZoneNames sortedArrayUsingSelector:@selector(compare:)];
    self.filtered = self.allZones;

    self.search = [UISearchBar new];
    self.search.placeholder = @"ابحث عن مدينة أو دولة (بالإنجليزي)...";
    self.search.delegate = self;
    self.search.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.search];

    self.resultCard = [UIView new];
    self.resultCard.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.resultCard.layer.cornerRadius = 12;
    self.resultCard.hidden = YES;
    self.resultCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultCity = [UILabel new];
    self.resultCity.font = [UIFont boldSystemFontOfSize:17];
    self.resultCity.textColor = UIColor.labelColor;
    self.resultCity.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultTime = [UILabel new];
    self.resultTime.font = [UIFont monospacedDigitSystemFontOfSize:30 weight:UIFontWeightBold];
    self.resultTime.textColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
    self.resultTime.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultDiff = [UILabel new];
    self.resultDiff.font = [UIFont systemFontOfSize:13];
    self.resultDiff.textColor = UIColor.secondaryLabelColor;
    self.resultDiff.translatesAutoresizingMaskIntoConstraints = NO;
    [self.resultCard addSubview:self.resultCity]; [self.resultCard addSubview:self.resultTime]; [self.resultCard addSubview:self.resultDiff];
    [self.view addSubview:self.resultCard];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.search.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.search.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.resultCard.topAnchor constraintEqualToAnchor:self.search.bottomAnchor constant:8],
        [self.resultCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.resultCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.resultCity.topAnchor constraintEqualToAnchor:self.resultCard.topAnchor constant:12],
        [self.resultCity.leadingAnchor constraintEqualToAnchor:self.resultCard.leadingAnchor constant:14],
        [self.resultTime.topAnchor constraintEqualToAnchor:self.resultCity.bottomAnchor constant:4],
        [self.resultTime.leadingAnchor constraintEqualToAnchor:self.resultCard.leadingAnchor constant:14],
        [self.resultDiff.topAnchor constraintEqualToAnchor:self.resultTime.bottomAnchor constant:2],
        [self.resultDiff.leadingAnchor constraintEqualToAnchor:self.resultCard.leadingAnchor constant:14],
        [self.resultDiff.bottomAnchor constraintEqualToAnchor:self.resultCard.bottomAnchor constant:-12],

        [self.table.topAnchor constraintEqualToAnchor:self.resultCard.bottomAnchor constant:8],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [self refreshClock]; }];
}
- (void)close { [self.clockTimer invalidate]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.filtered = text.length ? [self.allZones filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", text]] : self.allZones;
    [self.table reloadData];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return MIN((NSInteger)self.filtered.count, 200); }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSString *z = self.filtered[ip.row];
    c.textLabel.text = [z stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    self.selectedZone = self.filtered[ip.row];
    self.resultCard.hidden = NO;
    [self refreshClock];
    [self.search resignFirstResponder];
}
- (void)refreshClock {
    if (!self.selectedZone) return;
    NSTimeZone *tz = [NSTimeZone timeZoneWithName:self.selectedZone];
    if (!tz) return;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    fmt.timeZone = tz;
    self.resultCity.text = [self.selectedZone stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    self.resultTime.text = [fmt stringFromDate:NSDate.date];
    NSInteger diffSeconds = tz.secondsFromGMT - NSTimeZone.localTimeZone.secondsFromGMT;
    double diffHours = diffSeconds / 3600.0;
    self.resultDiff.text = diffHours == 0 ? @"نفس توقيتك" : [NSString stringWithFormat:@"%@%.1f ساعة عن توقيتك", diffHours > 0 ? @"+" : @"", diffHours];
}
@end

__attribute__((constructor)) static void init(void) {
    igdRun(@"HTWorldClock", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.worldclock" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *top = raTop();
            if (!top) return;
            HTWorldClockVC *vc = [HTWorldClockVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
