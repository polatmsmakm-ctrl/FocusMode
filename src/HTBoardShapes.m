// HTBoardShapes — ready-made shapes and stamps for the HelloTalk live-class whiteboard (Netless/Fastboard).
// A small floating button appears on the whiteboard; tapping it opens a sheet with:
//   * ready shapes  -> switches the whiteboard's shape tool to that shape (you then drag to draw it)
//   * ready stamps  -> drops an emoji stamp (⭐ ❤️ ✅ ❌ …) on the board through WhiteRoom insertText
#import "igd_common.h"

#define HT_BOARD_ON @"ht.board.shapes"
#ifndef HT_BOARD_BUILD
#define HT_BOARD_BUILD @"boardshapes1"
#endif

static __weak id gBoardRoom;          // last WhiteRoom created by the SDK
static const void *kBoardBtnKey = &kBoardBtnKey;

// ---- helpers: talk to the Whiteboard framework dynamically (no headers needed) ----
static void htBoardSetShape(NSString *shapeType) {
    id room = gBoardRoom;
    Class ms = NSClassFromString(@"WhiteMemberState");
    if (!room || !ms) { igdToast(@"السبورة غير جاهزة بعد"); return; }
    id st = [ms new];
    ((void (*)(id, SEL, id))objc_msgSend)(st, sel_registerName("setCurrentApplianceName:"), @"shape");
    ((void (*)(id, SEL, id))objc_msgSend)(st, sel_registerName("setShapeType:"), shapeType);
    ((void (*)(id, SEL, id))objc_msgSend)(room, sel_registerName("setMemberState:"), st);
}

static void htBoardStamp(NSString *glyph) {
    id room = gBoardRoom;
    Class ms = NSClassFromString(@"WhiteMemberState");
    if (!room) { igdToast(@"السبورة غير جاهزة بعد"); return; }
    if (ms) {   // bigger text so the stamp is easy to see
        id st = [ms new];
        ((void (*)(id, SEL, id))objc_msgSend)(st, sel_registerName("setTextSize:"), @(64));
        ((void (*)(id, SEL, id))objc_msgSend)(room, sel_registerName("setMemberState:"), st);
    }
    CGFloat x = -60 + (arc4random_uniform(160) - 80);
    CGFloat y = -60 + (arc4random_uniform(160) - 80);
    ((void (*)(id, SEL, CGFloat, CGFloat, id, id))objc_msgSend)(
        room, sel_registerName("insertText:y:textContent:completionHandler:"), x, y, glyph, nil);
}

static void htBoardShowMenu(UIView *anchor) {
    UIViewController *top = igdTopVC();
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"رسمات جاهزة" message:@"اختر شكل أو ملصق" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *shapes = @[@[@"▭ مستطيل", @"rectangle"], @[@"◯ دائرة", @"ellipse"], @[@"△ مثلث", @"triangle"],
                        @[@"◇ معين", @"rhombus"], @[@"★ نجمة", @"pentagram"], @[@"💬 فقاعة كلام", @"speechBalloon"],
                        @[@"➜ سهم", @"arrow"], @[@"／ خط مستقيم", @"straight"]];
    for (NSArray *s in shapes)
        [ac addAction:[UIAlertAction actionWithTitle:s[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { htBoardSetShape(s[1]); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"ملصقات ⭐ ❤️ ✅ ❌ …" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIAlertController *st = [UIAlertController alertControllerWithTitle:@"ملصقات" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *g in @[@"⭐", @"❤️", @"✅", @"❌", @"❓", @"❗", @"👍", @"😀", @"➡️", @"⬆️", @"🔴", @"🟢"])
            [st addAction:[UIAlertAction actionWithTitle:g style:UIAlertActionStyleDefault handler:^(UIAlertAction *b) { htBoardStamp(g); }]];
        [st addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        st.popoverPresentationController.sourceView = anchor;
        st.popoverPresentationController.sourceRect = anchor.bounds;
        [igdTopVC() presentViewController:st animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = anchor;
    ac.popoverPresentationController.sourceRect = anchor.bounds;
    [top presentViewController:ac animated:YES completion:nil];
}

@interface HTBoardBtnTarget : NSObject
+ (instancetype)shared;
- (void)tap:(UIButton *)b;
@end
@implementation HTBoardBtnTarget
+ (instancetype)shared { static HTBoardBtnTarget *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [HTBoardBtnTarget new]; }); return t; }
- (void)tap:(UIButton *)b { htBoardShowMenu(b); }
@end

static void htBoardAttachButton(UIView *board) {
    if (!raOn(HT_BOARD_ON)) return;
    if (objc_getAssociatedObject(board, kBoardBtnKey)) return;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"🔷" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:22];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    b.layer.cornerRadius = 22;
    b.layer.shadowOpacity = 0.25; b.layer.shadowRadius = 4; b.layer.shadowOffset = CGSizeMake(0, 2);
    b.frame = CGRectMake(12, 12, 44, 44);
    b.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
    [b addTarget:HTBoardBtnTarget.shared action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    [board addSubview:b];
    objc_setAssociatedObject(board, kBoardBtnKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الفصول", HT_BOARD_ON, @"🔷 رسمات جاهزة بالسبورة", @"يضيف زر فوق سبورة الفصول المباشرة فيه أشكال جاهزة (نجمة، سهم، فقاعة…) وملصقات (⭐ ❤️ ✅ ❌)", YES);
    igdRun(@"HTBoardShapes", HT_BOARD_BUILD, ^{
        igdHook("WhiteRoom", "initWithUuid:bridge:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (nargs != 2) return nil;
            return ^id(id self, id uuid, id bridge) {
                id r = ((id (*)(id, SEL, id, id))orig)(self, s, uuid, bridge);
                gBoardRoom = r;
                return r;
            };
        });
        igdHook("WhiteBoardView", "didMoveToWindow", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (nargs != 0) return nil;
            return ^void(UIView *self) {
                ((void (*)(id, SEL))orig)(self, s);
                if (self.window) htBoardAttachButton(self);
            };
        });
    });
}
