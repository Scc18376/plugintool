// PluginTool — iOS 原生外壳（WebView + 原生插件桥 + 主机直连）
// 编译：clang-18 -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -fblocks -Os -w -c ios/main.m -o build/main.o

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - 内置主机配置

static NSString *const kHostName      = @"香港";
static NSString *const kHostAddr      = @"165.99.43.34";
static NSString *const kHostUser      = @"root";
static NSString *const kHostPubKeyFP  = @"SHA256:UILGXdkSdzucU1CsN3OajdBr+73g5PvTsdtGMoZfwLg";
static const NSInteger kHostPort      = 22;

#pragma mark - SSH 端口探测（getaddrinfo + 非阻塞 connect + 读 banner）

typedef void (^ProbeBlock)(BOOL ok, NSString *banner, NSString *error);

@interface SSHProbe : NSObject
+ (void)probeHost:(NSString *)host port:(NSInteger)port timeout:(NSTimeInterval)timeout completion:(ProbeBlock)completion;
@end

@implementation SSHProbe

+ (void)probeHost:(NSString *)host port:(NSInteger)port timeout:(NSTimeInterval)timeout completion:(ProbeBlock)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *err = nil;
        NSString *banner = nil;
        BOOL ok = NO;

        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = NULL;
        char portbuf[16];
        snprintf(portbuf, sizeof(portbuf), "%ld", (long)port);

        int gai = getaddrinfo([host UTF8String], portbuf, &hints, &res);
        if (gai != 0 || res == NULL) {
            err = [NSString stringWithFormat:@"DNS 解析失败 (%s)", gai_strerror(gai)];
        } else {
            int fd = -1;
            for (struct addrinfo *p = res; p != NULL; p = p->ai_next) {
                fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
                if (fd < 0) continue;
                int flags = fcntl(fd, F_GETFL, 0);
                fcntl(fd, F_SETFL, flags | O_NONBLOCK);
                int r = connect(fd, p->ai_addr, p->ai_addrlen);
                if (r == 0) { ok = YES; break; }
                if (errno == EINPROGRESS) {
                    fd_set wfds; FD_ZERO(&wfds); FD_SET(fd, &wfds);
                    struct timeval tv; tv.tv_sec = (long)timeout; tv.tv_usec = 0;
                    r = select(fd + 1, NULL, &wfds, NULL, &tv);
                    if (r > 0) {
                        int soerr = 0; socklen_t len = sizeof(soerr);
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
                        if (soerr == 0) { ok = YES; break; }
                        err = [NSString stringWithFormat:@"连接被拒绝/超时 (%s)", strerror(soerr)];
                    } else {
                        err = r == 0 ? @"连接超时" : @"select 失败";
                    }
                } else {
                    err = [NSString stringWithFormat:@"connect 失败 (%s)", strerror(errno)];
                }
                close(fd); fd = -1;
            }
            if (res) freeaddrinfo(res);

            if (ok && fd >= 0) {
                // 读 SSH 服务端 banner
                NSMutableData *buf = [NSMutableData data];
                char tmp[512];
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4.0];
                while ([deadline timeIntervalSinceNow] > 0) {
                    fd_set rfds; FD_ZERO(&rfds); FD_SET(fd, &rfds);
                    struct timeval tv; tv.tv_sec = 1; tv.tv_usec = 0;
                    int r = select(fd + 1, &rfds, NULL, NULL, &tv);
                    if (r > 0) {
                        ssize_t n = recv(fd, tmp, sizeof(tmp) - 1, 0);
                        if (n > 0) {
                            tmp[n] = 0;
                            [buf appendBytes:tmp length:(NSUInteger)n];
                            NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
                            if ([s containsString:@"\n"] || [s containsString:@"\r"]) break;
                        } else {
                            break;
                        }
                    } else if (r < 0 && errno != EINTR) {
                        break;
                    }
                }
                banner = [[[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding]
                          stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                close(fd);
                if (banner.length == 0) banner = @"(无 banner)";
            } else if (fd >= 0) {
                close(fd);
            }
        }
        if (!ok && err == nil) err = @"连接失败";

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, banner, err);
        });
    });
}

@end

#pragma mark - 原生桥

static NSString *const kBridgeName = @"native";

@interface PTBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic, weak) UIViewController *host;
- (void)reply:(NSString *)js;
@end

@implementation PTBridge

- (void)reply:(NSString *)js {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = (NSDictionary *)message.body;
    NSString *action = body[@"action"];
    NSDictionary *data = [body[@"data"] isKindOfClass:[NSDictionary class]] ? body[@"data"] : @{};
    NSString *cb = body[@"cb"];

    void (^finish)(id) = ^(id result) {
        if (!cb) return;
        NSData *jd = [NSJSONSerialization dataWithJSONObject:(result ?: [NSNull null]) options:0 error:NULL];
        NSString *js = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : @"null";
        [self reply:[NSString stringWithFormat:@"window.__pt_resolve(%@, %@);", cb, js]];
    };

    if ([action isEqualToString:@"hostInfo"]) {
        finish(@{@"name": kHostName, @"host": kHostAddr, @"port": @(kHostPort),
                 @"user": kHostUser, @"fingerprint": kHostPubKeyFP,
                 @"auth": @"publickey", @"keyFile": @"id_ed25519"});
    } else if ([action isEqualToString:@"sshCommand"]) {
        finish(@{@"cmd": [NSString stringWithFormat:@"ssh -i ~/.ssh/id_ed25519 -p %ld %@@%@",
                          (long)kHostPort, kHostUser, kHostAddr]});
    } else if ([action isEqualToString:@"pingSSH"]) {
        NSString *host = data[@"host"] ?: kHostAddr;
        NSInteger port = data[@"port"] ? [data[@"port"] integerValue] : kHostPort;
        [SSHProbe probeHost:host port:port timeout:6.0 completion:^(BOOL ok, NSString *banner, NSString *error) {
            finish(@{@"ok": @(ok), @"banner": banner ?: @"", @"error": error ?: @""});
        }];
    } else if ([action isEqualToString:@"deviceInfo"]) {
        UIDevice *d = [UIDevice currentDevice];
        finish(@{@"model": d.model, @"name": d.name, @"system": [NSString stringWithFormat:@"%@ %@", d.systemName, d.systemVersion],
                 @"idiom": @(d.userInterfaceIdiom), @"scale": @([UIScreen mainScreen].scale)});
    } else if ([action isEqualToString:@"copy"]) {
        [UIPasteboard generalPasteboard].string = data[@"text"] ?: @"";
        finish(@{@"ok": @(YES)});
    } else if ([action isEqualToString:@"paste"]) {
        finish(@{@"text": [UIPasteboard generalPasteboard].string ?: @""});
    } else if ([action isEqualToString:@"openURL"]) {
        NSURL *u = [NSURL URLWithString:data[@"url"] ?: @""];
        BOOL ok = NO;
        if (u) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            ok = YES;
        }
        finish(@{@"ok": @(ok)});
    } else if ([action isEqualToString:@"toast"]) {
        NSString *msg = data[@"text"] ?: @"";
        UIWindow *win = self.host.view.window ?: UIApplication.sharedApplication.keyWindow;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
        l.text = [NSString stringWithFormat:@"  %@  ", msg];
        l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        l.textColor = UIColor.whiteColor;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        [l sizeToFit];
        CGRect f = l.frame;
        f.size.width = MIN(f.size.width, win.bounds.size.width - 60);
        f.size.height = MAX(f.size.height, 36);
        f.origin.x = (win.bounds.size.width - f.size.width) / 2;
        f.origin.y = win.bounds.size.height - f.size.height - 90;
        l.frame = f;
        l.layer.cornerRadius = 10;
        l.clipsToBounds = YES;
        [win addSubview:l];
        l.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:1.4 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL fin) { [l removeFromSuperview]; }];
        }];
        finish(@{@"ok": @(YES)});
    } else if ([action isEqualToString:@"vibrate"]) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [g impactOccurred];
        finish(@{@"ok": @(YES)});
    } else if ([action isEqualToString:@"exitApp"]) {
        finish(@{@"ok": @(YES)});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    } else {
        finish(@{@"ok": @(NO), @"error": [NSString stringWithFormat:@"未知动作: %@", action ?: @"(null)"]});
    }
}

@end

#pragma mark - 主控制器（WKWebView 外壳）

@interface PTViewController : UIViewController <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) PTBridge *bridge;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation PTViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1.0];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = YES;

    // 原生桥 + 注入 window.pt
    PTBridge *bridge = [[PTBridge alloc] init];
    self.bridge = bridge;
    WKUserContentController *ucc = cfg.userContentController;
    [ucc addScriptMessageHandler:bridge name:kBridgeName];
    NSString *js = @"window.__pt_cbs={};window.__pt_seq=0;"
                   "window.__pt_resolve=function(id,v){var f=window.__pt_cbs[id];if(f){delete window.__pt_cbs[id];try{f(v);}catch(e){}}};"
                   "window.pt=function(action,data){return new Promise(function(res,rej){"
                   "var id='cb'+(++window.__pt_seq);window.__pt_cbs[id]=res;"
                   "try{window.webkit.messageHandlers.native.postMessage({action:action,data:data||{},cb:id});}"
                   "catch(e){delete window.__pt_cbs[id];rej(e);}});};"
                   "window.__PT_NATIVE__=true;";
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    bridge.webView = nil;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.navigationDelegate = self;
    wv.UIDelegate = self;
    wv.opaque = NO;
    wv.backgroundColor = self.view.backgroundColor;
    wv.scrollView.bounces = YES;
    wv.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:wv];
    self.webView = wv;
    bridge.webView = wv;
    bridge.host = self;

    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.color = UIColor.whiteColor;
    sp.center = self.view.center;
    sp.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                          UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:sp];
    self.spinner = sp;
    [sp startAnimating];

    [self loadLocalIndex];
}

- (void)loadLocalIndex {
    NSString *www = [[NSBundle mainBundle] pathForResource:@"www" ofType:nil];
    NSString *index = [www stringByAppendingPathComponent:@"index.html"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (www && [fm fileExistsAtPath:index]) {
        NSURL *dir = [NSURL fileURLWithPath:www isDirectory:YES];
        [self.webView loadFileURL:[NSURL fileURLWithPath:index] allowingReadAccessToURL:dir];
    } else {
        NSString *fallback = @"<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
                             "<style>body{background:#0d0f14;color:#e8eaf0;font:16px -apple-system;padding:40px 24px;text-align:center}</style></head>"
                             "<body><h2>PluginTool</h2><p>www/index.html 未打包进 Bundle。</p></body></html>";
        [self.webView loadHTMLString:fallback baseURL:nil];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (action.navigationType == WKNavigationTypeLinkActivated &&
        ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.webView.frame = self.view.bounds;
    self.spinner.center = self.view.center;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

@end

#pragma mark - AppDelegate

@interface PTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation PTAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    PTViewController *vc = [[PTViewController alloc] init];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {}
- (void)applicationWillTerminate:(UIApplication *)application {}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([PTAppDelegate class]));
    }
}
