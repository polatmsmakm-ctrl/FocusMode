// HTTranslate: an independent translate + pronounce tool, fully separate from HelloTalk's own
// paid AI translation/correction system (AITranslateManager/FreeTranslateManager) — this never
// touches those, calls a free public translation API instead, and reads text aloud with iOS's
// own on-device speech synthesizer. Opened from the "🌐 ترجمة" button in Ra Menu's footer.
#import "igd_common.h"
#import <AVFoundation/AVFoundation.h>
#define BUILD @"tr1"

static NSArray<NSArray<NSString *> *> *gLangs;   // [[code, Arabic display name], ...]

@interface HTTranslateVC : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UILabel *output;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *fromBtn, *toBtn, *speakBtn;
@property (nonatomic, assign) NSInteger fromIdx, toIdx;
@property (nonatomic, strong) AVSpeechSynthesizer *tts;
@end

@implementation HTTranslateVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"ترجمة";
    self.fromIdx = 0; self.toIdx = 1;   // English -> Arabic by default
    self.tts = [AVSpeechSynthesizer new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    self.input = [UITextView new];
    self.input.font = [UIFont systemFontOfSize:16];
    self.input.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.3].CGColor;
    self.input.layer.borderWidth = 1;
    self.input.layer.cornerRadius = 8;
    self.input.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.input];

    self.fromBtn = [self langButton];
    self.toBtn = [self langButton];
    [self.fromBtn addTarget:self action:@selector(pickFrom) forControlEvents:UIControlEventTouchUpInside];
    [self.toBtn addTarget:self action:@selector(pickTo) forControlEvents:UIControlEventTouchUpInside];

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    [swap setImage:[UIImage systemImageNamed:@"arrow.left.arrow.right"] forState:UIControlStateNormal];
    [swap addTarget:self action:@selector(swap) forControlEvents:UIControlEventTouchUpInside];
    swap.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    [go setTitle:@"ترجم" forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    go.backgroundColor = [UIColor colorWithRed:0.55 green:0.58 blue:1.0 alpha:1];
    [go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    go.layer.cornerRadius = 10;
    [go addTarget:self action:@selector(go) forControlEvents:UIControlEventTouchUpInside];
    go.translatesAutoresizingMaskIntoConstraints = NO;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;

    self.output = [UILabel new];
    self.output.numberOfLines = 0;
    self.output.font = [UIFont systemFontOfSize:17];
    self.output.translatesAutoresizingMaskIntoConstraints = NO;

    self.speakBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.speakBtn setImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"] forState:UIControlStateNormal];
    [self.speakBtn addTarget:self action:@selector(speak) forControlEvents:UIControlEventTouchUpInside];
    self.speakBtn.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *langRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.fromBtn, swap, self.toBtn]];
    langRow.axis = UILayoutConstraintAxisHorizontal;
    langRow.distribution = UIStackViewDistributionFillEqually;
    langRow.spacing = 8;
    langRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:langRow];
    [self.view addSubview:go];
    [self.view addSubview:self.spinner];

    UIView *outBox = [UIView new];
    outBox.layer.cornerRadius = 10;
    outBox.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.08];
    outBox.translatesAutoresizingMaskIntoConstraints = NO;
    [outBox addSubview:self.output];
    [outBox addSubview:self.speakBtn];
    [self.view addSubview:outBox];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [langRow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [langRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [langRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [langRow.heightAnchor constraintEqualToConstant:36],

        [self.input.topAnchor constraintEqualToAnchor:langRow.bottomAnchor constant:10],
        [self.input.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.input.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.input.heightAnchor constraintEqualToConstant:110],

        [go.topAnchor constraintEqualToAnchor:self.input.bottomAnchor constant:10],
        [go.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [go.widthAnchor constraintEqualToConstant:140],
        [go.heightAnchor constraintEqualToConstant:40],

        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:go.bottomAnchor constant:8],

        [outBox.topAnchor constraintEqualToAnchor:go.bottomAnchor constant:16],
        [outBox.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [outBox.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [outBox.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-16],

        [self.output.topAnchor constraintEqualToAnchor:outBox.topAnchor constant:12],
        [self.output.leadingAnchor constraintEqualToAnchor:outBox.leadingAnchor constant:12],
        [self.output.trailingAnchor constraintEqualToAnchor:self.speakBtn.leadingAnchor constant:-8],
        [self.output.bottomAnchor constraintEqualToAnchor:outBox.bottomAnchor constant:-12],

        [self.speakBtn.topAnchor constraintEqualToAnchor:outBox.topAnchor constant:8],
        [self.speakBtn.trailingAnchor constraintEqualToAnchor:outBox.trailingAnchor constant:-8],
        [self.speakBtn.widthAnchor constraintEqualToConstant:30],
        [self.speakBtn.heightAnchor constraintEqualToConstant:30],
    ]];
    [self refreshLangButtons];
}
- (UIButton *)langButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.12];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    return b;
}
- (void)refreshLangButtons {
    [self.fromBtn setTitle:gLangs[self.fromIdx][1] forState:UIControlStateNormal];
    [self.toBtn setTitle:gLangs[self.toIdx][1] forState:UIControlStateNormal];
}
- (void)swap {
    NSInteger t = self.fromIdx; self.fromIdx = self.toIdx; self.toIdx = t;
    [self refreshLangButtons];
}
- (void)pickFrom { [self pickForTarget:YES]; }
- (void)pickTo { [self pickForTarget:NO]; }
- (void)pickForTarget:(BOOL)isFrom {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"اختر اللغة" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < gLangs.count; i++) {
        NSArray *l = gLangs[i];
        [sheet addAction:[UIAlertAction actionWithTitle:l[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (isFrom) self.fromIdx = i; else self.toIdx = i;
            [self refreshLangButtons];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = isFrom ? self.fromBtn : self.toBtn;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)go {
    NSString *text = [self.input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    [self.input resignFirstResponder];
    self.output.text = @"";
    [self.spinner startAnimating];
    NSString *from = gLangs[self.fromIdx][0], *to = gLangs[self.toIdx][0];
    NSString *esc = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *urlStr = [NSString stringWithFormat:@"https://api.mymemory.translated.net/get?q=%@&langpair=%@|%@", esc, from, to];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { [self.spinner stopAnimating]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (err || !data) { self.output.text = @"تعذر الاتصال."; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *translated = json[@"responseData"][@"translatedText"];
            self.output.text = translated.length ? translated : @"ما قدرت أترجم هالنص.";
        });
    }];
    [t resume];
}
- (void)speak {
    if (!self.output.text.length) return;
    NSString *voiceLang = gLangs[self.toIdx][0];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:self.output.text];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:voiceLang] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    [self.tts speakUtterance:u];
}
@end

__attribute__((constructor)) static void init(void) {
    gLangs = @[
        @[@"en", @"الإنجليزية"], @[@"ar", @"العربية"], @[@"es", @"الإسبانية"], @[@"fr", @"الفرنسية"],
        @[@"de", @"الألمانية"], @[@"tr", @"التركية"], @[@"ja", @"اليابانية"], @[@"ko", @"الكورية"],
        @[@"zh-CN", @"الصينية"], @[@"ru", @"الروسية"], @[@"pt", @"البرتغالية"], @[@"it", @"الإيطالية"],
    ];
    raRegisterD(@"الإضافات", @"ht.translate", @"الترجمة والنطق", @"مستقلة تماماً عن ترجمة HelloTalk المدفوعة — زر 🌐 بأسفل Ra Menu، ترجمة نصية + نطق صوتي من نظام iOS", YES);
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
