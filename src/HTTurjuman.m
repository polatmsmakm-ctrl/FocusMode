// HTTurjuman: combined translate + dictionary tool, REPLACING the old separate HTTranslate.m and
// HTDict.m. Deliberately narrowed to exactly two tabs — "ترجمة" and "قاموس" — with no other mode:
// no OCR/camera, no conversation screen, no clipboard-detection banner. The translate tab is backed
// EXCLUSIVELY by DeepL, the dictionary tab EXCLUSIVELY by Merriam-Webster — no MyMemory, no
// dictionaryapi.dev free fallback, no other service of any kind. Both need the user's own free API
// key (gear icon, same screen); without a key that tab simply shows "add your key" and does nothing
// else, by design — there is no silent fallback to another backend.
//
// Keeps HT_DICT_RECENT_KEY / HT_DICT_MW_KEY under their original key names so HTVocabTools and
// HTWidget2 (which read the recent-words list directly) and anyone who already saved an MW key keep
// working unchanged. Still answers both ra.dict and ra.translate notifications (posted by Ra Menu's
// footer buttons and HTPanel) — each just opens this same screen on the matching tab.
#import "igd_common.h"
#import "ht_bg.h"
#import <AVFoundation/AVFoundation.h>
#import <ctype.h>
#define BUILD @"turjuman1"

#define HT_TR_FROM_KEY @"ht.translate.from"
#define HT_TR_TO_KEY @"ht.translate.to"
#define HT_TR_DEEPL_KEY @"ht.translate.deepl.key"
#define HT_DICT_RECENT_KEY @"ht.dict.recent"
#define HT_DICT_BTN_POS_KEY @"ht.dict.btn.pos"
#define HT_DICT_MW_KEY @"ht.dict.mw.key"
#define HT_DICT_RECENT_MAX 20

static NSArray<NSArray<NSString *> *> *gLangs;   // [[code, Arabic display name, flag emoji], ...]

// ================================================================================================
#pragma mark - DeepL (translate tab's only backend)
// ================================================================================================
// DeepL's source codes carry no regional variant; two targets do (English, Portuguese) — picking
// the American/European defaults since that's what a free personal key almost always wants.
static NSString *htDeepLSource(NSString *code) {
    NSDictionary *map = @{ @"zh-CN": @"ZH" };
    return map[code] ?: code.uppercaseString;
}
static NSString *htDeepLTarget(NSString *code) {
    NSDictionary *map = @{ @"en": @"EN-US", @"pt": @"PT-PT", @"zh-CN": @"ZH" };
    return map[code] ?: code.uppercaseString;
}
typedef void (^HTTranslateReply)(NSString *translated, NSString *error);
static void htDeepLTranslate(NSString *text, NSString *fromCode, NSString *toCode, NSString *key, HTTranslateReply reply) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) { reply(nil, @"النص فاضي."); return; }
    if (!key.length) { reply(nil, @"ضيف مفتاح DeepL أول (من زر الإعدادات ⚙️)."); return; }
    // DeepL issues two kinds of key: a free one always ends with ":fx" (api-free.deepl.com), a paid
    // one doesn't (api.deepl.com) — the host has to match the key or every call fails with 403/456.
    BOOL isFree = [key hasSuffix:@":fx"];
    NSString *host = isFree ? @"https://api-free.deepl.com/v2/translate" : @"https://api.deepl.com/v2/translate";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:host]];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"DeepL-Auth-Key %@", key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *esc = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *body = [NSString stringWithFormat:@"text=%@&source_lang=%@&target_lang=%@", esc, htDeepLSource(fromCode), htDeepLTarget(toCode)];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            if (err || !data) { reply(nil, @"تعذر الاتصال — تأكد من الإنترنت."); return; }
            if (status == 403) { reply(nil, @"مفتاح DeepL غير صالح."); return; }
            if (status == 456) { reply(nil, @"تجاوزت الحد الشهري لمفتاح DeepL المجاني."); return; }
            if (status == 429) { reply(nil, @"طلبات كثيرة — جرب بعد شوي."); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *out = [[json[@"translations"] firstObject] isKindOfClass:[NSDictionary class]] ? json[@"translations"][0][@"text"] : nil;
            if (!out.length) { reply(nil, @"ما قدرت أترجم هالنص — تأكد إن اللغة مدعومة بـDeepL."); return; }
            reply(out, nil);
        });
    }];
    [t resume];
}

// ================================================================================================
#pragma mark - Merriam-Webster (dictionary tab's only backend)
// ================================================================================================
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
    NSString *p = pos.lowercaseString;
    if ([p containsString:@"verb"]) return @"فعل";
    if ([p containsString:@"noun"]) return @"اسم";
    if ([p containsString:@"adjective"]) return @"صفة";
    if ([p containsString:@"adverb"]) return @"ظرف";
    if ([p containsString:@"pronoun"]) return @"ضمير";
    if ([p containsString:@"preposition"]) return @"حرف جر";
    if ([p containsString:@"conjunction"]) return @"حرف عطف";
    if ([p containsString:@"interjection"] || [p containsString:@"exclamation"]) return @"تعجب";
    if ([p containsString:@"determiner"] || [p containsString:@"article"]) return @"أداة تعريف";
    return pos.length ? pos : @"—";
}
static NSString *htMWAudioURL(NSString *audio) {
    if (!audio.length) return nil;
    NSString *subdir;
    unichar c0 = [audio characterAtIndex:0];
    if ([audio hasPrefix:@"bix"]) subdir = @"bix";
    else if ([audio hasPrefix:@"gg"]) subdir = @"gg";
    else if (c0 >= '0' && c0 <= '9') subdir = @"number";
    else if (!isalpha(c0)) subdir = @"number";
    else subdir = [[audio substringToIndex:1] lowercaseString];
    return [NSString stringWithFormat:@"https://media.merriam-webster.com/audio/prons/en/us/mp3/%@/%@.mp3", subdir, audio];
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
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.contentView.backgroundColor = UIColor.clearColor;
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

// ================================================================================================
#pragma mark - HTTurjumanVC — one screen, two tabs, nothing else
// ================================================================================================
@interface HTTurjumanVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UIView *translatePane, *dictPane;
// -- translate pane --
@property (nonatomic, strong) UIView *deeplBanner;
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UILabel *placeholder, *charCount;
@property (nonatomic, strong) UIButton *fromBtn, *toBtn, *goBtn, *speakBtn, *copyBtn;
@property (nonatomic, strong) UIView *outBox;
@property (nonatomic, strong) UILabel *output;
@property (nonatomic, strong) UIActivityIndicatorView *trSpinner;
@property (nonatomic, assign) NSInteger fromIdx, toIdx;
@property (nonatomic, assign) BOOL hasOutput;
@property (nonatomic, assign) NSInteger trGen;
@property (nonatomic, strong) NSTimer *debounce;
@property (nonatomic, strong) AVSpeechSynthesizer *tts;
// -- dictionary pane --
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIView *mwBanner;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIActivityIndicatorView *dictSpinner;
@property (nonatomic, strong) UILabel *headwordLabel, *phoneticLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIView *resultHeader;
@property (nonatomic, strong) UILabel *recentHeader;
@property (nonatomic, strong) UIScrollView *recentScroll;
@property (nonatomic, strong) UIStackView *recentStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *groups;
@property (nonatomic, strong) NSArray<NSString *> *suggestions;
@property (nonatomic, copy) NSString *pendingAudioURL;
@property (nonatomic, assign) NSInteger dictGen;
@end

@implementation HTTurjumanVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    htApplyBackground(self.view);
    self.title = @"ترجمان";
    self.tts = [AVSpeechSynthesizer new];
    self.groups = @[]; self.suggestions = @[];
    NSInteger savedFrom = [NSUserDefaults.standardUserDefaults integerForKey:HT_TR_FROM_KEY];
    NSInteger savedTo = [NSUserDefaults.standardUserDefaults integerForKey:HT_TR_TO_KEY];
    self.fromIdx = (savedFrom >= 0 && savedFrom < gLangs.count) ? savedFrom : 0;
    self.toIdx = (savedTo > 0 && savedTo < gLangs.count) ? savedTo : 1;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:htSymbol(@"gearshape.fill", @"gear") style:UIBarButtonItemStylePlain target:self action:@selector(openSettings)];

    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"ترجمة", @"قاموس"]];
    self.tabs.selectedSegmentIndex = 0;
    [self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tabs];

    [self buildTranslatePane];
    [self buildDictPane];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tabs.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [self.tabs.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:40],
        [self.tabs.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-40],

        [self.translatePane.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:10],
        [self.translatePane.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.translatePane.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.translatePane.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.dictPane.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:10],
        [self.dictPane.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.dictPane.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.dictPane.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self tabChanged];
    [self refreshLangButtons];
    [self updateDeeplBanner];
    [self updateMWBanner];
    [self reloadRecentChips];
    [self setEmptyState:@"ابحث عن أي كلمة إنجليزية"];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)selectTab:(NSInteger)i { self.tabs.selectedSegmentIndex = i; [self tabChanged]; }
- (void)tabChanged {
    BOOL tr = self.tabs.selectedSegmentIndex == 0;
    self.translatePane.hidden = !tr;
    self.dictPane.hidden = tr;
    if (tr) [self.input becomeFirstResponder]; else [self.field becomeFirstResponder];
}
- (void)openSettings {
    BOOL tr = self.tabs.selectedSegmentIndex == 0;
    NSString *key = tr ? HT_TR_DEEPL_KEY : HT_DICT_MW_KEY;
    NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:key] ?: @"";
    NSString *title = tr ? @"مفتاح DeepL" : @"مفتاح Merriam-Webster";
    NSString *msg = tr
        ? @"الترجمة هنا حصراً عن طريق DeepL — محتاج مفتاحك المجاني. احصل عليه من deepl.com/pro-api (مجاني، بدون بطاقة لحد 500 ألف حرف شهرياً) والصقه هنا."
        : @"القاموس هنا حصراً عن طريق Merriam-Webster — محتاج مفتاحك المجاني. احصل عليه من dictionaryapi.com (Collegiate Dictionary، مجاني) والصقه هنا.";
    NSString *regURL = tr ? @"https://www.deepl.com/pro-api" : @"https://dictionaryapi.com/register/index";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current; tf.placeholder = @"API key"; tf.autocorrectionType = UITextAutocorrectionTypeNo; tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"فتح صفحة التسجيل" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:regURL] options:@{} completionHandler:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *k = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [NSUserDefaults.standardUserDefaults setObject:k forKey:key];
        igdToast(k.length ? @"تم حفظ المفتاح" : @"تم مسح المفتاح");
        [self updateDeeplBanner]; [self updateMWBanner];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - translate pane
- (void)buildTranslatePane {
    self.translatePane = [UIView new];
    self.translatePane.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.translatePane];

    self.deeplBanner = [self keyBannerWithText:@"الترجمة حصراً عبر DeepL — أضف مفتاحك المجاني من زر الإعدادات ⚙️" action:@selector(openSettings)];
    [self.translatePane addSubview:self.deeplBanner];

    self.fromBtn = [self langButton];
    self.toBtn = [self langButton];
    [self.fromBtn addTarget:self action:@selector(pickFrom) forControlEvents:UIControlEventTouchUpInside];
    [self.toBtn addTarget:self action:@selector(pickTo) forControlEvents:UIControlEventTouchUpInside];
    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    [swap setImage:htSymbol(@"arrow.left.arrow.right", @"arrow.2.squarepath") forState:UIControlStateNormal];
    [swap addTarget:self action:@selector(swapLangs) forControlEvents:UIControlEventTouchUpInside];
    swap.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *langRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.fromBtn, swap, self.toBtn]];
    langRow.axis = UILayoutConstraintAxisHorizontal;
    langRow.distribution = UIStackViewDistributionFillEqually;
    langRow.spacing = 8;
    langRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.translatePane addSubview:langRow];

    self.input = [UITextView new];
    self.input.delegate = self;
    self.input.font = [UIFont systemFontOfSize:16];
    self.input.textColor = UIColor.labelColor;
    self.input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.input.layer.cornerRadius = 12;
    self.input.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.input.translatesAutoresizingMaskIntoConstraints = NO;
    [self.translatePane addSubview:self.input];

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
    [self.translatePane addSubview:self.charCount];

    self.goBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.goBtn setTitle:@"ترجم" forState:UIControlStateNormal];
    self.goBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.goBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.47 blue:0.84 alpha:1];   // DeepL blue
    [self.goBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.goBtn.layer.cornerRadius = 10;
    [self.goBtn addTarget:self action:@selector(goTapped) forControlEvents:UIControlEventTouchUpInside];
    self.goBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.translatePane addSubview:self.goBtn];

    self.trSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.trSpinner.color = UIColor.whiteColor;
    self.trSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.goBtn addSubview:self.trSpinner];

    self.output = [UILabel new];
    self.output.numberOfLines = 0;
    self.output.font = [UIFont systemFontOfSize:17];
    self.output.text = @"بتظهر الترجمة هنا";
    self.output.textColor = UIColor.tertiaryLabelColor;
    self.output.translatesAutoresizingMaskIntoConstraints = NO;

    self.speakBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.speakBtn setImage:htSymbol(@"speaker.wave.2.fill", @"speaker.2.fill") forState:UIControlStateNormal];
    [self.speakBtn addTarget:self action:@selector(speak) forControlEvents:UIControlEventTouchUpInside];
    self.speakBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.copyBtn setImage:htSymbol(@"doc.on.doc", @"doc.on.doc.fill") forState:UIControlStateNormal];
    [self.copyBtn addTarget:self action:@selector(copyOutput) forControlEvents:UIControlEventTouchUpInside];
    self.copyBtn.translatesAutoresizingMaskIntoConstraints = NO;

    self.outBox = [UIView new];
    self.outBox.layer.cornerRadius = 12;
    self.outBox.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.outBox.translatesAutoresizingMaskIntoConstraints = NO;
    [self.outBox addSubview:self.output];
    [self.outBox addSubview:self.speakBtn];
    [self.outBox addSubview:self.copyBtn];
    [self.translatePane addSubview:self.outBox];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.deeplBanner.topAnchor constraintEqualToAnchor:self.translatePane.topAnchor],
        [self.deeplBanner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.deeplBanner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [langRow.topAnchor constraintEqualToAnchor:self.deeplBanner.bottomAnchor constant:10],
        [langRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [langRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [langRow.heightAnchor constraintEqualToConstant:38],

        [self.input.topAnchor constraintEqualToAnchor:langRow.bottomAnchor constant:10],
        [self.input.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.input.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.input.heightAnchor constraintEqualToConstant:120],

        [self.placeholder.topAnchor constraintEqualToAnchor:self.input.topAnchor constant:10],
        [self.placeholder.leadingAnchor constraintEqualToAnchor:self.input.leadingAnchor constant:12],

        [self.charCount.topAnchor constraintEqualToAnchor:self.input.bottomAnchor constant:3],
        [self.charCount.trailingAnchor constraintEqualToAnchor:self.input.trailingAnchor constant:-4],

        [self.goBtn.topAnchor constraintEqualToAnchor:self.charCount.bottomAnchor constant:10],
        [self.goBtn.centerXAnchor constraintEqualToAnchor:self.translatePane.centerXAnchor],
        [self.goBtn.widthAnchor constraintEqualToConstant:140],
        [self.goBtn.heightAnchor constraintEqualToConstant:42],
        [self.trSpinner.centerXAnchor constraintEqualToAnchor:self.goBtn.centerXAnchor],
        [self.trSpinner.centerYAnchor constraintEqualToAnchor:self.goBtn.centerYAnchor],

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

        [self.copyBtn.centerYAnchor constraintEqualToAnchor:self.speakBtn.centerYAnchor],
        [self.copyBtn.trailingAnchor constraintEqualToAnchor:self.speakBtn.leadingAnchor constant:-4],
        [self.copyBtn.widthAnchor constraintEqualToConstant:32],
        [self.copyBtn.heightAnchor constraintEqualToConstant:32],
    ]];
}
- (UIView *)keyBannerWithText:(NSString *)text action:(SEL)sel {
    UIView *banner = [UIView new];
    banner.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.14];
    banner.layer.cornerRadius = 10;
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    [banner addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:sel]];
    UILabel *l = [UILabel new];
    l.text = text;
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = UIColor.labelColor;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [banner addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10],
        [l.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10],
        [l.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12],
        [l.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12],
    ]];
    return banner;
}
- (void)updateDeeplBanner {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:HT_TR_DEEPL_KEY];
    self.deeplBanner.hidden = key.length > 0;
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
- (void)swapLangs {
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
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:HT_TR_DEEPL_KEY];
    if (!key.length) { igdToast(@"ضيف مفتاح DeepL أول من زر الإعدادات ⚙️"); [self updateDeeplBanner]; return; }
    self.trGen++;
    NSInteger myGen = self.trGen;
    [self.trSpinner startAnimating];
    [self.goBtn setTitle:@"" forState:UIControlStateNormal];
    htDeepLTranslate(text, gLangs[self.fromIdx][0], gLangs[self.toIdx][0], key, ^(NSString *translated, NSString *error) {
        if (myGen != self.trGen) return;
        [self.trSpinner stopAnimating];
        [self.goBtn setTitle:@"ترجم" forState:UIControlStateNormal];
        self.output.text = translated ?: error;
        self.output.textColor = translated ? UIColor.labelColor : UIColor.systemRedColor;
        self.hasOutput = translated != nil;
        if (translated) [[UIImpactFeedbackGenerator new] impactOccurred];
    });
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

#pragma mark - dictionary pane
- (void)buildDictPane {
    self.dictPane = [UIView new];
    self.dictPane.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.dictPane];

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
    [self.dictPane addSubview:self.field];

    self.mwBanner = [self keyBannerWithText:@"القاموس حصراً عبر Merriam-Webster — أضف مفتاحك المجاني من زر الإعدادات ⚙️" action:@selector(openSettings)];
    [self.dictPane addSubview:self.mwBanner];

    self.resultHeader = [UIView new];
    self.resultHeader.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.resultHeader.layer.cornerRadius = 12;
    self.resultHeader.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultHeader.hidden = YES;
    [self.dictPane addSubview:self.resultHeader];

    self.headwordLabel = [UILabel new];
    self.headwordLabel.font = [UIFont boldSystemFontOfSize:22];
    self.headwordLabel.textColor = UIColor.labelColor;
    self.headwordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.resultHeader addSubview:self.headwordLabel];

    self.phoneticLabel = [UILabel new];
    self.phoneticLabel.font = [UIFont italicSystemFontOfSize:14];
    self.phoneticLabel.textColor = UIColor.secondaryLabelColor;
    self.phoneticLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.resultHeader addSubview:self.phoneticLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playButton setImage:htSymbolSized(@"speaker.wave.2.fill", @"speaker.2.fill", 22, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playAudio) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton.hidden = YES;
    [self.resultHeader addSubview:self.playButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.headwordLabel.topAnchor constraintEqualToAnchor:self.resultHeader.topAnchor constant:10],
        [self.headwordLabel.trailingAnchor constraintEqualToAnchor:self.resultHeader.trailingAnchor constant:-14],
        [self.phoneticLabel.topAnchor constraintEqualToAnchor:self.headwordLabel.bottomAnchor constant:2],
        [self.phoneticLabel.trailingAnchor constraintEqualToAnchor:self.resultHeader.trailingAnchor constant:-14],
        [self.phoneticLabel.bottomAnchor constraintEqualToAnchor:self.resultHeader.bottomAnchor constant:-10],
        [self.playButton.centerYAnchor constraintEqualToAnchor:self.resultHeader.centerYAnchor],
        [self.playButton.leadingAnchor constraintEqualToAnchor:self.resultHeader.leadingAnchor constant:10],
        [self.playButton.widthAnchor constraintEqualToConstant:34],
        [self.playButton.heightAnchor constraintEqualToConstant:34],
        [self.phoneticLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.playButton.trailingAnchor constant:8],
        [self.headwordLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.playButton.trailingAnchor constant:8],
    ]];

    self.recentHeader = [UILabel new];
    self.recentHeader.text = @"آخر عمليات البحث";
    self.recentHeader.font = [UIFont boldSystemFontOfSize:13];
    self.recentHeader.textColor = UIColor.secondaryLabelColor;
    self.recentHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dictPane addSubview:self.recentHeader];

    self.recentStack = [UIStackView new];
    self.recentStack.axis = UILayoutConstraintAxisHorizontal;
    self.recentStack.spacing = 8;
    self.recentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.recentScroll = [UIScrollView new];
    self.recentScroll.showsHorizontalScrollIndicator = NO;
    self.recentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.recentScroll addSubview:self.recentStack];
    [self.dictPane addSubview:self.recentScroll];

    self.dictSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.dictSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dictPane addSubview:self.dictSpinner];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 70;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.table registerClass:[HTDictDefCell class] forCellReuseIdentifier:@"c"];
    [self.dictPane addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.field.topAnchor constraintEqualToAnchor:self.dictPane.topAnchor],
        [self.field.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.field.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.field.heightAnchor constraintEqualToConstant:40],

        [self.mwBanner.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:10],
        [self.mwBanner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.mwBanner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.resultHeader.topAnchor constraintEqualToAnchor:self.mwBanner.bottomAnchor constant:10],
        [self.resultHeader.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.resultHeader.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.recentHeader.topAnchor constraintEqualToAnchor:self.resultHeader.bottomAnchor constant:10],
        [self.recentHeader.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.recentScroll.topAnchor constraintEqualToAnchor:self.recentHeader.bottomAnchor constant:4],
        [self.recentScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.recentScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.recentScroll.heightAnchor constraintEqualToConstant:34],
        [self.recentStack.topAnchor constraintEqualToAnchor:self.recentScroll.topAnchor],
        [self.recentStack.bottomAnchor constraintEqualToAnchor:self.recentScroll.bottomAnchor],
        [self.recentStack.leadingAnchor constraintEqualToAnchor:self.recentScroll.leadingAnchor],
        [self.recentStack.trailingAnchor constraintEqualToAnchor:self.recentScroll.trailingAnchor],
        [self.recentStack.heightAnchor constraintEqualToAnchor:self.recentScroll.heightAnchor],

        [self.dictSpinner.centerXAnchor constraintEqualToAnchor:self.dictPane.centerXAnchor],
        [self.dictSpinner.topAnchor constraintEqualToAnchor:self.recentScroll.bottomAnchor constant:16],
        [self.table.topAnchor constraintEqualToAnchor:self.recentScroll.bottomAnchor constant:4],
        [self.table.leadingAnchor constraintEqualToAnchor:self.dictPane.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.dictPane.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.dictPane.bottomAnchor],
    ]];
}
- (void)updateMWBanner {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:HT_DICT_MW_KEY];
    self.mwBanner.hidden = key.length > 0;
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self search:tf.text]; return YES; }

- (void)reloadRecentChips {
    for (UIView *v in self.recentStack.arrangedSubviews.copy) {
        [self.recentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray<NSString *> *recent = htDictRecent();
    BOOL showRecent = (self.groups.count == 0) && recent.count > 0;
    self.recentScroll.hidden = !showRecent;
    self.recentHeader.hidden = !showRecent;
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
    AVPlayer *player = [AVPlayer playerWithURL:url];
    objc_setAssociatedObject(self, @selector(playAudio), player, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [player play];
}
- (void)setEmptyState:(NSString *)msg {
    if (!msg) { self.table.backgroundView = nil; return; }
    UILabel *l = [UILabel new];
    l.text = msg;
    l.textColor = UIColor.secondaryLabelColor;
    l.font = [UIFont systemFontOfSize:15];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.frame = CGRectMake(0, 0, self.table.bounds.size.width - 40, 60);
    self.table.backgroundView = l;
}
- (void)search:(NSString *)word {
    word = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!word.length) return;
    NSString *mwKey = [NSUserDefaults.standardUserDefaults stringForKey:HT_DICT_MW_KEY];
    if (!mwKey.length) { igdToast(@"ضيف مفتاح Merriam-Webster أول من زر الإعدادات ⚙️"); [self updateMWBanner]; return; }
    self.dictGen++;
    NSInteger myGen = self.dictGen;
    self.groups = @[]; self.suggestions = @[];
    self.resultHeader.hidden = YES;
    self.playButton.hidden = YES;
    self.pendingAudioURL = nil;
    [self setEmptyState:nil];
    [self.table reloadData];
    [self.dictSpinner startAnimating];
    [self searchMW:word key:mwKey gen:myGen];
}
- (void)searchMW:(NSString *)word key:(NSString *)key gen:(NSInteger)gen {
    NSString *esc = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *keyEsc = [key stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.dictionaryapi.com/api/v3/references/collegiate/json/%@?key=%@", esc, keyEsc]];
    if (!url) { [self.dictSpinner stopAnimating]; [self setEmptyState:@"تعذر تكوين الطلب."]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.dictGen) return;
            if (err || !data) { [self.dictSpinner stopAnimating]; [self setEmptyState:@"تعذر الاتصال — تأكد من الإنترنت."]; [self.table reloadData]; return; }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || ![(NSArray *)json count]) {
                if ([json isKindOfClass:[NSArray class]]) { [self finishNotFound:word]; return; }
                [self.dictSpinner stopAnimating];
                igdToast(@"مفتاح Merriam-Webster غير صالح");
                [self setEmptyState:@"مفتاح Merriam-Webster غير صالح — تأكد منه بالإعدادات ⚙️"];
                [self.table reloadData];
                return;
            }
            NSArray *arr = (NSArray *)json;
            if ([arr.firstObject isKindOfClass:[NSString class]]) {
                self.suggestions = arr;
                [self setEmptyState:[NSString stringWithFormat:@"ما لقيت \"%@\" — جرب إحدى هذي:", word]];
                self.recentScroll.hidden = YES; self.recentHeader.hidden = YES;
                [self showSuggestionChips];
                [self.dictSpinner stopAnimating];
                [self.table reloadData];
                return;
            }
            [self renderMWEntries:arr word:word];
        });
    }];
    [t resume];
}
- (void)showSuggestionChips {
    for (UIView *v in self.recentStack.arrangedSubviews.copy) { [self.recentStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    self.recentScroll.hidden = !self.suggestions.count; self.recentHeader.hidden = YES;
    NSInteger i = 0;
    for (NSString *w in self.suggestions) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        [chip setTitle:w forState:UIControlStateNormal];
        [chip setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        chip.backgroundColor = [UIColor colorWithRed:0.0 green:0.47 blue:0.84 alpha:1];
        chip.layer.cornerRadius = 15;
        chip.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
        chip.tag = i++;
        [chip addTarget:self action:@selector(suggestionChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.recentStack addArrangedSubview:chip];
    }
}
- (void)suggestionChipTapped:(UIButton *)sender {
    NSString *w = self.suggestions[sender.tag];
    self.field.text = w;
    [self search:w];
}
- (void)renderMWEntries:(NSArray *)entries word:(NSString *)word {
    NSDictionary *first = entries.firstObject;
    NSDictionary *hwi = first[@"hwi"];
    NSString *hw = [hwi[@"hw"] stringByReplacingOccurrencesOfString:@"*" withString:@"·"];
    self.headwordLabel.text = hw.length ? hw : word;
    NSArray *prs = hwi[@"prs"];
    NSString *phonetic = nil, *audio = nil;
    for (NSDictionary *pr in prs) {
        if (!phonetic.length && [pr[@"mw"] length]) phonetic = [NSString stringWithFormat:@"/%@/", pr[@"mw"]];
        if (!audio.length && [pr[@"sound"][@"audio"] length]) audio = htMWAudioURL(pr[@"sound"][@"audio"]);
    }
    self.phoneticLabel.text = phonetic ?: @"";
    self.phoneticLabel.hidden = !phonetic.length;
    if (audio.length) { self.pendingAudioURL = audio; self.playButton.hidden = NO; }
    self.resultHeader.hidden = NO;

    NSMutableOrderedSet<NSString *> *posOrder = [NSMutableOrderedSet new];
    NSMutableDictionary<NSString *, NSMutableArray *> *byPos = [NSMutableDictionary new];
    for (NSDictionary *entry in entries) {
        NSString *pos = entry[@"fl"] ?: @"";
        NSArray *shortdefs = entry[@"shortdef"];
        if (!shortdefs.count) continue;
        [posOrder addObject:pos];
        NSMutableArray *rows = byPos[pos] ?: [NSMutableArray new];
        for (NSString *def in shortdefs) [rows addObject:@{@"definition": def, @"example": @"", @"synonyms": @[]}];
        byPos[pos] = rows;
    }
    NSMutableArray *groups = [NSMutableArray new];
    for (NSString *pos in posOrder) [groups addObject:@{@"pos": pos, @"rows": byPos[pos]}];
    self.groups = groups;
    [self setEmptyState:groups.count ? nil : @"ما فيه تعريف متوفر."];
    [self.dictSpinner stopAnimating];
    [self.table reloadData];
    htDictRemember(word);
    [self reloadRecentChips];
}
- (void)finishNotFound:(NSString *)word {
    [self.dictSpinner stopAnimating];
    [self setEmptyState:[NSString stringWithFormat:@"ما لقيت \"%@\"", word]];
    self.recentScroll.hidden = YES; self.recentHeader.hidden = YES;
    [self.table reloadData];
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

// ================================================================================================
#pragma mark - opening, shared by Ra Menu's two footer buttons + HTPanel + the floating button
// ================================================================================================
static UIWindow *gTurjumanWindow;   // unused for now, kept for symmetry with other full-screen tools
static void htTurjumanOpen(NSInteger tab) {
    BOOL trOn = raOn(@"ht.translate"), dictOn = raOn(@"ht.dict");
    if (!trOn && !dictOn) { igdToast(@"ترجمان مطفي من Ra Menu"); return; }
    UIViewController *top = raTop();
    if (!top || [top isKindOfClass:[HTTurjumanVC class]]) return;
    HTTurjumanVC *vc = [HTTurjumanVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:^{
        [vc selectTab:tab];
    }];
}

// ---- independent floating button (opens straight to the dictionary tab, same as before) ---------
@interface HTTurjumanOpener : NSObject
+ (void)tap:(id)sender;
+ (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation HTTurjumanOpener
+ (void)tap:(id)sender { htTurjumanOpen(1); }
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

static void htInstallTurjumanButton(void) {
    __block UIButton *btn = nil;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        UIWindow *w = igdKeyWindow();
        if (!w) return;
        BOOL show = raOn(@"ht.dict") && raOn(@"ht.dict.btn") && ![raTop() isKindOfClass:[HTTurjumanVC class]];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.bounds = CGRectMake(0, 0, 50, 50);
            btn.layer.cornerRadius = 25;
            btn.clipsToBounds = YES;
            btn.backgroundColor = raThemeColor([UIColor colorWithRed:0.0 green:0.47 blue:0.84 alpha:0.92]);
            [btn setImage:htSymbolSized(@"character.book.closed.fill", @"book.closed.fill", 21, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
            btn.tintColor = UIColor.whiteColor;
            btn.layer.borderWidth = 1.2;
            btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
            btn.accessibilityIdentifier = @"ht.dict.btn";
            [btn addTarget:[HTTurjumanOpener class] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[HTTurjumanOpener class] action:@selector(pan:)]];
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
    gLangs = @[
        @[@"en", @"الإنجليزية", @"🇬🇧"], @[@"ar", @"العربية", @"🇸🇦"], @[@"es", @"الإسبانية", @"🇪🇸"], @[@"fr", @"الفرنسية", @"🇫🇷"],
        @[@"de", @"الألمانية", @"🇩🇪"], @[@"tr", @"التركية", @"🇹🇷"], @[@"ja", @"اليابانية", @"🇯🇵"], @[@"ko", @"الكورية", @"🇰🇷"],
        @[@"zh-CN", @"الصينية", @"🇨🇳"], @[@"ru", @"الروسية", @"🇷🇺"], @[@"pt", @"البرتغالية", @"🇵🇹"], @[@"it", @"الإيطالية", @"🇮🇹"],
    ];
    raRegisterD(@"الإضافات", @"ht.translate", @"الترجمة (DeepL)", @"تبويب الترجمة بشاشة ترجمان — حصراً عبر DeepL بمفتاحك المجاني، بدون أي مصدر بديل", YES);
    raRegisterD(@"الإضافات", @"ht.dict", @"القاموس (Merriam-Webster)", @"تبويب القاموس بشاشة ترجمان — حصراً عبر Merriam-Webster بمفتاحك المجاني، بدون أي مصدر بديل", YES);
    raRegisterD(@"الواجهة", @"ht.dict.btn", @"زر ترجمان العائم", @"زر منفصل عن شعار Ra، يفتح ترجمان (تبويب القاموس) مباشرة بضغطة وحدة. تقدر تسحبه لأي مكان", YES);
    igdRun(@"HTTurjuman", BUILD, ^{
        htInstallTurjumanButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.dict" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htTurjumanOpen(1);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.translate" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htTurjumanOpen(0);
        }];
    });
}
