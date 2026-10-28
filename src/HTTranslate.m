// HTTranslate: an independent translate + pronounce tool, fully separate from HelloTalk's own
// paid AI translation/correction system (AITranslateManager/FreeTranslateManager) — this never
// touches those, calls a free public translation API instead, and reads text aloud with iOS's
// own on-device speech synthesizer. Opened from the "🌐 ترجمة" button in Ra Menu's footer.
//
// v3: rebuilt to match the reference mockup — a top row of four mode shortcuts (صورة/كاميرا للـ
// OCR عبر Vision framework، استماع لتفعيل الديكتيشن حق لوحة المفاتيح، ومحادثة تفتح شاشة حوار
// منفصلة)، وبانر يظهر تلقائياً إذا فيه نص بالكليبورد يقترح لصقه وترجمته فوراً.
//
// Deliberately NOT using SFSpeechRecognizer anywhere in this file: HelloTalk's own Info.plist is
// missing NSSpeechRecognitionUsageDescription (confirmed by inspecting the compiled plist), and a
// dylib injected after the app binary is already built cannot add that key — calling any
// SFSpeechRecognizer API without it present crashes immediately at the OS permission-check level.
// "استماع" instead just focuses the text field and tells the user to tap the mic icon that iOS's
// own system keyboard already shows — a completely separate OS-level dictation path that needs no
// permission from this app at all. "محادثة" mode (HTConversationVC) uses the same trick: typing
// through an alert's text field, whose keyboard also carries the system dictation mic.
//
// v2 fix (kept): the previous version's output text was INVISIBLE in dark mode — a plain
// `[UILabel new]` defaults to black text, sitting on this screen's near-black translucent output
// card, so every translation was actually succeeding and just couldn't be seen. Fixed by setting
// explicit semantic colors everywhere, plus: live debounced translation as you type, swap now
// swaps the text too, copy button, remembered last-used language pair, friendlier handling of the
// free API's quota message, and haptic feedback.
#import "igd_common.h"
#import "ht_bg.h"
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <ImageIO/CGImageProperties.h>
#define BUILD @"tr4"

#define HT_TR_FROM_KEY @"ht.translate.from"
#define HT_TR_TO_KEY @"ht.translate.to"
#define HT_TR_LAST_CLIP_KEY @"ht.translate.lastclip"

static NSArray<NSArray<NSString *> *> *gLangs;   // [[code, Arabic display name, flag emoji], ...]

// ---- shared translate network call (used by both the main screen and conversation mode) -------
typedef void (^HTTranslateReply)(NSString *translated, NSString *error);
static void htTranslate(NSString *text, NSString *from, NSString *to, HTTranslateReply reply) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) { reply(nil, @"النص فاضي."); return; }
    NSString *esc = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    // raw "|" breaks NSURL parsing on newer iOS (stricter RFC 3986 checking makes URLWithString:
    // return nil for an unescaped pipe) — %7C fixes it
    NSString *urlStr = [NSString stringWithFormat:@"https://api.mymemory.translated.net/get?q=%@&langpair=%@%%7C%@", esc, from, to];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { reply(nil, @"تعذر تكوين الطلب."); return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) { reply(nil, @"تعذر الاتصال — تأكد من الإنترنت."); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *translated = json[@"responseData"][@"translatedText"];
            NSInteger status = [json[@"responseStatus"] integerValue];
            if ([translated.uppercaseString containsString:@"QUERY LENGTH LIMIT"] || [translated.uppercaseString containsString:@"MYMEMORY WARNING"]) {
                reply(nil, @"تجاوزت الحد اليومي للترجمة المجانية — جرب بعد شوي."); return;
            }
            if (status != 0 && status != 200) { reply(nil, @"تعذرت الترجمة، حاول مرة ثانية."); return; }
            if (!translated.length) { reply(nil, @"ما قدرت أترجم هالنص."); return; }
            reply(translated, nil);
        });
    }];
    [t resume];
}

// ---- OCR via Vision (on-device, no network, no extra permission beyond Camera/Photos which ----
// ---- HelloTalk's Info.plist already declares) ---------------------------------------------------
//
// A raw photo straight from UIImagePickerController (especially the camera) can be 4000x3000px or
// bigger — handing that full-size CGImage to Vision inside an already-running host app (HelloTalk,
// which has its own large memory footprint) can push the process over iOS's memory limit and get
// it killed by the OS, which looks exactly like a crash. Every image is redrawn at a sane max
// dimension before OCR ever sees it — this also neatly fixes orientation at the same time, since
// drawing a UIImage via UIGraphicsImageRenderer always produces an upright image regardless of its
// original EXIF orientation, so Vision can't misread sideways/upside-down photos.
static UIImage *htDownscaleUpright(UIImage *image, CGFloat maxDim) {
    CGSize size = image.size;
    if (size.width < 1 || size.height < 1) return image;
    CGFloat scale = MIN(1.0, maxDim / MAX(size.width, size.height));
    CGSize target = CGSizeMake(MAX(1, size.width * scale), MAX(1, size.height * scale));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = YES;
    fmt.scale = 1;   // we already picked the pixel size we want — don't multiply by screen scale too
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}
typedef void (^HTOcrReply)(NSString *text);
static void htRecognizeText(UIImage *image, HTOcrReply reply) {
    if (!image) { dispatch_async(dispatch_get_main_queue(), ^{ reply(nil); }); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *safe = htDownscaleUpright(image, 1600);   // plenty of resolution for OCR, far less memory
        CGImageRef cg = safe.CGImage;
        if (!cg) { dispatch_async(dispatch_get_main_queue(), ^{ reply(nil); }); return; }
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg orientation:kCGImagePropertyOrientationUp options:@{}];
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
            if (error) { dispatch_async(dispatch_get_main_queue(), ^{ reply(nil); }); return; }
            NSMutableArray *lines = [NSMutableArray new];
            for (VNRecognizedTextObservation *obs in request.results) {
                VNRecognizedText *top = [[obs topCandidates:1] firstObject];
                if (top.string.length) [lines addObject:top.string];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ reply([lines componentsJoinedByString:@"\n"]); });
        }];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = YES;
        NSError *err = nil;
        [handler performRequests:@[req] error:&err];
        if (err) dispatch_async(dispatch_get_main_queue(), ^{ reply(nil); });
    });
}

// ================================================================================================
#pragma mark - forward interfaces (HTTranslateVC's openConversation needs HTConversationVC's shape;
#pragma mark   the full implementations live further down, after HTTranslateVC)
// ================================================================================================
@interface HTConversationBubble : UIView
@property (nonatomic, strong) UILabel *langLabel;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIButton *micButton;
@end

@interface HTConversationVC : UIViewController
@property (nonatomic, assign) NSInteger fromIdx, toIdx;
@property (nonatomic, strong) HTConversationBubble *topBubble, *bottomBubble;
@property (nonatomic, strong) AVSpeechSynthesizer *tts;
@end

// ================================================================================================
#pragma mark - HTTranslateVC
// ================================================================================================
@interface HTTranslateVC : UIViewController <UITextViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIView *clipBanner;
@property (nonatomic, strong) UILabel *clipLabel;
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UILabel *placeholder;
@property (nonatomic, strong) UILabel *charCount;
@property (nonatomic, strong) UILabel *dictHint;
@property (nonatomic, strong) UILabel *output;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *fromBtn, *toBtn, *speakBtn, *clipboardBtn, *goBtn;
@property (nonatomic, strong) UIView *outBox;
@property (nonatomic, assign) NSInteger fromIdx, toIdx;
@property (nonatomic, strong) AVSpeechSynthesizer *tts;
@property (nonatomic, strong) NSTimer *debounce;
@property (nonatomic, assign) NSInteger requestGen;   // bumped per request; stale replies are dropped
@property (nonatomic, assign) BOOL hasOutput;          // real translated text is showing (vs. placeholder/error)
@property (nonatomic, strong) NSLayoutConstraint *clipBannerHeight;
@end

@implementation HTTranslateVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    htApplyBackground(self.view);
    self.title = @"ترجمة";
    NSInteger savedFrom = [NSUserDefaults.standardUserDefaults integerForKey:HT_TR_FROM_KEY];
    NSInteger savedTo = [NSUserDefaults.standardUserDefaults integerForKey:HT_TR_TO_KEY];
    self.fromIdx = (savedFrom >= 0 && savedFrom < gLangs.count) ? savedFrom : 0;
    self.toIdx = (savedTo > 0 && savedTo < gLangs.count) ? savedTo : 1;
    self.tts = [AVSpeechSynthesizer new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    // ---- mode shortcut row: صورة / كاميرا / استماع / محادثة ----
    UIStackView *modeRow = [self buildModeRow];
    [self.view addSubview:modeRow];

    // ---- clipboard-detected banner (hidden until viewWillAppear finds something worth offering) ----
    self.clipBanner = [UIView new];
    self.clipBanner.backgroundColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:0.14];
    self.clipBanner.layer.cornerRadius = 10;
    self.clipBanner.clipsToBounds = YES;
    self.clipBanner.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *clipIcon = [[UIImageView alloc] initWithImage:htSymbolSized(@"doc.on.clipboard.fill", @"doc.on.clipboard", 16, UIImageSymbolWeightMedium)];
    clipIcon.tintColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
    clipIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipLabel = [UILabel new];
    self.clipLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.clipLabel.textColor = UIColor.labelColor;
    self.clipLabel.numberOfLines = 1;
    self.clipLabel.text = @"فيه نص بالحافظة — اضغط للصق وترجمته";
    self.clipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *clipClose = [UIButton buttonWithType:UIButtonTypeSystem];
    [clipClose setImage:htSymbolSized(@"xmark.circle.fill", @"xmark.circle", 15, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    clipClose.tintColor = UIColor.tertiaryLabelColor;
    [clipClose addTarget:self action:@selector(dismissClipBanner) forControlEvents:UIControlEventTouchUpInside];
    clipClose.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *clipTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(useClipboard)];
    [self.clipBanner addGestureRecognizer:clipTap];
    [self.clipBanner addSubview:clipIcon];
    [self.clipBanner addSubview:self.clipLabel];
    [self.clipBanner addSubview:clipClose];
    [self.view addSubview:self.clipBanner];
    self.clipBanner.hidden = YES;

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

    // always-visible reminder that dictation works through the keyboard's own mic — not just a
    // toast that can be missed, since "استماع" itself is just this same tip + focusing the field
    self.dictHint = [UILabel new];
    self.dictHint.text = @"💡 تقدر تنطق بدل الكتابة — اضغط 🎤 بلوحة المفاتيح";
    self.dictHint.font = [UIFont systemFontOfSize:11];
    self.dictHint.textColor = UIColor.tertiaryLabelColor;
    self.dictHint.numberOfLines = 1;
    self.dictHint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.dictHint];

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
    self.clipBannerHeight = [self.clipBanner.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [modeRow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [modeRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [modeRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [modeRow.heightAnchor constraintEqualToConstant:56],

        [self.clipBanner.topAnchor constraintEqualToAnchor:modeRow.bottomAnchor constant:8],
        [self.clipBanner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.clipBanner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        self.clipBannerHeight,

        [clipIcon.leadingAnchor constraintEqualToAnchor:self.clipBanner.leadingAnchor constant:10],
        [clipIcon.centerYAnchor constraintEqualToAnchor:self.clipBanner.centerYAnchor],
        [clipIcon.widthAnchor constraintEqualToConstant:18],

        [self.clipLabel.leadingAnchor constraintEqualToAnchor:clipIcon.trailingAnchor constant:8],
        [self.clipLabel.centerYAnchor constraintEqualToAnchor:self.clipBanner.centerYAnchor],
        [self.clipLabel.trailingAnchor constraintEqualToAnchor:clipClose.leadingAnchor constant:-8],

        [clipClose.trailingAnchor constraintEqualToAnchor:self.clipBanner.trailingAnchor constant:-8],
        [clipClose.centerYAnchor constraintEqualToAnchor:self.clipBanner.centerYAnchor],
        [clipClose.widthAnchor constraintEqualToConstant:20],

        [langRow.topAnchor constraintEqualToAnchor:self.clipBanner.bottomAnchor constant:8],
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

        [self.dictHint.centerYAnchor constraintEqualToAnchor:self.charCount.centerYAnchor],
        [self.dictHint.leadingAnchor constraintEqualToAnchor:self.input.leadingAnchor constant:4],
        [self.dictHint.trailingAnchor constraintLessThanOrEqualToAnchor:self.charCount.leadingAnchor constant:-8],

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

- (UIButton *)modeButton:(NSString *)symbol fallback:(NSString *)fb title:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:htSymbolSized(symbol, fb, 20, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.imagePlacement = NSDirectionalRectEdgeTop;
        cfg.imagePadding = 4;
        cfg.baseForegroundColor = UIColor.labelColor;
        b.configuration = cfg;
    } else {
        [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    }
    b.tintColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
    b.backgroundColor = UIColor.secondarySystemBackgroundColor;
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UIStackView *)buildModeRow {
    UIButton *photoBtn = [self modeButton:@"photo.fill" fallback:@"photo" title:@"صورة" action:@selector(openPhotoOcr)];
    UIButton *cameraBtn = [self modeButton:@"camera.fill" fallback:@"camera" title:@"كاميرا" action:@selector(openCameraOcr)];
    UIButton *listenBtn = [self modeButton:@"mic.fill" fallback:@"mic" title:@"استماع" action:@selector(openDictation)];
    UIButton *convoBtn = [self modeButton:@"bubble.left.and.bubble.right.fill" fallback:@"bubble.left.and.bubble.right" title:@"محادثة" action:@selector(openConversation)];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[photoBtn, cameraBtn, listenBtn, convoBtn]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self checkClipboard];
}
- (void)checkClipboard {
    NSString *s = [UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:HT_TR_LAST_CLIP_KEY];
    BOOL worth = s.length > 1 && s.length < 500 && ![s isEqualToString:last] && ![s isEqualToString:self.input.text];
    self.clipBannerHeight.constant = worth ? 36 : 0;
    self.clipBanner.hidden = !worth;
    if (worth) {
        NSString *preview = s.length > 28 ? [[s substringToIndex:28] stringByAppendingString:@"…"] : s;
        self.clipLabel.text = [NSString stringWithFormat:@"فيه نص بالحافظة: «%@» — اضغط للصق وترجمته", preview];
    }
    [UIView animateWithDuration:0.2 animations:^{ [self.view layoutIfNeeded]; }];
}
- (void)dismissClipBanner {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (s) [NSUserDefaults.standardUserDefaults setObject:s forKey:HT_TR_LAST_CLIP_KEY];
    self.clipBannerHeight.constant = 0;
    self.clipBanner.hidden = YES;
    [UIView animateWithDuration:0.2 animations:^{ [self.view layoutIfNeeded]; }];
}
- (void)useClipboard {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (!s.length) return;
    self.input.text = s;
    [self updateCharCount];
    [self dismissClipBanner];
    [self goTapped];
}

// ---- mode row actions ----
- (void)openPhotoOcr { [self presentPickerSource:UIImagePickerControllerSourceTypePhotoLibrary]; }
- (void)openCameraOcr {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        igdToast(@"الكاميرا غير متوفرة على هذا الجهاز"); return;
    }
    [self presentPickerSource:UIImagePickerControllerSourceTypeCamera];
}
- (void)presentPickerSource:(UIImagePickerControllerSourceType)src {
    if (self.presentedViewController) return;   // avoid "present while a presentation is in progress" from a double tap
    UIImagePickerController *p = [UIImagePickerController new];
    p.sourceType = src;
    p.delegate = self;
    p.allowsEditing = NO;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!img) return;
        igdToast(@"جاري استخراج النص من الصورة…");
        htRecognizeText(img, ^(NSString *text) {
            if (!text.length) { igdToast(@"ما قدرت ألقط نص واضح من الصورة"); return; }
            self.input.text = text;
            [self updateCharCount];
            [self goTapped];
        });
    }];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
- (void)openDictation {
    [self.input becomeFirstResponder];
    igdToast(@"اضغط أيقونة المايك 🎤 بلوحة المفاتيح وابدأ الكلام");
    // visible pulse on the input box itself so something is obviously different, not just a keyboard
    self.input.layer.borderWidth = 2;
    self.input.layer.borderColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1].CGColor;
    [UIView animateWithDuration:0.6 delay:0.3 options:0 animations:^{
        self.input.layer.borderColor = UIColor.clearColor.CGColor;
    } completion:nil];
}
- (void)openConversation {
    HTConversationVC *vc = [HTConversationVC new];
    vc.fromIdx = self.fromIdx; vc.toIdx = self.toIdx;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
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
    htTranslate(text, gLangs[self.fromIdx][0], gLangs[self.toIdx][0], ^(NSString *translated, NSString *error) {
        [self finishWithText:(translated ?: error) isError:(translated == nil) gen:myGen];
    });
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

// ================================================================================================
#pragma mark - HTConversationVC — two-sided face-to-face mode
// ================================================================================================
// Each side is a big tappable panel. Tapping it opens a small alert with a text field — its
// keyboard carries iOS's own dictation mic, so this is real voice input without ever touching
// SFSpeechRecognizer. The typed/dictated line gets translated to the OTHER side's language and
// spoken aloud there automatically, like a real face-to-face conversation aid.
@implementation HTConversationBubble
- (instancetype)init {
    self = [super init];
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.layer.cornerRadius = 16;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    self.langLabel = [UILabel new];
    self.langLabel.font = [UIFont boldSystemFontOfSize:13];
    self.langLabel.textColor = UIColor.secondaryLabelColor;
    self.langLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.textLabel = [UILabel new];
    self.textLabel.font = [UIFont systemFontOfSize:20];
    self.textLabel.textColor = UIColor.labelColor;
    self.textLabel.numberOfLines = 0;
    self.textLabel.text = @"اضغط المايك وابدأ الكلام";
    self.textLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.micButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.micButton setImage:htSymbolSized(@"mic.circle.fill", @"mic.circle", 48, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    self.micButton.tintColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
    self.micButton.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:self.langLabel];
    [self addSubview:self.textLabel];
    [self addSubview:self.micButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.langLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [self.langLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],

        [self.textLabel.topAnchor constraintEqualToAnchor:self.langLabel.bottomAnchor constant:6],
        [self.textLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [self.textLabel.trailingAnchor constraintEqualToAnchor:self.micButton.leadingAnchor constant:-10],

        [self.micButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [self.micButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.micButton.widthAnchor constraintEqualToConstant:52],
        [self.micButton.heightAnchor constraintEqualToConstant:52],
        [self.textLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-12],
    ]];
    return self;
}
@end

@implementation HTConversationVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    htApplyBackground(self.view);
    self.title = @"محادثة";
    self.tts = [AVSpeechSynthesizer new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    self.topBubble = [HTConversationBubble new];
    self.bottomBubble = [HTConversationBubble new];
    [self.topBubble.micButton addTarget:self action:@selector(tapTop) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBubble.micButton addTarget:self action:@selector(tapBottom) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.topBubble];
    [self.view addSubview:self.bottomBubble];

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    [swap setImage:htSymbolSized(@"arrow.up.arrow.down", @"arrow.2.squarepath", 22, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
    [swap addTarget:self action:@selector(swapLangs) forControlEvents:UIControlEventTouchUpInside];
    swap.backgroundColor = UIColor.systemBackgroundColor;
    swap.layer.cornerRadius = 18;
    swap.layer.borderWidth = 1;
    swap.layer.borderColor = UIColor.separatorColor.CGColor;
    swap.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:swap];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.topBubble.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [self.topBubble.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.topBubble.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.topBubble.heightAnchor constraintGreaterThanOrEqualToConstant:140],
        [self.topBubble.bottomAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-28],

        [swap.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [swap.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [swap.widthAnchor constraintEqualToConstant:36],
        [swap.heightAnchor constraintEqualToConstant:36],

        [self.bottomBubble.topAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:28],
        [self.bottomBubble.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.bottomBubble.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.bottomBubble.heightAnchor constraintGreaterThanOrEqualToConstant:140],
        [self.bottomBubble.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
    [self refresh];
}
- (void)refresh {
    self.topBubble.langLabel.text = [NSString stringWithFormat:@"%@ %@", gLangs[self.toIdx][2], gLangs[self.toIdx][1]];
    self.bottomBubble.langLabel.text = [NSString stringWithFormat:@"%@ %@", gLangs[self.fromIdx][2], gLangs[self.fromIdx][1]];
}
- (void)swapLangs {
    NSInteger t = self.fromIdx; self.fromIdx = self.toIdx; self.toIdx = t;
    [[UISelectionFeedbackGenerator new] selectionChanged];
    [self refresh];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
// tapping the BOTTOM mic speaks in fromIdx's language, translates to toIdx, shows+speaks on TOP
- (void)tapBottom { [self promptForLang:self.fromIdx otherLang:self.toIdx mySide:self.bottomBubble otherSide:self.topBubble]; }
- (void)tapTop { [self promptForLang:self.toIdx otherLang:self.fromIdx mySide:self.topBubble otherSide:self.bottomBubble]; }
- (void)promptForLang:(NSInteger)myLang otherLang:(NSInteger)otherLang mySide:(HTConversationBubble *)mine otherSide:(HTConversationBubble *)other {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"تكلم بـ %@", gLangs[myLang][1]]
                                                                message:@"اكتب، أو اضغط 🎤 بلوحة المفاتيح للديكتيشن" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"..."; }];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakA = a;
    [a addAction:[UIAlertAction actionWithTitle:@"ترجم" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *text = weakA.textFields.firstObject.text;
        if (!text.length) return;
        mine.textLabel.text = text;
        mine.textLabel.textColor = UIColor.labelColor;
        htTranslate(text, gLangs[myLang][0], gLangs[otherLang][0], ^(NSString *translated, NSString *error) {
            if (!translated) { igdToast(error); return; }
            other.textLabel.text = translated;
            other.textLabel.textColor = UIColor.labelColor;
            AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:translated];
            u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:gLangs[otherLang][0]] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
            [self.tts speakUtterance:u];
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void init(void) {
    gLangs = @[
        @[@"en", @"الإنجليزية", @"🇬🇧"], @[@"ar", @"العربية", @"🇸🇦"], @[@"es", @"الإسبانية", @"🇪🇸"], @[@"fr", @"الفرنسية", @"🇫🇷"],
        @[@"de", @"الألمانية", @"🇩🇪"], @[@"tr", @"التركية", @"🇹🇷"], @[@"ja", @"اليابانية", @"🇯🇵"], @[@"ko", @"الكورية", @"🇰🇷"],
        @[@"zh-CN", @"الصينية", @"🇨🇳"], @[@"ru", @"الروسية", @"🇷🇺"], @[@"pt", @"البرتغالية", @"🇵🇹"], @[@"it", @"الإيطالية", @"🇮🇹"],
    ];
    raRegisterD(@"الإضافات", @"ht.translate", @"الترجمة والنطق", @"زر 🌐 بأسفل Ra Menu — ترجمة فورية أثناء الكتابة، نطق صوتي، ترجمة من صورة/كاميرا (OCR)، ووضع محادثة وجه لوجه", YES);
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
