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
#import <CoreFoundation/CoreFoundation.h>
#import <time.h>
#import <sys/time.h>
#import <stdatomic.h>
#define BUILD @"spoof9"

#define HT_SPOOF_LAT_KEY @"ht.spoof.lat"
#define HT_SPOOF_LNG_KEY @"ht.spoof.lng"
#define HT_SPOOF_TIME_OFFSET_KEY @"ht.spoof.time.offset"
#define HT_SPOOF_LOC_ON @"ht.spoof.location"
#define HT_SPOOF_TIME_ON @"ht.spoof.time"

// Reported: account creation hung forever on "Add a profile picture" (an infinite spinner) even
// after the TLS fix below, specifically while وقت مزيف was on. Real cause: the interposed C time
// functions below (time/gettimeofday/CFAbsoluteTimeGetCurrent/clock_gettime) run from EVERY corner
// of the process — including deep inside Foundation/CFNetwork's own internals (NSUserDefaults'
// caching, GCD timer bookkeeping, TLS timing, etc.), code that may ALREADY be holding one of
// NSUserDefaults' own internal (non-reentrant) locks on that same thread. The previous version
// called raOn()/NSUserDefaults from inside those same interposed functions to check the toggle —
// so a call that started inside NSUserDefaults could loop straight back into NSUserDefaults again
// on the same thread, which simply locks up forever against a lock it's already holding. That
// hang, triggered by exactly the kind of network-heavy flow account creation is, is almost
// certainly what the video showed.
//
// Fix: never touch NSUserDefaults (or anything else from Foundation) from inside the interposed C
// functions. Keep a plain C atomic cache of "is time-spoof on" + "offset in nanoseconds" instead,
// refreshed only from safe, ordinary Objective-C call sites (module install, the settings screen's
// apply/reset buttons, and NSUserDefaultsDidChangeNotification) — the interposed functions then
// just do a lock-free atomic read, nothing that can ever contend with anything else in the process.
static _Atomic BOOL gSpoofTimeOnCache = NO;
static _Atomic int64_t gSpoofOffsetNanosCache = 0;

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
    CLLocation *loc = htFakeLocation();
    if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:mgr didUpdateLocations:@[loc]];
    }
    // some older/hybrid delegates (and third-party location-SDK adapters built on top of
    // CLLocationManager) still only implement the pre-iOS6 single-location callback — fire it
    // too, with "fromLocation" set to the same fake point, so neither code path is left dark.
    if ([del respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [del locationManager:mgr didUpdateToLocation:loc fromLocation:loc];
#pragma clang diagnostic pop
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
// NB: these three use the same atomic cache as the low-level interpose layer further down (never
// raOn()/NSUserDefaults directly) — explained in the big comment above gSpoofTimeOnCache.
static void hookTime(void) {
    igdHookClass("NSDate", "date", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 0) return nil;
        return ^NSDate *(id cls) {
            NSDate *real = ((NSDate *(*)(id, SEL))orig)(cls, s);
            if (!atomic_load_explicit(&gSpoofTimeOnCache, memory_order_relaxed)) return real;
            NSTimeInterval off = (NSTimeInterval)atomic_load_explicit(&gSpoofOffsetNanosCache, memory_order_relaxed) / 1e9;
            return off != 0 ? [real dateByAddingTimeInterval:off] : real;
        };
    });
    igdHookClass("NSDate", "dateWithTimeIntervalSinceNow:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^NSDate *(id cls, NSTimeInterval secs) {
            NSDate *real = ((NSDate *(*)(id, SEL, NSTimeInterval))orig)(cls, s, secs);
            if (!atomic_load_explicit(&gSpoofTimeOnCache, memory_order_relaxed)) return real;
            NSTimeInterval off = (NSTimeInterval)atomic_load_explicit(&gSpoofOffsetNanosCache, memory_order_relaxed) / 1e9;
            return off != 0 ? [real dateByAddingTimeInterval:off] : real;
        };
    });
    igdHookClass("NSDate", "timeIntervalSinceReferenceDate", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'd' || nargs != 0) return nil;
        return ^NSTimeInterval(id cls) {
            NSTimeInterval real = ((NSTimeInterval (*)(id, SEL))orig)(cls, s);
            if (!atomic_load_explicit(&gSpoofTimeOnCache, memory_order_relaxed)) return real;
            NSTimeInterval off = (NSTimeInterval)atomic_load_explicit(&gSpoofOffsetNanosCache, memory_order_relaxed) / 1e9;
            return real + off;
        };
    });
}

// ---- low-level time interpose ------------------------------------------------------------------
// The ObjC NSDate hooks above cover ObjC/UIKit code, but Swift's own `Date()` is a plain struct —
// it does NOT call +[NSDate date] at all, it reads the real clock straight from a handful of
// libSystem/CoreFoundation C functions. HelloTalk has Swift screens (confirmed from its own binary
// symbols — the Voice Room classes), so without this, "وقت مزيف" would do nothing for any Swift
// code path, which matches exactly what was reported. Fix: interpose those few C primitives
// system-wide for this process, via the same __DATA,__interpose mechanism dylib injectors use —
// this is what makes it reach Swift (and C/C++) callers too, not just Objective-C ones.
#define HT_DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _htSpoofInterpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(uintptr_t)&(_replacement), (const void *)(uintptr_t)&(_replacee) };

// Ground truth, read via a libSystem call we never interpose ourselves — so none of the
// replacements below ever call back into themselves (which would spin forever).
static uint64_t htRealNowNanos(void) { return clock_gettime_nsec_np(CLOCK_REALTIME); }
static uint64_t htSpoofNowNanos(void) {
    uint64_t real = htRealNowNanos();
    if (!atomic_load_explicit(&gSpoofTimeOnCache, memory_order_relaxed)) return real;
    int64_t offNanos = atomic_load_explicit(&gSpoofOffsetNanosCache, memory_order_relaxed);
    return (uint64_t)((int64_t)real + offNanos);
}
// Re-syncs the atomic cache from NSUserDefaults. Only ever called from safe, ordinary
// Objective-C contexts (never from inside the interposed C functions above) — see the big
// comment up top for why that separation is what actually matters here.
static void htSpoofRefreshTimeCache(void) {
    atomic_store_explicit(&gSpoofTimeOnCache, raOn(HT_SPOOF_TIME_ON), memory_order_relaxed);
    atomic_store_explicit(&gSpoofOffsetNanosCache, (int64_t)(htSpoofTimeOffset() * 1e9), memory_order_relaxed);
}
// The REAL current date, never affected by our own hooks (dateWithTimeIntervalSince1970: isn't
// hooked, and clock_gettime_nsec_np isn't interposed). The settings screen must compute offsets and
// show "real vs fake" against THIS — using NSDate.date there (as an earlier version did) reads the
// already-faked clock once the hook is active, so every "طبّق" corrupted the saved offset.
static NSDate *htRealNowDate(void) { return [NSDate dateWithTimeIntervalSince1970:(double)htRealNowNanos() / 1e9]; }

static time_t htSpoofTimeFn(time_t *t) {
    time_t v = (time_t)(htSpoofNowNanos() / 1000000000ULL);
    if (t) *t = v;
    return v;
}
HT_DYLD_INTERPOSE(htSpoofTimeFn, time)

static int htSpoofGettimeofday(struct timeval *tv, void *tz) {
    if (!tv) return 0;
    uint64_t n = htSpoofNowNanos();
    tv->tv_sec = (time_t)(n / 1000000000ULL);
    tv->tv_usec = (int)((n % 1000000000ULL) / 1000ULL);
    return 0;
}
HT_DYLD_INTERPOSE(htSpoofGettimeofday, gettimeofday)

static CFAbsoluteTime htSpoofCFAbsoluteTimeGetCurrent(void) {
    double secsSinceUnixEpoch = (double)htSpoofNowNanos() / 1e9;
    return secsSinceUnixEpoch - kCFAbsoluteTimeIntervalSince1970;   // CF epoch is 2001-01-01
}
HT_DYLD_INTERPOSE(htSpoofCFAbsoluteTimeGetCurrent, CFAbsoluteTimeGetCurrent)

static int htSpoofClockGettime(clockid_t clk, struct timespec *ts) {
    if (!ts) return 0;
    // only the wall clock gets spoofed — monotonic/uptime clocks pass through untouched so
    // timers, animations and "x دقائق مضت" elapsed-time math keep working normally
    uint64_t nanos = (clk == CLOCK_REALTIME) ? htSpoofNowNanos() : clock_gettime_nsec_np(clk);
    ts->tv_sec = (time_t)(nanos / 1000000000ULL);
    ts->tv_nsec = (long)(nanos % 1000000000ULL);
    return 0;
}
HT_DYLD_INTERPOSE(htSpoofClockGettime, clock_gettime)

// (An earlier version of this file also interposed SecTrustEvaluate/SecTrustEvaluateWithError to
// keep TLS certificate checks on the real clock. That ran UNCONDITIONALLY — for every HTTPS
// connection HelloTalk ever makes, regardless of whether either spoof toggle was even on — and
// account creation kept hanging even with both toggles off, which pointed squarely at it (nothing
// else in this file runs unless a toggle is on or the settings screen is used). Removed: it's not
// worth the risk it touches every network request in the app for what's ultimately a narrower
// problem. Known trade-off instead: if ht.spoof.time's picked date falls outside the validity
// window of HelloTalk's server certificate, HTTPS calls will fail at the TLS handshake — if that
// happens, pick a closer date, or turn وقت مزيف off just for the network-heavy step (signup,
// account creation) and back on after.

// ---- settings screen ----------------------------------------------------------------------------
static NSArray<NSArray *> *htSpoofCities(void) {
    // name, lat, lng
    static NSArray *c;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        c = @[
            @[@"لوس أنجلوس", @34.0522, @-118.2437],
            @[@"سان فرانسيسكو", @37.7749, @-122.4194],
            @[@"سان دييغو", @32.7157, @-117.1611],
            @[@"سكرامنتو", @38.5816, @-121.4944],
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
@property (nonatomic, strong) UILabel *diagStatus;
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
    self.latField = [self coordField];
    self.lngField = [self coordField];
    self.latField.text = [NSString stringWithFormat:@"%.6f", htSpoofLat()];
    self.lngField.text = [NSString stringWithFormat:@"%.6f", htSpoofLng()];
    [col addArrangedSubview:[self fieldRow:@"خط العرض (lat)" field:self.latField]];
    [col addArrangedSubview:[self fieldRow:@"خط الطول (lng)" field:self.lngField]];

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
    self.picker.date = [htRealNowDate() dateByAddingTimeInterval:htSpoofTimeOffset()];
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

    // ---- live self-test: calls the exact same APIs HelloTalk itself would, right here, so you can
    // see directly whether the hooks are actually intercepting anything, independent of whether
    // HelloTalk's own screens happen to show that value anywhere.
    [col addArrangedSubview:[self sectionTitle:@"🔍 اختبار مباشر"]];
    self.diagStatus = [self statusLabel];
    self.diagStatus.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [col addArrangedSubview:self.diagStatus];

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
- (UITextField *)coordField {
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
    return f;
}
- (UIStackView *)fieldRow:(NSString *)label field:(UITextField *)f {
    UILabel *l = [UILabel new];
    l.text = label;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
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
    NSTimeInterval off = [self.picker.date timeIntervalSinceDate:htRealNowDate()];
    [NSUserDefaults.standardUserDefaults setDouble:off forKey:HT_SPOOF_TIME_OFFSET_KEY];
    htSpoofRefreshTimeCache();
    [[UIImpactFeedbackGenerator new] impactOccurred];
    if (!raOn(HT_SPOOF_TIME_ON)) igdToast(@"تم الحفظ — بس خيار \"وقت مزيف\" مطفي من Ra Menu");
    [self refreshStatus];
}
- (void)resetTime {
    [NSUserDefaults.standardUserDefaults setDouble:0 forKey:HT_SPOOF_TIME_OFFSET_KEY];
    htSpoofRefreshTimeCache();
    self.picker.date = htRealNowDate();
    [self refreshStatus];
}
- (void)refreshStatus {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    BOOL locOn = raOn(HT_SPOOF_LOC_ON), timeOn = raOn(HT_SPOOF_TIME_ON);
    NSDate *realNow = htRealNowDate();
    NSDate *wantedFake = [realNow dateByAddingTimeInterval:htSpoofTimeOffset()];
    self.locStatus.text = [NSString stringWithFormat:@"%@ المحفوظ: %.5f, %.5f", locOn ? @"🟢 مفعّل —" : @"⚪️ غير مفعّل —", htSpoofLat(), htSpoofLng()];
    self.timeStatus.text = [NSString stringWithFormat:@"%@ الوقت المطلوب: %@", timeOn ? @"🟢 مفعّل —" : @"⚪️ غير مفعّل —", [fmt stringFromDate:wantedFake]];

    // Live self-test: the exact APIs HelloTalk's own code calls, answered right now.
    NSDate *hooked = NSDate.date;
    CLLocation *liveLoc = [CLLocationManager new].location;
    BOOL timeOK = !timeOn || fabs([hooked timeIntervalSinceDate:wantedFake]) < 5;
    BOOL locOK = !locOn || (liveLoc && fabs(liveLoc.coordinate.latitude - htSpoofLat()) < 0.001 && fabs(liveLoc.coordinate.longitude - htSpoofLng()) < 0.001);

    Method dm = class_getClassMethod(NSDate.class, @selector(date));
    Method lm = class_getInstanceMethod(CLLocationManager.class, @selector(location));
    BOOL dHooked = dm && imp_getBlock(method_getImplementation(dm)) != nil;
    BOOL lHooked = lm && imp_getBlock(method_getImplementation(lm)) != nil;

    NSMutableString *d = [NSMutableString string];
    [d appendFormat:@"الوقت الحقيقي:   %@\n", [fmt stringFromDate:realNow]];
    [d appendFormat:@"NSDate.date:     %@  %@\n", [fmt stringFromDate:hooked], timeOK ? @"✅" : @"❌"];
    [d appendFormat:@"location:        %@  %@\n",
        liveLoc ? [NSString stringWithFormat:@"%.4f, %.4f", liveLoc.coordinate.latitude, liveLoc.coordinate.longitude] : @"nil", locOK ? @"✅" : @"❌"];
    [d appendFormat:@"hook +date: %@   hook location: %@\n", dHooked ? @"✓" : @"✗", lHooked ? @"✓" : @"✗"];
    [d appendFormat:@"cache: on=%d off=%.0fs   ra: loc=%d time=%d\n",
        (int)atomic_load(&gSpoofTimeOnCache), (double)atomic_load(&gSpoofOffsetNanosCache) / 1e9, locOn, timeOn];
    for (NSString *line in [igdStatus() copy])
        if ([line containsString:@"NSDate"] || [line containsString:@"CLLocation"] || [line containsString:@"HTSpoof"]) [d appendFormat:@"%@\n", line];
    self.diagStatus.text = d;
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"التخفي", HT_SPOOF_LOC_ON, @"📍 موقع مزيف", @"يجعل HelloTalk يرى الموقع اللي تحدده إنت (شاشة الموقع والوقت) بدل موقعك الحقيقي — بدون أي صلاحية موقع", NO);
    raRegisterD(@"التخفي", HT_SPOOF_TIME_ON, @"🕐 وقت مزيف", @"يجعل HelloTalk يرى الوقت اللي تحدده إنت (بإزاحة عن وقتك الحقيقي يستمر يتحرك طبيعي) بدل وقت جهازك الفعلي", NO);
    igdRun(@"HTSpoof", BUILD, ^{
        hookLocation();
        hookTime();
        htSpoofRefreshTimeCache();   // prime the atomic cache before anything can call the interposed functions
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htSpoofRefreshTimeCache();   // keeps the cache in sync when the toggle is flipped from Ra Menu itself
        }];
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
