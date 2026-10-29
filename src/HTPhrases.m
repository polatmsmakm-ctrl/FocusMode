// HTPhrases: a quick-phrases board — common English/Arabic phrases you copy with a tap and paste
// into the chat yourself. Fully standalone (no hook into HelloTalk's compose box at all), reached
// either from its own draggable floating button or "💬 عبارات جاهزة" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"phrases1"
#define HT_PHRASES_BTN_POS_KEY @"ht.phrases.btn.pos"

static NSArray<NSDictionary *> *htPhraseBank(void) {
    static NSArray *bank;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        bank = @[
            @{@"cat": @"تحية", @"items": @[
                @[@"Hi! How are you?", @"هلا! كيف حالك؟"],
                @[@"Good morning!", @"صباح الخير!"],
                @[@"Good evening!", @"مساء الخير!"],
                @[@"Nice to meet you", @"تشرفت فيك"],
            ]},
            @{@"cat": @"تعارف", @"items": @[
                @[@"My name is ...", @"اسمي ..."],
                @[@"I'm learning English", @"أتعلم الإنجليزية"],
                @[@"Where are you from?", @"من وين انت؟"],
                @[@"I'm from Kuwait", @"أنا من الكويت"],
            ]},
            @{@"cat": @"طلب توضيح", @"items": @[
                @[@"Can you repeat that, please?", @"تقدر تعيدها لو سمحت؟"],
                @[@"What does this word mean?", @"وش معنى هالكلمة؟"],
                @[@"Can you say it slower?", @"تقدر تقولها أبطأ؟"],
                @[@"I don't understand", @"ما فهمت"],
            ]},
            @{@"cat": @"اعتذار", @"items": @[
                @[@"Sorry for the late reply", @"آسف على الرد المتأخر"],
                @[@"My apologies, I misunderstood", @"اعتذر، فهمت غلط"],
            ]},
            @{@"cat": @"وداع", @"items": @[
                @[@"Talk to you later!", @"نتكلم بعدين!"],
                @[@"Have a great day!", @"يومك سعيد!"],
                @[@"Take care!", @"اعتن بنفسك!"],
            ]},
        ];
    });
    return bank;
}

@interface HTPhrasesVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end
@implementation HTPhrasesVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"عبارات جاهزة";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self; self.table.delegate = self;
    [self.view addSubview:self.table];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return htPhraseBank().count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return [htPhraseBank()[s][@"items"] count]; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return htPhraseBank()[s][@"cat"]; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *pair = htPhraseBank()[ip.section][@"items"][ip.row];
    c.textLabel.text = pair[0];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = pair[1];
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSArray *pair = htPhraseBank()[ip.section][@"items"][ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"انسخ أي نسخة؟" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"English" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { UIPasteboard.generalPasteboard.string = pair[0]; igdToast(@"تم نسخ النص الإنجليزي"); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"العربية" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { UIPasteboard.generalPasteboard.string = pair[1]; igdToast(@"تم نسخ النص العربي"); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [t cellForRowAtIndexPath:ip];
    a.popoverPresentationController.sourceView = cell;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:a animated:YES completion:nil];
}
@end

static void htPhrasesOpen(void) {
    if (!raOn(@"ht.phrases")) { igdToast(@"العبارات الجاهزة مطفية من Ra Menu"); return; }
    UIViewController *top = raTop();
    if (!top || [top isKindOfClass:[HTPhrasesVC class]]) return;
    HTPhrasesVC *vc = [HTPhrasesVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

@interface HTPhrasesOpener : NSObject
+ (void)tap:(id)sender;
+ (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation HTPhrasesOpener
+ (void)tap:(id)sender { htPhrasesOpen(); }
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *sup = v.superview;
    if (!sup) return;
    CGPoint t = [g translationInView:sup];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:sup];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat W = sup.bounds.size.width, H = sup.bounds.size.height;
        CGFloat x = v.center.x < W / 2 ? 34 : W - 34;
        CGFloat y = MIN(MAX(v.center.y, sup.safeAreaInsets.top + 40), H - sup.safeAreaInsets.bottom - 70);
        [UIView animateWithDuration:0.22 animations:^{ v.center = CGPointMake(x, y); }];
        [NSUserDefaults.standardUserDefaults setObject:@[@(x / W), @(y / H)] forKey:HT_PHRASES_BTN_POS_KEY];
    }
}
@end

static void htInstallPhrasesButton(void) {
    __block UIButton *btn = nil;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        UIWindow *w = igdKeyWindow();
        if (!w) return;
        BOOL show = raOn(@"ht.phrases") && raOn(@"ht.phrases.btn") && ![raTop() isKindOfClass:[HTPhrasesVC class]];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.bounds = CGRectMake(0, 0, 48, 48);
            btn.layer.cornerRadius = 24;
            btn.clipsToBounds = YES;
            btn.backgroundColor = raThemeColor([UIColor colorWithRed:0.15 green:0.55 blue:0.5 alpha:0.92]);
            [btn setImage:htSymbolSized(@"text.bubble.fill", @"bubble.left.fill", 19, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
            btn.tintColor = UIColor.whiteColor;
            btn.layer.borderWidth = 1.2;
            btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
            btn.accessibilityIdentifier = @"ht.phrases.btn";
            [btn addTarget:[HTPhrasesOpener class] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[HTPhrasesOpener class] action:@selector(pan:)]];
            NSArray *pos = [NSUserDefaults.standardUserDefaults arrayForKey:HT_PHRASES_BTN_POS_KEY];
            CGSize S = w.bounds.size;
            btn.center = pos.count == 2 ? CGPointMake([pos[0] doubleValue] * S.width, [pos[1] doubleValue] * S.height) : CGPointMake(S.width - 32, S.height * 0.58);
        }
        btn.hidden = !show;
        if (btn.superview != w) [w addSubview:btn];
        else if (w.subviews.lastObject != btn) [w bringSubviewToFront:btn];
    }];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الإضافات", @"ht.phrases", @"عبارات جاهزة", @"زر عائم فيه عبارات شائعة بالإنجليزي والعربي، تنسخها بضغطة وتلصقها بالشات", YES);
    raRegisterD(@"الواجهة", @"ht.phrases.btn", @"زر العبارات العائم", @"زر منفصل يفتح قائمة العبارات الجاهزة مباشرة", YES);
    igdRun(@"HTPhrases", BUILD, ^{
        htInstallPhrasesButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.phrases" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htPhrasesOpen();
        }];
    });
}
