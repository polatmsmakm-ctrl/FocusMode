// HTTheme: full look presets, broader than HTAccent's single-color system-tint picker. Picking a
// theme here sets a shared RGB (stored under "ht.theme.rgb", read by raThemeColor() in ra_menu.h)
// that every piece of this project's own chrome reads through raThemeColor(originalColor) instead
// of a hardcoded literal: Ra Menu's icons/switches/section headers (raAccent()), the Ra logo's
// border, and the HTDict/HTPhrases/HTLiveCaption floating buttons — so one pick changes the menu
// and all the floating buttons together, not just system-provided elements like HTAccent does.
// "🌈 الثيم" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"theme1"

#define HT_THEME_RGB_KEY @"ht.theme.rgb"
#define HT_THEME_IDX_KEY @"ht.theme.idx"

typedef struct { const char *name; CGFloat r, g, b; } HTThemePreset;
static NSArray<NSDictionary *> *htThemePresets(void) {
    static NSArray *p;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        p = @[
            @{@"name": @"الأصلي", @"rgb": @[]},                                                    // idx 0 = reset, no override
            @{@"name": @"نيون بنفسجي", @"rgb": @[@0.52, @0.33, @0.92]},
            @{@"name": @"أزرق ليلي", @"rgb": @[@0.20, @0.45, @0.95]},
            @{@"name": @"أخضر زمردي", @"rgb": @[@0.10, @0.70, @0.45]},
            @{@"name": @"أحمر ناري", @"rgb": @[@0.92, @0.28, @0.30]},
            @{@"name": @"ذهبي", @"rgb": @[@0.85, @0.65, @0.13]},
            @{@"name": @"وردي", @"rgb": @[@0.95, @0.35, @0.65]},
        ];
    });
    return p;
}
static void htThemeApply(NSInteger idx) {
    NSArray *p = htThemePresets();
    if (idx < 0 || idx >= (NSInteger)p.count) return;
    NSArray *rgb = p[idx][@"rgb"];
    [NSUserDefaults.standardUserDefaults setInteger:idx forKey:HT_THEME_IDX_KEY];
    if (rgb.count == 3) [NSUserDefaults.standardUserDefaults setObject:rgb forKey:HT_THEME_RGB_KEY];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:HT_THEME_RGB_KEY];
}

@interface HTThemeVC : UIViewController
@end
@implementation HTThemeVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"الثيم";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    UILabel *note = [UILabel new];
    note.text = @"يغيّر شكل Ra Menu والأزرار العائمة (القاموس، العبارات، ترجمة غرف الصوت) كلها دفعة وحدة. أعد فتح التطبيق بعد الاختيار ليشمل كل شي.";
    note.numberOfLines = 0;
    note.font = [UIFont systemFontOfSize:13];
    note.textColor = UIColor.secondaryLabelColor;
    note.textAlignment = NSTextAlignmentCenter;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:note];

    NSArray *presets = htThemePresets();
    NSInteger current = [NSUserDefaults.standardUserDefaults integerForKey:HT_THEME_IDX_KEY];
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 10;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSInteger i = 0; i < (NSInteger)presets.count; i++) {
        NSDictionary *preset = presets[i];
        NSArray *rgb = preset[@"rgb"];
        UIColor *swatchColor = rgb.count == 3 ? [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue] blue:[rgb[2] doubleValue] alpha:1] : [UIColor colorWithWhite:0.6 alpha:1];

        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.backgroundColor = UIColor.secondarySystemBackgroundColor;
        row.layer.cornerRadius = 14;
        row.tag = i;
        row.layer.borderWidth = (i == current) ? 2.5 : 0;
        row.layer.borderColor = swatchColor.CGColor;
        [row addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
        [row.heightAnchor constraintEqualToConstant:54].active = YES;

        UIView *dot = [UIView new];
        dot.backgroundColor = swatchColor;
        dot.layer.cornerRadius = 14;
        dot.userInteractionEnabled = NO;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:dot];
        UILabel *name = [UILabel new];
        name.text = preset[@"name"];
        name.font = [UIFont boldSystemFontOfSize:15];
        name.textColor = UIColor.labelColor;
        name.userInteractionEnabled = NO;
        name.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:name];
        [NSLayoutConstraint activateConstraints:@[
            [dot.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [dot.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
            [dot.widthAnchor constraintEqualToConstant:28],
            [dot.heightAnchor constraintEqualToConstant:28],
            [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        ]];
        [col addArrangedSubview:row];
    }
    [self.view addSubview:col];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [col.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
        [col.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [col.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [note.topAnchor constraintEqualToAnchor:col.bottomAnchor constant:20],
        [note.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [note.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    ]];
}
- (void)pick:(UIButton *)b {
    htThemeApply(b.tag);
    [[UIImpactFeedbackGenerator new] impactOccurred];
    igdToast(@"تم تغيير الثيم — أعد فتح التطبيق ليشمل كل شي");
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

__attribute__((constructor)) static void init(void) {
    igdRun(@"HTTheme", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.theme" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *top = raTop();
            if (!top) return;
            HTThemeVC *vc = [HTThemeVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
