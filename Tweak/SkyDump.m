// SkyDump.dylib —— 只读诊断：把目标 App 里 WKWebView 的页面结构导出来
// 用途：拿到 SkyCam 面板的真实 HTML/CSS/类名，之后写精确换肤 CSS
// 行为：不修改任何页面、不 hook 业务逻辑，只旁路监听 + 抓快照
//
// 日志/数据通道：TCP 到 PC 的 9805（默认 192.168.10.2:9805，可用 UserDefaults key SKYDumpHost 覆盖）
// 本地落盘：NSTemporaryDirectory()/skydump.json

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <string.h>
#import <unistd.h>

static int g_sock = -1;
static NSString* g_host = nil;
static int g_port = 9805;
static NSMutableSet* g_seen = nil;

static void SkyLog(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SKYD] %@", s);
    if (g_sock >= 0) {
        NSString* line = [s stringByAppendingString:@"\n"];
        const char* p = line.UTF8String;
        send(g_sock, p, strlen(p), 0);
    }
}

static void SkyEnsureConn(void) {
    if (g_sock >= 0) return;
    if (!g_host) {
        NSString* h = [[NSUserDefaults standardUserDefaults] stringForKey:@"SKYDumpHost"];
        g_host = h.length ? h : @"192.168.10.2";
    }
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return;
    struct timeval tv = { 1, 0 };
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_port = htons(g_port);
    a.sin_addr.s_addr = inet_addr(g_host.UTF8String);
    int one = 1; setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) != 0) { close(s); return; }
    g_sock = s;
    SkyLog(@"connected %@:%d", g_host, g_port);
}

static void SkySendChunks(NSString* tag, NSString* text) {
    NSData* d = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString* b64 = [d base64EncodedStringWithOptions:0];
    SkyLog(@"%@ bytes=%lu b64=%lu", tag, (unsigned long)d.length, (unsigned long)b64.length);
    SkyEnsureConn();
    if (g_sock < 0) return;
    NSString* head = [NSString stringWithFormat:@"BEGIN %@ %lu\n", tag, (unsigned long)b64.length];
    send(g_sock, head.UTF8String, strlen(head.UTF8String), 0);
    NSUInteger step = 700;
    for (NSUInteger i = 0; i < b64.length; i += step) {
        NSUInteger n = MIN(step, b64.length - i);
        NSString* part = [NSString stringWithFormat:@"D %@\n", [b64 substringWithRange:NSMakeRange(i, n)]];
        const char* p = part.UTF8String;
        ssize_t off = 0; ssize_t len = (ssize_t)strlen(p);
        while (off < len) { ssize_t w = send(g_sock, p + off, len - off, 0); if (w <= 0) break; off += w; }
        usleep(1500);
    }
    const char* end = "END\n";
    send(g_sock, end, 4, 0);
}

static void SkyDumpNow(WKWebView* wv) {
    if (!wv) return;
    NSString* js =
        @"JSON.stringify({"
         "href:location.href,"
         "title:document.title,"
         "html:document.documentElement?document.documentElement.outerHTML:'',"
         "styles:(function(){var o=[];var ss=document.styleSheets;for(var i=0;i<ss.length;i++){try{var r=ss[i].cssRules;for(var j=0;j<r.length;j++){o.push(r[j].cssText);}}catch(e){o.push('/*'+e.message+'*/');}}return o.join('\\n');})()"
        "})";
    dispatch_async(dispatch_get_main_queue(), ^{
        [wv evaluateJavaScript:js completionHandler:^(id res, NSError* err) {
            if (err) { SkyLog(@"js err %@", err.localizedDescription); return; }
            NSString* s = [res isKindOfClass:[NSString class]] ? res : [res description];
            NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"skydump.json"];
            [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            SkyLog(@"snapshot %@ len=%lu -> %@", wv.URL.absoluteString ?: @"?", (unsigned long)s.length, path);
            SkySendChunks(@"SKYDUMP", s);
        }];
    });
}

static void SkyScheduleDumps(WKWebView* wv) {
    NSArray* delays = @[ @1.0, @2.5, @4.5, @7.0, @10.0, @15.0 ];
    for (NSNumber* n in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SkyDumpNow(wv);
        });
    }
}

// ---- swizzles ----

static void swizzle(Class cls, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(cls, a);
    Method mb = class_getInstanceMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

@interface WKWebView (SkyDump)
@end

@implementation WKWebView (SkyDump)

- (void)sky_loadRequest:(NSURLRequest*)req {
    SkyLog(@"loadRequest %@", req.URL.absoluteString);
    [self sky_loadRequest:req];
    SkyScheduleDumps(self);
}

- (void)sky_loadHTMLString:(NSString*)html baseURL:(NSURL*)base {
    SkyLog(@"loadHTMLString base=%@ len=%lu", base.absoluteString, (unsigned long)html.length);
    [self sky_loadHTMLString:html baseURL:base];
    SkySendChunks(@"HTMLSTRING", html ?: @"");
    SkyScheduleDumps(self);
}

- (void)sky_loadFileURL:(NSURL*)u allowingReadAccessToURL:(NSURL*)r {
    SkyLog(@"loadFileURL %@", u.absoluteString);
    [self sky_loadFileURL:u allowingReadAccessToURL:r];
    SkyScheduleDumps(self);
}

@end

@interface WKUserContentController (SkyDump)
@end

@implementation WKUserContentController (SkyDump)

- (void)sky_addUserScript:(WKUserScript*)s {
    SkyLog(@"addUserScript time=%ld len=%lu", (long)s.injectionTime, (unsigned long)s.source.length);
    SkySendChunks(@"USERSCRIPT", s.source ?: @"");
    [self sky_addUserScript:s];
}

@end

static void SkyInstall(void) {
    Class wv = [WKWebView class];
    swizzle(wv, @selector(loadRequest:), @selector(sky_loadRequest:));
    swizzle(wv, @selector(loadHTMLString:baseURL:), @selector(sky_loadHTMLString:baseURL:));
    swizzle(wv, @selector(loadFileURL:allowingReadAccessToURL:), @selector(sky_loadFileURL:allowingReadAccessToURL:));
    Class uc = [WKUserContentController class];
    swizzle(uc, @selector(addUserScript:), @selector(sky_addUserScript:));
    SkyLog(@"hooks installed");
}

__attribute__((constructor))
static void sky_init(void) {
    g_seen = [NSMutableSet new];
    SkyLog(@"init, target 9805");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { SkyInstall(); } @catch (NSException* e) { SkyLog(@"install exception %@", e); }
    });
}
