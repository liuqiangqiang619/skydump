// SkySkin.dylib —— SkyCam 面板换肤（暗金 · 天乐风格）+ 结构快照
//
// 原理：
//   1) 在 WKWebView 加载前注入 WKUserScript（documentStart），覆盖它的主题变量与通用样式；
//   2) 页面内跑一段「智能反色」脚本：把浅色卡片/白底按钮/绿色强调色统一改成暗金，
//      并对新插入的节点用 MutationObserver 持续纠正 —— 这样即使不知道它真实 DOM 也能换肤；
//   3) 顺带把 outerHTML + 全部 CSS 规则发回 PC（9805），用于后续精确微调。
//
// 不改任何业务逻辑与 JS 桥（kamiAction / kamiShowMsg 原样保留）。

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

static void SkyLog(NSString* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SKYSKIN] %@", s);
    if (g_sock >= 0) { NSString* l = [s stringByAppendingString:@"\n"]; send(g_sock, l.UTF8String, strlen(l.UTF8String), 0); }
}

static void SkyEnsureConn(void) {
    if (g_sock >= 0) return;
    if (!g_host) {
        NSString* h = [[NSUserDefaults standardUserDefaults] stringForKey:@"SKYDumpHost"];
        g_host = h.length ? h : @"192.168.10.2";
    }
    int s = socket(AF_INET, SOCK_STREAM, 0); if (s < 0) return;
    struct timeval tv = { 1, 0 }; setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
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
    SkyLog(@"%@ bytes=%lu", tag, (unsigned long)d.length);
    SkyEnsureConn(); if (g_sock < 0) return;
    NSString* head = [NSString stringWithFormat:@"BEGIN %@ %lu\n", tag, (unsigned long)b64.length];
    send(g_sock, head.UTF8String, strlen(head.UTF8String), 0);
    NSUInteger step = 700;
    for (NSUInteger i = 0; i < b64.length; i += step) {
        NSUInteger n = MIN(step, b64.length - i);
        NSString* part = [NSString stringWithFormat:@"D %@\n", [b64 substringWithRange:NSMakeRange(i, n)]];
        const char* p = part.UTF8String; ssize_t off = 0, len = (ssize_t)strlen(p);
        while (off < len) { ssize_t w = send(g_sock, p + off, len - off, 0); if (w <= 0) break; off += w; }
        usleep(1200);
    }
    send(g_sock, "END\n", 4, 0);
}

// ---------------- 主题 CSS ----------------
static NSString* SkyCSS(void) {
    return @""
    ":root{"
      "--scl-bg:#12100C;--scl-background-color:#12100C;--scl-title:#E8D9B5;--scl-title-color:#E8D9B5;"
      "--scl-text:#C9B98F;--scl-accent:#D6B05C;--scl-button:#D6B05C;--scl-button-color:#D6B05C;"
      "--scl-line:rgba(214,176,92,.35);"
    "}"
    "html,body{background:#12100C !important;color:#C9B98F !important;"
      "-webkit-text-fill-color:currentColor !important;font-family:-apple-system,'PingFang SC' !important}"
    "h1,h2,h3,h4,h5,.title,.scl_title,.card-title,.header{color:#E8D9B5 !important}"
    ".kami-btn,.scl_button,button,.btn{"
      "background:rgba(214,176,92,.10) !important;border:1px solid rgba(214,176,92,.55) !important;"
      "color:#D6B05C !important;border-radius:8px !important;box-shadow:none !important}"
    ".kami-btn-primary,.kami-btn-custom{background:rgba(214,176,92,.18) !important;color:#E8D9B5 !important}"
    "input,textarea,select{background:#1a1712 !important;border:1px solid rgba(214,176,92,.35) !important;"
      "color:#E8D9B5 !important;border-radius:8px !important}"
    "hr{border-color:rgba(214,176,92,.20) !important}"
    "::selection{background:rgba(214,176,92,.35) !important}"
    "*{box-shadow:none !important}";
}

// ---------------- 智能反色脚本 ----------------
// 目标：不依赖具体类名，把「浅色底 / 深色字 / 绿色强调」整体扭到暗金；
// 同时对后来插入的节点（面板是动态渲染的）持续生效。
static NSString* SkyJS(void) {
    return @"(function(){"
      "if(window.__skySkin){return 'already'}"
      "window.__skySkin=1;"
      "var GOLD='rgb(214,176,92)',GOLD2='rgb(232,217,181)',TEXT='rgb(201,185,143)',BG='rgb(18,16,12)',LINEC='rgba(214,176,92,0.35)';"
      "function rgb(s){var m=(s||'').match(/[0-9.]+/g);if(!m||m.length<3)return null;var p=m.map(Number);return {r:p[0],g:p[1],b:p[2],a:p.length>3?p[3]:1}}"
      "function lum(c){return (0.2126*c.r+0.7152*c.g+0.0722*c.b)/255}"
      "function isGreen(c){return c.g>c.r*1.25&&c.g>c.b*1.15&&lum(c)>0.15}"
      "function isWarm(c){return c.r>140&&c.b<c.r*0.42&&lum(c)>0.30}"
      "function isAccent(c){return isGreen(c)||isWarm(c)}"
      "function fix(el){"
        "if(!el||el.nodeType!==1)return;"
        "if(el.getAttribute&&el.getAttribute('data-sky'))return;"
        "var t=el.tagName;if(t==='IMG'||t==='VIDEO'||t==='CANVAS'||t==='SVG'||t==='PATH')return;"
        "var cs=getComputedStyle(el);if(!cs)return;"
        "var bg=rgb(cs.backgroundColor),fg=rgb(cs.color);"
        "var bgGreen=!!(bg&&bg.a>0.02&&isAccent(bg));"
        "var bgLight=!!(bg&&bg.a>0.02&&!bgGreen&&lum(bg)>0.55);"
        "var fgGreen=!!(fg&&isAccent(fg));"
        "if(bgGreen){"
          "el.style.setProperty('background',GOLD,'important');"
          "el.style.setProperty('border-color','rgba(232,217,181,.65)','important');"
          "el.style.setProperty('color','#12100C','important');"
          "el.style.setProperty('-webkit-text-fill-color','#12100C','important');"
        "}else if(bgLight){"
          "el.style.setProperty('background-color','#1A1712','important');"
          "el.style.setProperty('border','1px solid '+LINEC,'important');"
          "el.style.setProperty('border-radius','10px','important');"
        "}else if(bg&&bg.a>0.02&&lum(bg)<0.10){"
          "el.style.setProperty('background-color',BG,'important');"
        "}"
        "if(!bgGreen&&fg){var FL=lum(fg);"
          "if(fgGreen){el.style.setProperty('color',GOLD,'important');el.style.setProperty('-webkit-text-fill-color',GOLD,'important')}"
          "else if(FL<0.45){el.style.setProperty('color',el.matches('h1,h2,h3,h4,h5,.title')?GOLD2:TEXT,'important');el.style.setProperty('-webkit-text-fill-color','currentColor','important')}"
          "else if(FL>0.80&&bgLight){el.style.setProperty('color',GOLD2,'important')}"
        "}"
        "if(cs.borderTopWidth!=='0px'&&cs.borderTopColor){var bc=rgb(cs.borderTopColor);if(bc&&lum(bc)>0.5&&!bgGreen)el.style.setProperty('border-color',LINEC,'important')}"
        "if(el.setAttribute)el.setAttribute('data-sky','1')"
      "}"
      "function el0(e){return e?(e.textContent||''):''}"
      "function relabel(){try{"
        "var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null),n;"
        "while(n=w.nextNode()){var v=n.nodeValue;if(!v)continue;var o=v;"
          "v=v.split('SkyCam').join('天乐系统');"
          "v=v.split('SKY LAB · 增强项').join('直播去重效果');"
          "v=v.split('SKY LAB·增强项').join('直播去重效果');"
          "v=v.split('SKY LAB').join('直播去重');"
          "var tt=v.replace(/[\s\u00a0]/g,'');"
          "if((tt==='·增强项'||tt==='•增强项')&&el0(n.parentNode).indexOf('直播去重')>=0){v='';}"
          "if(tt==='直播去重'&&(n.parentNode.textContent||'').indexOf('增强项')<0){v='直播去重效果';}"
          "if(v!==o)n.nodeValue=v}"
        "}catch(e){}}"
      "function all(){relabel();var n=document.querySelectorAll('*');for(var i=0;i<n.length;i++){try{fix(n[i])}catch(e){}}}"
      "function start(){all();setTimeout(all,300);setTimeout(all,900);setTimeout(all,1800);"
        "var mo=new MutationObserver(function(m){all()});"
        "mo.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class']})}"
      "if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',start)}else{start()}"
      "return 'ok'"
    "})();";
}

static void SkyDumpNow(WKWebView* wv) {
    if (!wv) return;
    NSString* js = @"JSON.stringify({href:location.href,title:document.title,html:document.documentElement?document.documentElement.outerHTML:'',styles:(function(){var o=[],ss=document.styleSheets;for(var i=0;i<ss.length;i++){try{var r=ss[i].cssRules;for(var j=0;j<r.length;j++)o.push(r[j].cssText)}catch(e){o.push('/*'+e.message+'*/')}}return o.join('\\n')})()})";
    dispatch_async(dispatch_get_main_queue(), ^{
        [wv evaluateJavaScript:js completionHandler:^(id res, NSError* err) {
            if (err) { SkyLog(@"dump err %@", err.localizedDescription); return; }
            NSString* s = [res isKindOfClass:[NSString class]] ? res : [res description];
            NSURL* url = wv.URL;
            SkyLog(@"snapshot %@ len=%lu", url.absoluteString ?: @"?", (unsigned long)s.length);
            SkySendChunks(@"SKYDUMP", s);
        }];
    });
}

static void SkyApply(WKWebView* wv) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [wv evaluateJavaScript:SkyJS() completionHandler:^(id r, NSError* e) {
            SkyLog(@"skin apply -> %@ %@", r, e ? e.localizedDescription : @"");
        }];
    });
}

static void SkyPrepare(WKWebView* wv) {
    static void* kPrepared = &kPrepared;
    if (objc_getAssociatedObject(wv, kPrepared)) return;
    objc_setAssociatedObject(wv, kPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WKUserContentController* uc = wv.configuration.userContentController;
    WKUserScript* css = [[WKUserScript alloc] initWithSource:
        [NSString stringWithFormat:@"(function(){var s=document.createElement('style');s.setAttribute('data-sky','1');s.textContent=%@;document.documentElement.appendChild(s)})();",
            [NSString stringWithFormat:@"'%@'", [SkyCSS() stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]]
        ]
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [uc addUserScript:css];
    WKUserScript* js = [[WKUserScript alloc] initWithSource:SkyJS()
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO];
    [uc addUserScript:js];
    SkyLog(@"user scripts injected");
}

static void SkySchedule(WKWebView* wv) {
    NSArray* delays = @[ @0.8, @2.0, @4.0, @7.0, @12.0 ];
    for (NSNumber* n in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SkyApply(wv);
            if (n.doubleValue >= 4.0) SkyDumpNow(wv);
        });
    }
}

static void swz(Class c, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(c, a), mb = class_getInstanceMethod(c, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

@interface WKWebView (SkySkin) @end
@implementation WKWebView (SkySkin)
- (void)sky_loadRequest:(NSURLRequest*)r {
    SkyLog(@"loadRequest %@", r.URL.absoluteString);
    SkyPrepare(self);
    [self sky_loadRequest:r];
    SkySchedule(self);
}
- (void)sky_loadHTMLString:(NSString*)h baseURL:(NSURL*)b {
    SkyLog(@"loadHTMLString len=%lu", (unsigned long)h.length);
    SkyPrepare(self);
    [self sky_loadHTMLString:h baseURL:b];
    SkySendChunks(@"HTMLSTRING", h ?: @"");
    SkySchedule(self);
}
- (void)sky_loadFileURL:(NSURL*)u allowingReadAccessToURL:(NSURL*)r {
    SkyLog(@"loadFileURL %@", u.absoluteString);
    SkyPrepare(self);
    [self sky_loadFileURL:u allowingReadAccessToURL:r];
    SkySchedule(self);
}
@end

static void SkyInstall(void) {
    Class wv = [WKWebView class];
    swz(wv, @selector(loadRequest:), @selector(sky_loadRequest:));
    swz(wv, @selector(loadHTMLString:baseURL:), @selector(sky_loadHTMLString:baseURL:));
    swz(wv, @selector(loadFileURL:allowingReadAccessToURL:), @selector(sky_loadFileURL:allowingReadAccessToURL:));
    SkyLog(@"hooks installed");
}


// ---------------- 原生面板换肤（SkyCam 是原生 UIKit，不走 WebView） ----------------
// 依据真实视图树（VCamOverlayWindow, level 2120）：
//   卡片底 #E1EDF9 / 方块白 #FFFFFF / 选中绿 #72D689 / 橙色 #F49919 / 面板 #1377EF@5%
//   标题 "SkyCam"、分隔 UILabel "SKY LAB · 增强项"、7 个开关 UIButton
// 规则：浅底→深卡，绿/橙→金，深字→沙金，标题→亮金；文案替换为天乐口径。

static UIColor* SkyRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}
static UIColor* SkyGoldC(void)  { return SkyRGB(0.839, 0.690, 0.361, 1.0); }   // D6B05C
static UIColor* SkyCardC(void)  { return SkyRGB(0.102, 0.090, 0.071, 1.0); }   // 1A1712
static UIColor* SkyBgC(void)    { return SkyRGB(0.071, 0.063, 0.047, 1.0); }   // 12100C
static UIColor* SkyTextC(void)  { return SkyRGB(0.788, 0.725, 0.561, 1.0); }   // C9B98F
static UIColor* SkyTitleC(void) { return SkyRGB(0.910, 0.851, 0.710, 1.0); }   // E8D9B5
static UIColor* SkyLineC(void)  { return SkyRGB(0.839, 0.690, 0.361, 0.35); }

static BOOL SkyNear(UIColor* c, CGFloat r, CGFloat g, CGFloat b, CGFloat tol) {
    if (!c) return NO;
    CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
    if (![c getRed:&rr green:&gg blue:&bb alpha:&aa]) return NO;
    return fabs(rr - r) < tol && fabs(gg - g) < tol && fabs(bb - b) < tol;
}

static BOOL SkyIsGold(CGFloat r, CGFloat g, CGFloat b) {
    return fabs(r - 0.839) < 0.08 && fabs(g - 0.690) < 0.08 && fabs(b - 0.361) < 0.08;
}

// 第一遍：背景色映射（先改底，后面按底色决定文字色）
static void SkyWalkBg(UIView* v) {
    UIColor* bg = v.backgroundColor;
    if (bg) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if ([bg getRed:&r green:&g blue:&b alpha:&a]) {
            if (a <= 0.08 && r < 0.15 && g > 0.35 && b > 0.80) {
                v.backgroundColor = SkyRGB(0.09, 0.08, 0.06, 1.0);       // #1377EF@5% 面板 → 深底
            } else if (a > 0.05 && SkyNear(bg, 0.882, 0.929, 0.976, 0.05)) {
                v.backgroundColor = SkyBgC();                            // #E1EDF9 卡片 → #12100C
            } else if (a > 0.05 && (SkyNear(bg, 0.447, 0.839, 0.537, 0.08) ||
                                    SkyNear(bg, 0.957, 0.600, 0.098, 0.08))) {
                v.backgroundColor = SkyGoldC();                          // 绿 / 橙 → 金
                v.layer.cornerRadius = 8;
                v.clipsToBounds = YES;
            } else if (a > 0.05 && SkyNear(bg, 1.0, 1.0, 1.0, 0.04)) {
                v.backgroundColor = SkyCardC();                          // 白方块 → 深卡
                v.layer.cornerRadius = 8;
                v.layer.borderWidth = 1.0;
                v.layer.borderColor = SkyLineC().CGColor;
            }
        }
    }
    if (v.frame.size.height > 0 && v.frame.size.height <= 2.5 && v.frame.size.width >= 100) {
        v.backgroundColor = SkyLineC();                                  // 分隔线 → 金色细线
    }
    for (UIView* s in v.subviews) SkyWalkBg(s);
}

static NSString* SkyMapText(NSString* t) {
    if (!t.length) return t;
    if ([t isEqualToString:@"SkyCam"]) return @"天乐系统";
    if ([t rangeOfString:@"SKY LAB"].location != NSNotFound) return @"直播去重效果";
    return t;
}

static BOOL SkyViewIsGold(UIView* v) {
    UIColor* c = v.backgroundColor;
    if (!c) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    return [c getRed:&r green:&g blue:&b alpha:&a] && a > 0.5 && SkyIsGold(r, g, b);
}

static BOOL SkyHasGoldChild(UIView* v, int depth) {
    if (depth <= 0) return NO;
    for (UIView* s in v.subviews) {
        if (SkyViewIsGold(s)) return YES;
        if (SkyHasGoldChild(s, depth - 1)) return YES;
    }
    return NO;
}

// 文字是否压在金色底上：向上找 3 层，同时看每层的子树（方块底色与文字是兄弟节点）
static BOOL SkyGoldBehind(UIView* v) {
    UIView* p = v;
    int up = 0;
    while (p && up < 3) {
        if (SkyViewIsGold(p)) return YES;
        if (SkyHasGoldChild(p, 2)) return YES;
        p = p.superview;
        up++;
    }
    return NO;
}

// 第二遍：文字色 + 文案替换
static void SkyWalkText(UIView* v) {
    BOOL onGold = SkyGoldBehind(v);
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel* l = (UILabel*)v;
        l.text = SkyMapText(l.text);
        if (l.text.length) {
            BOOL titleLike = (l.font.pointSize >= 15.0 || [l.text isEqualToString:@"天乐系统"]);
            l.textColor = onGold ? SkyRGB(0.071, 0.063, 0.047, 1.0) : (titleLike ? SkyTitleC() : SkyTextC());
        }
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton* btn = (UIButton*)v;
        NSString* t = [btn titleForState:UIControlStateNormal];
        if (t.length) [btn setTitle:SkyMapText(t) forState:UIControlStateNormal];
        UIColor* col = onGold ? SkyRGB(0.071, 0.063, 0.047, 1.0) : SkyTextC();
        [btn setTitleColor:col forState:UIControlStateNormal];
        [btn setTitleColor:col forState:UIControlStateHighlighted];
        [btn setTitleColor:col forState:UIControlStateSelected];
    }
    for (UIView* s in v.subviews) SkyWalkText(s);
}

static void SkyApplyNative(void) {
    NSArray<UIWindow*>* wins = [UIApplication sharedApplication].windows;
    for (UIWindow* w in wins) {
        NSString* cn = NSStringFromClass(w.class);
        if ([cn rangeOfString:@"VCamOverlay"].location == NSNotFound) continue;
        if (w.hidden || w.alpha < 0.05) continue;
        SkyWalkBg(w);
        SkyWalkText(w);
    }
}

static void SkyStartNative(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer* t) {
        @try { SkyApplyNative(); } @catch (NSException* e) { SkyLog(@"native skin exception %@", e); }
    }];
    SkyLog(@"native skin timer started");
}


// ---------------- 颜色过滤钩子（避免和面板自身的重绘互相打架） ----------------
// 面板每次刷新都会把自己的颜色再设一遍，若我们用定时器硬改就会来回闪。
// 这里直接拦截 setBackgroundColor:/setText:/setTextColor:，把它的浅色值换成暗金值，
// 它设一次我们换一次 —— 视觉上永远只看到暗金，不会来回切。

static BOOL SkyInOverlay(UIView* v) {
    UIView* p = v;
    int guard = 0;
    while (p && guard++ < 40) {
        if ([NSStringFromClass(p.window.class) rangeOfString:@"VCamOverlay"].location != NSNotFound) return YES;
        p = p.superview;
    }
    return NO;
}

static UIColor* SkyMapBgColor(UIColor* c) {
    if (!c) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return nil;
    if (a <= 0.08 && r < 0.15 && g > 0.35 && b > 0.80) return SkyRGB(0.09, 0.08, 0.06, 1.0);
    if (a > 0.05 && SkyNear(c, 0.882, 0.929, 0.976, 0.05)) return SkyBgC();
    if (a > 0.05 && (SkyNear(c, 0.447, 0.839, 0.537, 0.08) || SkyNear(c, 0.957, 0.600, 0.098, 0.08))) return SkyGoldC();
    if (a > 0.05 && SkyNear(c, 1.0, 1.0, 1.0, 0.04)) return SkyCardC();
    // 兜底：面板里任何偏亮的底色（浅蓝 #EAF2FE、米白、淡灰）一律压成深卡
    if (a > 0.02 && (r + g + b) > 2.15) return SkyCardC();
    return nil;
}

static void (*orig_setBg)(id, SEL, UIColor*) = NULL;
static void sky_setBackgroundColor(id self, SEL _cmd, UIColor* color) {
    @try {
        UIColor* m = SkyMapBgColor(color);
        if (m && SkyInOverlay((UIView*)self)) { orig_setBg(self, _cmd, m); return; }
    } @catch (NSException* e) {}
    orig_setBg(self, _cmd, color);
}

static void (*orig_setText)(id, SEL, NSString*) = NULL;
static void sky_setText(id self, SEL _cmd, NSString* text) {
    @try {
        if ([text isKindOfClass:[NSString class]] && text.length) {
            UITableViewCell* noop = nil; (void)noop;
            if ([text isEqualToString:@"SkyCam"] && SkyInOverlay((UIView*)self)) text = @"天乐系统";
            else if ([text rangeOfString:@"SKY LAB"].location != NSNotFound && SkyInOverlay((UIView*)self)) text = @"直播去重效果";
        }
    } @catch (NSException* e) {}
    orig_setText(self, _cmd, text);
}

static void (*orig_setTextColor)(id, SEL, UIColor*) = NULL;
static void sky_setTextColor(id self, SEL _cmd, UIColor* color) {
    @try {
        if (SkyInOverlay((UIView*)self)) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            if ([color getRed:&r green:&g blue:&b alpha:&a]) {
                BOOL goldBehind = SkyGoldBehind((UIView*)self);
                if (goldBehind) { orig_setTextColor(self, _cmd, SkyRGB(0.071, 0.063, 0.047, 1.0)); return; }
                if (r + g + b < 1.2) { orig_setTextColor(self, _cmd, SkyTextC()); return; }
            }
        }
    } @catch (NSException* e) {}
    orig_setTextColor(self, _cmd, color);
}

static void SkyInstallColorFilters(void) {
    Method m1 = class_getInstanceMethod([UIView class], @selector(setBackgroundColor:));
    if (m1) orig_setBg = (void*)method_getImplementation(m1),
            method_setImplementation(m1, (IMP)sky_setBackgroundColor);
    Method m2 = class_getInstanceMethod([UILabel class], @selector(setText:));
    if (m2) orig_setText = (void*)method_getImplementation(m2),
            method_setImplementation(m2, (IMP)sky_setText);
    Method m3 = class_getInstanceMethod([UILabel class], @selector(setTextColor:));
    if (m3) orig_setTextColor = (void*)method_getImplementation(m3),
            method_setImplementation(m3, (IMP)sky_setTextColor);
    SkyLog(@"color filters installed");
}


// ---- CALayer 层颜色拦截（开关盒子等可能是直接画在 layer 上） ----
static void (*orig_layerSetBg)(id, SEL, CGColorRef) = NULL;
static void sky_layerSetBackgroundColor(id self, SEL _cmd, CGColorRef color) {
    @try {
        if (color) {
            UIView* owner = nil;
            @try { id d = ((CALayer*)self).delegate; if ([d isKindOfClass:[UIView class]]) owner = d; } @catch (NSException* e) {}
            if (owner && SkyInOverlay(owner)) {
                UIColor* ui = [UIColor colorWithCGColor:color];
                UIColor* m = SkyMapBgColor(ui);
                if (m) { orig_layerSetBg(self, _cmd, m.CGColor); return; }
            }
        }
    } @catch (NSException* e) {}
    orig_layerSetBg(self, _cmd, color);
}

static void SkyInstallLayerFilter(void) {
    Method m = class_getInstanceMethod([CALayer class], @selector(setBackgroundColor:));
    if (m) {
        orig_layerSetBg = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)sky_layerSetBackgroundColor);
        SkyLog(@"layer color filter installed");
    }
}

// 新加进来的子视图立刻处理，不等定时器（避免"先原色后变暗"的跳变）
static void (*orig_didAddSubview)(id, SEL, UIView*) = NULL;
static void sky_didAddSubview(id self, SEL _cmd, UIView* sub) {
    orig_didAddSubview(self, _cmd, sub);
    @try {
        if (sub && SkyInOverlay((UIView*)self)) { SkyWalkBg(sub); SkyWalkText(sub); }
    } @catch (NSException* e) {}
}

static void SkyInstallAddSubFilter(void) {
    Method m = class_getInstanceMethod([UIView class], @selector(didAddSubview:));
    if (m) {
        orig_didAddSubview = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)sky_didAddSubview);
        SkyLog(@"didAddSubview filter installed");
    }
}

__attribute__((constructor))
static void skyskin_init(void) {
    SkyLog(@"init");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { SkyInstall(); SkyInstallColorFilters(); SkyInstallLayerFilter(); SkyInstallAddSubFilter(); SkyStartNative(); } @catch (NSException* e) { SkyLog(@"install exception %@", e); }
    });
}
