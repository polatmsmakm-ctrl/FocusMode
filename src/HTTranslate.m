// HTTranslate: an independent translate + pronounce tool, fully separate from HelloTalk's own
// paid AI translation/correction system (AITranslateManager/FreeTranslateManager) — this never
// touches those, calls a free public translation API instead, and reads text aloud with iOS's
// own on-device speech synthesizer. Opened from the "🌐 ترجمة" button in Ra Menu's footer.
//
// v2 fix: the previous version's output text was INVISIBLE in dark mode — a plain `[UILabel new]`
// defaults to black text, sitting on this screen's near-black translucent output card, so every
// translation was actually succeeding and just couldn't be seen. Fixed by setting explicit
// semantic colors everywhere (never rely on UIKit's non-adaptive defaults again), plus a full
// redesign: live debounced translation as you type, swap now swaps the text too, copy button,
// remembered last-used language pair, friendlier handling of the free API's quota message, and
// haptic feedback.
#import "igd_common.h"
#import <AVFoundation/AVFoundation.h>
#define BUILD @"tr2"

#define HT_TR_FROM_KEY @"ht.translate.from"
#define HT_TR_TO_KEY @"ht.translate.to"

static NSArray<NSArray<NSString *> *> *gLangs;   // [[code, Arabic display name, flag emoji], ...]

@interface HTTranslateVC : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UILabel *placeholder;
@property (nonatomic, strong) UILabel *charCount;
@property (nonatomic, strong) UILabel *output;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *fromBtn, *toBtn, *speakBtn, *clipboardBtn, *goBtn;
@property (nonatomic, strong) UIView *outBox;
@property (nonatomic, assign) NSInteger fromIdx, toIdx;
@property (nonatomic, strong) AVSpeechSynthesizer *tts;
@property (nonatomic, strong) NSTimer *debounce;
@property (nonatomic, assign) NSInteger requestGen;   // bumped per request; stale replies are dropped
@property (nonatomic, assign) BOOL hasOutput;          // real translated text is showing (vs. placeholder/error)
@end

@implementation HTTranslateVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"ترجمة";
    NSInteger savedFrom = [NSUserDefaults.standardUserDefaults integerForKey:HT_TR_FROM_KEY];
    NSInteger savedTo = [NSUserDefaults.standardUserDefaults integerForKey:HT_TR_TO_KEY];
    self.fromIdx = (savedFrom >= 0 && savedFrom < gLangs.count) ? savedFrom : 0;
    self.toIdx = (savedTo > 0 && savedTo < gLangs.count) ? savedTo : 1;
    self.tts = [AVSpeechSynthesizer new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    self.input = [UITextView new];
    self.input.delegate = self;
    self.input.font = [UIFont systemFontOfSize:16];
    self.input.textColor = UIColor.labelColor;
    self.input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.input.layer.cornerRadius = 12;
    self.input.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.input.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.input];

    self.placeholder = [UILabel new];
    self.placeholder.text = @"اكتب أو الصق النص هنا...";
    self.placeholder.textColor = UIColor.placeholderTextColor;
    self.placeholder.font = [UIFont systemFontOfSize:16];
    self.placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.input addSubview:self.placeholder];

    self.charCount = [UILabel new];
    self.charCount.font = [UIFont systemFontOfSize:11];
    self.charCount.textColor = UIColor.tertiaryLabelColor;
    self.charCount.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.charCount];

    self.fromBtn = [self langButton];
    self.toBtn = [self langButton];
    [self.fromBtn addTarget:self action:@selector(pickFrom) forControlEvents:UIControlEventTouchUpInside];
    [self.toBtn addTarget:self action:@selector(pickTo) forControlEvents:UIControlEventTouchUpInside];

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    [swap setImage:htSymbol(@"arrow.left.arrow.right", @"arrow.2.squarepath") forState:UIControlStateNormal];
    [swap addTarget:self action:@selector(swap) forControlEvents:UIControlEventTouchUpInside];
    swap.translatesAutoresizingMaskIntoConstraints = NO;

    self.goBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.goBtn setTitle:@"ترجم" forState:UIControlStateNormal];
    self.goBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.goBtn.backgroundColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
    [self.goBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.goBtn.layer.cornerRadius = 10;
    [self.goBtn addTarget:self action:@selector(goTapped) forControlEvents:UIControlEventTouchUpInside];
    self.goBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.goBtn addSubview:self.spinner];

    self.output = [UILabel new];
    self.output.numberOfLines = 0;
    self.output.font = [UIFont systemFontOfSize:17];
    self.output.textColor = UIColor.labelColor;                 // the actual v1 bug: this was never set
    self.output.text = @"بتظهر الترجمة هنا";
    self.output.textColor = UIColor.tertiaryLabelColor;
    self.hasOutput = NO;
    self.output.translatesAutoresizingMaskIntoConstraints = NO;

    self.speakBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.speakBtn setImage:htSymbol(@"speaker.wave.2.fill", @"speaker.2.fill") forState:UIControlStateNormal];
    [self.speakBtn addTarget:self action:@selector(speak) forControlEvents:UIControlEventTouchUpInside];
    self.speakBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.clipboardBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clipboardBtn setImage:htSymbol(@"doc.on.doc", @"doc.on.doc.fill") forState:UIControlStateNormal];
    [self.clipboardBtn addTarget:self action:@selector(copyOutput) forControlEvents:UIControlEventTouchUpInside];
    self.clipboardBtn.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *langRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.fromBtn, swap, self.toBtn]];
    langRow.axis = UILayoutConstraintAxisHorizontal;
    langRow.distribution = UIStackViewDistributionFillEqually;
    langRow.spacing = 8;
    langRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:langRow];
    [self.view addSubview:self.goBtn];

    self.outBox = [UIView new];
    self.outBox.layer.cornerRadius = 12;
    self.outBox.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.outBox.translatesAutoresizingMaskIntoConstraints = NO;
    [self.outBox addSubview:self.output];
    [self.outBox addSubview:self.speakBtn];
    [self.outBox addSubview:self.clipboardBtn];
    [self.view addSubview:self.outBox];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [langRow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [langRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [langRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [langRow.heightAnchor constraintEqualToConstant:38],

        [self.input.topAnchor constraintEqualToAnchor:langRow.bottomAnchor constant:10],
        [self.input.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.input.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.input.heightAnchor constraintEqualToConstant:110],

        [self.placeholder.topAnchor constraintEqualToAnchor:self.input.topAnchor constant:10],
        [self.placeholder.leadingAnchor constraintEqualToAnchor:self.input.leadingAnchor constant:12],

        [self.charCount.topAnchor constraintEqualToAnchor:self.input.bottomAnchor constant:3],
        [self.charCount.trailingAnchor constraintEqualToAnchor:self.input.trailingAnchor constant:-4],

        [self.goBtn.topAnchor constraintEqualToAnchor:self.charCount.bottomAnchor constant:10],
        [self.goBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.goBtn.widthAnchor constraintEqualToConstant:140],
        [self.goBtn.heightAnchor constraintEqualToConstant:42],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.goBtn.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.goBtn.centerYAnchor],

        [self.outBox.topAnchor constraintEqualToAnchor:self.goBtn.bottomAnchor constant:16],
        [self.outBox.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.outBox.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.outBox.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-16],

        [self.output.topAnchor constraintEqualToAnchor:self.outBox.topAnchor constant:12],
        [self.output.leadingAnchor constraintEqualToAnchor:self.outBox.leadingAnchor constant:12],
        [self.output.trailingAnchor constraintEqualToAnchor:self.outBox.trailingAnchor constant:-12],
        [self.output.bottomAnchor constraintEqualToAnchor:self.speakBtn.topAnchor constant:-8],

        [self.speakBtn.bottomAnchor constraintEqualToAnchor:self.outBox.bottomAnchor constant:-6],
        [self.speakBtn.trailingAnchor constraintEqualToAnchor:self.outBox.trailingAnchor constant:-6],
        [self.speakBtn.widthAnchor constraintEqualToConstant:32],
        [self.speakBtn.heightAnchor constraintEqualToConstant:32],

        [self.clipboardBtn.centerYAnchor constraintEqualToAnchor:self.speakBtn.centerYAnchor],
        [self.clipboardBtn.trailingAnchor constraintEqualToAnchor:self.speakBtn.leadingAnchor constant:-4],
        [self.clipboardBtn.widthAnchor constraintEqualToConstant:32],
        [self.clipboardBtn.heightAnchor constraintEqualToConstant:32],
    ]];
    [self refreshLangButtons];
    [self updateCharCount];
}
- (UIButton *)langButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    return b;
}
- (void)refreshLangButtons {
    [self.fromBtn setTitle:[NSString stringWithFormat:@"%@ %@", gLangs[self.fromIdx][2], gLangs[self.fromIdx][1]] forState:UIControlStateNormal];
    [self.toBtn setTitle:[NSString stringWithFormat:@"%@ %@", gLangs[self.toIdx][2], gLangs[self.toIdx][1]] forState:UIControlStateNormal];
    [NSUserDefaults.standardUserDefaults setInteger:self.fromIdx forKey:HT_TR_FROM_KEY];
    [NSUserDefaults.standardUserDefaults setInteger:self.toIdx forKey:HT_TR_TO_KEY];
}
- (void)swap {
    NSInteger t = self.fromIdx; self.fromIdx = self.toIdx; self.toIdx = t;
    [self refreshLangButtons];
    [[UISelectionFeedbackGenerator new] selectionChanged];
    if (self.hasOutput) {
        NSString *out = self.output.text;
        self.input.text = out;
        self.output.text = @"بتظهر الترجمة هنا";
        self.output.textColor = UIColor.tertiaryLabelColor;
        self.hasOutput = NO;
        [self updateCharCount];
        [self scheduleTranslate];
    }
}
- (void)pickFrom { [self pickForTarget:YES]; }
- (void)pickTo { [self pickForTarget:NO]; }
- (void)pickForTarget:(BOOL)isFrom {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"اختر اللغة" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < gLangs.count; i++) {
        NSArray *l = gLangs[i];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", l[2], l[1]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (isFrom) self.fromIdx = i; else self.toIdx = i;
            [self refreshLangButtons];
            [self scheduleTranslate];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = isFrom ? self.fromBtn : self.toBtn;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)updateCharCount {
    NSInteger n = self.input.text.length;
    self.charCount.text = [NSString stringWithFormat:@"%ld/500", (long)n];
    self.charCount.textColor = n > 500 ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
    self.placeholder.hidden = n > 0;
}
- (void)textViewDidChange:(UITextView *)tv {
    [self updateCharCount];
    [self scheduleTranslate];
}
- (void)scheduleTranslate {
    [self.debounce invalidate];
    if (!self.input.text.length) return;
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.7 repeats:NO block:^(NSTimer *t) { [self goTapped]; }];
}

- (void)goTapped {
    [self.debounce invalidate];
    NSString *text = [self.input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    self.requestGen++;
    NSInteger myGen = self.requestGen;
    [self.spinner startAnimating];
    [self.goBtn setTitle:@"" forState:UIControlStateNormal];
    NSString *from = gLangs[self.fromIdx][0], *to = gLangs[self.toIdx][0];
    NSString *esc = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *urlStr = [NSString stringWithFormat:@"https://api.mymemory.translated.net/get?q=%@&langpair=%@|%@", esc, from, to];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { [self finishWithText:@"تعذر تكوين الطلب." isError:YES gen:myGen]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) { [self finishWithText:@"تعذر الاتصال — تأكد من الإنترنت." isError:YES gen:myGen]; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *translated = json[@"responseData"][@"translatedText"];
            NSInteger status = [json[@"responseStatus"] integerValue];
            if ([translated.uppercaseString containsString:@"QUERY LENGTH LIMIT"] || [translated.uppercaseString containsString:@"MYMEMORY WARNING"]) {
                [self finishWithText:@"تجاوزت الحد اليومي للترجمة المجانية — جرب بعد شوي." isError:YES gen:myGen]; return;
            }
            if (status != 0 && status != 200) { [self finishWithText:@"تعذرت الترجمة، حاول مرة ثانية." isError:YES gen:myGen]; return; }
            [self finishWithText:(translated.length ? translated : @"ما قدرت أترجم هالنص.") isError:!translated.length gen:myGen];
        });
    }];
    [t resume];
}
- (void)finishWithText:(NSString *)text isError:(BOOL)isError gen:(NSInteger)gen {
    if (gen != self.requestGen) return;   // a newer request already landed; drop this stale reply
    [self.spinner stopAnimating];
    [self.goBtn setTitle:@"ترجم" forState:UIControlStateNormal];
    self.output.text = text;
    self.output.textColor = isError ? UIColor.systemRedColor : UIColor.labelColor;
    self.hasOutput = !isError;
    if (!isError) [[UIImpactFeedbackGenerator new] impactOccurred];
}
- (void)copyOutput {
    if (!self.hasOutput) return;
    UIPasteboard.generalPasteboard.string = self.output.text;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    igdToast(@"تم النسخ");
}
- (void)speak {
    if (!self.hasOutput) return;
    NSString *voiceLang = gLangs[self.toIdx][0];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:self.output.text];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:voiceLang] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    [self.tts speakUtterance:u];
}
@end

__attribute__((constructor)) static void init(void) {
    gLangs = @[
        @[@"en", @"الإنجليزية", @"🇬🇧"], @[@"ar", @"العربية", @"🇸🇦"], @[@"es", @"الإسبانية", @"🇪🇸"], @[@"fr", @"الفرنسية", @"🇫🇷"],
        @[@"de", @"الألمانية", @"🇩🇪"], @[@"tr", @"التركية", @"🇹🇷"], @[@"ja", @"اليابانية", @"🇯🇵"], @[@"ko", @"الكورية", @"🇰🇷"],
        @[@"zh-CN", @"الصينية", @"🇨🇳"], @[@"ru", @"الروسية", @"🇷🇺"], @[@"pt", @"البرتغالية", @"🇵🇹"], @[@"it", @"الإيطالية", @"🇮🇹"],
    ];
    raRegisterD(@"الإضافات", @"ht.translate", @"الترجمة والنطق", @"مستقلة تماماً عن ترجمة HelloTalk المدفوعة — زر 🌐 بأسفل Ra Menu، ترجمة فورية أثناء الكتابة + نطق صوتي من نظام iOS", YES);
    igdRun(@"HTTranslate", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.translate" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (!raOn(@"ht.translate")) { igdToast(@"الترجمة مطفية من Ra Menu"); return; }
            UIViewController *top = raTop();
            if (!top) return;
            HTTranslateVC *vc = [HTTranslateVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
