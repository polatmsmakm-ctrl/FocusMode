// HTDict: an English dictionary lookup, fully independent of HelloTalk's own account/servers.
// Reachable two ways: the "📖 القاموس" button in Ra Menu's footer (ra.dict notification), and its
// own small draggable floating button (independent of the main Ra logo button) for one-tap access
// without opening the full menu first.
//
// v2 adds: phonetic spelling + pronunciation playback, synonyms per definition, and a recent-words
// list (saved locally, never touches HelloTalk's account/servers) so repeat lookups are one tap.
#import "igd_common.h"
#import <AVFoundation/AVFoundation.h>
#define BUILD @"dict2"

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

@interface HTDictVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *phoneticLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) NSArray<NSDictionary *> *meanings;
@property (nonatomic, strong) NSArray<NSString *> *recent;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, copy) NSString *pendingAudioURL;
@end

@implementation HTDictVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"القاموس";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.recent = htDictRecent();

    self.field = [UITextField new];
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.placeholder = @"اكتب كلمة إنجليزية...";
    self.field.textAlignment = NSTextAlignmentRight;
    self.field.returnKeyType = UIReturnKeySearch;
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
    [self.playButton setImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"] forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playAudio) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton.hidden = YES;
    [self.view addSubview:self.playButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.field.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.field.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.field.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.field.heightAnchor constraintEqualToConstant:40],

        [self.phoneticLabel.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:6],
        [self.phoneticLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.playButton.centerYAnchor constraintEqualToAnchor:self.phoneticLabel.centerYAnchor],
        [self.playButton.trailingAnchor constraintEqualToAnchor:self.phoneticLabel.leadingAnchor constant:-6],
        [self.playButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],

        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.phoneticLabel.bottomAnchor constant:12],
        [self.table.topAnchor constraintEqualToAnchor:self.phoneticLabel.bottomAnchor constant:8],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self.field becomeFirstResponder];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self search:tf.text]; return YES; }

- (void)playAudio {
    if (!self.pendingAudioURL.length) return;
    NSString *urlStr = self.pendingAudioURL;
    if ([urlStr hasPrefix:@"//"]) urlStr = [@"https:" stringByAppendingString:urlStr];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    self.player = [AVPlayer playerWithURL:url];
    [self.player play];
}

- (void)searchRecent:(UIButton *)sender {
    NSString *word = self.recent[sender.tag];
    self.field.text = word;
    [self search:word];
}

- (void)search:(NSString *)word {
    word = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!word.length) return;
    self.meanings = @[];
    self.phoneticLabel.hidden = YES;
    self.playButton.hidden = YES;
    self.pendingAudioURL = nil;
    [self.table reloadData];
    [self.spinner startAnimating];
    NSString *esc = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", esc]];
    if (!url) { [self.spinner stopAnimating]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (err || !data) { self.meanings = @[@{@"definition": @"تعذر الاتصال — تأكد من الإنترنت."}]; [self.table reloadData]; return; }
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || !json.count) { self.meanings = @[@{@"definition": @"ما لقيت الكلمة."}]; [self.table reloadData]; return; }

            // phonetic text + first playable audio, from whichever entry/phonetics array has them
            NSString *phonetic = nil, *audio = nil;
            for (NSDictionary *entry in json) {
                if (!phonetic.length && [entry[@"phonetic"] length]) phonetic = entry[@"phonetic"];
                for (NSDictionary *ph in entry[@"phonetics"]) {
                    if (!phonetic.length && [ph[@"text"] length]) phonetic = ph[@"text"];
                    if (!audio.length && [ph[@"audio"] length]) audio = ph[@"audio"];
                }
            }
            if (phonetic.length) {
                self.phoneticLabel.text = phonetic;
                self.phoneticLabel.hidden = NO;
            }
            if (audio.length) {
                self.pendingAudioURL = audio;
                self.playButton.hidden = NO;
            }

            NSMutableArray *flat = [NSMutableArray new];
            for (NSDictionary *entry in json) for (NSDictionary *m in entry[@"meanings"]) {
                NSString *pos = m[@"partOfSpeech"] ?: @"";
                NSArray *meaningSyn = m[@"synonyms"];
                for (NSDictionary *d in m[@"definitions"]) {
                    NSArray *syn = [d[@"synonyms"] count] ? d[@"synonyms"] : meaningSyn;
                    [flat addObject:@{@"pos": pos, @"definition": d[@"definition"] ?: @"", @"example": d[@"example"] ?: @"",
                                       @"synonyms": syn ?: @[]}];
                }
            }
            self.meanings = flat.count ? flat : @[@{@"definition": @"ما فيه تعريف متوفر."}];
            [self.table reloadData];
            htDictRemember(word);
            self.recent = htDictRecent();
        });
    }];
    [t resume];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return (self.meanings.count == 0 && self.field.text.length == 0) ? MIN(self.recent.count, 10) : 0;
    return self.meanings.count;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return ([self tableView:t numberOfRowsInSection:0] > 0) ? @"آخر الكلمات" : nil;
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.accessoryType = UITableViewCellAccessoryNone;
    c.textLabel.numberOfLines = 0;
    c.textLabel.font = [UIFont systemFontOfSize:15];
    if (ip.section == 0) {
        c.textLabel.text = self.recent[ip.row];
        c.textLabel.textAlignment = NSTextAlignmentRight;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSDictionary *m = self.meanings[ip.row];
    NSString *txt = m[@"definition"];
    if ([m[@"pos"] length]) txt = [NSString stringWithFormat:@"(%@) %@", m[@"pos"], txt];
    if ([m[@"example"] length]) txt = [txt stringByAppendingFormat:@"\n— %@", m[@"example"]];
    if ([m[@"synonyms"] count]) txt = [txt stringByAppendingFormat:@"\nمرادفات: %@", [m[@"synonyms"] componentsJoinedByString:@"، "]];
    c.textLabel.text = txt;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0) return;
    NSString *word = self.recent[ip.row];
    self.field.text = word;
    [self search:word];
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
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
            [btn setImage:[UIImage systemImageNamed:@"character.book.closed.fill" withConfiguration:cfg] forState:UIControlStateNormal];
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
    raRegisterD(@"الإضافات", @"ht.dict", @"القاموس", @"بحث إنجليزي مستقل تماماً عن حساب أو سيرفرات HelloTalk — فيه نطق وتشغيل صوت ومرادفات وآخر الكلمات", YES);
    raRegisterD(@"الواجهة", @"ht.dict.btn", @"زر القاموس العائم", @"زر منفصل عن شعار Ra، يفتح القاموس مباشرة بضغطة وحدة. تقدر تسحبه لأي مكان", YES);
    igdRun(@"HTDict", BUILD, ^{
        htInstallDictButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.dict" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htDictOpen();
        }];
    });
}
