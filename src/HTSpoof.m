// HTSpoof.m — fakes GPS location and the system clock, but only as HelloTalk itself sees them.
// The dylib runs embedded inside HelloTalk's own process, so these hooks only change what THIS
// app reads — the real device location and the real device clock, and every other app, are
// untouched. Two independent toggles, each off by default:
//
//  - ht.spoof.location: -[CLLocationManager location], -startUpdatingLocation/-requestLocation,
//    and the authorization checks CoreLocation exposes are all answered with a location made up
//    locally (by lat/lng you set below) — the real location engine is never touched at all, so
//    this needs no location permission and works even if HelloTalk's own permission was denied.
//
//  - ht.spoof.time: +[NSDate date] / +[NSDate dateWithTimeIntervalSinceNow:] /
//    +[NSDate timeIntervalSinceReferenceDate] return the real clock plus a saved offset. Pick a
//    target date once and the fake clock keeps ticking forward normally from there — it's an
//    offset, not a frozen value, so anything that measures elapsed time (timers, "x دقائق مضت")
//    still behaves sanely.
//
// "📍 الموقع والوقت" in Ra Menu's footer.
#import "igd_common.h"
#import <CoreLocation/CoreLocation.h>
#define BUILD @"spoof1"

#define HT_SPOOF_LAT_KEY @"ht.spoof.lat"
#define HT_SPOOF_LNG_KEY @"ht.spoof.lng"
#define HT_SPOOF_TIME_OFFSET_KEY @"ht.spoof.time.offset"
#define HT_SPOOF_LOC_ON @"ht.spoof.location"
#define HT_SPOOF_TIME_ON @"ht.spoof.time"

// ---- shared state -------------------------------------------------------------------------------
static double htSpoofLat(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:HT_SPOOF_LAT_KEY];
    return v ? v.doubleValue : 29.3759;   // default: Kuwait City
}
static double htSpoofLng(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:HT_SPOOF_LNG_KEY];
    return v ? v.doubleValue : 47.9774;
}
static CLLocation *htFakeLocation(void) {
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(htSpoofLat(), htSpoofLng())
                                          altitude:12 horizontalAccuracy:5 verticalAccuracy:5
                                            course:0 speed:0 timestamp:NSDate.date];
}
static NSTimeInterval htSpoofTimeOffset(void) {
    return [NSUserDefaults.standardUserDefaults doubleForKey:HT_SPOOF_TIME_OFFSET_KEY];
}

// ---- location hooks -------------------------------------------------------------------------
static const void *kSpoofTimerKey = &kSpoofTimerKey;

static void htSpoofFireDelegate(CLLocationManager *mgr) {
    id del = mgr.delegate;
    if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:mgr didUpdateLocations:@[htFakeLocation()]];
    }
}
static void htSpoofAnnounceAuthorized(CLLocationManager *mgr) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id del = mgr.delegate;
        if ([del respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [del locationManagerDidChangeAuthorization:mgr];
        } else if ([del respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
            [del locationManager:mgr didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
        }
    });
}
static void hookLocation(void) {
    igdHook("CLLocationManager", "location", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 0) return nil;
        return ^id(CLLocationManager *self) {
            if (raOn(HT_SPOOF_LOC_ON)) return htFakeLocation();
            return ((id (*)(id, SEL))orig)(self, s);
        };
    });
    igdHook("CLLocationManager", "startUpdatingLocation", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^void(CLLocationManager *self) {
            if (!raOn(HT_SPOOF_LOC_ON)) { ((void (*)(id, SEL))orig)(self, s); return; }
            if (objc_getAssociatedObject(self, kSpoofTimerKey)) return;   // already "running"
            dispatch_async(dispatch_get_main_queue(), ^{
                htSpoofFireDelegate(self);
                NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *tt) {
                    if (!raOn(HT_SPOOF_LOC_ON)) { [tt invalidate]; objc_setAssociatedObject(self, kSpoofTimerKey, nil, OBJC_ASSOCIATION_RETAIN); return; }
                    htSpoofFireDelegate(self);
                }];
                objc_setAssociatedObject(self, kSpoofTimerKey, t, OBJC_ASSOCIATION_RETAIN);
            });
        };
    });
    igdHook("CLLocationManager", "stopUpdatingLocation", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^void(CLLocationManager *self) {
            NSTimer *t = objc_getAssociatedObject(self, kSpoofTimerKey);
            if (t) { [t invalidate]; objc_setAssociatedObject(self, kSpoofTimerKey, nil, OBJC_ASSOCIATION_RETAIN); }
            ((void (*)(id, SEL))orig)(self, s);
        };
    });
    igdHook("CLLocationManager", "requestLocation", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^void(CLLocationManager *self) {
            if (!raOn(HT_SPOOF_LOC_ON)) { ((void (*)(id, SEL))orig)(self, s); return; }
            dispatch_async(dispatch_get_main_queue(), ^{ htSpoofFireDelegate(self); });
        };
    });
    igdHook("CLLocationManager", "requestWhenInUseAuthorization", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^void(CLLocationManager *self) {
            if (!raOn(HT_SPOOF_LOC_ON)) { ((void (*)(id, SEL))orig)(self, s); return; }
            htSpoofAnnounceAuthorized(self);
        };
    });
    igdHook("CLLocationManager", "requestAlwaysAuthorization", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^void(CLLocationManager *self) {
            if (!raOn(HT_SPOOF_LOC_ON)) { ((void (*)(id, SEL))orig)(self, s); return; }
            htSpoofAnnounceAuthorized(self);
        };
    });
    igdHook("CLLocationManager", "authorizationStatus", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^CLAuthorizationStatus(CLLocationManager *self) {
            if (raOn(HT_SPOOF_LOC_ON)) return kCLAuthorizationStatusAuthorizedAlways;
            return ((CLAuthorizationStatus (*)(id, SEL))orig)(self, s);
        };
    });
    igdHookClass("CLLocationManager", "locationServicesEnabled", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^BOOL(id cls) {
            if (raOn(HT_SPOOF_LOC_ON)) return YES;
            return ((BOOL (*)(id, SEL))orig)(cls, s);
        };
    });
    igdHookClass("CLLocationManager", "authorizationStatus", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^CLAuthorizationStatus(id cls) {
            if (raOn(HT_SPOOF_LOC_ON)) return kCLAuthorizationStatusAuthorizedAlways;
            return ((CLAuthorizationStatus (*)(id, SEL))orig)(cls, s);
        };
    });
}

// ---- time hooks -------------------------------------------------------------------------------
static void hookTime(void) {
    igdHookClass("NSDate", "date", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 0) return nil;
        return ^NSDate *(id cls) {
            NSDate *real = ((NSDate *(*)(id, SEL))orig)(cls, s);
            if (!raOn(HT_SPOOF_TIME_ON)) return real;
            NSTimeInterval off = htSpoofTimeOffset();
            return off != 0 ? [real dateByAddingTimeInterval:off] : real;
        };
    });
    igdHookClass("NSDate", "dateWithTimeIntervalSinceNow:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^NSDate *(id cls, NSTimeInterval secs) {
            NSDate *real = ((NSDate *(*)(id, SEL, NSTimeInterval))orig)(cls, s, secs);
            if (!raOn(HT_SPOOF_TIME_ON)) return real;
            NSTimeInterval off = htSpoofTimeOffset();
            return off != 0 ? [real dateByAddingTimeInterval:off] : real;
        };
    });
    igdHookClass("NSDate", "timeIntervalSinceReferenceDate", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'd' || nargs != 0) return nil;
        return ^NSTimeInterval(id cls) {
            NSTimeInterval real = ((NSTimeInterval (*)(id, SEL))orig)(cls, s);
            if (!raOn(HT_SPOOF_TIME_ON)) return real;
            return real + htSpoofTimeOffset();
        };
    });
}

// ---- settings screen ----------------------------------------------------------------------------
static NSArray<NSArray *> *htSpoofCities(void) {
    // name, lat, lng
    static NSArray *c;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        c = @[
            @[@"الكويت", @29.3759, @47.9774],
            @[@"الرياض", @24.7136, @46.6753],
            @[@"مكة", @21.3891, @39.8579],
            @[@"المدينة", @24.5247, @39.5692],
            @[@"دبي", @25.2048, @55.2708],
            @[@"القاهرة", @30.0444, @31.2357],
            @[@"إسطنبول", @41.0082, @28.9784],
            @[@"لندن", @51.5074, @-0.1278],
            @[@"نيويورك", @40.7128, @-74.0060],
            @[@"طوكيو", @35.6762, @139.6503],
        ];
    });
    return c;
}

@interface HTSpoofVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *latField;
@property (nonatomic, strong) UITextField *lngField;
@property (nonatomic, strong) UILabel *locStatus;
@property (nonatomic, strong) UIDatePicker *picker;
@property (nonatomic, strong) UILabel *timeStatus;
@property (nonatomic, strong) NSTimer *clockTimer;
@end

@implementation HTSpoofVC
- (UIColor *)accent { return raAccent(); }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"الموقع والوقت";
    self.view.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.97];
    self.navigationController.navigationBar.tintColor = [self accent];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 18;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:18],
        [col.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-30],
        [col.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:18],
        [col.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-18],
        [col.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36],
    ]];

    UILabel *note = [self noteLabel:@"فعّل التبديلين من Ra Menu (موقع مزيف / وقت مزيف) ليشتغل أي شي هنا — هذي الشاشة بس لضبط القيم"];
    [col addArrangedSubview:note];

    // ---- location section ----
    [col addArrangedSubview:[self sectionTitle:@"📍 الموقع المزيف"]];
    UIStackView *latRow = [self fieldRow:@"خط العرض (lat)" fieldOut:&_latField];
    UIStackView *lngRow = [self fieldRow:@"خط الطول (lng)" fieldOut:&_lngField];
    self.latField.text = [NSString stringWithFormat:@"%.6f", htSpoofLat()];
    self.lngField.text = [NSString stringWithFormat:@"%.6f", htSpoofLng()];
    [col addArrangedSubview:latRow];
    [col addArrangedSubview:lngRow];

    UIScrollView *chipScroll = [UIScrollView new];
    chipScroll.showsHorizontalScrollIndicator = NO;
    [chipScroll.heightAnchor constraintEqualToConstant:40].active = YES;
    UIStackView *chips = [UIStackView new];
    chips.axis = UILayoutConstraintAxisHorizontal;
    chips.spacing = 8;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [chipScroll addSubview:chips];
    [NSLayoutConstraint activateConstraints:@[
        [chips.topAnchor constraintEqualToAnchor:chipScroll.topAnchor],
        [chips.bottomAnchor constraintEqualToAnchor:chipScroll.bottomAnchor],
        [chips.leadingAnchor constraintEqualToAnchor:chipScroll.leadingAnchor],
        [chips.trailingAnchor constraintEqualToAnchor:chipScroll.trailingAnchor],
        [chips.heightAnchor constraintEqualToAnchor:chipScroll.heightAnchor],
    ]];
    NSInteger idx = 0;
    for (NSArray *city in htSpoofCities()) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:city[0] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        b.tintColor = UIColor.whiteColor;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        b.layer.cornerRadius = 15;
        b.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
        b.tag = idx++;
        [b addTarget:self action:@selector(cityTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chips addArrangedSubview:b];
    }
    [col addArrangedSubview:chipScroll];

    UIButton *applyLoc = [self primaryButton:@"📍 طبّق الموقع"];
    [applyLoc addTarget:self action:@selector(applyLocation) forControlEvents:UIControlEventTouchUpInside];
    [col addArrangedSubview:applyLoc];
    self.locStatus = [self statusLabel];
    [col addArrangedSubview:self.locStatus];

    // ---- time section ----
    [col addArrangedSubview:[self sectionTitle:@"🕐 الوقت المزيف"]];
    self.picker = [UIDatePicker new];
    self.picker.datePickerMode = UIDatePickerModeDateAndTime;
    self.picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    self.picker.date = [NSDate.date dateByAddingTimeInterval:htSpoofTimeOffset()];
    self.picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [col addArrangedSubview:self.picker];

    UIButton *applyTime = [self primaryButton:@"🕐 طبّق الوقت"];
    [applyTime addTarget:self action:@selector(applyTime) forControlEvents:UIControlEventTouchUpInside];
    [col addArrangedSubview:applyTime];
    UIButton *resetTime = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetTime setTitle:@"↩️ رجّع الوقت الحقيقي" forState:UIControlStateNormal];
    resetTime.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    [resetTime addTarget:self action:@selector(resetTime) forControlEvents:UIControlEventTouchUpInside];
    [col addArrangedSubview:resetTime];
    self.timeStatus = [self statusLabel];
    [col addArrangedSubview:self.timeStatus];

    [self refreshStatus];
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [self refreshStatus]; }];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.clockTimer invalidate]; }
- (UILabel *)noteLabel:(NSString *)s {
    UILabel *l = [UILabel new];
    l.text = s;
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:12.5];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    return l;
}
- (UILabel *)sectionTitle:(NSString *)s {
    UILabel *l = [UILabel new];
    l.text = s;
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    l.textColor = [self accent];
    return l;
}
- (UILabel *)statusLabel {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    return l;
}
- (UIButton *)primaryButton:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    b.backgroundColor = [self accent];
    b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    return b;
}
- (UIStackView *)fieldRow:(NSString *)label fieldOut:(UITextField **)out {
    UILabel *l = [UILabel new];
    l.text = label;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UITextField *f = [UITextField new];
    f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    f.textColor = UIColor.whiteColor;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    f.layer.cornerRadius = 8;
    f.textAlignment = NSTextAlignmentCenter;
    f.borderStyle = UITextBorderStyleNone;
    [f.heightAnchor constraintEqualToConstant:36].active = YES;
    [f.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
    f.delegate = self;
    *out = f;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[l, f]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.distribution = UIStackViewDistributionEqualSpacing;
    return row;
}
- (void)cityTapped:(UIButton *)b {
    NSArray *city = htSpoofCities()[b.tag];
    self.latField.text = [NSString stringWithFormat:@"%.6f", [city[1] doubleValue]];
    self.lngField.text = [NSString stringWithFormat:@"%.6f", [city[2] doubleValue]];
    [self applyLocation];
}
- (void)applyLocation {
    double lat = self.latField.text.doubleValue;
    double lng = self.lngField.text.doubleValue;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) { igdToast(@"إحداثيات غير صحيحة"); return; }
    [NSUserDefaults.standardUserDefaults setDouble:lat forKey:HT_SPOOF_LAT_KEY];
    [NSUserDefaults.standardUserDefaults setDouble:lng forKey:HT_SPOOF_LNG_KEY];
    [[UIImpactFeedbackGenerator new] impactOccurred];
    if (!raOn(HT_SPOOF_LOC_ON)) igdToast(@"تم الحفظ — بس خيار \"موقع مزيف\" مطفي من Ra Menu");
    [self refreshStatus];
}
- (void)applyTime {
    NSTimeInterval off = [self.picker.date timeIntervalSinceDate:NSDate.date];
    [NSUserDefaults.standardUserDefaults setDouble:off forKey:HT_SPOOF_TIME_OFFSET_KEY];
    [[UIImpactFeedbackGenerator new] impactOccurred];
    if (!raOn(HT_SPOOF_TIME_ON)) igdToast(@"تم الحفظ — بس خيار \"وقت مزيف\" مطفي من Ra Menu");
    [self refreshStatus];
}
- (void)resetTime {
    [NSUserDefaults.standardUserDefaults setDouble:0 forKey:HT_SPOOF_TIME_OFFSET_KEY];
    self.picker.date = NSDate.date;
    [self refreshStatus];
}
- (void)refreshStatus {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    BOOL locOn = raOn(HT_SPOOF_LOC_ON), timeOn = raOn(HT_SPOOF_TIME_ON);
    self.locStatus.text = [NSString stringWithFormat:@"%@ المحفوظ: %.5f, %.5f", locOn ? @"🟢 مفعّل —" : @"⚪️ غير مفعّل —", htSpoofLat(), htSpoofLng()];
    NSDate *fakeNow = [NSDate.date dateByAddingTimeInterval:htSpoofTimeOffset()];
    self.timeStatus.text = [NSString stringWithFormat:@"%@ الوقت اللي يشوفه التطبيق الآن: %@", timeOn ? @"🟢 مفعّل —" : @"⚪️ غير مفعّل —", [fmt stringFromDate:fakeNow]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"التخفي", HT_SPOOF_LOC_ON, @"📍 موقع مزيف", @"يجعل HelloTalk يرى الموقع اللي تحدده إنت (شاشة الموقع والوقت) بدل موقعك الحقيقي — بدون أي صلاحية موقع", NO);
    raRegisterD(@"التخفي", HT_SPOOF_TIME_ON, @"🕐 وقت مزيف", @"يجعل HelloTalk يرى الوقت اللي تحدده إنت (بإزاحة عن وقتك الحقيقي يستمر يتحرك طبيعي) بدل وقت جهازك الفعلي", NO);
    igdRun(@"HTSpoof", BUILD, ^{
        hookLocation();
        hookTime();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.spoof" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *top = raTop();
            if (!top) return;
            HTSpoofVC *vc = [HTSpoofVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
