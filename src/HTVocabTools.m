// HTVocabTools: three small tools built on top of the dictionary lookups you already saved
// (reuses HTDict's HT_DICT_RECENT_KEY) — a "كلمة اليوم" daily toast, a self-quiz from your saved
// words, and a PDF export of your vocabulary list. "🎓 أدوات التعلم" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"vocabtools1"
#define HT_DICT_RECENT_KEY @"ht.dict.recent"
#define HT_VOCAB_WORDDAY_BUCKET_KEY @"ht.vocab.wordday.bucket"

static NSInteger htTodayBucket2(void) { return (NSInteger)floor(NSDate.date.timeIntervalSince1970 / 86400.0); }

static NSArray<NSString *> *htSavedWords(void) {
    NSArray *recent = [NSUserDefaults.standardUserDefaults arrayForKey:HT_DICT_RECENT_KEY];
    NSMutableArray<NSString *> *words = [NSMutableArray new];
    for (id item in recent) {
        NSString *w = [item isKindOfClass:[NSString class]] ? item : ([item isKindOfClass:[NSDictionary class]] ? item[@"word"] : nil);
        if (w.length) [words addObject:w];
    }
    return words;
}

// --- Word of the day --------------------------------------------------------------------------
static void htVocabMaybeShowWordOfDay(void) {
    if (!raOn(@"ht.vocab.wordday")) return;
    NSInteger today = htTodayBucket2();
    if ([NSUserDefaults.standardUserDefaults integerForKey:HT_VOCAB_WORDDAY_BUCKET_KEY] == today) return;
    NSArray<NSString *> *words = htSavedWords();
    if (words.count == 0) return;
    NSString *word = words[arc4random_uniform((uint32_t)words.count)];
    [NSUserDefaults.standardUserDefaults setInteger:today forKey:HT_VOCAB_WORDDAY_BUCKET_KEY];
    NSString *url = [NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *def = nil;
        if (data) {
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSArray class]] && json.count) {
                NSArray *meanings = json[0][@"meanings"];
                if ([meanings isKindOfClass:[NSArray class]] && meanings.count) {
                    NSArray *defs = meanings[0][@"definitions"];
                    if ([defs isKindOfClass:[NSArray class]] && defs.count) def = defs[0][@"definition"];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            igdToast(def.length ? [NSString stringWithFormat:@"📖 كلمة اليوم: %@ — %@", word, def] : [NSString stringWithFormat:@"📖 كلمة اليوم: %@", word]);
        });
    }];
    [task resume];
}

// --- Quiz --------------------------------------------------------------------------------------
@interface HTQuizVC : UIViewController
@property (nonatomic, strong) NSArray<NSString *> *pool;
@property (nonatomic) NSInteger index, score;
@property (nonatomic, strong) UILabel *question, *progress, *feedback;
@property (nonatomic, strong) UIStackView *choices;
@property (nonatomic, copy) NSString *currentAnswer;
@end
@implementation HTQuizVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"اختبار المفردات";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.index = 0; self.score = 0;
    self.pool = [htSavedWords() sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return arc4random_uniform(2) ? NSOrderedAscending : NSOrderedDescending; }];
    if (self.pool.count > 12) self.pool = [self.pool subarrayWithRange:NSMakeRange(0, 12)];

    self.progress = [UILabel new]; self.progress.font = [UIFont systemFontOfSize:13]; self.progress.textColor = UIColor.secondaryLabelColor;
    self.question = [UILabel new]; self.question.font = [UIFont boldSystemFontOfSize:22]; self.question.numberOfLines = 0; self.question.textAlignment = NSTextAlignmentCenter;
    self.feedback = [UILabel new]; self.feedback.font = [UIFont systemFontOfSize:15]; self.feedback.numberOfLines = 0; self.feedback.textAlignment = NSTextAlignmentCenter;
    self.choices = [UIStackView new]; self.choices.axis = UILayoutConstraintAxisVertical; self.choices.spacing = 10; self.choices.distribution = UIStackViewDistributionFillEqually;
    for (UIView *v in @[self.progress, self.question, self.feedback, self.choices]) v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progress]; [self.view addSubview:self.question]; [self.view addSubview:self.feedback]; [self.view addSubview:self.choices];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.progress.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [self.progress.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.question.topAnchor constraintEqualToAnchor:self.progress.bottomAnchor constant:28],
        [self.question.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.question.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.feedback.topAnchor constraintEqualToAnchor:self.question.bottomAnchor constant:14],
        [self.feedback.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.feedback.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.choices.topAnchor constraintEqualToAnchor:self.feedback.bottomAnchor constant:24],
        [self.choices.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.choices.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    ]];
    if (self.pool.count < 4) {
        self.question.text = @"محتاج 4 كلمات محفوظة بالقاموس على الأقل عشان يبدأ الاختبار 📚";
    } else {
        [self loadQuestion];
    }
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)loadQuestion {
    [self.choices.subviews.copy makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.feedback.text = @"";
    if (self.index >= self.pool.count) {
        self.question.text = [NSString stringWithFormat:@"🎉 خلصت! نتيجتك: %ld من %ld", (long)self.score, (long)self.pool.count];
        self.progress.text = @"";
        return;
    }
    self.progress.text = [NSString stringWithFormat:@"سؤال %ld من %ld — النقاط: %ld", (long)(self.index + 1), (long)self.pool.count, (long)self.score];
    NSString *word = self.pool[self.index];
    self.question.text = word;
    self.currentAnswer = word;
    NSMutableArray<NSString *> *options = [NSMutableArray arrayWithObject:word];
    NSArray<NSString *> *others = [self.pool filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != %@", word]];
    NSMutableArray *shuffledOthers = [others mutableCopy];
    for (NSInteger i = shuffledOthers.count - 1; i > 0; i--) [shuffledOthers exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)(i + 1))];
    for (NSString *o in shuffledOthers) { if (options.count >= 4) break; [options addObject:o]; }
    while (options.count < 2) [options addObject:@"—"];
    for (NSInteger i = options.count - 1; i > 0; i--) [options exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)(i + 1))];
    // We quiz "which of these did you save?" style isn't ideal without definitions, so instead
    // fetch the definition for the target word and ask the user to pick the matching word.
    NSString *url = [NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *def = nil;
        if (data) {
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSArray class]] && json.count) {
                NSArray *meanings = json[0][@"meanings"];
                if ([meanings isKindOfClass:[NSArray class]] && meanings.count) {
                    NSArray *defs = meanings[0][@"definitions"];
                    if ([defs isKindOfClass:[NSArray class]] && defs.count) def = defs[0][@"definition"];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.question.text = def.length ? [NSString stringWithFormat:@"وش الكلمة المناسبة لهذا التعريف؟\n\n\"%@\"", def] : [NSString stringWithFormat:@"اختر معنى/تطابق لكلمة: %@", word];
            for (NSString *opt in options) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                [b setTitle:opt forState:UIControlStateNormal];
                b.backgroundColor = UIColor.secondarySystemBackgroundColor;
                b.layer.cornerRadius = 10;
                [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
                [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
                [self.choices addArrangedSubview:b];
            }
        });
    }] resume];
}
- (void)pick:(UIButton *)b {
    NSString *chosen = b.titleLabel.text;
    BOOL correct = [chosen isEqualToString:self.currentAnswer];
    if (correct) { self.score++; self.feedback.text = @"✅ صحيح!"; self.feedback.textColor = UIColor.systemGreenColor; }
    else { self.feedback.text = [NSString stringWithFormat:@"❌ الصحيح: %@", self.currentAnswer]; self.feedback.textColor = UIColor.systemRedColor; }
    for (UIView *v in self.choices.subviews) v.userInteractionEnabled = NO;
    self.index++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self loadQuestion]; });
}
@end

// --- PDF export ----------------------------------------------------------------------------
static void htVocabExportPDF(void) {
    NSArray<NSString *> *words = htSavedWords();
    if (words.count == 0) { igdToast(@"ما فيه كلمات محفوظة بالقاموس بعد"); return; }
    UIGraphicsPDFRenderer *renderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:CGRectMake(0, 0, 612, 792)];
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vocabulary.pdf"]];
    NSError *writeErr = nil;
    NSData *data = [renderer PDFDataWithActions:^(UIGraphicsPDFRendererContext *ctx) {
        CGFloat y = 40; NSInteger page = 0;
        [ctx beginPage];
        [[NSString stringWithFormat:@"قائمة المفردات — %ld كلمة", (long)words.count] drawAtPoint:CGPointMake(40, y) withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:20]}];
        y += 44;
        for (NSInteger i = 0; i < words.count; i++) {
            if (y > 740) { [ctx beginPage]; y = 40; page++; }
            [[NSString stringWithFormat:@"%ld. %@", (long)(i + 1), words[i]] drawAtPoint:CGPointMake(40, y) withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14]}];
            y += 26;
        }
    }];
    [data writeToURL:tmp options:NSDataWritingAtomic error:&writeErr];
    if (writeErr) { igdToast(@"فشل تصدير PDF"); return; }
    UIViewController *top = raTop();
    if (!top) return;
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[tmp] applicationActivities:nil];
    av.popoverPresentationController.sourceView = top.view;
    [top presentViewController:av animated:YES completion:nil];
}

// --- Main screen -----------------------------------------------------------------------------
@interface HTVocabToolsVC : UIViewController
@end
@implementation HTVocabToolsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"أدوات التعلم";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    NSArray *items = @[
        @[@"🧠", @"اختبار المفردات", @(1)],
        @[@"📄", @"تصدير قائمة الكلمات PDF", @(2)],
        @[@"📖", @"كلمة اليوم (تشغيل/إيقاف)", @(3)],
    ];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    ]];
    for (NSArray *item in items) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:[NSString stringWithFormat:@"%@  %@", item[0], item[1]] forState:UIControlStateNormal];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        b.contentEdgeInsets = UIEdgeInsetsMake(14, 16, 14, 16);
        b.backgroundColor = UIColor.secondarySystemBackgroundColor;
        b.layer.cornerRadius = 12;
        b.tag = [item[2] integerValue];
        [b.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:b];
    }
    UISwitch *sw = [UISwitch new];
    sw.on = raOn(@"ht.vocab.wordday");
    [sw addTarget:self action:@selector(toggleWordDay:) forControlEvents:UIControlEventValueChanged];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [sw.centerYAnchor constraintEqualToAnchor:[stack.arrangedSubviews lastObject].centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    ]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)toggleWordDay:(UISwitch *)sw {
    NSString *key = [@"ra.toggle." stringByAppendingString:@"ht.vocab.wordday"];
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:key];
    igdToast(sw.on ? @"تم تشغيل كلمة اليوم" : @"تم إيقاف كلمة اليوم");
}
- (void)tap:(UIButton *)b {
    if (b.tag == 1) {
        if (htSavedWords().count < 4) { igdToast(@"محتاج 4 كلمات محفوظة بالقاموس على الأقل"); return; }
        HTQuizVC *vc = [HTQuizVC new];
        [self.navigationController pushViewController:vc animated:YES];
    } else if (b.tag == 2) {
        htVocabExportPDF();
    } else if (b.tag == 3) {
        igdToast(raOn(@"ht.vocab.wordday") ? @"كلمة اليوم مفعّلة — غيّرها من المفتاح" : @"كلمة اليوم مطفية — فعّلها من المفتاح");
    }
}
@end

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الفوكس", @"ht.vocab.wordday", @"كلمة اليوم", @"تنبيه يومي بكلمة عشوائية من قاموسك المحفوظ مع تعريفها", YES);
    igdRun(@"HTVocabTools", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.vocabtools" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *top = raTop();
            if (!top) return;
            HTVocabToolsVC *vc = [HTVocabToolsVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htVocabMaybeShowWordOfDay();
        }];
    });
}
