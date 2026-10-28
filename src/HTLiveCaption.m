// HTLiveCaption: real-time captions — whatever the person near you (or in a call) says gets
// picked up through iOS's own system-keyboard dictation (tap the 🎤 on the keyboard) and shown,
// translated, as big scrolling captions right on screen. Fully standalone — no hook into
// HelloTalk's own call/chat classes at all, and (like HTTranslate's "استماع") deliberately does
// NOT use SFSpeechRecognizer directly: HelloTalk's Info.plist has no NSSpeechRecognitionUsageDescription
// key, and a dylib injected after the app is built cannot add one, so calling that API directly
// would crash instantly at the OS permission-check level. Going through the system keyboard's own
// dictation button sidesteps that entirely — it's a separate OS-level path needing no permission
// declaration from this app. "🎙️ ترجمة فورية" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"livecaption2"
#define HT_LC_FROM_KEY @"ht.livecaption.from"
#define HT_LC_TO_KEY @"ht.livecaption.to"

static NSArray<NSArray<NSString *> *> *htLCLangs(void) {
    static NSArray *langs;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        langs = @[
            @[@"en", @"الإنجليزية", @"🇬🇧"], @[@"ar", @"العربية", @"🇸🇦"], @[@"es", @"الإسبانية", @"🇪🇸"], @[@"fr", @"الفرنسية", @"🇫🇷"],
            @[@"de", @"الألمانية", @"🇩🇪"], @[@"tr", @"التركية", @"🇹🇷"], @[@"ja", @"اليابانية", @"🇯🇵"], @[@"ko", @"الكورية", @"🇰🇷"],
            @[@"zh-CN", @"الصينية", @"🇨🇳"], @[@"ru", @"الروسية", @"🇷🇺"], @[@"pt", @"البرتغالية", @"🇵🇹"], @[@"it", @"الإيطالية", @"🇮🇹"],
        ];
    });
    return langs;
}

typedef void (^HTLCReply)(NSString *translated, NSString *error);
static void htLCTranslate(NSString *text, NSString *from, NSString *to, HTLCReply reply) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) { reply(nil, nil); return; }
    NSString *esc = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *urlStr = [NSString stringWithFormat:@"https://api.mymemory.translated.net/get?q=%@&langpair=%@%%7C%@", esc, from, to];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { reply(nil, @"تعذر تكوين الطلب."); return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) { reply(nil, @"تعذر الاتصال بالإنترنت"); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *translated = json[@"responseData"][@"translatedText"];
            if ([translated.uppercaseString containsString:@"QUERY LENGTH LIMIT"] || [translated.uppercaseString containsString:@"MYMEMORY WARNING"]) {
                reply(nil, @"تجاوزت الحد اليومي للترجمة المجانية"); return;
            }
            if (!translated.length) { reply(nil, @"تعذرت الترجمة"); return; }
            reply(translated, nil);
        });
    }];
    [t resume];
}

@interface HTLiveCaptionVC : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UITextView *hiddenInput;
@property (nonatomic, strong) UILabel *instruction;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *history;
@property (nonatomic, strong) UILabel *liveCaption;
@property (nonatomic, strong) UIButton *fromBtn, *toBtn;
@property (nonatomic) NSInteger fromIdx, toIdx;
@property (nonatomic, copy) NSString *lastCommitted;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic) NSTimeInterval lastChangeTime;
@property (nonatomic, strong) NSTimer *debounce;
@end
@implementation HTLiveCaptionVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.97];
    self.lastCommitted = @"";

    NSArray *langs = htLCLangs();
    NSString *savedFrom = [NSUserDefaults.standardUserDefaults stringForKey:HT_LC_FROM_KEY] ?: @"en";
    NSString *savedTo = [NSUserDefaults.standardUserDefaults stringForKey:HT_LC_TO_KEY] ?: @"ar";
    for (NSInteger i = 0; i < langs.count; i++) { if ([langs[i][0] isEqualToString:savedFrom]) self.fromIdx = i; if ([langs[i][0] isEqualToString:savedTo]) self.toIdx = i; }

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setImage:htSymbolSized(@"xmark.circle.fill", @"xmark.circle", 26, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
    closeBtn.tintColor = UIColor.whiteColor;
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeBtn];

    self.fromBtn = [self langButton];
    self.toBtn = [self langButton];
    [self.fromBtn addTarget:self action:@selector(pickFrom) forControlEvents:UIControlEventTouchUpInside];
    [self.toBtn addTarget:self action:@selector(pickTo) forControlEvents:UIControlEventTouchUpInside];
    UIButton *swapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [swapBtn setImage:htSymbolSized(@"arrow.left.arrow.right", @"arrow.2.circlepath", 16, UIImageSymbolWeightBold) forState:UIControlStateNormal];
    swapBtn.tintColor = UIColor.whiteColor;
    [swapBtn addTarget:self action:@selector(swapLangs) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *langRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.fromBtn, swapBtn, self.toBtn]];
    langRow.axis = UILayoutConstraintAxisHorizontal; langRow.spacing = 10; langRow.alignment = UIStackViewAlignmentCenter;
    langRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:langRow];

    self.instruction = [UILabel new];
    self.instruction.text = @"🎤 اضغط زر الديكتيشن بلوحة المفاتيح وابدأ — الكلام يترجم ويظهر هنا تلقائياً";
    self.instruction.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.instruction.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    self.instruction.numberOfLines = 0;
    self.instruction.textAlignment = NSTextAlignmentCenter;
    self.instruction.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.instruction];

    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scroll];
    self.history = [UIStackView new];
    self.history.axis = UILayoutConstraintAxisVertical; self.history.spacing = 14;
    self.history.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.history];

    self.liveCaption = [UILabel new];
    self.liveCaption.font = [UIFont boldSystemFontOfSize:26];
    self.liveCaption.textColor = UIColor.whiteColor;
    self.liveCaption.numberOfLines = 0;
    self.liveCaption.text = @"…";
    self.liveCaption.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.liveCaption];

    // Off-screen but still-real text view: the system keyboard needs a genuine first responder to
    // show its dictation mic, but we don't want a visible text box cluttering the caption screen.
    self.hiddenInput = [UITextView new];
    self.hiddenInput.delegate = self;
    self.hiddenInput.frame = CGRectMake(0, 0, 1, 1);
    self.hiddenInput.alpha = 0.01;
    [self.view addSubview:self.hiddenInput];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeBtn.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [closeBtn.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],

        [langRow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [langRow.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [self.instruction.topAnchor constraintEqualToAnchor:langRow.bottomAnchor constant:14],
        [self.instruction.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [self.instruction.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],

        [self.scroll.topAnchor constraintEqualToAnchor:self.instruction.bottomAnchor constant:16],
        [self.scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.liveCaption.topAnchor constant:-16],
        [self.history.topAnchor constraintEqualToAnchor:self.scroll.topAnchor],
        [self.history.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor],
        [self.history.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor],
        [self.history.bottomAnchor constraintEqualToAnchor:self.scroll.bottomAnchor],
        [self.history.widthAnchor constraintEqualToAnchor:self.scroll.widthAnchor],

        [self.liveCaption.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.liveCaption.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.liveCaption.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-110],
    ]];
    [self updateLangButtons];
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [self checkIdle]; }];
}
- (UIButton *)langButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    return b;
}
- (void)updateLangButtons {
    NSArray *langs = htLCLangs();
    [self.fromBtn setTitle:[NSString stringWithFormat:@"%@ %@", langs[self.fromIdx][2], langs[self.fromIdx][1]] forState:UIControlStateNormal];
    [self.toBtn setTitle:[NSString stringWithFormat:@"%@ %@", langs[self.toIdx][2], langs[self.toIdx][1]] forState:UIControlStateNormal];
    [NSUserDefaults.standardUserDefaults setObject:langs[self.fromIdx][0] forKey:HT_LC_FROM_KEY];
    [NSUserDefaults.standardUserDefaults setObject:langs[self.toIdx][0] forKey:HT_LC_TO_KEY];
}
- (void)pickFrom { [self presentLangPicker:YES]; }
- (void)pickTo { [self presentLangPicker:NO]; }
- (void)presentLangPicker:(BOOL)isFrom {
    NSArray *langs = htLCLangs();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:isFrom ? @"لغة المتكلم" : @"ترجم إلى" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < langs.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", langs[i][2], langs[i][1]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            if (isFrom) self.fromIdx = i; else self.toIdx = i;
            [self updateLangButtons];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = isFrom ? self.fromBtn : self.toBtn;
    [self presentViewController:a animated:YES completion:nil];
}
- (void)swapLangs {
    NSInteger tmp = self.fromIdx; self.fromIdx = self.toIdx; self.toIdx = tmp;
    [self updateLangButtons];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.hiddenInput becomeFirstResponder];
}
- (void)close {
    [self.idleTimer invalidate];
    [self.debounce invalidate];
    [self.hiddenInput resignFirstResponder];
    UIWindow *w = self.view.window;
    w.hidden = YES;
    w.rootViewController = nil;
}
- (void)textViewDidChange:(UITextView *)tv {
    self.lastChangeTime = CFAbsoluteTimeGetCurrent();
    [self.debounce invalidate];
    NSString *text = tv.text;
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.45 repeats:NO block:^(NSTimer *t) {
        [self translateLive:text];
    }];
}
- (void)translateLive:(NSString *)text {
    if (!text.length) return;
    NSArray *langs = htLCLangs();
    htLCTranslate(text, langs[self.fromIdx][0], langs[self.toIdx][0], ^(NSString *translated, NSString *error) {
        if (translated.length) self.liveCaption.text = translated;
    });
}
- (void)checkIdle {
    NSString *text = self.hiddenInput.text;
    if (!text.length) return;
    // ~2s of silence after the keyboard's own dictation delivered text = treat it as one finished
    // sentence: push it into the scrolling history and clear the buffer for the next one.
    if (CFAbsoluteTimeGetCurrent() - self.lastChangeTime < 2.0) return;
    if ([text isEqualToString:self.lastCommitted]) return;
    self.lastCommitted = text;
    NSArray *langs = htLCLangs();
    htLCTranslate(text, langs[self.fromIdx][0], langs[self.toIdx][0], ^(NSString *translated, NSString *error) {
        UILabel *orig = [UILabel new];
        orig.text = text; orig.font = [UIFont systemFontOfSize:13]; orig.textColor = [UIColor colorWithWhite:1 alpha:0.45]; orig.numberOfLines = 0;
        UILabel *tr = [UILabel new];
        tr.text = translated.length ? translated : text; tr.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold]; tr.textColor = UIColor.whiteColor; tr.numberOfLines = 0;
        UIStackView *pair = [[UIStackView alloc] initWithArrangedSubviews:@[orig, tr]];
        pair.axis = UILayoutConstraintAxisVertical; pair.spacing = 2;
        [self.history addArrangedSubview:pair];
        self.hiddenInput.text = @"";
        self.liveCaption.text = @"…";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.scroll setContentOffset:CGPointMake(0, MAX(0, self.scroll.contentSize.height - self.scroll.bounds.size.height)) animated:YES];
        });
    });
}
@end

static UIWindow *gLiveCaptionWindow;
static void htLiveCaptionOpen(void) {
    if (!raOn(@"ht.livecaption")) { igdToast(@"الترجمة الفورية مطفية من Ra Menu"); return; }
    if (gLiveCaptionWindow && !gLiveCaptionWindow.hidden) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; } }
    if (!scene) return;
    gLiveCaptionWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gLiveCaptionWindow.windowLevel = UIWindowLevelAlert + 150;
    HTLiveCaptionVC *vc = [HTLiveCaptionVC new];
    gLiveCaptionWindow.rootViewController = vc;
    [gLiveCaptionWindow makeKeyAndVisible];
}

// --- Fixed purple button, shown only while inside a HelloTalk Voice Room -----------------------
// Detected by walking the live view-controller tree (nav stacks, tab stacks, child/presented VCs)
// and checking class names for "VoiceRoom" — the real class names (VoiceRoomBusinessViewController,
// VoiceRoomAudioViewController, VoiceRoomBaseViewController, ...) pulled from the 6.3.51 binary
// itself. This is read-only inspection, not a hook into any of HelloTalk's own code or methods.
static BOOL htVCTreeHasVoiceRoom(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 8) return NO;
    if ([NSStringFromClass(vc.class) containsString:@"VoiceRoom"]) return YES;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers) {
            if (htVCTreeHasVoiceRoom(c, depth + 1)) return YES;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        if (htVCTreeHasVoiceRoom(((UITabBarController *)vc).selectedViewController, depth + 1)) return YES;
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (htVCTreeHasVoiceRoom(child, depth + 1)) return YES;
    }
    if (vc.presentedViewController) return htVCTreeHasVoiceRoom(vc.presentedViewController, depth + 1);
    return NO;
}
static BOOL htInVoiceRoom(void) {
    return htVCTreeHasVoiceRoom(igdKeyWindow().rootViewController, 0);
}

@interface HTLiveCaptionOpener : NSObject
+ (void)tap:(id)sender;
@end
@implementation HTLiveCaptionOpener
+ (void)tap:(id)sender { htLiveCaptionOpen(); }
@end

static void htInstallLiveCaptionButton(void) {
    __block UIButton *btn = nil;
    [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *t) {
        UIWindow *w = igdKeyWindow();
        if (!w) return;
        BOOL show = raOn(@"ht.livecaption") && htInVoiceRoom() && !(gLiveCaptionWindow && !gLiveCaptionWindow.hidden);
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.bounds = CGRectMake(0, 0, 46, 46);
            btn.layer.cornerRadius = 23;
            btn.clipsToBounds = YES;
            // HelloTalk's own voice-room theme is purple — matching it (instead of a clashing
            // color) makes this read as part of the room's UI while still standing out as new
            btn.backgroundColor = [UIColor colorWithRed:0.52 green:0.33 blue:0.92 alpha:0.96];
            [btn setImage:htSymbolSized(@"captions.bubble.fill", @"text.bubble.fill", 19, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
            btn.tintColor = UIColor.whiteColor;
            btn.layer.borderWidth = 1.2;
            btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
            btn.accessibilityIdentifier = @"ht.livecaption.btn";
            [btn addTarget:[HTLiveCaptionOpener class] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        }
        // fixed spot (not draggable): bottom-right, stacked just above the comment bar, in line
        // with the room's existing right-side column of mic/action icons
        CGSize S = w.bounds.size;
        btn.center = CGPointMake(S.width - 38, S.height - w.safeAreaInsets.bottom - 190);
        btn.hidden = !show;
        if (btn.superview != w) [w addSubview:btn];
        else if (show && w.subviews.lastObject != btn) [w bringSubviewToFront:btn];
    }];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الإضافات", @"ht.livecaption", @"ترجمة فورية (كابشن)", @"زر ثابت بنفسجي يظهر فقط وأنت داخل Voice Room، يفتح شاشة ترجمة فورية لكلام أي شخص بالروم — باستخدام ديكتيشن لوحة المفاتيح", YES);
    igdRun(@"HTLiveCaption", BUILD, ^{
        htInstallLiveCaptionButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.livecaption" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htLiveCaptionOpen();
        }];
    });
}
