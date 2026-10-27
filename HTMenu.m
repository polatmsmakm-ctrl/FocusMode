//
//  HTMenu.m
//  زر قائمة عائم يضيفه الدايلب فوق واجهة HelloTalk. يفتح قائمة خيارات،
//  وفيها حالياً خيار "القاموس" — بحث إنجليزي/عربي مستقل تماماً عن أي
//  بيانات أو حساب داخل HelloTalk (يستخدم قاموس مجاني مفتوح عبر الإنترنت،
//  ولا يلمس شبكة أو حساب HelloTalk نفسه).
//
//  Rashid Al-Shammari — HelloTalk 6.3.51
//

#import <UIKit/UIKit.h>

#pragma mark - الزر العائم (قابل للسحب)

@interface HTMenuButton : UIButton
@end

@implementation HTMenuButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.10 green:0.52 blue:0.95 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 4;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        [self setTitle:@"≡" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

// نحرّك نافذة الزر نفسها (مو الزر داخل superview)، لأن النافذة الحين
// بحجم الزر بالضبط — مو شاشة كاملة. هذا يضمن إن أي لمسة برّا الزر
// تروح للتطبيق تحته طبيعياً، بدون أي حيلة hit-test.
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIWindow *win = self.window;
    if (!win) return;
    CGPoint translation = [pan translationInView:win];
    CGRect frame = win.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    win.frame = frame;
    [pan setTranslation:CGPointZero inView:win];

    if (pan.state == UIGestureRecognizerStateEnded) {
        CGRect screenBounds = win.windowScene.coordinateSpace.bounds;
        CGFloat margin = 16;
        CGFloat centerX = CGRectGetMidX(win.frame);
        CGFloat targetX = (centerX < screenBounds.size.width / 2.0)
            ? margin
            : (screenBounds.size.width - win.frame.size.width - margin);
        CGFloat clampedY = MAX(margin, MIN(win.frame.origin.y, screenBounds.size.height - win.frame.size.height - margin));
        CGRect finalFrame = win.frame;
        finalFrame.origin.x = targetX;
        finalFrame.origin.y = clampedY;
        [UIView animateWithDuration:0.25 animations:^{
            win.frame = finalFrame;
        }];
    }
}

@end

#pragma mark - شاشة القاموس

@interface HTDictionaryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *meanings; // كل عنصر: {partOfSpeech, definition, example}
@end

@implementation HTDictionaryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"القاموس";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                        target:self
                                                        action:@selector(closeTapped)];

    self.searchField = [[UITextField alloc] init];
    self.searchField.borderStyle = UITextBorderStyleRoundedRect;
    self.searchField.placeholder = @"اكتب كلمة إنجليزية...";
    self.searchField.textAlignment = NSTextAlignmentRight;
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.delegate = self;
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchField];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.searchField.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.searchField.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.searchField.heightAnchor constraintEqualToConstant:40],

        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:12],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self searchWord:textField.text];
    return YES;
}

// قاموس إنجليزي مفتوح ومجاني (dictionaryapi.dev) — لا علاقة له بحساب أو
// سيرفرات HelloTalk إطلاقاً، مجرد طلب HTTP عادي من جهازك.
- (void)searchWord:(NSString *)word {
    word = [word stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (word.length == 0) return;

    self.meanings = @[];
    [self.tableView reloadData];
    [self.spinner startAnimating];

    NSString *escaped = [word stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", escaped];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self.spinner stopAnimating];
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                               completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (error || !data) {
                self.meanings = @[@{@"partOfSpeech": @"", @"definition": @"تعذر الاتصال — تأكد من الإنترنت.", @"example": @""}];
                [self.tableView reloadData];
                return;
            }
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || json.count == 0) {
                self.meanings = @[@{@"partOfSpeech": @"", @"definition": @"ما لقيت الكلمة.", @"example": @""}];
                [self.tableView reloadData];
                return;
            }
            NSMutableArray *flat = [NSMutableArray array];
            for (NSDictionary *entry in json) {
                NSArray *meaningsArr = entry[@"meanings"];
                for (NSDictionary *m in meaningsArr) {
                    NSString *pos = m[@"partOfSpeech"] ?: @"";
                    NSArray *defs = m[@"definitions"];
                    for (NSDictionary *d in defs) {
                        [flat addObject:@{
                            @"partOfSpeech": pos,
                            @"definition": d[@"definition"] ?: @"",
                            @"example": d[@"example"] ?: @""
                        }];
                    }
                }
            }
            self.meanings = flat.count > 0 ? flat : @[@{@"partOfSpeech": @"", @"definition": @"ما فيه تعريف متوفر.", @"example": @""}];
            [self.tableView reloadData];
        });
    }];
    [task resume];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.meanings.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    NSDictionary *m = self.meanings[indexPath.row];
    NSString *pos = m[@"partOfSpeech"];
    NSString *def = m[@"definition"];
    NSString *ex = m[@"example"];
    NSString *text = def;
    if (pos.length > 0) {
        text = [NSString stringWithFormat:@"(%@) %@", pos, def];
    }
    if (ex.length > 0) {
        text = [text stringByAppendingFormat:@"\n— %@", ex];
    }
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.text = text;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    return cell;
}

@end

#pragma mark - القائمة الرئيسية + تركيب الزر على الشاشة

@interface HTMenuController : NSObject
@property (nonatomic, strong) UIWindow *overlayWindow; // نافذة مستقلة فوق كل شي، بدل ما نضيف الزر كـ subview داخل نافذة التطبيق (كان هذا سبب اختفاء الزر: أي شاشة جديدة تفتح بالتطبيق تغطي عليه)
+ (instancetype)shared;
- (void)attachOverlay;
@end

@implementation HTMenuController

+ (instancetype)shared {
    static HTMenuController *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (UIWindowScene *)activeScene {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return scene;
        }
    }
    // احتياط: أي مشهد نوافذ موجود حتى لو مو "نشط" رسمياً بعد
    for (id scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return scene;
    }
    return nil;
}

- (void)attachOverlay {
    if (self.overlayWindow) return; // مركّبة مسبقاً

    UIWindowScene *scene = [self activeScene];
    if (!scene) return;

    // النافذة بحجم الزر بالضبط (مو الشاشة كاملة) — فما فيها أي مساحة
    // تقدر "تمسك" لمسة ما تخصها. هذي أبسط وأضمن طريقة لزر عائم.
    CGFloat size = 52;
    CGFloat margin = 16;
    CGRect screenBounds = scene.coordinateSpace.bounds;
    CGRect btnFrame = CGRectMake(screenBounds.size.width - size - margin,
                                  screenBounds.size.height * 0.6,
                                  size, size);

    UIWindow *overlay = [[UIWindow alloc] initWithWindowScene:scene];
    overlay.frame = btnFrame;
    overlay.windowLevel = UIWindowLevelAlert + 1; // فوق كل شي بالتطبيق
    overlay.backgroundColor = [UIColor clearColor];

    // نبني الفيو بحجم صريح (0,0,size,size) يدوياً، ولا نترك UIKit يسوي
    // الفيو الافتراضي تلقائياً — هذا بالضبط كان سبب المشكلة: الفيو
    // الافتراضي كان ينولد بحجم الشاشة كاملة (قبل ما ينضم للنافذة
    // الصغيرة)، فيطلع الزر ممتد كخانة طويلة، وموقع اللمس الحقيقي يصير
    // بس داخل النافذة الصغيرة (52×52) اللي ما تتطابق مع شكله الظاهر.
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    container.backgroundColor = [UIColor clearColor];
    container.clipsToBounds = YES; // ضمان إضافي: أي شي يفيض عن حجم الزر ينقص، ما يفيض على الشاشة

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = container;
    overlay.rootViewController = vc;

    HTMenuButton *btn = [[HTMenuButton alloc] initWithFrame:container.bounds];
    [btn addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:btn];

    overlay.hidden = NO;
    self.overlayWindow = overlay; // نحتفظ بمرجع لها وإلا تنمسح من الذاكرة

    NSLog(@"[HTMenu] 🟢 الزر تركّب فوق الشاشة.");
}

- (void)menuTapped:(UIButton *)sender {
    UIViewController *root = [self topViewController];
    if (!root) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"القائمة"
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"📖 القاموس"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction * _Nonnull action) {
        // القائمة (action sheet) لسا بطريقها تختفي وقت ما يشتغل هذا الهاندلر.
        // لو عرضنا الشاشة الجديدة فوراً على نفس "root" القديم، iOS يرفض
        // العرض لأنه فيه عرض شغال أصلاً — فنستنى تيك واحد ونجيب
        // topViewController من جديد (بعد ما تختفي القائمة تماماً).
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *freshRoot = [weakSelf topViewController];
            if (!freshRoot) {
                NSLog(@"[HTMenu] ⚠️ ما قدرت أعرض القاموس — ما لقيت شاشة أعرض فوقها.");
                return;
            }
            HTDictionaryViewController *dictVC = [[HTDictionaryViewController alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:dictVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [freshRoot presentViewController:nav animated:YES completion:^{
                NSLog(@"[HTMenu] ✅ شاشة القاموس انعرضت.");
            }];
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];

    // إعدادات iPad: الـ action sheet يحتاج popover source
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;

    [root presentViewController:sheet animated:YES completion:nil];
}

- (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;

    // أولوية للمشهد النشط فعلياً بالمقدمة، وإلا أي مشهد فيه نافذة رئيسية
    NSMutableArray<UIWindowScene *> *scenes = [NSMutableArray array];
    for (id s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) [scenes addObject:s];
    }
    [scenes sortUsingComparator:^NSComparisonResult(UIWindowScene *a, UIWindowScene *b) {
        BOOL aActive = a.activationState == UISceneActivationStateForegroundActive;
        BOOL bActive = b.activationState == UISceneActivationStateForegroundActive;
        if (aActive == bActive) return NSOrderedSame;
        return aActive ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (UIWindowScene *scene in scenes) {
        for (UIWindow *w in scene.windows) {
            // نتجاهل نافذتنا نفسها (overlayWindow) حتى لو صارت key بالغلط
            if (w == self.overlayWindow) continue;
            if (w.isKeyWindow && w.rootViewController != nil) { keyWindow = w; break; }
        }
        if (keyWindow) break;
    }

    if (!keyWindow) {
        NSLog(@"[HTMenu] ⚠️ ما لقيت keyWindow حقيقية — ما أقدر أعرض شي.");
        return nil;
    }

    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    NSLog(@"[HTMenu] topViewController = %@", NSStringFromClass([top class]));
    return top;
}

@end

static void HTMenuShowLoadConfirmationOnce(void) {
    // تنبيه يطلع مرة وحدة بس، أول ما التطبيق يفتح، عشان تتأكد "بعينك" إن
    // الدايلب محقون وشغال — بغض النظر عن أي مشكلة بالزر نفسه لاحقاً.
    static BOOL shown = NO;
    if (shown) return;
    shown = YES;
    UIViewController *root = [[HTMenuController shared] topViewController];
    if (!root) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✅ HTMenu شغال"
                                                                     message:@"الدايلب محقون صح. لو ما طلع الزر العائم بعد إغلاق هذي الرسالة، قولي."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"تمام" style:UIAlertActionStyleDefault handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
}

static void HTMenuAttemptAttach(void) {
    [[HTMenuController shared] attachOverlay];
    HTMenuShowLoadConfirmationOnce();
}

__attribute__((constructor))
static void HTMenuInit(void) {
    NSLog(@"[HTMenu] تم تحميل الدايلب (constructor اشتغل).");

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification * _Nonnull note) {
        HTMenuAttemptAttach();
    }];

    // محاولات متكررة لأول 15 ثانية فقط، تحسباً إذا المشهد (scene) ما كان
    // جاهز وقت أول إشعار. بعد كذا تتوقف تلقائياً.
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSInteger attempts = 0;
        NSTimer *retry = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            attempts++;
            HTMenuAttemptAttach();
            if ([HTMenuController shared].overlayWindow || attempts >= 15) {
                [timer invalidate];
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:retry forMode:NSRunLoopCommonModes];
    });

    NSLog(@"[HTMenu] تم التفعيل — زر القائمة العائم (فيه القاموس) جاهز.");
}
