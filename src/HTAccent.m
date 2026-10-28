// HTAccent: lets you pick an accent color applied via UIView.appearance proxies + the key
// window's tintColor. Best-effort and explicitly labeled as such in its own screen: most apps,
// HelloTalk included, hardcode their own colors in code rather than relying on tintColor, so this
// mainly reaches system-provided chrome (alerts, the share sheet, switches/sliders if HelloTalk
// happens to use stock ones) rather than every pixel of the app. "🎨 لون التطبيق" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"accent1"

#define HT_ACCENT_KEY @"ht.accent.idx"

static NSArray<UIColor *> *htAccentPalette(void) {
    static NSArray *p;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        p = @[
            UIColor.systemBlueColor,                                     // 0 = الأصلي (ما نطبّق شي)
            [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1],     // بنفسجي
            [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1],     // أخضر
            [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1],      // أحمر مرجاني
            [UIColor colorWithRed:1.0 green:0.65 blue:0.0 alpha:1],       // برتقالي
            [UIColor colorWithRed:1.0 green:0.42 blue:0.75 alpha:1],      // وردي
        ];
    });
    return p;
}
static void htAccentApply(void) {
    NSInteger idx = [NSUserDefaults.standardUserDefaults integerForKey:HT_ACCENT_KEY];
    NSArray *p = htAccentPalette();
    if (idx <= 0 || idx >= (NSInteger)p.count) return;
    UIColor *c = p[idx];
    [UIBarButtonItem appearance].tintColor = c;
    [UINavigationBar appearance].tintColor = c;
    [UITabBar appearance].tintColor = c;
    [UISwitch appearance].onTintColor = c;
    [UISlider appearance].tintColor = c;
    [UIActivityIndicatorView appearance].color = c;
    igdKeyWindow().tintColor = c;
}

@interface HTAccentVC : UIViewController
@end
@implementation HTAccentVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"لون التطبيق";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    UILabel *note = [UILabel new];
    note.text = @"⚠️ تأثيره محدود على بعض العناصر فقط (مثل التنبيهات ومشاركة الملفات) — مو كل واجهة HelloTalk، لأن أغلب ألوانه مكتوبة يدوياً بالكود";
    note.numberOfLines = 0;
    note.font = [UIFont systemFontOfSize:13];
    note.textColor = UIColor.secondaryLabelColor;
    note.textAlignment = NSTextAlignmentCenter;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:note];

    UIStackView *grid = [UIStackView new];
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 14;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *p = htAccentPalette();
    NSInteger current = [NSUserDefaults.standardUserDefaults integerForKey:HT_ACCENT_KEY];
    for (NSInteger i = 0; i < (NSInteger)p.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.backgroundColor = p[i];
        b.layer.cornerRadius = 26;
        b.tag = i;
        b.layer.borderWidth = (i == current) ? 3 : 0;
        b.layer.borderColor = UIColor.labelColor.CGColor;
        [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
        [b.widthAnchor constraintEqualToConstant:52].active = YES;
        [b.heightAnchor constraintEqualToConstant:52].active = YES;
        [grid addArrangedSubview:b];
    }
    [self.view addSubview:grid];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [grid.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [grid.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [grid.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [note.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:24],
        [note.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [note.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    ]];
}
- (void)pick:(UIButton *)b {
    [NSUserDefaults.standardUserDefaults setInteger:b.tag forKey:HT_ACCENT_KEY];
    htAccentApply();
    [[UIImpactFeedbackGenerator new] impactOccurred];
    igdToast(b.tag == 0 ? @"رجعنا للون الأصلي" : @"تم تغيير اللون — أعد فتح التطبيق ليشمل كل شي ممكن");
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

__attribute__((constructor)) static void init(void) {
    igdRun(@"HTAccent", BUILD, ^{
        htAccentApply();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.accent" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *top = raTop();
            if (!top) return;
            HTAccentVC *vc = [HTAccentVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
