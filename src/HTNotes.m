// HTNotes: a tiny personal scratchpad, independent of HelloTalk's own data — one autosaving note,
// reachable from "📝 ملاحظاتي" in Ra Menu's footer.
#import "igd_common.h"
#define BUILD @"notes1"
#define HT_NOTES_KEY @"ht.notes.text"

@interface HTNotesVC : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UITextView *text;
@property (nonatomic, strong) NSTimer *debounce;
@end
@implementation HTNotesVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"ملاحظاتي";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.text = [UITextView new];
    self.text.delegate = self;
    self.text.font = [UIFont systemFontOfSize:16];
    self.text.textColor = UIColor.labelColor;
    self.text.backgroundColor = UIColor.systemBackgroundColor;
    self.text.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.text.text = [NSUserDefaults.standardUserDefaults stringForKey:HT_NOTES_KEY] ?: @"";
    self.text.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.text];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.text.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.text.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
}
- (void)close { [self.debounce invalidate]; [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)textViewDidChange:(UITextView *)tv {
    [self.debounce invalidate];
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *t) { [self save]; }];
}
- (void)save {
    [NSUserDefaults.standardUserDefaults setObject:self.text.text ?: @"" forKey:HT_NOTES_KEY];
}
@end

__attribute__((constructor)) static void init(void) {
    igdRun(@"HTNotes", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.notes" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *top = raTop();
            if (!top) return;
            HTNotesVC *vc = [HTNotesVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
