// HTDict: an English dictionary lookup, fully independent of HelloTalk's own account/servers —
// opened from the "📖 القاموس" button in Ra Menu's footer (ra.dict notification). Rewritten from
// HTMenu.m's original dictionary screen to plug into the shared Ra Menu instead of its own overlay
// button/window.
#import "igd_common.h"
#define BUILD @"dict1"

@interface HTDictVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *meanings;
@end

@implementation HTDictVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"القاموس";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    self.field = [UITextField new];
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.placeholder = @"اكتب كلمة إنجليزية...";
    self.field.textAlignment = NSTextAlignmentRight;
    self.field.returnKeyType = UIReturnKeySearch;
    self.field.delegate = self;
    self.field.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.field];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.field.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.field.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.field.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.field.heightAnchor constraintEqualToConstant:40],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:12],
        [self.table.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:8],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self search:tf.text]; return YES; }

- (void)search:(NSString *)word {
    word = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!word.length) return;
    self.meanings = @[];
    [self.table reloadData];
    [self.spinner startAnimating];
    NSString *esc = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.dictionaryapi.dev/api/v2/entries/en/%@", esc]];
    if (!url) { [self.spinner stopAnimating]; return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (err || !data) { self.meanings = @[@{@"definition": @"تعذر الاتصال — تأكد من الإنترنت."}]; [self.table reloadData]; return; }
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]] || !json.count) { self.meanings = @[@{@"definition": @"ما لقيت الكلمة."}]; [self.table reloadData]; return; }
            NSMutableArray *flat = [NSMutableArray new];
            for (NSDictionary *entry in json) for (NSDictionary *m in entry[@"meanings"]) {
                NSString *pos = m[@"partOfSpeech"] ?: @"";
                for (NSDictionary *d in m[@"definitions"]) [flat addObject:@{@"pos": pos, @"definition": d[@"definition"] ?: @"", @"example": d[@"example"] ?: @""}];
            }
            self.meanings = flat.count ? flat : @[@{@"definition": @"ما فيه تعريف متوفر."}];
            [self.table reloadData];
        });
    }];
    [t resume];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.meanings.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *m = self.meanings[ip.row];
    NSString *txt = m[@"definition"];
    if ([m[@"pos"] length]) txt = [NSString stringWithFormat:@"(%@) %@", m[@"pos"], txt];
    if ([m[@"example"] length]) txt = [txt stringByAppendingFormat:@"\n— %@", m[@"example"]];
    c.textLabel.numberOfLines = 0;
    c.textLabel.text = txt;
    c.textLabel.font = [UIFont systemFontOfSize:15];
    return c;
}
@end

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الإضافات", @"ht.dict", @"القاموس", @"بحث إنجليزي مستقل تماماً عن حساب أو سيرفرات HelloTalk — زر 📖 بأسفل Ra Menu", YES);
    igdRun(@"HTDict", BUILD, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:@"ra.dict" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (!raOn(@"ht.dict")) { igdToast(@"القاموس مطفي من Ra Menu"); return; }
            UIViewController *top = raTop();
            if (!top) return;
            HTDictVC *vc = [HTDictVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [top presentViewController:nav animated:YES completion:nil];
        }];
    });
}
