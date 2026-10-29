// HTLiveCaption: real-time captions — whatever the person near you (or in a call) says gets
// shown, translated, as big scrolling captions right on screen. Two paths, chosen automatically:
//
// 1) EASY (one tap, continuous, no keyboard): SFSpeechRecognizer + AVAudioEngine. This needs
//    HelloTalk's Info.plist to have an NSSpeechRecognitionUsageDescription key — without it, iOS
//    terminates the app instantly the moment the permission is requested, with no way to catch it.
//    HelloTalk's shipped Info.plist does NOT have that key, and a dylib injected after the app is
//    already built cannot add one — so we check for the key ourselves at runtime
//    (htSpeechKeyPresent) and NEVER call the Speech API unless it's actually there. If the user
//    adds that one key to the .app's Info.plist themselves (same moment they inject this dylib —
//    full instructions are in the toast this file shows when the key is missing) and re-signs as
//    usual, this path turns on automatically, with no code change needed on our side.
// 2) FALLBACK (manual, one tap per sentence): the old trick — focus a hidden text field so the
//    system keyboard's own dictation mic button appears, which is a separate OS-level permission
//    path that needs no Info.plist entry at all. Used automatically whenever path 1 isn't
//    available (key missing, permission denied, or the audio engine fails to start).
//
// "🎙️ ترجمة فورية" in Ra Menu's footer.
#import "igd_common.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#define BUILD @"livecaption3"
#define HT_LC_FROM_KEY @"ht.livecaption.from"
#define HT_LC_TO_KEY @"ht.livecaption.to"
#define HT_LC_SPEECH_KEY_NAME @"NSSpeechRecognitionUsageDescription"

// true only if HelloTalk's Info.plist (as it exists on THIS install, after whatever the user did
// when injecting the dylib) actually carries the usage-description key Apple requires before any
// SFSpeechRecognizer call is safe to make
static BOOL htSpeechKeyPresent(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:HT_LC_SPEECH_KEY_NAME] != nil;
}

static NSString *htLocaleForLangCode(NSString *code) {
    NSDictionary *map = @{
        @"en": @"en-US", @"ar": @"ar-SA", @"es": @"es-ES", @"fr": @"fr-FR", @"de": @"de-DE", @"tr": @"tr-TR",
        @"ja": @"ja-JP", @"ko": @"ko-KR", @"zh-CN": @"zh-CN", @"ru": @"ru-RU", @"pt": @"pt-PT", @"it": @"it-IT",
    };
    return map[code] ?: @"en-US";
}

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
// easy-path (SFSpeechRecognizer) state
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic) BOOL easyMode;      // becomes YES once the easy path is actually confirmed working
@property (nonatomic) BOOL listening;
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@property (nonatomic, copy) NSString *lastPartial;
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

    self.micButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.micButton.bounds = CGRectMake(0, 0, 64, 64);
    self.micButton.layer.cornerRadius = 32;
    self.micButton.backgroundColor = [UIColor colorWithRed:0.52 green:0.33 blue:0.92 alpha:0.96];
    [self.micButton setImage:htSymbolSized(@"mic.fill", @"mic", 26, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    self.micButton.tintColor = UIColor.whiteColor;
    self.micButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.micButton addTarget:self action:@selector(micTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.micButton];

    self.instruction = [UILabel new];
    self.instruction.text = @"🎤 اضغط الزر وابدأ الكلام — يترجم ويظهر هنا تلقائياً";
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

        [self.micButton.topAnchor constraintEqualToAnchor:langRow.bottomAnchor constant:16],
        [self.micButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [self.instruction.topAnchor constraintEqualToAnchor:self.micButton.bottomAnchor constant:10],
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
    // nothing auto-starts here on purpose — starting the mic (even the easy path) should always be
    // a deliberate tap, never silent/automatic listening
}
- (void)close {
    [self.idleTimer invalidate];
    [self.debounce invalidate];
    [self stopListening];
    [self.hiddenInput resignFirstResponder];
    UIWindow *w = self.view.window;
    w.hidden = YES;
    w.rootViewController = nil;
}
- (void)micTapped {
    if (self.listening) { [self stopListening]; return; }
    if (!htSpeechKeyPresent()) {
        NSString *key = [NSString stringWithFormat:@"%@.%@", @"ht.livecaption.easyhint", NSBundle.mainBundle.bundleIdentifier ?: @""];
        if (![NSUserDefaults.standardUserDefaults boolForKey:key]) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:key];
            igdToast(@"لتفعيل الاستماع المستمر بضغطة وحدة: ضيف مفتاح NSSpeechRecognitionUsageDescription بملف Info.plist حق HelloTalk (نفس وقت ما تحط الدايلب) — بدونه نستخدم طريقة لوحة المفاتيح اليدوية");
        }
        [self startFallbackListening];
        return;
    }
    [self startEasyListening];
}
// ---- EASY path: SFSpeechRecognizer + AVAudioEngine, continuous, one tap to start/stop ----------
- (void)startEasyListening {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                igdToast(@"ما قدرنا نفعّل صلاحية التعرف على الصوت — رجعنا للطريقة اليدوية (🎤 بلوحة المفاتيح)");
                [self startFallbackListening];
                return;
            }
            // AVAudioSession's own permission request (not AVAudioApplication, which needs iOS 17+
            // and this app targets 15+) — fully supported back to iOS 15
            [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { [self startFallbackListening]; return; }
                    [self beginEasyAudioSession];
                });
            }];
        });
    }];
}
- (void)beginEasyAudioSession {
    NSArray *langs = htLCLangs();
    NSString *locale = htLocaleForLangCode(langs[self.fromIdx][0]);
    self.recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:locale]];
    if (!self.recognizer.isAvailable) {
        igdToast(@"التعرف على الصوت لهالغة مو متوفر بجهازك — رجعنا للطريقة اليدوية");
        [self startFallbackListening];
        return;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *err = nil;
    [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement options:0 error:&err];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
    if (err) { igdToast(@"تعذر تشغيل المايك — رجعنا للطريقة اليدوية"); [self startFallbackListening]; return; }

    self.audioEngine = [AVAudioEngine new];
    AVAudioInputNode *input = self.audioEngine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    [input removeTapOnBus:0];
    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [weakSelf.speechRequest appendAudioPCMBuffer:buf];
    }];
    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&err] || err) {
        igdToast(@"تعذر تشغيل المايك — رجعنا للطريقة اليدوية");
        [input removeTapOnBus:0];
        [self startFallbackListening];
        return;
    }
    self.listening = YES;
    self.easyMode = YES;
    [self updateMicUI];
    [self startOneSpeechTask];
}
// Apple's recognition task auto-ends after a stretch of silence/final result — this restarts a
// fresh one immediately for as long as the person has listening turned on, so it feels continuous
- (void)startOneSpeechTask {
    if (!self.listening) return;
    self.speechRequest = [SFSpeechAudioBufferRecognitionRequest new];
    self.speechRequest.shouldReportPartialResults = YES;
    __weak typeof(self) weakSelf = self;
    self.speechTask = [self.recognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.listening) return;
        if (result) {
            NSString *text = result.bestTranscription.formattedString;
            strongSelf.lastPartial = text;
            [strongSelf translateLive:text];
            if (result.isFinal && text.length) {
                [strongSelf commitCaption:text];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [strongSelf startOneSpeechTask];
                });
            }
        }
        if (error) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (strongSelf.listening) [strongSelf startOneSpeechTask];
            });
        }
    }];
}
// ---- FALLBACK path: the old system-keyboard dictation trick ------------------------------------
- (void)startFallbackListening {
    self.easyMode = NO;
    self.listening = YES;
    [self updateMicUI];
    [self.hiddenInput becomeFirstResponder];
    // self.idleTimer (started once in viewDidLoad) already polls for committed fallback-dictation text
}
- (void)stopListening {
    if (!self.listening && !self.easyMode) return;
    self.listening = NO;
    [self.speechTask cancel];
    self.speechTask = nil;
    [self.speechRequest endAudio];
    self.speechRequest = nil;
    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        [self.audioEngine.inputNode removeTapOnBus:0];
    }
    self.audioEngine = nil;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [self.hiddenInput resignFirstResponder];
    [self updateMicUI];
}
- (void)updateMicUI {
    [self.micButton setImage:htSymbolSized(self.listening ? @"stop.fill" : @"mic.fill", self.listening ? @"stop.fill" : @"mic", 26, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    self.micButton.backgroundColor = self.listening ? [UIColor colorWithRed:0.92 green:0.28 blue:0.33 alpha:0.96] : [UIColor colorWithRed:0.52 green:0.33 blue:0.92 alpha:0.96];
    if (self.listening) {
        self.instruction.text = self.easyMode ? @"🎧 يسمع الآن باستمرار — اضغط الزر الأحمر لين توقف" : @"🎤 اضغط زر الديكتيشن بلوحة المفاتيح وابدأ الكلام";
    } else {
        self.instruction.text = htSpeechKeyPresent() ? @"🎤 اضغط الزر وابدأ الكلام — يترجم ويظهر هنا تلقائياً" : @"🎤 اضغط الزر ثم اضغط زر الديكتيشن بلوحة المفاتيح (لتفعيل الاستماع التلقائي المستمر، راجع ملاحظة Info.plist بتفاصيل المشروع)";
    }
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
    if (self.easyMode) return;   // the easy path commits on its own isFinal result, not by polling
    NSString *text = self.hiddenInput.text;
    if (!text.length) return;
    // ~2s of silence after the keyboard's own dictation delivered text = treat it as one finished
    // sentence: push it into the scrolling history and clear the buffer for the next one.
    if (CFAbsoluteTimeGetCurrent() - self.lastChangeTime < 2.0) return;
    if ([text isEqualToString:self.lastCommitted]) return;
    self.lastCommitted = text;
    [self commitCaption:text];
    self.hiddenInput.text = @"";
}
// shared by both paths: pushes one finished sentence (original + translation) into the scrolling
// history and resets the big live-caption line for whatever comes next
- (void)commitCaption:(NSString *)text {
    if (!text.length) return;
    NSArray *langs = htLCLangs();
    htLCTranslate(text, langs[self.fromIdx][0], langs[self.toIdx][0], ^(NSString *translated, NSString *error) {
        UILabel *orig = [UILabel new];
        orig.text = text; orig.font = [UIFont systemFontOfSize:13]; orig.textColor = [UIColor colorWithWhite:1 alpha:0.45]; orig.numberOfLines = 0;
        UILabel *tr = [UILabel new];
        tr.text = translated.length ? translated : text; tr.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold]; tr.textColor = UIColor.whiteColor; tr.numberOfLines = 0;
        UIStackView *pair = [[UIStackView alloc] initWithArrangedSubviews:@[orig, tr]];
        pair.axis = UILayoutConstraintAxisVertical; pair.spacing = 2;
        [self.history addArrangedSubview:pair];
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
            // color) makes this read as part of the room's UI while still standing out as new;
            // a picked HTTheme color overrides this default
            btn.backgroundColor = raThemeColor([UIColor colorWithRed:0.52 green:0.33 blue:0.92 alpha:0.96]);
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
    raRegisterD(@"الإضافات", @"ht.livecaption", @"ترجمة فورية (كابشن)", @"زر ثابت بنفسجي يظهر فقط وأنت داخل Voice Room — بضغطة وحدة يسمع ويترجم باستمرار (يحتاج إضافة مفتاح NSSpeechRecognitionUsageDescription بـ Info.plist مرة وحدة)، وإلا يرجع تلقائياً لطريقة ديكتيشن لوحة المفاتيح", YES);
    igdRun(@"HTLiveCaption", BUILD, ^{
        htInstallLiveCaptionButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.livecaption" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htLiveCaptionOpen();
        }];
    });
}
