// HTSave: save chat photos, Moments photos, and voice messages — written from scratch.
// Two different techniques, each the most reliable one available from static analysis:
//
// 1) Photos (chat bubbles + Moments): HelloTalk's own cell classes (ImageCell, HomeMomentCell,
//    MomentDetailContainerView) are Swift with no exposed image-URL property, but every one of
//    them ultimately puts the decoded photo in a plain UIImageView. So instead of reverse
//    engineering each cell, this hooks -[UIImageView setImage:] once, globally, and only acts
//    when the image is large enough to be real content AND sits inside one of those specific
//    cell classes (checked by walking up the view hierarchy) — never on avatars, icons or ads.
// 2) Voice messages: HelloTalk plays them with the system's own AVAudioPlayer. Hooking
//    -[AVAudioPlayer initWithContentsOfURL:...] captures the exact local file HelloTalk just
//    asked iOS to play, with no need to know VoiceCell's internal layout at all.
#import "igd_common.h"
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#define BUILD @"sv1"

static const void *kHeldKey = &kHeldKey;
static NSURL *gLastVoiceURL;

static void saveImage(UIImage *img) {
    if (!img) { igdToast(@"ما لقيت صورة"); return; }
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        [PHAssetCreationRequest creationRequestForAssetFromImage:img];
    } completionHandler:^(BOOL ok, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ igdToast(ok ? @"تم حفظ الصورة بالصور" : @"فشل الحفظ"); });
    }];
}

// ---- walk up the view hierarchy looking for one of the known content-cell classes ----------
static BOOL ancestorIs(UIView *v, NSString *prefix, int maxDepth) {
    for (UIView *p = v; p && maxDepth > 0; p = p.superview, maxDepth--)
        if ([NSStringFromClass(p.class) containsString:prefix]) return YES;
    return NO;
}

@interface HTSaveHold : NSObject
+ (void)hold:(UILongPressGestureRecognizer *)g;
@end
@implementation HTSaveHold
+ (void)hold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIImageView *iv = (UIImageView *)g.view;
    if (objc_getAssociatedObject(iv, kHeldKey)) return;
    objc_setAssociatedObject(iv, kHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(iv, kHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    [[UIImpactFeedbackGenerator new] impactOccurred];
    saveImage(iv.image);
}
@end

static void maybeAddHold(UIImageView *iv) {
    for (UIGestureRecognizer *g in iv.gestureRecognizers) if ([g.name isEqualToString:@"ht.save"]) return;
    BOOL inChat = raOn(@"ht.save.chatimg") && ancestorIs(iv, @"ImageCell", 6) && !ancestorIs(iv, @"ImagePickerGridViewCell", 6);
    BOOL inMoment = raOn(@"ht.save.moments") && (ancestorIs(iv, @"MomentDetailContainerView", 8) || ancestorIs(iv, @"HomeMomentCell", 8));
    if (!inChat && !inMoment) return;
    iv.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[HTSaveHold class] action:@selector(hold:)];
    lp.name = @"ht.save";
    lp.minimumPressDuration = 0.45;
    lp.cancelsTouchesInView = NO;
    [iv addGestureRecognizer:lp];
}

static void hookImageView(void) {
    igdHook("UIImageView", "setImage:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 1) return nil;
        return ^(UIImageView *self, UIImage *img) {
            ((void (*)(id, SEL, id))orig)(self, s, img);
            if (img.size.width * img.size.height < 120 * 120) return;      // skip avatars/icons
            dispatch_async(dispatch_get_main_queue(), ^{ maybeAddHold(self); });
        };
    });
}

// ---- voice messages ---------------------------------------------------------------------
static void hookVoicePlayer(void) {
    Class c = objc_getClass("AVAudioPlayer");
    SEL sel = @selector(initWithContentsOfURL:error:);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { [igdStatus() addObject:@"✗ AVAudioPlayer initWithContentsOfURL:error: (no method)"]; return; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^id(AVAudioPlayer *self, NSURL *url, NSError **err) {
        id r = ((id (*)(id, SEL, id, NSError **))orig)(self, sel, url, err);
        if (raOn(@"ht.save.voice")) gLastVoiceURL = url;
        return r;
    }));
    [igdStatus() addObject:@"✓ AVAudioPlayer initWithContentsOfURL:error:"];
}

@interface HTVoiceHold : NSObject
+ (void)hold:(UILongPressGestureRecognizer *)g;
@end
@implementation HTVoiceHold
+ (void)hold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!raOn(@"ht.save.voice")) return;
    if (!gLastVoiceURL) { igdToast(@"شغّل الرسالة الصوتية أول مرة، ثم اضغط مطوّل عليها"); return; }
    [[UIImpactFeedbackGenerator new] impactOccurred];
    UIViewController *top = raTop();
    if (!top) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[gLastVoiceURL] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = g.view;
    [top presentViewController:sheet animated:YES completion:nil];
}
@end

static void hookVoiceCell(void) {
    const char *C = "_TtC6HTChat9VoiceCell";
    igdHook(C, "initWithCoder:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^id(UIView *self, id coder) {
            id r = ((id (*)(id, SEL, id))orig)(self, s, coder);
            for (UIGestureRecognizer *g in self.gestureRecognizers) if ([g.name isEqualToString:@"ht.voice"]) return r;
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[HTVoiceHold class] action:@selector(hold:)];
            lp.name = @"ht.voice";
            lp.minimumPressDuration = 0.45;
            lp.cancelsTouchesInView = NO;
            [self addGestureRecognizer:lp];
            return r;
        };
    });
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"التنزيل", @"ht.save.chatimg", @"حفظ صور المحادثة بالضغط المطوّل",
               @"اضغط مطوّل على أي صورة بالشات لحفظها بالصور");
    raRegister(@"التنزيل", @"ht.save.moments", @"حفظ صور Moments بالضغط المطوّل",
               @"اضغط مطوّل على أي صورة بالـ Moments لحفظها بالصور");
    raRegister(@"التنزيل", @"ht.save.voice", @"حفظ الرسايل الصوتية",
               @"شغّل الرسالة الصوتية مرة، ثم اضغط مطوّل عليها — تطلع قائمة مشاركة/حفظ (الصوت ما يُحفظ بتطبيق الصور، فقط عبر Files أو مشاركة)");
    igdRun(@"HTSave", BUILD, ^{ hookImageView(); hookVoicePlayer(); hookVoiceCell(); });
}
