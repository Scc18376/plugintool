// TencentVideo iOS 壳 — 以网页通道复刻 APK 的主要功能
// clang-18 -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -fblocks -Os -w -c ios/main.m -o build/main.o

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static NSString *const kHomeURL = @"https://v.qq.com/";
static NSString *const kUAiPhone = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

#pragma mark - 工具条按钮

@interface TVButton : UIButton
@end

@implementation TVButton
- (instancetype)initWithTitle:(NSString *)t {
    if ((self = [super initWithFrame:CGRectZero])) {
        [self setTitle:t forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [self setTitleColor:[UIColor colorWithWhite:0.62 alpha:1] forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    }
    return self;
}
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; self.alpha = h ? 0.5 : 1.0; }
@end

#pragma mark - 主控制器

@interface TVViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) AVRoutePickerView *airplay;
@property (nonatomic, assign) BOOL didFirstLoad;
@property (nonatomic, strong) NSArray *toolbarButtons;
@end

@implementation TVViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.didFirstLoad = NO;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    cfg.suppressesIncrementalRendering = NO;
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    // 画中画 / 后台音频（WebKit 私有键，iOS 14+ 可用）
    @try {
        [cfg.preferences setValue:@YES forKey:@"_allowsPictureInPictureMediaPlayback"];
    } @catch (NSException *e) {}

    // 注入：强制 inline 播放 + 干掉 App 下载浮层 + 全屏视频
    NSString *js =
    @"(function(){"
    @"var s=document.createElement('style');"
    @"s.textContent='.txp_app_download,.app-download,.download-bar,[class*=downloadbar],[id*=downloadbar]{display:none!important}';"
    @"document.documentElement.appendChild(s);"
    @"document.addEventListener('DOMContentLoaded',function(){"
    @"var v=document.querySelectorAll('video');"
    @"for(var i=0;i<v.length;i++){v[i].setAttribute('playsinline','');v[i].setAttribute('webkit-playsinline','');v[i].setAttribute('x5-playsinline','');}"
    @"});"
    @"setInterval(function(){var v=document.querySelectorAll('video');for(var i=0;i<v.length;i++){if(!v[i].hasAttribute('playsinline')){v[i].setAttribute('playsinline','');v[i].setAttribute('webkit-playsinline','');}}},1500);"
    @"})();";
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:js
                                                                 injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                              forMainFrameOnly:NO]];

    WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    wv.navigationDelegate = self;
    wv.UIDelegate = self;
    wv.allowsBackForwardNavigationGestures = YES;
    wv.customUserAgent = kUAiPhone;
    wv.opaque = NO;
    wv.backgroundColor = [UIColor blackColor];
    wv.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    if ([wv respondsToSelector:@selector(setAllowsLinkPreview:)]) wv.allowsLinkPreview = YES;
    [self.view addSubview:wv];
    self.webView = wv;

    // 进度条
    UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    pv.progressTintColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.1 alpha:1.0];
    pv.trackTintColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    [self.view addSubview:pv];
    self.progress = pv;
    [wv addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:NULL];

    // 加载圈
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    sp.color = [UIColor whiteColor];
    sp.hidesWhenStopped = YES;
    [self.view addSubview:sp];
    self.spinner = sp;

    [self buildToolbar];
    [wv loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kHomeURL]]];
}

- (void)buildToolbar {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    [self.view addSubview:bar];
    self.toolbar = bar;

    NSArray *titles = @[@"后退", @"前进", @"首页", @"刷新", @"搜索"];
    SEL sels[] = {@selector(goBack), @selector(goForward), @selector(goHome), @selector(reload), @selector(openSearch)};
    NSMutableArray *btns = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        TVButton *b = [[TVButton alloc] initWithTitle:titles[i]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [b addTarget:self action:sels[i] forControlEvents:UIControlEventTouchUpInside];
#pragma clang diagnostic pop
        [bar addSubview:b];
        [btns addObject:b];
    }

    // AirPlay 投屏按钮（对应 APK 的投屏功能）
    AVRoutePickerView *rp = [[AVRoutePickerView alloc] initWithFrame:CGRectZero];
    rp.tintColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    rp.activeTintColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.1 alpha:1.0];
    rp.prioritizesVideoDevices = YES;
    [bar addSubview:rp];
    self.airplay = rp;

    self.toolbarButtons = btns;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeB = self.view.safeAreaInsets.bottom;
    CGFloat barH = 50 + safeB;

    self.toolbar.frame = CGRectMake(0, h - barH, w, barH);
    self.webView.frame = CGRectMake(0, self.view.safeAreaInsets.top > 0 ? 0 : 0, w, h - barH);
    self.progress.frame = CGRectMake(0, 0, w, 2);
    self.spinner.center = CGPointMake(w / 2, h / 2 - 40);

    NSUInteger n = self.toolbarButtons.count;
    CGFloat slot = w / (n + 1);
    for (NSUInteger i = 0; i < n; i++) {
        UIButton *b = self.toolbarButtons[i];
        b.frame = CGRectMake(slot * i, 4, slot, 42);
    }
    self.airplay.frame = CGRectMake(slot * n + slot * 0.2, 2, slot * 0.6, 44);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        float p = [change[NSKeyValueChangeNewKey] floatValue];
        self.progress.progress = p;
        self.progress.hidden = (p >= 1.0);
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

#pragma mark 动作

- (void)goBack { if (self.webView.canGoBack) [self.webView goBack]; }
- (void)goForward { if (self.webView.canGoForward) [self.webView goForward]; }
- (void)goHome { [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kHomeURL]]]; }
- (void)reload { [self.webView reload]; }
- (void)openSearch {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"搜索"
                                                              message:@"输入片名 / 演员"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"例如：三体"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *q = ac.textFields.firstObject.text ?: @"";
        NSString *esc = [q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"https://v.qq.com/x/search/?q=%@", esc]];
        if (u) [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark 导航

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    [self.spinner stopAnimating];
    self.didFirstLoad = YES;
    self.titleLabel.text = wv.title;
}

- (void)webView:(WKWebView *)wv didStartProvisionalNavigation:(WKNavigation *)n {
    [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)wv didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e {
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)n withError:(NSError *)e {}

- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)action
                                          decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *u = action.request.URL;
    NSString *scheme = u.scheme.lowercaseString;
    // 拦截唤起 App / App Store / itms
    NSArray *blocked = @[@"itms", @"itms-apps", @"itms-services", @"vqq", @"tenvideo", @"tencentvideo", @"weixin", @"alipay"];
    if (scheme && [blocked containsObject:scheme]) {
        handler(WKNavigationActionPolicyCancel);
        return;
    }
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        NSString *h = u.host.lowercaseString ?: @"";
        if ([h hasSuffix:@"apps.apple.com"] || [h containsString:@"itunes.apple.com"]) {
            handler(WKNavigationActionPolicyCancel);
            return;
        }
        if (action.navigationType == WKNavigationTypeLinkActivated && ![h hasSuffix:@"qq.com"]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            handler(WKNavigationActionPolicyCancel);
            return;
        }
    }
    handler(WKNavigationActionPolicyAllow);
}

// 新窗口（target=_blank）在本窗口打开，避免白屏
- (WKWebView *)webView:(WKWebView *)wv createWebViewWithConfiguration:(WKWebViewConfiguration *)c
          forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)f {
    if (!action.targetFrame.isMainFrame) {
        [wv loadRequest:action.request];
    }
    return nil;
}

#pragma mark 下载（对应 APK 的离线缓存入口）

- (void)webView:(WKWebView *)wv decidePolicyForNavigationResponse:(WKNavigationResponse *)resp
                                                decisionHandler:(void (^)(WKNavigationResponsePolicy))handler {
    if ([resp.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSString *cdn = ((NSHTTPURLResponse *)resp.response).allHeaderFields[@"Content-Disposition"];
        if (cdn && [cdn containsString:@"attachment"]) {
            handler(WKNavigationResponsePolicyDownload);
            return;
        }
    }
    handler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)wv navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)d {
    d.delegate = self;
}

- (void)webView:(WKWebView *)wv navigationResponse:(WKNavigationResponse *)resp didBecomeDownload:(WKDownload *)d {
    d.delegate = self;
}

- (void)download:(WKDownload *)d decideDestinationUsingResponse:(NSURLResponse *)r
 suggestedFilename:(NSString *)name completionHandler:(void (^)(NSURL * _Nullable))handler {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dst = [dir URLByAppendingPathComponent:name ?: @"download.bin"];
    handler(dst);
}

- (void)downloadDidFinish:(WKDownload *)d {}

@end

#pragma mark - AppDelegate

@interface TVAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TVAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[TVViewController alloc] init];
    [self.window makeKeyAndVisible];
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TVAppDelegate class]));
    }
}
