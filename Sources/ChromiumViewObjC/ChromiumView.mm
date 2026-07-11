#import "ChromiumViewObjC.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_parser.h"
#include "include/cef_request_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_resource_request_handler.h"
#include "include/wrapper/cef_helpers.h"
#include <cmath>

// Resolved root cache path (root_cache_path) captured by ChromiumApplication at
// CefInitialize, so a per-profile ChromiumDataStore can nest its cache_path
// under it — CEF requires each request context's cache_path be a child of
// root_cache_path. Empty when no cache path was configured (fully in-memory).
extern "C" NSString* _ChromiumResolvedRootCachePath(void);

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

// An unhandled key-down event handed to `ChromiumView.keyboardHandler`. All
// fields are set at construction and immutable; built on the main (CEF UI)
// thread from a `CefKeyEvent`.
@interface ChromiumKeyEvent ()
- (instancetype)_initWithCharacters:(nullable NSString*)characters
        charactersIgnoringModifiers:(nullable NSString*)charactersIgnoringModifiers
                      modifierFlags:(NSEventModifierFlags)modifierFlags
                            keyCode:(unsigned short)keyCode;
@end

@implementation ChromiumKeyEvent
- (instancetype)_initWithCharacters:(nullable NSString*)characters
        charactersIgnoringModifiers:(nullable NSString*)charactersIgnoringModifiers
                      modifierFlags:(NSEventModifierFlags)modifierFlags
                            keyCode:(unsigned short)keyCode {
  if ((self = [super init])) {
    _characters = [characters copy];
    _charactersIgnoringModifiers = [charactersIgnoringModifiers copy];
    _modifierFlags = modifierFlags;
    _keyCode = keyCode;
  }
  return self;
}
@end

// A pending navigation handed to `ChromiumView.navigationDecisionHandler` from
// OnBeforeBrowse. All fields set at construction and immutable; built on the
// main (CEF UI) thread from a CefRequest/CefFrame.
@interface ChromiumNavigationRequest ()
- (instancetype)_initWithURL:(nullable NSURL*)url
                   mainFrame:(BOOL)mainFrame
                 userGesture:(BOOL)userGesture
                    redirect:(BOOL)redirect
              navigationType:(ChromiumNavigationType)navigationType;
@end

@implementation ChromiumNavigationRequest
- (instancetype)_initWithURL:(nullable NSURL*)url
                   mainFrame:(BOOL)mainFrame
                 userGesture:(BOOL)userGesture
                    redirect:(BOOL)redirect
              navigationType:(ChromiumNavigationType)navigationType {
  if ((self = [super init])) {
    _url = [url copy];
    _mainFrame = mainFrame;
    _userGesture = userGesture;
    _redirect = redirect;
    _navigationType = navigationType;
  }
  return self;
}
@end

// A find-in-page result handed to `ChromiumView.findResultHandler` from
// OnFindResult. All fields set at construction and immutable; built on the main
// (CEF UI) thread from a CefFindHandler callback.
@interface ChromiumFindResult ()
- (instancetype)_initWithCount:(NSInteger)count
            activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                   finalUpdate:(BOOL)finalUpdate;
@end

@implementation ChromiumFindResult
- (instancetype)_initWithCount:(NSInteger)count
            activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                   finalUpdate:(BOOL)finalUpdate {
  if ((self = [super init])) {
    _count = count;
    _activeMatchOrdinal = activeMatchOrdinal;
    _finalUpdate = finalUpdate;
  }
  return self;
}
@end

// A live handle to one CEF download. Created in OnBeforeDownload, updated on
// each OnDownloadUpdated. Progress/lifecycle fields are declared readwrite here
// so their synthesized setters fire KVO (public header exposes them readonly).
// Holds the latest CefDownloadItemCallback so pause/resume/cancel can drive the
// download. All CEF-callback methods are invoked on the main thread — which is
// CEF's UI thread — so the callbacks are called directly, no extra hop.
@interface ChromiumDownload () {
  CefRefPtr<CefDownloadItemCallback> _itemCallback;
  BOOL _pendingCancel;
}
@property (nonatomic, assign) uint32_t downloadId;
@property (nonatomic, strong, readwrite, nullable) NSURL* url;
@property (nonatomic, strong, readwrite, nullable) NSURL* originalURL;
@property (nonatomic, copy, readwrite, nullable) NSString* suggestedFilename;
@property (nonatomic, copy, readwrite, nullable) NSString* mimeType;
@property (nonatomic, strong, readwrite, nullable) NSURL* fileURL;
@property (nonatomic, assign, readwrite) long long receivedBytes;
@property (nonatomic, assign, readwrite) long long totalBytes;
@property (nonatomic, assign, readwrite, getter=isInProgress) BOOL inProgress;
@property (nonatomic, assign, readwrite, getter=isComplete) BOOL complete;
@property (nonatomic, assign, readwrite, getter=isCanceled) BOOL canceled;
@end

@implementation ChromiumDownload
- (instancetype)initWithDownloadId:(uint32_t)downloadId {
  if ((self = [super init])) {
    _downloadId = downloadId;
    _totalBytes = -1;
  }
  return self;
}

- (void)cancel {
  if (_itemCallback) { _itemCallback->Cancel(); }
  else { _pendingCancel = YES; }
}

- (void)pause {
  if (_itemCallback) { _itemCallback->Pause(); }
}

- (void)resume {
  if (_itemCallback) { _itemCallback->Resume(); }
}

- (void)_updateItemCallback:(CefRefPtr<CefDownloadItemCallback>)cb {
  _itemCallback = cb;
}

- (void)_markPendingCancel {
  _pendingCancel = YES;
}

- (BOOL)_consumePendingCancel {
  if (_pendingCancel) { _pendingCancel = NO; return YES; }
  return NO;
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
- (void)_ensureDevToolsDomainsEnabled;
- (void)_installUserScript:(NSString*)source;
- (void)_onBeforeDownloadId:(uint32_t)downloadId
                        url:(nullable NSURL*)url
                originalURL:(nullable NSURL*)originalURL
              suggestedName:(nullable NSString*)suggestedName
                   mimeType:(nullable NSString*)mimeType
                 totalBytes:(long long)totalBytes
                   callback:(CefRefPtr<CefBeforeDownloadCallback>)callback;
- (void)_onDownloadUpdatedId:(uint32_t)downloadId
                    received:(long long)received
                       total:(long long)total
                  inProgress:(BOOL)inProgress
                    complete:(BOOL)complete
                    canceled:(BOOL)canceled
                    fullPath:(nullable NSString*)fullPath
                    callback:(CefRefPtr<CefDownloadItemCallback>)callback;
- (void)_reinstallUserScripts;
- (void)_applyZoomFactor;
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

NSString* cefToNSString(const CefString& s) {
  if (s.empty()) return nil;
  return [NSString stringWithUTF8String:s.ToString().c_str()];
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

// CEF key-event modifier bitmask -> NSEventModifierFlags.
static NSEventModifierFlags nsFlagsFromCefModifiers(uint32_t m) {
  NSEventModifierFlags f = 0;
  if (m & EVENTFLAG_SHIFT_DOWN) f |= NSEventModifierFlagShift;
  if (m & EVENTFLAG_CONTROL_DOWN) f |= NSEventModifierFlagControl;
  if (m & EVENTFLAG_ALT_DOWN) f |= NSEventModifierFlagOption;
  if (m & EVENTFLAG_COMMAND_DOWN) f |= NSEventModifierFlagCommand;
  if (m & EVENTFLAG_CAPS_LOCK_ON) f |= NSEventModifierFlagCapsLock;
  return f;
}

// A single UTF-16 code unit -> NSString (nil for a null character).
static NSString* _Nullable nsStringFromChar16(char16_t c) {
  if (c == 0) return nil;
  unichar u = (unichar)c;
  return [NSString stringWithCharacters:&u length:1];
}

static ChromiumKeyEvent* keyEventFromCef(const CefKeyEvent& e) {
  return [[ChromiumKeyEvent alloc]
        _initWithCharacters:nsStringFromChar16(e.character)
      charactersIgnoringModifiers:nsStringFromChar16(e.unmodified_character)
                    modifierFlags:nsFlagsFromCefModifiers(e.modifiers)
                          keyCode:(unsigned short)e.native_key_code];
}

// Map a CEF page-transition type to the coarse navigation kind Mirror routes on.
static ChromiumNavigationType navTypeFromTransition(cef_transition_type_t t) {
  switch (t & TT_SOURCE_MASK) {
    case TT_LINK: return ChromiumNavigationTypeLinkActivated;
    case TT_FORM_SUBMIT: return ChromiumNavigationTypeFormSubmitted;
    case TT_RELOAD: return ChromiumNavigationTypeReload;
    default: return ChromiumNavigationTypeOther;
  }
}

static ChromiumNavigationRequest* navRequestFromCef(CefRefPtr<CefFrame> frame,
                                                    CefRefPtr<CefRequest> request,
                                                    bool user_gesture,
                                                    bool is_redirect) {
  return [[ChromiumNavigationRequest alloc]
        _initWithURL:nsurlFromCefString(request->GetURL())
           mainFrame:(frame && frame->IsMain()) ? YES : NO
         userGesture:user_gesture ? YES : NO
            redirect:is_redirect ? YES : NO
      navigationType:navTypeFromTransition(request->GetTransitionType())];
}

static NSString* nsStringFromResourceType(cef_resource_type_t type) {
  switch (type) {
    case RT_MAIN_FRAME: return @"document";
    case RT_SUB_FRAME: return @"subframe";
    case RT_STYLESHEET: return @"stylesheet";
    case RT_SCRIPT: return @"script";
    case RT_IMAGE: return @"image";
    case RT_FONT_RESOURCE: return @"font";
    case RT_OBJECT: return @"object";
    case RT_MEDIA: return @"media";
    case RT_WORKER: return @"worker";
    case RT_SHARED_WORKER: return @"shared-worker";
    case RT_PREFETCH: return @"prefetch";
    case RT_FAVICON: return @"favicon";
    case RT_XHR: return @"xhr";
    case RT_PING: return @"ping";
    case RT_SERVICE_WORKER: return @"service-worker";
    case RT_CSP_REPORT: return @"csp-report";
    case RT_PLUGIN_RESOURCE: return @"plugin-resource";
    default: return @"other";
  }
}

class _ChromiumClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefRequestHandler,
                   public CefResourceRequestHandler,
                   public CefDownloadHandler,
                   public CefKeyboardHandler,
                   public CefFindHandler {
 public:
  _ChromiumClient() = default;
  explicit _ChromiumClient(ChromiumView* owner) : owner_(owner) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> /*browser*/,
      CefRefPtr<CefFrame> /*frame*/,
      CefRefPtr<CefRequest> /*request*/,
      bool /*is_navigation*/,
      bool /*is_download*/,
      const CefString& /*request_initiator*/,
      bool& /*disable_default_handling*/) override {
    // Only intercept when a blocker is installed; otherwise return null so CEF
    // keeps its default network path (and its associated request-context
    // handler, if any) untouched — no per-request overhead when unused.
    ChromiumView* view = owner_;
    return (view && view.resourceRequestBlocker) ? this : nullptr;
  }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

  // Called on the CEF UI thread (== main thread here) before a navigation
  // commits — the CEF analogue of WKWebView's decidePolicyFor navigationAction.
  // Consults the Swift `navigationDecisionHandler` SYNCHRONOUSLY and returns
  // true to CANCEL the navigation (handler returned YES), false to allow it. A
  // nil view or nil handler means "allow". Modifier/middle-click new-tab
  // navigations do NOT reach here — CEF routes those via OnOpenURLFromTab.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> /*browser*/,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    ChromiumView* view = owner_;
    if (!view) return false;
    BOOL (^handler)(ChromiumNavigationRequest*) = view.navigationDecisionHandler;
    if (!handler) return false;
    return handler(navRequestFromCef(frame, request, user_gesture, is_redirect))
               ? true
               : false;
  }

  // Called on the CEF IO thread before every resource request (main-frame
  // navigations + every subresource) hits the network — the CEF analogue of a
  // WKContentRuleList "block" action. Consults the Swift `resourceRequestBlocker`
  // SYNCHRONOUSLY and cancels the request when it returns YES. This deliberately
  // does NOT hop to the main thread: ad blocking needs a per-request verdict
  // before the network fetch starts, so the blocker must be thread-safe + fast.
  // owner_ is __weak (ARC-safe to load off-main); a nil view or nil blocker
  // means "allow" (RV_CONTINUE).
  cef_return_value_t OnBeforeResourceLoad(
      CefRefPtr<CefBrowser> /*browser*/,
      CefRefPtr<CefFrame> /*frame*/,
      CefRefPtr<CefRequest> request,
      CefRefPtr<CefCallback> /*callback*/) override {
    ChromiumView* view = owner_;
    if (!view) return RV_CONTINUE;
    BOOL (^blocker)(NSURL*, NSString*) = view.resourceRequestBlocker;
    if (!blocker) return RV_CONTINUE;
    NSURL* url = nsurlFromCefString(request->GetURL());
    if (!url) return RV_CONTINUE;
    NSString* type = nsStringFromResourceType(request->GetResourceType());
    return blocker(url, type) ? RV_CANCEL : RV_CONTINUE;
  }

  // Called after the renderer and page JavaScript have had their chance to
  // handle the key (CEF's post-page "unhandled key" callback). We deliberately
  // use OnKeyEvent, NOT OnPreKeyEvent: OnPreKeyEvent fires before the page and
  // would steal shortcuts (Cmd+F / Cmd+P) from web apps that handle them
  // themselves. This runs on the CEF UI thread — which is the main thread under
  // both the external-message-pump and CefRunMessageLoop models on macOS — so
  // we can consult the Swift `keyboardHandler` synchronously and return its
  // handled result straight back to CEF. Only key-down events are forwarded.
  bool OnKeyEvent(CefRefPtr<CefBrowser> /*browser*/,
                  const CefKeyEvent& event,
                  CefEventHandle /*os_event*/) override {
    if (event.type != KEYEVENT_RAWKEYDOWN && event.type != KEYEVENT_KEYDOWN) {
      return false;
    }
    ChromiumView* view = owner_;
    if (!view) return false;
    BOOL (^handler)(ChromiumKeyEvent*) = view.keyboardHandler;
    if (!handler) return false;
    return handler(keyEventFromCef(event)) ? true : false;
  }

  // Reports find-in-page results for a CefBrowserHost::Find search. Called on
  // the CEF UI thread (== main thread here); hop to the main queue and hand the
  // result to the Swift findResultHandler, matching the other display callbacks.
  // A nil view or nil handler drops the result.
  void OnFindResult(CefRefPtr<CefBrowser> /*browser*/,
                    int /*identifier*/,
                    int count,
                    const CefRect& /*selectionRect*/,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    __weak ChromiumView* o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      ChromiumView* view = o;
      if (!view) return;
      void (^handler)(ChromiumFindResult*) = view.findResultHandler;
      if (!handler) return;
      handler([[ChromiumFindResult alloc] _initWithCount:count
                                      activeMatchOrdinal:activeMatchOrdinal
                                             finalUpdate:finalUpdate ? YES : NO]);
    });
  }

  // A download is starting. Snapshot the item's fields on the UI thread, then
  // hop to the main queue to ask the ChromiumView's downloadDelegate where to
  // write it; the delegate's completion calls callback->Continue with the path
  // (or cancels). Returning true keeps CEF from doing its own default handling.
  bool OnBeforeDownload(CefRefPtr<CefBrowser> /*browser*/,
                        CefRefPtr<CefDownloadItem> item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    __weak ChromiumView* o = owner_;
    uint32_t downloadId = item->GetId();
    NSString* suggested = cefToNSString(suggested_name);
    NSURL* url = nsurlFromCefString(item->GetURL());
    NSURL* originalURL = nsurlFromCefString(item->GetOriginalUrl());
    NSString* mime = cefToNSString(item->GetMimeType());
    int64_t total = item->GetTotalBytes();
    dispatch_async(dispatch_get_main_queue(), ^{
      [o _onBeforeDownloadId:downloadId
                         url:url
                 originalURL:originalURL
               suggestedName:suggested
                    mimeType:mime
                  totalBytes:total
                    callback:callback];
    });
    return true;
  }

  // Progress / completion tick. Snapshot on the UI thread; the main-queue hop
  // updates the ChromiumDownload's KVO fields and stores the item callback so
  // the handle's pause/resume/cancel can drive the download.
  void OnDownloadUpdated(CefRefPtr<CefBrowser> /*browser*/,
                         CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    __weak ChromiumView* o = owner_;
    uint32_t downloadId = item->GetId();
    int64_t received = item->GetReceivedBytes();
    int64_t total = item->GetTotalBytes();
    BOOL inProgress = item->IsInProgress() ? YES : NO;
    BOOL complete = item->IsComplete() ? YES : NO;
    BOOL canceled = (item->IsCanceled() || item->IsInterrupted()) ? YES : NO;
    NSString* fullPath = cefToNSString(item->GetFullPath());
    dispatch_async(dispatch_get_main_queue(), ^{
      [o _onDownloadUpdatedId:downloadId
                     received:received
                        total:total
                   inProgress:inProgress
                     complete:complete
                     canceled:canceled
                     fullPath:fullPath
                     callback:callback];
    });
  }

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

#pragma mark - ChromiumDataStore

@interface ChromiumDataStore () {
  // Lazily-created CEF request context backing this store. Nil for the default
  // store (which uses CEF's process-global context, matching CreateBrowser's
  // null request_context) and until first use for the others.
  CefRefPtr<CefRequestContext> _context;
  // Absolute on-disk cache path for a persistent isolated store, or nil for an
  // in-memory (non-persistent) context.
  NSString* _cachePath;
  BOOL _isDefault;
  BOOL _persistent;
}
- (instancetype)_initInternal;
- (CefRefPtr<CefRequestContext>)_ensureRequestContext;
@end

@implementation ChromiumDataStore

+ (ChromiumDataStore*)defaultStore {
  ChromiumDataStore* s = [[ChromiumDataStore alloc] _initInternal];
  s->_isDefault = YES;
  s->_persistent = YES;
  return s;
}

+ (ChromiumDataStore*)nonPersistentStore {
  ChromiumDataStore* s = [[ChromiumDataStore alloc] _initInternal];
  s->_isDefault = NO;
  s->_cachePath = nil;  // empty cache_path => in-memory request context
  s->_persistent = NO;
  return s;
}

+ (ChromiumDataStore*)storeForIdentifier:(NSString*)identifier {
  ChromiumDataStore* s = [[ChromiumDataStore alloc] _initInternal];
  s->_isDefault = NO;
  NSString* root = _ChromiumResolvedRootCachePath();
  if (root.length) {
    // CEF requires a context cache_path be a child of root_cache_path. Reduce
    // the identifier to a safe single path component.
    NSCharacterSet* unsafe =
        [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString* safe = [[identifier componentsSeparatedByCharactersInSet:unsafe]
        componentsJoinedByString:@"_"];
    if (safe.length == 0) { safe = @"profile"; }
    s->_cachePath = [[root stringByAppendingPathComponent:@"Profiles"]
        stringByAppendingPathComponent:safe];
    s->_persistent = YES;
  } else {
    // No root cache path configured — degrade to an in-memory context.
    s->_cachePath = nil;
    s->_persistent = NO;
  }
  return s;
}

- (instancetype)_initInternal {
  return [super init];
}

- (BOOL)isPersistent {
  return _persistent;
}

// The CEF request context for this store, created on first use on the main (CEF
// UI) thread. Returns nullptr for the default store so CreateBrowser falls back
// to the process-global context.
- (CefRefPtr<CefRequestContext>)_ensureRequestContext {
  if (_isDefault) { return nullptr; }
  if (!_context) {
    CefRequestContextSettings settings;
    if (_cachePath.length) {
      CefString(&settings.cache_path).FromString(_cachePath.UTF8String);
    }
    _context = CefRequestContext::CreateContext(settings, nullptr);
  }
  return _context;
}

@end

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
  // Raw DevTools result callbacks keyed by message id — like _evalCallbacks
  // but delivering the whole `result` object (used to capture the identifier
  // that Page.addScriptToEvaluateOnNewDocument returns).
  NSMutableDictionary<NSNumber*, void(^)(NSDictionary* _Nullable)>* _rawResultCallbacks;
  // Document-start user scripts (WKUserScript @ .atDocumentStart equivalent):
  // the JS sources in add-order, plus the DevTools identifiers CEF assigned to
  // them (so removeAllUserScripts can tear them down). Sources survive
  // navigations and are re-applied whenever the browser (re)attaches.
  NSMutableArray<NSString*>* _documentStartScripts;
  NSMutableArray<NSString*>* _documentStartScriptIdentifiers;
  // In-flight downloads keyed by CEF download id, so OnDownloadUpdated can find
  // the ChromiumDownload handle created in OnBeforeDownload. Dropped when the
  // download finishes/cancels (the delegate retains its own reference).
  NSMutableDictionary<NSNumber*, ChromiumDownload*>* _downloads;
  // Requested page zoom as a multiplier (1.0 == 100%). Stored so the
  // getter is deterministic and the value survives a not-yet-attached
  // browser; pushed to CEF as a zoom LEVEL whenever a browser exists.
  CGFloat _zoomFactor;
  // Data store providing this view's CefRequestContext (cookies / cache /
  // localStorage isolation). Nil == the process-global (default) context.
  ChromiumDataStore* _dataStore;
}

@synthesize URL = _URL;
@synthesize navigationDelegate = _navigationDelegate;

- (instancetype)initWithFrame:(NSRect)frame URL:(NSURL*)url {
  if ((self = [super initWithFrame:frame])) {
    _URL = [url copy];
    _nextEvalId = 1;
    _evalCallbacks = [NSMutableDictionary new];
    _messageHandlers = [NSMutableDictionary new];
    _rawResultCallbacks = [NSMutableDictionary new];
    _documentStartScripts = [NSMutableArray new];
    _documentStartScriptIdentifiers = [NSMutableArray new];
    _downloads = [NSMutableDictionary new];
    _zoomFactor = 1.0;
    self.wantsLayer = YES;
  }
  return self;
}

- (instancetype)initWithFrame:(NSRect)frame URL:(NSURL*)url
                    dataStore:(ChromiumDataStore*)dataStore {
  if ((self = [self initWithFrame:frame URL:url])) {
    _dataStore = dataStore;
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

- (void)_onBeforeDownloadId:(uint32_t)downloadId
                        url:(NSURL*)url
                originalURL:(NSURL*)originalURL
              suggestedName:(NSString*)suggestedName
                   mimeType:(NSString*)mimeType
                 totalBytes:(long long)totalBytes
                   callback:(CefRefPtr<CefBeforeDownloadCallback>)callback {
  ChromiumDownload* dl = [[ChromiumDownload alloc] initWithDownloadId:downloadId];
  dl.url = url;
  dl.originalURL = originalURL;
  dl.suggestedFilename = suggestedName;
  dl.mimeType = mimeType;
  dl.totalBytes = totalBytes;
  dl.inProgress = YES;
  _downloads[@(downloadId)] = dl;

  id<ChromiumDownloadDelegate> d = self.downloadDelegate;
  SEL destSel = @selector(webView:decideDestinationForDownload:suggestedFilename:completionHandler:);
  if (![d respondsToSelector:destSel]) {
    // No delegate: cancel by never continuing; the next update tick cancels it.
    [dl _markPendingCancel];
    return;
  }
  [d webView:self
      decideDestinationForDownload:dl
                 suggestedFilename:suggestedName
                 completionHandler:^(NSURL* _Nullable destination) {
    if (destination) {
      dl.fileURL = destination;
      callback->Continue(CefString(destination.path.UTF8String),
                         /*show_dialog=*/false);
    } else {
      [dl _markPendingCancel];
    }
  }];
}

- (void)_onDownloadUpdatedId:(uint32_t)downloadId
                    received:(long long)received
                       total:(long long)total
                  inProgress:(BOOL)inProgress
                    complete:(BOOL)complete
                    canceled:(BOOL)canceled
                    fullPath:(NSString*)fullPath
                    callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  ChromiumDownload* dl = _downloads[@(downloadId)];
  if (!dl) { return; }
  [dl _updateItemCallback:callback];
  if ([dl _consumePendingCancel]) {
    callback->Cancel();
    [_downloads removeObjectForKey:@(downloadId)];
    return;
  }
  dl.receivedBytes = received;
  dl.totalBytes = total;
  if (fullPath.length > 0) { dl.fileURL = [NSURL fileURLWithPath:fullPath]; }
  dl.inProgress = inProgress;
  dl.complete = complete;
  dl.canceled = canceled;
  if (complete || canceled) {
    // The delegate retains the handle it received; drop our internal reference.
    [_downloads removeObjectForKey:@(downloadId)];
  }
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
  // Per-view data isolation: a data store vends its CefRequestContext; the
  // default store (or no store) passes null so CEF uses the global context.
  CefRefPtr<CefRequestContext> requestContext =
      _dataStore ? [_dataStore _ensureRequestContext] : nullptr;
  CefBrowserHost::CreateBrowser(wi, _client.get(),
                                [urlString UTF8String], bs, nullptr,
                                requestContext);
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
  [self _reinstallUserScripts];
  [self _applyZoomFactor];
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

#pragma mark - Audio

- (BOOL)isAudioMuted { auto b = [self _browser]; return b ? b->GetHost()->IsAudioMuted() : NO; }
- (void)setAudioMuted:(BOOL)muted { if (auto b = [self _browser]) b->GetHost()->SetAudioMuted(muted); }

#pragma mark - Zoom

// Chromium relates the zoom LEVEL that CefBrowserHost::SetZoomLevel takes to the
// zoom FACTOR (100% == factor 1.0) callers think in via factor = 1.2 ^ level,
// i.e. level = log(factor) / log(1.2) — Chromium's kTextSizeMultiplierRatio.
static const double kChromiumZoomTextSizeMultiplierRatio = 1.2;

- (CGFloat)zoomFactor { return _zoomFactor; }

- (void)setZoomFactor:(CGFloat)zoomFactor {
  _zoomFactor = zoomFactor;
  [self _applyZoomFactor];
}

// Push the stored factor to CEF as a zoom level. No-op until a browser attaches;
// _browserDidCreate re-applies so a zoom set before creation still takes effect.
- (void)_applyZoomFactor {
  auto b = [self _browser];
  if (!b) return;
  double level = (_zoomFactor > 0)
      ? std::log((double)_zoomFactor) / std::log(kChromiumZoomTextSizeMultiplierRatio)
      : 0.0;
  b->GetHost()->SetZoomLevel(level);
}

#pragma mark - Find

- (void)findText:(NSString*)text
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext {
  if (auto b = [self _browser]) {
    b->GetHost()->Find([text UTF8String], forward, matchCase, findNext);
  }
}

- (void)stopFinding:(BOOL)clearSelection {
  if (auto b = [self _browser]) b->GetHost()->StopFinding(clearSelection);
}

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
  if (void (^rawCb)(NSDictionary* _Nullable) = _rawResultCallbacks[@(messageId)]) {
    [_rawResultCallbacks removeObjectForKey:@(messageId)];
    id obj = success ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary* result = [obj isKindOfClass:[NSDictionary class]] ? ((NSDictionary*)obj)[@"result"] : nil;
    rawCb([result isKindOfClass:[NSDictionary class]] ? result : nil);
    return;
  }
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
  [self _sendDevToolsMethod:method params:params resultHandler:nil];
}

// Send a DevTools Protocol command. When `resultHandler` is non-nil it is
// invoked (main thread) with the command's `result` object once CEF replies,
// so callers can read values the command returns (e.g. the identifier from
// Page.addScriptToEvaluateOnNewDocument).
- (void)_sendDevToolsMethod:(NSString*)method
                     params:(nullable NSDictionary*)params
              resultHandler:(nullable void (^)(NSDictionary* _Nullable result))resultHandler {
  auto b = [self _browser];
  if (!b) return;
  int msgId = ++_nextEvalId;
  if (resultHandler) _rawResultCallbacks[@(msgId)] = [resultHandler copy];
  NSMutableDictionary* req = [@{ @"id": @(msgId), @"method": method } mutableCopy];
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

// Enable the Runtime/Page DevTools domains once per browser attach. Runtime.enable
// delivers bindingCalled events (the JS→native bridge); Page.enable is required
// for addScriptToEvaluateOnNewDocument (message-handler shims + user scripts).
- (void)_ensureDevToolsDomainsEnabled {
  if (_runtimeDomainsEnabled) return;
  [self _sendDevToolsMethod:@"Runtime.enable" params:nil];
  [self _sendDevToolsMethod:@"Page.enable" params:nil];
  _runtimeDomainsEnabled = YES;
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
  [self _ensureDevToolsDomainsEnabled];
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

#pragma mark - Document-start user scripts

- (void)addUserScriptAtDocumentStart:(NSString*)source {
  if (source.length == 0) return;
  [_documentStartScripts addObject:[source copy]];
  [self _installUserScript:source];
}

- (void)removeAllUserScripts {
  [_documentStartScripts removeAllObjects];
  if ([self _browser]) {
    for (NSString* identifier in _documentStartScriptIdentifiers) {
      [self _sendDevToolsMethod:@"Page.removeScriptToEvaluateOnNewDocument"
                         params:@{ @"identifier": identifier }];
    }
  }
  [_documentStartScriptIdentifiers removeAllObjects];
}

// Register one document-start script with CEF for all future documents. Unlike
// the message-handler shim we do NOT Runtime.evaluate it against the current
// document — WKUserScript at .atDocumentStart only affects subsequent loads.
- (void)_installUserScript:(NSString*)source {
  if (![self _browser]) return;  // deferred; _reinstallUserScripts re-applies
  [self _ensureDevToolsDomainsEnabled];
  __weak ChromiumView* weakSelf = self;
  [self _sendDevToolsMethod:@"Page.addScriptToEvaluateOnNewDocument"
                     params:@{ @"source": source }
              resultHandler:^(NSDictionary* _Nullable result) {
    ChromiumView* strongSelf = weakSelf;
    if (!strongSelf) return;
    NSString* identifier = result[@"identifier"];
    if ([identifier isKindOfClass:[NSString class]]) {
      [strongSelf->_documentStartScriptIdentifiers addObject:identifier];
    }
  }];
}

// Re-apply every document-start script when the browser (re)attaches. The old
// browser's identifiers are stale, so drop them and re-register from source.
- (void)_reinstallUserScripts {
  if (![self _browser] || _documentStartScripts.count == 0) return;
  [_documentStartScriptIdentifiers removeAllObjects];
  for (NSString* source in _documentStartScripts) {
    [self _installUserScript:source];
  }
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
