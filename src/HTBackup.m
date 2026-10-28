// HTBackup: exports every FocusMode/Ra Menu setting (every "ra.*"/"ht.*" NSUserDefaults key —
// toggles, saved language pairs, remembered API key, etc.) to a JSON file via the share sheet, and
// imports one back the same way — so a reinstall or a new device doesn't mean redoing every Ra
// Menu toggle by hand. "💾 نسخ احتياطي" button in Ra Menu's footer.
#import "igd_common.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#define BUILD @"backup1"

static NSDictionary *htBackupCollect(void) {
    NSMutableDictionary *out = [NSMutableDictionary new];
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    for (NSString *k in all) {
        if (![k hasPrefix:@"ra."] && ![k hasPrefix:@"ht."]) continue;
        id v = all[k];
        if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSArray class]]) out[k] = v;
    }
    return out;
}

@interface HTBackupDocDelegate : NSObject <UIDocumentPickerDelegate>
@end
@implementation HTBackupDocDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL secure = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (secure) [url stopAccessingSecurityScopedResource];
    if (!data) { igdToast(@"ما قدرت أقرأ الملف"); return; }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) { igdToast(@"الملف مو بصيغة صحيحة"); return; }
    NSDictionary *dict = (NSDictionary *)obj;
    NSInteger n = 0;
    for (NSString *k in dict) {
        if (![k hasPrefix:@"ra."] && ![k hasPrefix:@"ht."]) continue;
        [NSUserDefaults.standardUserDefaults setObject:dict[k] forKey:k];
        n++;
    }
    igdToast([NSString stringWithFormat:@"تم استرجاع %ld إعداد — أعد فتح التطبيق", (long)n]);
}
@end
static HTBackupDocDelegate *gDocDelegate;   // kept alive for the lifetime of the picker

static void htBackupExport(void) {
    UIViewController *top = raTop();
    if (!top) return;
    NSDictionary *dict = htBackupCollect();
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) { igdToast(@"تعذر تجهيز النسخة الاحتياطية"); return; }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FocusMode-backup.json"];
    [data writeToFile:path atomically:YES];
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    av.popoverPresentationController.sourceView = top.view;
    av.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height, 1, 1);
    [top presentViewController:av animated:YES completion:nil];
}
static void htBackupImport(void) {
    UIViewController *top = raTop();
    if (!top) return;
    gDocDelegate = [HTBackupDocDelegate new];
    UIDocumentPickerViewController *p;
    if (@available(iOS 14.0, *)) {
        p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON]];
    } else {
        p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.json"] inMode:UIDocumentPickerModeImport];
    }
    p.delegate = gDocDelegate;
    [top presentViewController:p animated:YES completion:nil];
}
static void htBackupAsk(void) {
    UIViewController *top = raTop();
    if (!top) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"نسخ احتياطي للإعدادات"
        message:@"يحفظ كل تفضيلات Ra Menu وإعدادات الأدوات (التشغيل/الإيقاف، لغاتك المحفوظة، مفتاح Merriam-Webster...) بملف JSON واحد"
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"تصدير" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { htBackupExport(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"استيراد" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { htBackupImport(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = top.view;
    a.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height, 1, 1);
    [top presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void init(void) {
    igdRun(@"HTBackup", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.backup" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htBackupAsk();
        }];
    });
}
