// HTPanel: one floating button that expands into a small grid of every feature this project added,
// instead of hunting through Ra Menu or juggling several separate floating buttons (dict, phrases,
// live-caption) scattered on screen. Tapping an icon in the grid just posts the same notification
// name each feature's own module already listens for (ra.dict, ra.translate, …) — nothing new to
// hook, this is purely a shortcut launcher. The old individual floating buttons (🔖 زر القاموس
// العائم, 💬 زر عبارات العائم) still work and can stay on if you like having both; this doesn't
// touch them.
#import "igd_common.h"
#define BUILD @"panel1"

#define HT_PANEL_BTN_POS_KEY @"ht.panel.btn.pos"

@interface HTPanelAction : NSObject
@property (nonatomic, copy) NSString *icon, *fallback, *title, *notif;
@end
@implementation HTPanelAction
@end

static NSArray<HTPanelAction *> *htPanelActions(void) {
    static NSArray *a;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSArray *rows = @[
            @[@"book.fill", @"book", @"القاموس", @"ra.dict"],
            @[@"globe", @"globe", @"ترجمة", @"ra.translate"],
            @[@"text.bubble.fill", @"bubble.left.fill", @"عبارات", @"ra.phrases"],
            @[@"note.text", @"note", @"ملاحظاتي", @"ra.notes"],
            @[@"clock.fill", @"clock", @"توقيت شريكك", @"ra.worldclock"],
            @[@"graduationcap.fill", @"book.closed.fill", @"أدوات التعلم", @"ra.vocabtools"],
            @[@"captions.bubble.fill", @"text.bubble.fill", @"ترجمة فورية", @"ra.livecaption"],
            @[@"waveform.circle.fill", @"waveform", @"سجل الصوت", @"ra.voicelog"],
            @[@"square.grid.2x2.fill", @"square.grid.2x2", @"اليوم بنظرة", @"ra.widget"],
            @[@"paintbrush.fill", @"paintbrush", @"الثيم", @"ra.theme"],
            @[@"paintpalette.fill", @"paintpalette", @"لون التطبيق", @"ra.accent"],
            @[@"externaldrive.fill.badge.checkmark", @"externaldrive.fill", @"نسخ احتياطي", @"ra.backup"],
            @[@"pause.circle.fill", @"pause.circle", @"استراحة", @"ra.break"],
            @[@"ellipsis.circle.fill", @"ellipsis.circle", @"القائمة الكاملة", @"ra.menu.full"],   // special-cased below
        ];
        NSMutableArray *built = [NSMutableArray new];
        for (NSArray *r in rows) {
            HTPanelAction *act = [HTPanelAction new];
            act.icon = r[0]; act.fallback = r[1]; act.title = r[2]; act.notif = r[3];
            [built addObject:act];
        }
        a = built;
    });
    return a;
}

// ---- one tappable icon cell in the grid -----------------------------------------------------
@interface HTPanelCell : UIControl
@property (nonatomic, copy) NSString *notif;
@end
@implementation HTPanelCell
+ (instancetype)cellWithAction:(HTPanelAction *)act {
    HTPanelCell *c = [[HTPanelCell alloc] initWithFrame:CGRectZero];
    c.notif = act.notif;
    c.translatesAutoresizingMaskIntoConstraints = NO;
    [c.widthAnchor constraintEqualToConstant:70].active = YES;
    [c.heightAnchor constraintEqualToConstant:70].active = YES;

    UIView *circle = [UIView new];
    circle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    circle.layer.cornerRadius = 22;
    circle.userInteractionEnabled = NO;
    circle.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *iv = [[UIImageView alloc] initWithImage:htSymbolSized(act.icon, act.fallback, 19, UIImageSymbolWeightSemibold)];
    iv.tintColor = raThemeColor([UIColor colorWithRed:0.55 green:0.58 blue:1.0 alpha:1]);
    iv.contentMode = UIViewContentModeCenter;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [circle addSubview:iv];
    UILabel *lbl = [UILabel new];
    lbl.text = act.title;
    lbl.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;
    lbl.userInteractionEnabled = NO;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:circle]; [c addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [circle.topAnchor constraintEqualToAnchor:c.topAnchor],
        [circle.centerXAnchor constraintEqualToAnchor:c.centerXAnchor],
        [circle.widthAnchor constraintEqualToConstant:44],
        [circle.heightAnchor constraintEqualToConstant:44],
        [iv.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
        [lbl.topAnchor constraintEqualToAnchor:circle.bottomAnchor constant:4],
        [lbl.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
        [lbl.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
    ]];
    [c addTarget:c action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    return c;
}
- (void)tapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [NSNotificationCenter.defaultCenter postNotificationName:@"ht.panel.pick" object:self.notif];
}
@end

// ---- the button + expanding card, installed directly on the key window like the other floating
// buttons (not a separate alert-level UIWindow — it should sit at the same layer as HelloTalk's UI,
// same as the dict/phrases buttons) --------------------------------------------------------------
static UIButton *gPanelBtn;
static UIView *gPanelCard;
static BOOL gPanelExpanded = NO;

static void htPanelClose(void) {
    if (!gPanelExpanded) return;
    gPanelExpanded = NO;
    UIView *card = gPanelCard;
    [UIView animateWithDuration:0.18 animations:^{ card.alpha = 0; card.transform = CGAffineTransformMakeScale(0.85, 0.85); }
        completion:^(BOOL f) { [card removeFromSuperview]; }];
    gPanelCard = nil;
}

static void htPanelBuildAndShowCard(UIWindow *w) {
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.4;
    card.layer.shadowRadius = 14;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.alpha = 0;
    [w addSubview:card];

    UIStackView *rowsStack = [UIStackView new];
    rowsStack.axis = UILayoutConstraintAxisVertical;
    rowsStack.spacing = 6;
    rowsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:rowsStack];

    NSArray<HTPanelAction *> *actions = htPanelActions();
    NSInteger perRow = 3;
    UIStackView *row = nil;
    for (NSInteger i = 0; i < (NSInteger)actions.count; i++) {
        if (i % perRow == 0) {
            row = [UIStackView new];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.spacing = 4;
            row.distribution = UIStackViewDistributionFillEqually;
            [rowsStack addArrangedSubview:row];
        }
        [row addArrangedSubview:[HTPanelCell cellWithAction:actions[i]]];
    }
    // pad the last row with invisible spacers so icons stay left-aligned instead of stretching
    NSInteger remainder = actions.count % perRow;
    if (remainder) for (NSInteger i = 0; i < perRow - remainder; i++) [row addArrangedSubview:[UIView new]];

    UIScrollView *scroll = [UIScrollView new];
    scroll.showsVerticalScrollIndicator = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:scroll];
    [rowsStack removeFromSuperview];
    [scroll addSubview:rowsStack];
    [NSLayoutConstraint activateConstraints:@[
        [rowsStack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [rowsStack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [rowsStack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [rowsStack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [rowsStack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    ]];

    CGFloat cardW = 70 * 3 + 4 * 2 + 28;   // 3 columns + inter-spacing + padding
    CGFloat maxH = w.bounds.size.height * 0.6;
    [NSLayoutConstraint activateConstraints:@[
        [card.widthAnchor constraintEqualToConstant:cardW],
        [scroll.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [scroll.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [card.heightAnchor constraintLessThanOrEqualToConstant:maxH],
    ]];

    // position the card beside the button: left/right flips with which half of the screen the
    // button sits in, up/down flips with which half it's vertically in, so it never runs off screen
    CGPoint btnCenter = gPanelBtn.center;
    BOOL onLeft = btnCenter.x < w.bounds.size.width / 2;
    BOOL onTop = btnCenter.y < w.bounds.size.height / 2;
    [card layoutIfNeeded];
    if (onLeft) [card.leadingAnchor constraintEqualToAnchor:gPanelBtn.trailingAnchor constant:10].active = YES;
    else [card.trailingAnchor constraintEqualToAnchor:gPanelBtn.leadingAnchor constant:-10].active = YES;
    if (onTop) [card.topAnchor constraintEqualToAnchor:gPanelBtn.topAnchor constant:-4].active = YES;
    else [card.bottomAnchor constraintEqualToAnchor:gPanelBtn.bottomAnchor constant:4].active = YES;

    card.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4 options:0 animations:^{
        card.alpha = 1; card.transform = CGAffineTransformIdentity;
    } completion:nil];
    gPanelCard = card;
}

static void htPanelToggle(void) {
    if (gPanelExpanded) { htPanelClose(); return; }
    UIWindow *w = igdKeyWindow();
    if (!w || !gPanelBtn) return;
    gPanelExpanded = YES;
    htPanelBuildAndShowCard(w);
}

@interface HTPanelOpener : NSObject
+ (void)tap:(id)sender;
+ (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation HTPanelOpener
+ (void)tap:(id)sender { htPanelToggle(); }
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *sup = v.superview;
    if (!sup) return;
    htPanelClose();
    CGPoint t = [g translationInView:sup];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:sup];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat W = sup.bounds.size.width, H = sup.bounds.size.height;
        CGFloat x = v.center.x < W / 2 ? 34 : W - 34;
        CGFloat y = MIN(MAX(v.center.y, sup.safeAreaInsets.top + 40), H - sup.safeAreaInsets.bottom - 70);
        [UIView animateWithDuration:0.22 animations:^{ v.center = CGPointMake(x, y); }];
        [NSUserDefaults.standardUserDefaults setObject:@[@(x / W), @(y / H)] forKey:HT_PANEL_BTN_POS_KEY];
    }
}
@end

static void htInstallPanelButton(void) {
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        UIWindow *w = igdKeyWindow();
        if (!w) return;
        BOOL show = raOn(@"ht.panel");
        if (!gPanelBtn) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.bounds = CGRectMake(0, 0, 52, 52);
            btn.layer.cornerRadius = 26;
            btn.clipsToBounds = YES;
            btn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
            [btn setImage:htSymbolSized(@"square.grid.3x3.fill", @"ellipsis.circle.fill", 20, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
            btn.tintColor = raThemeColor([UIColor colorWithRed:0.55 green:0.58 blue:1.0 alpha:1]);
            btn.layer.borderWidth = 1.2;
            btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
            btn.accessibilityIdentifier = @"ht.panel.btn";
            [btn addTarget:[HTPanelOpener class] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[HTPanelOpener class] action:@selector(pan:)]];
            NSArray *pos = [NSUserDefaults.standardUserDefaults arrayForKey:HT_PANEL_BTN_POS_KEY];
            CGSize S = w.bounds.size;
            btn.center = pos.count == 2 ? CGPointMake([pos[0] doubleValue] * S.width, [pos[1] doubleValue] * S.height) : CGPointMake(34, S.height * 0.56);
            gPanelBtn = btn;
        }
        gPanelBtn.hidden = !show;
        if (!show) htPanelClose();
        if (gPanelBtn.superview != w) [w addSubview:gPanelBtn];
        else if (w.subviews.lastObject != gPanelBtn && !gPanelExpanded) [w bringSubviewToFront:gPanelBtn];
    }];
    // every other module's screen is opened through these same notification names, so the panel's
    // grid just re-posts whichever one was tapped — "ra.menu.full" is the one exception, handled
    // directly here since it's not a per-module screen but the whole Ra Menu itself
    [NSNotificationCenter.defaultCenter addObserverForName:@"ht.panel.pick" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSString *notif = n.object;
        htPanelClose();
        if ([notif isEqualToString:@"ra.menu.full"]) { raOpenMenu(); return; }
        [NSNotificationCenter.defaultCenter postNotificationName:notif object:nil];
    }];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الواجهة", @"ht.panel", @"اللوحة العائمة", @"زر وحد يفتح شبكة فيها كل أدوات المشروع (قاموس، ترجمة، عبارات، ملاحظات، إحصائيات، ثيم...) بضغطة وحدة بدل ما تفتح القائمة كل مرة", YES);
    igdRun(@"HTPanel", BUILD, ^{
        htInstallPanelButton();
    });
}
