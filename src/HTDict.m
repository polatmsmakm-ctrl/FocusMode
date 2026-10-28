// HTDict: an English dictionary lookup, fully independent of HelloTalk's own account/servers.
// Reachable two ways: the "📖 القاموس" button in Ra Menu's footer (ra.dict notification), and its
// own small draggable floating button (independent of the main Ra logo button) for one-tap access.
//
// v4: real dictionary data. Uses the Merriam-Webster Collegiate Dictionary API when the user pastes
// in their own free API key (gear icon → get one at dictionaryapi.com, free, ~1000 lookups/day) —
// proper definitions, syllable-broken headword, MW's own phonetic transcription, real audio, and
// "did you mean" suggestions for misspelled words. Falls back automatically to the free
// dictionaryapi.dev lookup (no key needed) when no key is set or the key/request fails.
#import "igd_common.h"
#import <AVFoundation/AVFoundation.h>
#import <ctype.h>
#define BUILD @"dict4"

#define HT_DICT_RECENT_KEY @"ht.dict.recent"
#define HT_DICT_BTN_POS_KEY @"ht.dict.btn.pos"
#define HT_DICT_MW_KEY @"ht.dict.mw.key"
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
// Merriam-Webster's CDN splits pronunciation mp3s into subfolders by a fixed, documented rule.
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
@property (nonatomic, strong) UILabel *headwordLabel, *phoneticLabel, *sourceLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIView *resultHeader;
@property (nonatomic, strong) UIScrollView *recentScroll;
@property (nonatomic, strong) UIStackView *recentStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *groups;   // [{"pos": "noun", "rows": [{"definition","example","synonyms"}]}]
@property (nonatomic, strong) NSArray<NSString *> *suggestions;
@property (nonatomic, copy) NSString *pendingAudioURL;
@property (nonatomic, assign) NSInteger requestGen;
@end

@implementation HTDictVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"القاموس";
    self.groups = @[];
    self.suggestions = @[];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:htSymbol(@"gearshape.fill", @"gear") style:UIBarButtonItemStylePlain target:self action:@selector(openSettings)];

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

    // ---- result header card: headword + phonetic + source + play button ----------------------
    self.resultHeader = [UIView new];
    self.resultHeader.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.resultHeader.layer.cornerRadius = 12;
    self.resultHeader.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultHeader.hidden = YES;
    [self.view addSubview:self.resultHeader];

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

    self.sourceLabel = [UILabel new];
    self.sourceLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    self.sourceLabel.textColor = UIColor.tertiaryLabelColor;
    self.sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.resultHeader addSubview:self.sourceLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playButton setImage:htSymbolSized(@"speaker.wave.2.fill", @"speaker.2.fill", 22, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playAudio) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton.hidden = YES;
    [self.resultHeader addSubview:self.playButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.headwordLabel.topAnchor constraintEqualToAnchor:self.resultHeader.topAnchor constant:10],
        [self.headwordLabel.trailingAnchor constraintEqualToAnchor:self.resultHeader.trailingAnchor constant:-14],
        [self.sourceLabel.topAnchor constraintEqualToAnchor:self.headwordLabel.topAnchor constant:3],
        [self.sourceLabel.leadingAnchor constraintEqualToAnchor:self.resultHeader.leadingAnchor constant:14],
        [self.phoneticLabel.topAnchor constraintEqualToAnchor:self.headwordLabel.bottomAnchor constant:2],
        [self.phoneticLabel.trailingAnchor constraintEqualToAnchor:self.resultHeader.trailingAnchor constant:-14],
        [self.phoneticLabel.bottomAnchor constraintEqualToAnchor:self.resultHeader.bottomAnchor constant:-10],
        [self.playButton.centerYAnchor constraintEqualToAnchor:self.resultHeader.centerYAnchor],
        [self.playButton.leadingAnchor constraintEqualToAnchor:self.resultHeader.leadingAnchor constant:10],
        [self.playButton.widthAnchor constraintEqualToConstant:34],
        [self.playButton.heightAnchor constraintEqualToConstant:34],
        [self.phoneticLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.playButton.trailingAnchor constant:8],
    ]];

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
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.table registerClass:[HTDictDefCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.field.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.field.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.field.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.field.heightAnchor constraintEqualToConstant:40],

        [self.resultHeader.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:10],
        [self.resultHeader.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.resultHeader.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.recentScroll.topAnchor constraintEqualToAnchor:self.resultHeader.bottomAnchor constant:8],
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
    [self setEmptyState:@"ابحث عن أي كلمة إنجليزية"];
    [self.field becomeFirstResponder];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self search:tf.text]; return YES; }

- (void)openSettings {
    NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:HT_DICT_MW_KEY] ?: @"";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"مفتاح Merriam-Webster"
        message:@"القاموس يشتغل بدون مفتاح (مصدر مجاني بسيط)، بس مفتاح Merriam-Webster المجاني يعطيك تعريفات أدق وصوت حقيقي واقتراحات تصحيح. احصل عليه من dictionaryapi.com (مجاني، Collegiate Dictionary) والصقه هنا."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current; tf.placeholder = @"API key"; tf.autocorrectionType = UITextAutocorrectionTypeNo; tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"فتح صفحة التسجيل" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://dictionaryapi.com/register/index"] options:@{} completionHandler:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *key = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [NSUserDefaults.standardUserDefaults setObject:key forKey:HT_DICT_MW_KEY];
        igdToast(key.length ? @"تم حفظ المفتاح" : @"رجعت للقاموس المجاني");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

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
    self.requestGen++;
    NSInteger myGen = self.requestGen;
    self.groups = @[]; self.suggestions = @[];
    self.resultHeader.hidden = YES;
    self.playButton.hidden = YES;
    self.pendingAudioURL = nil;
    [self setEmptyState:nil];
    [self.table reloadData];
    [self.spinner startAnimating];
    NSString *mwKey = [NSUserDefaults.standardUserDefaults stringForKey:HT_DICT_MW_KEY];
    if (mwKey.length) [self searchMW:word key:mwKey gen:myGen];
    else [self searchFree:word gen:myGen];
}

// ---- Merriam-Webster path ---------------------------------------------------------------------
- (void)searchMW:(NSString *)word key:(NSString *)key gen:(NSInteger)gen {
    NSString *esc = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *keyEsc = [key stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.dictionaryapi.com/api/v3/references/collegiate/json/%@?key=%@", esc, keyEsc]];
    if (!url) { [self searchFree:word gen:gen]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.requestGen) return;
            if (err || !data) { [self searchFree:word gen:gen]; return; }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || ![(NSArray *)json count]) {
                // empty array = genuinely not found even as a suggestion; anything else (dict, nil) = bad/invalid key
                if ([json isKindOfClass:[NSArray class]]) { [self finishNotFound:word]; return; }
                igdToast(@"مفتاح Merriam-Webster غير صالح — رجعت للقاموس المجاني");
                [self searchFree:word gen:gen];
                return;
            }
            NSArray *arr = (NSArray *)json;
            if ([arr.firstObject isKindOfClass:[NSString class]]) {
                // MW returns plain strings instead of entries when the word isn't found: spelling suggestions
                self.suggestions = arr;
                [self setEmptyState:[NSString stringWithFormat:@"ما لقيت \"%@\" — جرب إحدى هذي:", word]];
                self.recentScroll.hidden = YES;
                [self showSuggestionChips];
                [self.spinner stopAnimating];
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
    self.recentScroll.hidden = !self.suggestions.count;
    NSInteger i = 0;
    for (NSString *w in self.suggestions) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        [chip setTitle:w forState:UIControlStateNormal];
        [chip setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        chip.backgroundColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.98 alpha:1];
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
    self.sourceLabel.text = @"MERRIAM-WEBSTER";
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
    [self.spinner stopAnimating];
    [self.table reloadData];
    htDictRemember(word);
    [self reloadRecentChips];
}

// ---- free fallback (no key needed) -------------------------------------------------------------
- (void)searchFree:(NSString *)word gen:(NSInteger)gen {
    NSString *esc = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", esc]];
    if (!url) { [self.spinner stopAnimating]; [self setEmptyState:@"تعذر تكوين الطلب."]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.requestGen) return;
            [self.spinner stopAnimating];
            if (err || !data) { [self setEmptyState:@"تعذر الاتصال — تأكد من الإنترنت."]; [self.table reloadData]; return; }
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || !json.count) { [self finishNotFound:word]; return; }

            self.headwordLabel.text = word;
            self.sourceLabel.text = @"FREE DICTIONARY";
            NSString *phonetic = nil, *audio = nil;
            for (NSDictionary *entry in json) {
                if (!phonetic.length && [entry[@"phonetic"] length]) phonetic = entry[@"phonetic"];
                for (NSDictionary *ph in entry[@"phonetics"]) {
                    if (!phonetic.length && [ph[@"text"] length]) phonetic = ph[@"text"];
                    if (!audio.length && [ph[@"audio"] length]) audio = ph[@"audio"];
                }
            }
            self.phoneticLabel.text = phonetic ?: @"";
            self.phoneticLabel.hidden = !phonetic.length;
            if (audio.length) { self.pendingAudioURL = audio; self.playButton.hidden = NO; }
            self.resultHeader.hidden = NO;

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
- (void)finishNotFound:(NSString *)word {
    [self.spinner stopAnimating];
    [self setEmptyState:[NSString stringWithFormat:@"ما لقيت \"%@\"", word]];
    self.recentScroll.hidden = YES;
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
    raRegisterD(@"الإضافات", @"ht.dict", @"القاموس", @"مستقل تماماً عن حساب أو سيرفرات HelloTalk — يدعم Merriam-Webster (بمفتاح مجاني من إعدادات القاموس) مع رجوع تلقائي لمصدر مجاني بسيط", YES);
    raRegisterD(@"الواجهة", @"ht.dict.btn", @"زر القاموس العائم", @"زر منفصل عن شعار Ra، يفتح القاموس مباشرة بضغطة وحدة. تقدر تسحبه لأي مكان", YES);
    igdRun(@"HTDict", BUILD, ^{
        htInstallDictButton();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.dict" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htDictOpen();
        }];
    });
}
