// HTDict: an English dictionary lookup, fully independent of HelloTalk's own account/servers.
// Reachable two ways: the "📖 القاموس" button in Ra Menu's footer (ra.dict notification), and its
// own small draggable floating button (independent of the main Ra logo button) for one-tap access.
//
// v3: a proper redesign on top of v2's phonetic/synonyms/recent-words additions — definitions are
// now grouped into sections by part of speech (noun/verb/adjective/...) with Arabic section
// headers, each shown in a real card-style cell (part-of-speech pill + definition + example in
// gray italics + synonyms as a chip-style line) instead of one flat list of plain rows. Recent
// words moved out of the table into their own horizontal chip strip. Every label's color is now
// set explicitly (never UIKit's black-by-default) after a dark-mode bug elsewhere in this project
// (HTTranslate) turned out to be exactly that mistake.
#import "igd_common.h"
#import <AVFoundation/AVFoundation.h>
#define BUILD @"dict3"

#define HT_DICT_RECENT_KEY @"ht.dict.recent"
#define HT_DICT_BTN_POS_KEY @"ht.dict.btn.pos"
#define HT_DICT_RECENT_MAX 20

static NSMutableArray<NSString *> *htDictRecent(void) {
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:HT_DICT_RECENT_KEY];
    return saved ? [saved mutableCopy] : [NSMutableArray new];
}
static void htDictRemember(NSString *word) {
    NSMutableArray *r = htDictRecent();
    [r removeObject:word];
    [r insertObject:word atIndex:0];
    while (r.count > HT_DICT_RECENT_MAX) [r removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:r forKey:HT_DICT_RECENT_KEY];
}
static NSString *htDictPosArabic(NSString *pos) {
    NSDictionary *map = @{@"noun": @"اسم", @"verb": @"فعل", @"adjective": @"صفة", @"adverb": @"ظرف",
                           @"pronoun": @"ضمير", @"preposition": @"حرف جر", @"conjunction": @"حرف عطف",
                           @"interjection": @"تعجب", @"exclamation": @"تعجب", @"determiner": @"أداة تعريف", @"article": @"أداة تعريف"};
    NSString *m = map[pos.lowercaseString];
    return m ?: (pos.length ? pos : @"—");
}

// ---- a card-style cell for one definition ---------------------------------------------------
@interface HTDictDefCell : UITableViewCell
@property (nonatomic, strong) UILabel *defLabel, *exampleLabel, *synLabel;
- (void)configureWithDefinition:(NSString *)def example:(NSString *)example synonyms:(NSArray<NSString *> *)syn;
@end
@implementation HTDictDefCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.defLabel = [UILabel new];
    self.defLabel.numberOfLines = 0;
    self.defLabel.font = [UIFont systemFontOfSize:15.5];
    self.defLabel.textColor = UIColor.labelColor;
    self.defLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.exampleLabel = [UILabel new];
    self.exampleLabel.numberOfLines = 0;
    self.exampleLabel.font = [UIFont italicSystemFontOfSize:13.5];
    self.exampleLabel.textColor = UIColor.secondaryLabelColor;
    self.exampleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.synLabel = [UILabel new];
    self.synLabel.numberOfLines = 0;
    self.synLabel.font = [UIFont systemFontOfSize:12.5];
    self.synLabel.textColor = UIColor.systemIndigoColor;
    self.synLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:self.defLabel];
    [self.contentView addSubview:self.exampleLabel];
    [self.contentView addSubview:self.synLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.defLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.defLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.defLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.exampleLabel.topAnchor constraintEqualToAnchor:self.defLabel.bottomAnchor constant:4],
        [self.exampleLabel.leadingAnchor constraintEqualToAnchor:self.defLabel.leadingAnchor],
        [self.exampleLabel.trailingAnchor constraintEqualToAnchor:self.defLabel.trailingAnchor],

        [self.synLabel.topAnchor constraintEqualToAnchor:self.exampleLabel.bottomAnchor constant:4],
        [self.synLabel.leadingAnchor constraintEqualToAnchor:self.defLabel.leadingAnchor],
        [self.synLabel.trailingAnchor constraintEqualToAnchor:self.defLabel.trailingAnchor],
        [self.synLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
    ]];
    return self;
}
- (void)configureWithDefinition:(NSString *)def example:(NSString *)example synonyms:(NSArray<NSString *> *)syn {
    self.defLabel.text = def;
    self.exampleLabel.text = example.length ? [@"— " stringByAppendingString:example] : nil;
    self.exampleLabel.hidden = !example.length;
    self.synLabel.text = syn.count ? [@"⇄ " stringByAppendingString:[syn componentsJoinedByString:@"، "]] : nil;
    self.synLabel.hidden = !syn.count;
}
@end

// ---- the dictionary screen itself ------------------------------------------------------------
@interface HTDictVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *phoneticLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIScrollView *recentScroll;
@property (nonatomic, strong) UIStackView *recentStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *groups;   // [{"pos": "noun", "rows": [{"definition","example","synonyms"}]}]
@property (nonatomic, copy) NSString *emptyMessage;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, copy) NSString *pendingAudioURL;
@property (nonatomic, assign) NSInteger requestGen;
@end

@implementation HTDictVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"القاموس";
    self.groups = @[];
    self.emptyMessage = @"ابحث عن أي كلمة إنجليزية";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    self.field = [UITextField new];
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.placeholder = @"اكتب كلمة إنجليزية...";
    self.field.textColor = UIColor.labelColor;
    self.field.textAlignment = NSTextAlignmentRight;
    self.field.returnKeyType = UIReturnKeySearch;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.delegate = self;
    self.field.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.field];

    self.phoneticLabel = [UILabel new];
    self.phoneticLabel.font = [UIFont italicSystemFontOfSize:14];
    self.phoneticLabel.textColor = UIColor.secondaryLabelColor;
    self.phoneticLabel.textAlignment = NSTextAlignmentRight;
    self.phoneticLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.phoneticLabel.hidden = YES;
    [self.view addSubview:self.phoneticLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playButton setImage:htSymbol(@"speaker.wave.2.fill", @"speaker.2.fill") forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playAudio) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton.hidden = YES;
    [self.view addSubview:self.playButton];

    self.recentStack = [UIStackView new];
    self.recentStack.axis = UILayoutConstraintAxisHorizontal;
    self.recentStack.spacing = 8;
    self.recentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.recentScroll = [UIScrollView new];
    self.recentScroll.showsHorizontalScrollIndicator = NO;
    self.recentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.recentScroll addSubview:self.recentStack];
    [self.view addSubview:self.recentScroll];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 70;
    [self.table registerClass:[HTDictDefCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.field.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.field.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.field.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.field.heightAnchor constraintEqualToConstant:40],

        [self.phoneticLabel.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:6],
        [self.phoneticLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.phoneticLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:52],
        [self.playButton.centerYAnchor constraintEqualToAnchor:self.phoneticLabel.centerYAnchor],
        [self.playButton.trailingAnchor constraintEqualToAnchor:self.phoneticLabel.leadingAnchor constant:-6],
        [self.playButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],

        [self.recentScroll.topAnchor constraintEqualToAnchor:self.phoneticLabel.bottomAnchor constant:8],
        [self.recentScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.recentScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.recentScroll.heightAnchor constraintEqualToConstant:34],
        [self.recentStack.topAnchor constraintEqualToAnchor:self.recentScroll.topAnchor],
        [self.recentStack.bottomAnchor constraintEqualToAnchor:self.recentScroll.bottomAnchor],
        [self.recentStack.leadingAnchor constraintEqualToAnchor:self.recentScroll.leadingAnchor],
        [self.recentStack.trailingAnchor constraintEqualToAnchor:self.recentScroll.trailingAnchor],
        [self.recentStack.heightAnchor constraintEqualToAnchor:self.recentScroll.heightAnchor],

        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.recentScroll.bottomAnchor constant:16],
        [self.table.topAnchor constraintEqualToAnchor:self.recentScroll.bottomAnchor constant:4],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self reloadRecentChips];
    [self.field becomeFirstResponder];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self search:tf.text]; return YES; }

- (void)reloadRecentChips {
    for (UIView *v in self.recentStack.arrangedSubviews.copy) {
        [self.recentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray<NSString *> *recent = htDictRecent();
    self.recentScroll.hidden = (self.groups.count > 0) || !recent.count;
    NSInteger i = 0;
    for (NSString *w in recent) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        [chip setTitle:w forState:UIControlStateNormal];
        [chip setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:13];
        chip.backgroundColor = UIColor.secondarySystemBackgroundColor;
        chip.layer.cornerRadius = 15;
        chip.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
        chip.tag = i++;
        [chip addTarget:self action:@selector(recentChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.recentStack addArrangedSubview:chip];
    }
}
- (void)recentChipTapped:(UIButton *)sender {
    NSString *w = htDictRecent()[sender.tag];
    self.field.text = w;
    [self search:w];
}

- (void)playAudio {
    if (!self.pendingAudioURL.length) return;
    NSString *urlStr = self.pendingAudioURL;
    if ([urlStr hasPrefix:@"//"]) urlStr = [@"https:" stringByAppendingString:urlStr];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    self.player = [AVPlayer playerWithURL:url];
    [self.player play];
}

- (void)setEmptyState:(NSString *)msg {
    self.emptyMessage = msg;
    if (msg) {
        UILabel *l = [UILabel new];
        l.text = msg;
        l.textColor = UIColor.secondaryLabelColor;
        l.font = [UIFont systemFontOfSize:15];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 0;
        l.frame = CGRectMake(0, 0, self.table.bounds.size.width - 40, 60);
        self.table.backgroundView = l;
    } else {
        self.table.backgroundView = nil;
    }
}

- (void)search:(NSString *)word {
    word = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!word.length) return;
    self.requestGen++;
    NSInteger myGen = self.requestGen;
    self.groups = @[];
    self.phoneticLabel.hidden = YES;
    self.playButton.hidden = YES;
    self.pendingAudioURL = nil;
    [self setEmptyState:nil];
    [self.table reloadData];
    [self.spinner startAnimating];
    NSString *esc = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", esc]];
    if (!url) { [self.spinner stopAnimating]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (myGen != self.requestGen) return;
            [self.spinner stopAnimating];
            if (err || !data) { [self setEmptyState:@"تعذر الاتصال — تأكد من الإنترنت."]; [self.table reloadData]; return; }
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || !json.count) {
                [self setEmptyState:[NSString stringWithFormat:@"ما لقيت \"%@\"", word]];
                self.recentScroll.hidden = YES;
                [self.table reloadData];
                return;
            }
            NSString *phonetic = nil, *audio = nil;
            for (NSDictionary *entry in json) {
                if (!phonetic.length && [entry[@"phonetic"] length]) phonetic = entry[@"phonetic"];
                for (NSDictionary *ph in entry[@"phonetics"]) {
                    if (!phonetic.length && [ph[@"text"] length]) phonetic = ph[@"text"];
                    if (!audio.length && [ph[@"audio"] length]) audio = ph[@"audio"];
                }
            }
            if (phonetic.length) { self.phoneticLabel.text = phonetic; self.phoneticLabel.hidden = NO; }
            if (audio.length) { self.pendingAudioURL = audio; self.playButton.hidden = NO; }

            NSMutableOrderedSet<NSString *> *posOrder = [NSMutableOrderedSet new];
            NSMutableDictionary<NSString *, NSMutableArray *> *byPos = [NSMutableDictionary new];
            for (NSDictionary *entry in json) for (NSDictionary *m in entry[@"meanings"]) {
                NSString *pos = m[@"partOfSpeech"] ?: @"";
                NSArray *meaningSyn = m[@"synonyms"];
                [posOrder addObject:pos];
                NSMutableArray *rows = byPos[pos] ?: [NSMutableArray new];
                for (NSDictionary *d in m[@"definitions"]) {
                    NSArray *syn = [d[@"synonyms"] count] ? d[@"synonyms"] : meaningSyn;
                    [rows addObject:@{@"definition": d[@"definition"] ?: @"", @"example": d[@"example"] ?: @"", @"synonyms": syn ?: @[]}];
                }
                byPos[pos] = rows;
            }
            NSMutableArray *groups = [NSMutableArray new];
            for (NSString *pos in posOrder) [groups addObject:@{@"pos": pos, @"rows": byPos[pos]}];
            self.groups = groups;
            [self setEmptyState:groups.count ? nil : @"ما فيه تعريف متوفر."];
            [self.table reloadData];
            htDictRemember(word);
            [self reloadRecentChips];
        });
    }];
    [t resume];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return self.groups.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return [self.groups[s][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return htDictPosArabic(self.groups[s][@"pos"]); }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    HTDictDefCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *m = self.groups[ip.section][@"rows"][ip.row];
    [c configureWithDefinition:m[@"definition"] example:m[@"example"] synonyms:m[@"synonyms"]];
    return c;
}
@end

// ---- opening the dictionary screen, shared by the Ra Menu button and the floating button --------
static void htDictOpen(void) {
    if (!raOn(@"ht.dict")) { igdToast(@"القاموس مطفي من Ra Menu"); return; }
    UIViewController *top = raTop();
    if (!top || [top isKindOfClass:[HTDictVC class]]) return;
    HTDictVC *vc = [HTDictVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

// ---- independent floating button (separate from the main Ra logo button) ------------------------
@interface HTDictOpener : NSObject
+ (void)tap:(id)sender;
+ (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation HTDictOpener
+ (void)tap:(id)sender { htDictOpen(); }
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
        [NSUserDefaults.standardUserDefaults setObject:@[@(x / W), @(y / H)] forKey:HT_DICT_BTN_POS_KEY];
    }
}
@end

static void htInstallDictButton(void) {
    __block UIButton *btn = nil;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        UIWindow *w = igdKeyWindow();
        if (!w) return;
        BOOL show = raOn(@"ht.dict") && raOn(@"ht.dict.btn") && ![raTop() isKindOfClass:[HTDictVC class]];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.bounds = CGRectMake(0, 0, 50, 50);
            btn.layer.cornerRadius = 25;
            btn.clipsToBounds = YES;
            btn.backgroundColor = [UIColor colorWithRed:0.25 green:0.2 blue:0.6 alpha:0.92];
            [btn setImage:htSymbolSized(@"character.book.closed.fill", @"book.closed.fill", 21, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
            btn.tintColor = UIColor.whiteColor;
            btn.layer.borderWidth = 1.2;
            btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
            btn.accessibilityIdentifier = @"ht.dict.btn";
            [btn addTarget:[HTDictOpener class] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[HTDictOpener class] action:@selector(pan:)]];
            NSArray *pos = [NSUserDefaults.standardUserDefaults arrayForKey:HT_DICT_BTN_POS_KEY];
            CGSize S = w.bounds.size;
            btn.center = pos.count == 2 ? CGPointMake([pos[0] doubleValue] * S.width, [pos[1] doubleValue] * S.height) : CGPointMake(S.width - 32, S.height * 0.42);
        }
        btn.hidden = !show;
        if (btn.superview != w) [w addSubview:btn];
        else if (w.subviews.lastObject != btn) [w bringSubviewToFront:btn];
    }];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الإضافات", @"ht.dict", @"القاموس", @"بحث إنجليزي مستقل تماماً عن حساب أو سيرفرات HelloTalk — معاني مبوبة حسب نوع الكلمة، نطق، مرادفات، وآخر الكلمات", YES);
    raRegisterD(@"الواجهة", @"ht.dict.btn", @"زر القاموس العائم", @"زر منفصل عن شعار Ra، يفتح القاموس مباشرة بضغطة وحدة. تقدر تسحبه لأي مكان", YES);
    igdRun(@"HTDict", BUILD, ^{
        htInstallDictButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.dict" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htDictOpen();
        }];
    });
}
