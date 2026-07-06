#import "ChromiumViewObjC.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_handler.h"
#include "include/wrapper/cef_helpers.h"

// Redeclare the public-readonly state-mirror properties as readwrite inside
// the class so synthesized setters fire KVO automatically. Public callers
// still see them as readonly via the header.
@interface CEFFaviconRef ()
@property (nonatomic, strong, nullable) NSImage* image;
@end
@implementation CEFFaviconRef
- (instancetype)initWithURL:(NSURL*)url {
  if ((self = [super init])) { _url = [url copy]; }
  return self;
}
@end

@interface ChromiumView ()
@property (nonatomic, copy, nullable) NSString* title;
@property (nonatomic, strong, nullable) CEFFaviconRef* favicon;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL canGoBack;
@property (nonatomic, assign) BOOL canGoForward;

- (void)_onLoadStartURL:(nullable NSURL*)url;
- (void)_onLoadEndURL:(nullable NSURL*)url statusCode:(int)code;
- (void)_browserDidCreate;
- (CefClient*)_internalCefClient;
- (nullable ChromiumView*)_requestNewTabFor:(nullable NSURL*)url
                            disposition:(CEFTabDisposition)disposition
                            userGesture:(BOOL)userGesture;
- (void)_onLoadErrorURL:(nullable NSURL*)url
                  error:(NSError*)error;
- (void)_onDevToolsResult:(int)messageId
                  success:(BOOL)success
                   result:(NSData*)data;
- (void)_onDevToolsEventMethod:(NSString*)method params:(NSData*)params;
- (void)_installMessageHandlerShims;
@end

namespace {

// CEF → our coarse two-case enum. Returns false for dispositions the host
// doesn't route through the delegate (popups with feature strings, save-as,
// etc.), letting CEF apply its default behavior.
bool cefToTabDisposition(CefLifeSpanHandler::WindowOpenDisposition cef,
                         CEFTabDisposition* out) {
  switch (cef) {
    case CEF_WOD_NEW_FOREGROUND_TAB:
    case CEF_WOD_NEW_WINDOW:
      *out = CEFTabDispositionNewForegroundTab;
      return true;
    case CEF_WOD_NEW_BACKGROUND_TAB:
      *out = CEFTabDispositionNewBackgroundTab;
      return true;
    default:
      return false;
  }
}

NSURL* nsurlFromCefString(const CefString& s) {
  if (s.empty()) return nil;
  return [NSURL URLWithString:
      [NSString stringWithUTF8String:s.ToString().c_str()]];
}

class _ChromiumClient;

class _CEFFaviconCallback : public CefDownloadImageCallback {
 public:
  explicit _CEFFaviconCallback(CEFFaviconRef* target) : target_(target) {}
  void OnDownloadImageFinished(const CefString&, int http_status_code,
                               CefRefPtr<CefImage> image) override {
    NSImage* nsImage = nil;
    if (image && http_status_code >= 200 && http_status_code < 400) {
      int w = 0, h = 0;
      CefRefPtr<CefBinaryValue> png = image->GetAsPNG(1.0f, true, w, h);
      if (png && png->GetSize() > 0) {
        NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
        png->GetData(data.mutableBytes, png->GetSize(), 0);
        nsImage = [[NSImage alloc] initWithData:data];
      }
    }
    // Weak target: if the view's favicon has since swapped to a new URL,
    // this CEFFaviconRef is unreferenced and gone — the assignment is a
    // no-op, no race guard needed.
    __weak CEFFaviconRef* target = target_;
    dispatch_async(dispatch_get_main_queue(), ^{ target.image = nsImage; });
  }
 private:
  __weak CEFFaviconRef* target_;
  IMPLEMENT_REFCOUNTING(_CEFFaviconCallback);
};

class _CEFDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  _CEFDevToolsObserver() = default;
  void SetOwner(__weak ChromiumView* o) { owner_ = o; }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id,
                              bool success, const void* result,
                              size_t result_size) override {
    NSData* data = [NSData dataWithBytes:result length:result_size];
    __weak ChromiumView* owner = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [owner _onDevToolsResult:message_id success:success result:data];
    });
  }
  // DevTools protocol events. `Runtime.bindingCalled` is how a JS→native
  // message-handler binding delivers its payload; forward every event to the
  // view, which filters for the ones it cares about.
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method,
                       const void* params, size_t params_size) override {
    NSString* m = [NSString stringWithUTF8String:method.ToString().c_str()];
    NSData* data = params_size ? [NSData dataWithBytes:params length:params_size]
                               : [NSData data];
    __weak ChromiumView* owner = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [owner _onDevToolsEventMethod:m params:data];
    });
  }
 private:
  __weak ChromiumView* owner_;
  IMPLEMENT_REFCOUNTING(_CEFDevToolsObserver);
};

class _ChromiumClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefRequestHandler {
 public:
  _ChromiumClient() = default;
  explicit _ChromiumClient(ChromiumView* owner) : owner_(owner) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // cmd+click and middle-click skip OnBeforePopup and arrive here as
  // tab-disposition navigations. The opener relationship is NOT preserved
  // on this path (matches real-browser noopener-by-default for modifier
  // clicks).
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> /*browser*/,
                        CefRefPtr<CefFrame> /*frame*/,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    CEFTabDisposition dispo;
    if (!cefToTabDisposition(target_disposition, &dispo)) return false;

    ChromiumView* opener_view = owner_;
    NSURL* url = nsurlFromCefString(target_url);
    BOOL gesture = user_gesture ? YES : NO;

    // Defer the tab spawn so CEF finishes settling the cancelled navigation
    // before SwiftUI mutates the tab list.
    dispatch_async(dispatch_get_main_queue(), ^{
      ChromiumView* shell = [opener_view _requestNewTabFor:url
                                          disposition:dispo
                                          userGesture:gesture];
      if (shell && url) { [shell load:url]; }
    });
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    CEF_REQUIRE_UI_THREAD();
    browser_ = b;
    devtools_ = new _CEFDevToolsObserver();
    devtools_->SetOwner(owner_);
    devtools_registration_ = b->GetHost()->AddDevToolsMessageObserver(devtools_.get());
    // CEF adds its browser NSView here, asynchronously — typically AFTER our last
    // layout pass — at the size passed to CreateBrowser. If the view grew in the
    // meantime, the browser is left pinned at its creation size in the
    // bottom-left corner. Re-sync the child to our current bounds now that it
    // exists. (Hop to the main thread to touch AppKit safely.)
    __weak ChromiumView* o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{ [o _browserDidCreate]; });
  }

  bool OnBeforePopup(
      CefRefPtr<CefBrowser> /*opener*/,
      CefRefPtr<CefFrame> /*frame*/,
      int /*popup_id*/,
      const CefString& target_url,
      const CefString& /*target_frame_name*/,
      WindowOpenDisposition target_disposition,
      bool user_gesture,
      const CefPopupFeatures& /*popupFeatures*/,
      CefWindowInfo& windowInfo,
      CefRefPtr<CefClient>& client,
      CefBrowserSettings& /*settings*/,
      CefRefPtr<CefDictionaryValue>& /*extra_info*/,
      bool* /*no_javascript_access*/) override {
    CEF_REQUIRE_UI_THREAD();

    CEFTabDisposition dispo;
    if (!cefToTabDisposition(target_disposition, &dispo)) return false;

    ChromiumView* shell = [owner_ _requestNewTabFor:nsurlFromCefString(target_url)
                                    disposition:dispo
                                    userGesture:user_gesture ? YES : NO];
    if (!shell) return false;

    // Returning false (allow) is what keeps window.opener wired up — CEF
    // creates the popup inside `shell` and fires OnAfterCreated on its
    // client. Size is a placeholder; SwiftUI resizes on mount.
    windowInfo.SetAsChild((__bridge void*)shell, CefRect(0, 0, 800, 600));
    client = [shell _internalCefClient];
    return false;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    CEF_REQUIRE_UI_THREAD();
    browser_ = nullptr;
    devtools_registration_ = nullptr;
    owner_ = nil;
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    __weak ChromiumView* o = owner_;
    BOOL il = isLoading, cb = canGoBack, cf = canGoForward;
    dispatch_async(dispatch_get_main_queue(), ^{
      o.isLoading = il;
      o.canGoBack = cb;
      o.canGoForward = cf;
    });
  }

  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (!frame || !frame->IsMain()) return;
    NSURL* url = [NSURL URLWithString:
        [NSString stringWithUTF8String:frame->GetURL().ToString().c_str()]];
    __weak ChromiumView* o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{ [o _onLoadStartURL:url]; });
  }

  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (!frame || !frame->IsMain()) return;
    NSURL* url = [NSURL URLWithString:
        [NSString stringWithUTF8String:frame->GetURL().ToString().c_str()]];
    int code = httpStatusCode;
    __weak ChromiumView* o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [o _onLoadEndURL:url statusCode:code];
    });
  }

  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode, const CefString& errorText,
                   const CefString& failedUrl) override {
    if (!frame || !frame->IsMain()) return;
    NSURL* url = [NSURL URLWithString:
        [NSString stringWithUTF8String:failedUrl.ToString().c_str()]];
    NSString* msg = [NSString stringWithUTF8String:errorText.ToString().c_str()];
    NSError* err = [NSError errorWithDomain:@"ChromiumView"
                                       code:(NSInteger)errorCode
                                   userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
    __weak ChromiumView* o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [o _onLoadErrorURL:url error:err];
    });
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override {
    __weak ChromiumView* o = owner_;
    if (icon_urls.empty()) {
      dispatch_async(dispatch_get_main_queue(), ^{ o.favicon = nil; });
      return;
    }
    NSURL* url = [NSURL URLWithString:
        [NSString stringWithUTF8String:icon_urls.front().ToString().c_str()]];
    if (!url) return;
    CefString cefURL = icon_urls.front();
    CefRefPtr<CefBrowserHost> host = browser->GetHost();
    dispatch_async(dispatch_get_main_queue(), ^{
      CEFFaviconRef* ref = [[CEFFaviconRef alloc] initWithURL:url];
      o.favicon = ref;  // KVO fires; old ref (if any) loses its strong owner
      host->DownloadImage(cefURL, /*is_favicon=*/true, /*max_image_size=*/64,
                          /*bypass_cache=*/false, new _CEFFaviconCallback(ref));
    });
  }

  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    NSString* t = [NSString stringWithUTF8String:title.ToString().c_str()];
    __weak ChromiumView* o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{ o.title = t; });
  }

  CefRefPtr<CefBrowser> browser() const { return browser_; }

 private:
  __weak ChromiumView* owner_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<_CEFDevToolsObserver> devtools_;
  CefRefPtr<CefRegistration> devtools_registration_;
  IMPLEMENT_REFCOUNTING(_ChromiumClient);
  DISALLOW_COPY_AND_ASSIGN(_ChromiumClient);
};

}  // namespace

@implementation ChromiumView {
  CefRefPtr<_ChromiumClient> _client;
  BOOL _browserCreated;
  int _nextEvalId;
  NSMutableDictionary<NSNumber*, void(^)(id _Nullable, NSError* _Nullable)>* _evalCallbacks;
  // JS→native message handlers, keyed by the public handler name (the `<name>`
  // in `window.webkit.messageHandlers.<name>`). Registrations survive
  // navigations and are (re)applied to the browser whenever it (re)attaches.
  NSMutableDictionary<NSString*, void(^)(id _Nullable)>* _messageHandlers;
  BOOL _runtimeDomainsEnabled;
}

@synthesize URL = _URL;
@synthesize navigationDelegate = _navigationDelegate;

- (instancetype)initWithFrame:(NSRect)frame URL:(NSURL*)url {
  if ((self = [super initWithFrame:frame])) {
    _URL = [url copy];
    _nextEvalId = 1;
    _evalCallbacks = [NSMutableDictionary new];
    _messageHandlers = [NSMutableDictionary new];
    self.wantsLayer = YES;
  }
  return self;
}

- (void)dealloc {
  if (auto b = [self _browser]) {
    b->GetHost()->CloseBrowser(/*force_close=*/true);
  }
}

+ (ChromiumView*)popupView {
  // _ChromiumClient is built up front so OnBeforePopup can hand it back to CEF;
  // the browser arrives later via OnAfterCreated.
  ChromiumView* v = [[ChromiumView alloc] initWithFrame:NSZeroRect URL:nil];
  v->_client = new _ChromiumClient(v);
  v->_browserCreated = YES;
  return v;
}

- (CefClient*)_internalCefClient {
  return _client.get();
}

- (ChromiumView*)_requestNewTabFor:(NSURL*)url
                  disposition:(CEFTabDisposition)disposition
                  userGesture:(BOOL)userGesture {
  id<ChromiumNavigationDelegate> d = self.navigationDelegate;
  if (![d respondsToSelector:
      @selector(webView:requestsNewTabForURL:userGesture:disposition:)]) {
    return nil;
  }
  return [d webView:self
       requestsNewTabForURL:url
                userGesture:userGesture
                disposition:disposition];
}

// Create the CefBrowser once we're in a window AND have a non-zero size. CEF
// sizes the browser's NSView to the CefRect passed here and never tracks our
// bounds again, so the size at creation matters: embedded in SwiftUI
// (NSViewRepresentable), `viewDidMoveToWindow` fires while our bounds are still
// zero — creating the browser then yields a 0x0 CEF view that loads the page but
// never paints. So we defer creation until the first layout pass with a real
// size (see `resizeSubviewsWithOldSize:`). An AppKit host that hands us a sized
// frame up front creates immediately, straight from `viewDidMoveToWindow`.
- (void)_createBrowserIfReady {
  if (_browserCreated || !self.window) return;
  NSRect b = self.bounds;
  if (b.size.width < 1 || b.size.height < 1) return;
  _browserCreated = YES;
  _client = new _ChromiumClient(self);
  CefWindowInfo wi;
  wi.SetAsChild((__bridge void*)self,
                CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  CefBrowserSettings bs;
  NSString* urlString = _URL.absoluteString ?: @"about:blank";
  CefBrowserHost::CreateBrowser(wi, _client.get(),
                                [urlString UTF8String], bs, nullptr, nullptr);
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self _createBrowserIfReady];
}

// CEF adds its browser NSView as a child of `self`, sized to our bounds at
// creation time and WITHOUT an autoresizing mask, so AppKit won't grow it for
// us. A view created small — e.g. an NSViewRepresentable laid out at zero/100pt
// and then grown by SwiftUI — would leave the browser pinned tiny in the
// bottom-left corner. We must resize the child ourselves on every layout pass.
//
// Crucially, SwiftUI hosts us in a layer-backed tree and resizes via `layout` /
// `setFrameSize:`, NOT the classic `resizeSubviewsWithOldSize:` autoresizing
// path — so hooking only the latter (as a plain AppKit host would) never fires
// under SwiftUI and the browser stays tiny. Hook all three; each forwards to
// `_syncBrowserLayout`, which also fires the deferred browser creation once we
// finally have a real size.
- (void)_syncBrowserLayout {
  [self _createBrowserIfReady];
  NSRect b = self.bounds;
  if (auto browser = [self _browser]) {
    // Resize CEF's browser NSView to fill us. GetWindowHandle() is the view CEF
    // created under `SetAsChild`; it carries no autoresizing mask, so we drive
    // its frame ourselves, then tell CEF to re-layout + repaint at the new size.
    if (NSView* cefView = (__bridge NSView*)browser->GetHost()->GetWindowHandle()) {
      cefView.frame = b;
    }
    browser->GetHost()->WasResized();
  }
}

// CEF adds its child view asynchronously (OnAfterCreated), often after our last
// layout pass, at the CreateBrowser size — so sync it to our current bounds the
// moment it exists, or it stays pinned tiny in the bottom-left.
- (void)_browserDidCreate {
  [self _syncBrowserLayout];
  // The devtools agent attaches lazily on the first message; enabling the
  // Runtime/Page domains + (re)installing any handlers registered before the
  // browser existed has to wait until now.
  _runtimeDomainsEnabled = NO;
  [self _installMessageHandlerShims];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self _syncBrowserLayout];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self _syncBrowserLayout];
}

- (void)layout {
  [super layout];
  [self _syncBrowserLayout];
}

#pragma mark - Navigation

- (CefRefPtr<CefBrowser>)_browser { return _client ? _client->browser() : nullptr; }

- (void)load:(NSURL*)url {
  self.URL = url;  // synthesized setter → KVO fires
  if (auto b = [self _browser]) {
    b->GetMainFrame()->LoadURL([url.absoluteString UTF8String]);
  }
}

- (void)loadHTMLString:(NSString*)html baseURL:(NSURL*)baseURL {
  if (auto b = [self _browser]) {
    std::string s([html UTF8String]);
    CefString encoded = CefBase64Encode(s.data(), s.size());
    std::string dataUrl = std::string("data:text/html;base64,") + encoded.ToString();
    b->GetMainFrame()->LoadURL(dataUrl);
  }
}

- (void)reload            { if (auto b = [self _browser]) b->Reload(); }
- (void)reloadFromOrigin  { if (auto b = [self _browser]) b->ReloadIgnoreCache(); }
- (void)stopLoading       { if (auto b = [self _browser]) b->StopLoad(); }
- (void)goBack            { if (auto b = [self _browser]) b->GoBack(); }
- (void)goForward         { if (auto b = [self _browser]) b->GoForward(); }

#pragma mark - DevTools

- (BOOL)isDevToolsOpen {
  auto b = [self _browser];
  return b ? b->GetHost()->HasDevTools() : NO;
}

- (void)setIsDevToolsOpen:(BOOL)open {
  auto b = [self _browser];
  if (!b) return;
  if (open) {
    // Empty window info → CEF creates a floating native window. Idempotent
    // when DevTools is already open (just focuses the existing window).
    CefWindowInfo wi;
    CefBrowserSettings bs;
    CefPoint inspect;  // (0,0) — no element pre-selected
    b->GetHost()->ShowDevTools(wi, nullptr, bs, inspect);
  } else {
    b->GetHost()->CloseDevTools();
  }
}

#pragma mark - JS eval (DevTools Runtime.evaluate)

- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^)(id, NSError*))completion {
  auto b = [self _browser];
  if (!b) {
    if (completion) {
      completion(nil, [NSError errorWithDomain:@"ChromiumView" code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                  @"browser not yet created"}]);
    }
    return;
  }
  int msgId = ++_nextEvalId;
  if (completion) {
    _evalCallbacks[@(msgId)] = [completion copy];
  }
  NSDictionary* req = @{
    @"id": @(msgId),
    @"method": @"Runtime.evaluate",
    @"params": @{
      @"expression": script,
      @"returnByValue": @YES,
      @"awaitPromise": @YES,
    },
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:req options:0 error:nil];
  b->GetHost()->SendDevToolsMessage(json.bytes, json.length);
}

- (void)_onDevToolsResult:(int)messageId success:(BOOL)success result:(NSData*)data {
  void (^cb)(id, NSError*) = _evalCallbacks[@(messageId)];
  if (!cb) return;
  [_evalCallbacks removeObjectForKey:@(messageId)];

  NSError* jsonErr = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
  if (!success || ![obj isKindOfClass:[NSDictionary class]]) {
    cb(nil, [NSError errorWithDomain:@"ChromiumView" code:3
                            userInfo:@{NSLocalizedDescriptionKey:
                                        jsonErr.localizedDescription ?: @"eval failed"}]);
    return;
  }
  // DevTools shape: { "result": { "type": "string"|..., "value": ..., "description": "..." },
  //                   "exceptionDetails": { "text": ... } }
  NSDictionary* d = obj;
  NSDictionary* ex = d[@"exceptionDetails"];
  if ([ex isKindOfClass:[NSDictionary class]]) {
    NSString* text = ex[@"text"] ?: @"JS exception";
    cb(nil, [NSError errorWithDomain:@"ChromiumView" code:4
                            userInfo:@{NSLocalizedDescriptionKey: text}]);
    return;
  }
  NSDictionary* r = d[@"result"];
  if (![r isKindOfClass:[NSDictionary class]]) { cb(nil, nil); return; }
  id value = r[@"value"];
  if (value == nil || value == NSNull.null) {
    // `undefined` shows up as no `value` key, type=undefined
    NSString* type = r[@"type"];
    if ([type isEqual:@"undefined"]) { cb(nil, nil); return; }
    cb(NSNull.null, nil);
    return;
  }
  cb(value, nil);
}

#pragma mark - JS → native message handlers

// Prefix for the raw `Runtime.addBinding` function names installed on `window`.
// The shim calls `window.<prefix><name>(json)`; the public `<name>` never
// collides with page globals because the actual binding lives under this
// namespaced key.
static NSString* const kBindingPrefix = @"__chromiumkit_msg_";

// JSON-encode a string into a JS string literal (quotes + escaping) so it can be
// interpolated safely into generated source.
static NSString* jsStringLiteral(NSString* s) {
  NSData* d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""]
                                             options:0 error:nil];
  NSString* arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  // arr == ["..."]; strip the surrounding brackets to get the bare literal.
  return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

// Build the JS that (re)installs `window.webkit.messageHandlers.<name>` as a
// thin wrapper over the raw binding. Idempotent — safe to run on every document
// and after `Runtime.addBinding`. Mirrors WKWebView's
// `window.webkit.messageHandlers.<name>.postMessage(body)` shape exactly.
static NSString* messageHandlerShimJS(NSString* name) {
  NSString* binding = [kBindingPrefix stringByAppendingString:name];
  // The raw binding takes a single string arg, so JSON-serialize the body (as
  // WKWebView consumers already do: postMessage(JSON.stringify(...))). A body
  // that's already a string is passed through as-is so double-encoding is
  // avoided for the common `postMessage(JSON.stringify(x))` call site.
  return [NSString stringWithFormat:
      @"(function(){"
      @"  var w = (window.webkit = window.webkit || {});"
      @"  var h = (w.messageHandlers = w.messageHandlers || {});"
      @"  h[%@] = { postMessage: function(body){"
      @"    var s = (typeof body === 'string') ? body : JSON.stringify(body);"
      @"    return window[%@](s);"
      @"  }};"
      @"})();",
      jsStringLiteral(name), jsStringLiteral(binding)];
}

- (void)_sendDevToolsMethod:(NSString*)method params:(nullable NSDictionary*)params {
  auto b = [self _browser];
  if (!b) return;
  NSMutableDictionary* req = [@{ @"id": @(++_nextEvalId), @"method": method } mutableCopy];
  if (params) req[@"params"] = params;
  NSData* json = [NSJSONSerialization dataWithJSONObject:req options:0 error:nil];
  b->GetHost()->SendDevToolsMessage(json.bytes, json.length);
}

- (void)addMessageHandlerName:(NSString*)name handler:(void (^)(id))handler {
  _messageHandlers[name] = [handler copy];
  [self _installMessageHandler:name];
}

- (void)removeMessageHandlerName:(NSString*)name {
  [_messageHandlers removeObjectForKey:name];
  if (![self _browser]) return;
  [self _sendDevToolsMethod:@"Runtime.removeBinding"
                     params:@{ @"name": [kBindingPrefix stringByAppendingString:name] }];
  // Tear down the shim for future documents. (Existing documents keep the
  // now-inert wrapper until they navigate — harmless: the removed binding
  // throws, and callers have deregistered.)
  NSString* del = [NSString stringWithFormat:
      @"(function(){try{delete window.webkit.messageHandlers[%@];}catch(e){}})();",
      jsStringLiteral(name)];
  [self _sendDevToolsMethod:@"Runtime.evaluate" params:@{ @"expression": del }];
}

// Ensure the Runtime/Page domains are enabled, then (re)install every currently
// registered handler. Called when the browser (re)attaches.
- (void)_installMessageHandlerShims {
  if (![self _browser] || _messageHandlers.count == 0) return;
  for (NSString* name in _messageHandlers.allKeys) {
    [self _installMessageHandler:name];
  }
}

- (void)_installMessageHandler:(NSString*)name {
  if (![self _browser]) return;  // deferred; _browserDidCreate re-applies
  if (!_runtimeDomainsEnabled) {
    // Runtime.enable → bindingCalled events; Page.enable → addScriptToEvaluateOnNewDocument.
    [self _sendDevToolsMethod:@"Runtime.enable" params:nil];
    [self _sendDevToolsMethod:@"Page.enable" params:nil];
    _runtimeDomainsEnabled = YES;
  }
  NSString* binding = [kBindingPrefix stringByAppendingString:name];
  // Raw binding: JS calling window.<binding>(str) fires Runtime.bindingCalled.
  [self _sendDevToolsMethod:@"Runtime.addBinding" params:@{ @"name": binding }];
  NSString* shim = messageHandlerShimJS(name);
  // Future documents (survives navigation).
  [self _sendDevToolsMethod:@"Page.addScriptToEvaluateOnNewDocument"
                     params:@{ @"source": shim }];
  // The already-loaded document, so a handler added after load works immediately.
  [self _sendDevToolsMethod:@"Runtime.evaluate" params:@{ @"expression": shim }];
}

- (void)_onDevToolsEventMethod:(NSString*)method params:(NSData*)params {
  if (![method isEqualToString:@"Runtime.bindingCalled"]) return;
  id obj = [NSJSONSerialization JSONObjectWithData:params options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) return;
  NSString* bindingName = obj[@"name"];
  if (![bindingName hasPrefix:kBindingPrefix]) return;
  NSString* name = [bindingName substringFromIndex:kBindingPrefix.length];
  void (^handler)(id) = _messageHandlers[name];
  if (!handler) return;
  // `payload` is the single string arg the shim passed (JSON.stringify(body),
  // or a bare string). Parse it back to a Foundation JSON value; if it isn't
  // valid JSON, deliver the raw string verbatim.
  NSString* payload = obj[@"payload"];
  id body = payload;
  if ([payload isKindOfClass:[NSString class]]) {
    NSData* pdata = [payload dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:pdata
                                                options:NSJSONReadingFragmentsAllowed
                                                  error:nil];
    if (parsed) body = parsed;
  }
  handler(body);
}

#pragma mark - Delegate forwarding (events only — state is KVO)

- (void)_onLoadStartURL:(NSURL*)url {
  // New page → clear stale favicon until OnFaviconURLChange arrives.
  self.favicon = nil;
  self.URL = url;  // KVO fires; covers redirects + history nav, not just load:
  id<ChromiumNavigationDelegate> d = self.navigationDelegate;
  if ([d respondsToSelector:@selector(webView:didStartProvisionalNavigation:)]) {
    [d webView:self didStartProvisionalNavigation:url];
  }
}
- (void)_onLoadEndURL:(NSURL*)url statusCode:(int)code {
  id<ChromiumNavigationDelegate> d = self.navigationDelegate;
  if ([d respondsToSelector:@selector(webView:didFinishNavigationTo:statusCode:)]) {
    [d webView:self didFinishNavigationTo:url statusCode:code];
  }
}
- (void)_onLoadErrorURL:(NSURL*)url error:(NSError*)error {
  id<ChromiumNavigationDelegate> d = self.navigationDelegate;
  if ([d respondsToSelector:@selector(webView:didFailNavigationWithError:)]) {
    [d webView:self didFailNavigationWithError:error];
  }
}

@end
