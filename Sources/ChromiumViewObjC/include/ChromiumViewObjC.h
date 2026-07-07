// Obj-C surface. The Swift names (via NS_SWIFT_NAME) are what consumers see.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ChromiumView;
@class ChromiumConfiguration;
@class ChromiumDownload;
@class ChromiumKeyEvent;
@protocol ChromiumNavigationDelegate;
@protocol ChromiumDownloadDelegate;

/// Backing object for a single favicon download. Identity = URL: when the
/// page swaps to a new favicon URL, `ChromiumView.favicon` is replaced with a
/// fresh instance, so stale download callbacks land on the old (now
/// unreferenced) one rather than overwriting current state.
/// The Swift `Favicon` wrapper in ChromiumKit exposes this with @Observable.
NS_SWIFT_NAME(CEFFaviconRef)
@interface CEFFaviconRef : NSObject
@property (nonatomic, readonly) NSURL* url;
@property (nonatomic, readonly, nullable) NSImage* image;
- (instancetype)initWithURL:(NSURL*)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef void (^CEFSetupBlock)(void);

NS_SWIFT_NAME(ChromiumConfiguration)
@interface ChromiumConfiguration : NSObject <NSCopying>
/// Overrides the User-Agent string sent on every request.
@property (nonatomic, copy, nullable) NSString* userAgent;
/// Locale to advertise (defaults to system).
@property (nonatomic, copy, nullable) NSString* locale;
/// Cache directory. Defaults to `~/Library/Caches/<bundle-id>`.
@property (nonatomic, copy, nullable) NSURL* cachePath;
/// Disable the Chromium sandbox (default YES — standard CEF distribution
/// doesn't ship `cef_sandbox.a`). Flip off only if linking the Sandbox
/// Distribution.
@property (nonatomic, assign) BOOL sandboxDisabled;
/// Use Chromium's mock keychain instead of the macOS Keychain for "safe
/// storage" (cookie/password encryption). Default NO. Set YES to avoid the
/// "<App> wants to use the 'Chromium Safe Storage' key" prompt — useful for
/// demos, CI, and automated UI tests, where the prompt blocks an unattended
/// run. Trade-off: safe-storage encryption uses a fixed mock key rather than
/// one held in the Keychain, so don't enable it for an app holding real
/// credentials.
@property (nonatomic, assign) BOOL useMockKeychain;
/// Run CEF as an EXTERNAL message pump instead of letting CEF own the run loop.
/// Default NO: `ChromiumApplication.run` calls `CefRunMessageLoop()`, which runs
/// Chromium's own loop and never `[NSApp run]`. Set YES when the HOST wants to
/// own the AppKit run loop (`[NSApp run]`) — CEF then sets
/// `external_message_pump` and is pumped via `CefDoMessageLoopWork()` scheduled
/// onto the main queue from `OnScheduleMessagePumpWork`. This lets AppKit's run
/// loop keep draining libdispatch and the Swift main-actor executor, which
/// `CefRunMessageLoop()` starves — required for any host that awaits on the
/// main actor (e.g. SwiftUI `.task`) between AppKit events.
@property (nonatomic, assign) BOOL externalMessagePump;
@end

NS_SWIFT_NAME(ChromiumApplication)
@interface ChromiumApplication : NSObject
+ (int)runWithSetup:(CEFSetupBlock)setup NS_SWIFT_NAME(run(setup:));
+ (int)runWithConfiguration:(nullable ChromiumConfiguration*)config
                      setup:(CEFSetupBlock)setup
    NS_SWIFT_NAME(run(configuration:setup:));
+ (int)runHelper NS_SWIFT_NAME(runHelper());

+ (int)runWithSetup:(CEFSetupBlock)setup argc:(int)argc argv:(char* _Nonnull[_Nonnull])argv
    NS_SWIFT_UNAVAILABLE("use run(setup:)");
+ (int)runHelperWithArgc:(int)argc argv:(char* _Nonnull[_Nonnull])argv
    NS_SWIFT_UNAVAILABLE("use runHelper()");
@end

/// Where a popup wants to land. Mirrors a subset of CEF's
/// `WindowOpenDisposition`. Only the TAB cases get routed through the
/// `requestsNewTab` delegate; everything else falls through to CEF's
/// default popup behavior.
typedef NS_ENUM(NSInteger, CEFTabDisposition) {
    /// `target="_blank"` click; `cmd+shift+click`.
    CEFTabDispositionNewForegroundTab = 0,
    /// `cmd+click`.
    CEFTabDispositionNewBackgroundTab = 1,
} NS_SWIFT_NAME(CEFTabDisposition);

NS_SWIFT_NAME(ChromiumNavigationDelegate)
@protocol ChromiumNavigationDelegate <NSObject>
@optional
// Navigation EVENTS. State mirrors (title / isLoading / canGoBack /
// canGoForward / URL) are KVO-observable on ChromiumView directly — observe
// those rather than listening here.
- (void)webView:(ChromiumView*)webView didStartProvisionalNavigation:(nullable NSURL*)url
    NS_SWIFT_NAME(webView(_:didStartProvisionalNavigationTo:));
- (void)webView:(ChromiumView*)webView didFinishNavigationTo:(nullable NSURL*)url statusCode:(int)code
    NS_SWIFT_NAME(webView(_:didFinishNavigationTo:statusCode:));
- (void)webView:(ChromiumView*)webView didFailNavigationWithError:(NSError*)error
    NS_SWIFT_NAME(webView(_:didFailNavigationWith:));

/// A page in `webView` (the opener) asked to open `url` in a new tab —
/// either via `target="_blank"` or `window.open(url, "_blank")`. The
/// delegate should:
///   • create a popup ChromiumView via `+[ChromiumView popupView]`
///   • append it to its tab model (so it stays alive + gets mounted in a window)
///   • select it if the disposition is foreground
///   • return that view
///
/// CEF will then create the popup browser INSIDE the returned view, with
/// `window.opener` wired up to the source page. Returning nil falls back
/// to CEF's default behavior (a detached browser window).
- (nullable ChromiumView*)webView:(ChromiumView*)webView
        requestsNewTabForURL:(nullable NSURL*)url
                 userGesture:(BOOL)userGesture
                 disposition:(CEFTabDisposition)disposition
    NS_SWIFT_NAME(webView(_:requestsNewTabFor:userGesture:disposition:));
@end

#pragma mark - Downloads

/// A live handle to a single file download started inside a ChromiumView —
/// the ChromiumKit analogue of `WKDownload`. Progress and lifecycle fields are
/// KVO-observable (like `WKDownload.progress`); retain this handle to control
/// the download via `pause` / `resume` / `cancel`. Delivered to the
/// `ChromiumDownloadDelegate`; backed by CEF's `CefDownloadItem` +
/// `CefDownloadItemCallback`.
NS_SWIFT_NAME(ChromiumDownload)
@interface ChromiumDownload : NSObject
/// The download URL (after redirects).
@property (nonatomic, readonly, nullable) NSURL* url;
/// The original URL before any redirection.
@property (nonatomic, readonly, nullable) NSURL* originalURL;
/// CEF's suggested file name for the download.
@property (nonatomic, readonly, nullable) NSString* suggestedFilename;
/// The download's MIME type, if known.
@property (nonatomic, readonly, nullable) NSString* mimeType;
/// The full path to the (downloading or finished) file once a destination has
/// been chosen. KVO-observable.
@property (nonatomic, readonly, nullable) NSURL* fileURL;
/// Bytes received so far. KVO-observable.
@property (nonatomic, readonly) long long receivedBytes;
/// Total bytes expected, or -1 if unknown. KVO-observable.
@property (nonatomic, readonly) long long totalBytes;
/// YES while the download is running. KVO-observable.
@property (nonatomic, readonly, getter=isInProgress) BOOL inProgress;
/// YES once the download has finished successfully. KVO-observable.
@property (nonatomic, readonly, getter=isComplete) BOOL complete;
/// YES once the download has been canceled or interrupted. KVO-observable.
@property (nonatomic, readonly, getter=isCanceled) BOOL canceled;
/// Cancel the download. Any partially-written file is removed by CEF.
- (void)cancel;
/// Pause the download. Resume with `resume`.
- (void)pause;
/// Resume a paused download.
- (void)resume;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Delegate that decides where a ChromiumView's downloads are written — the
/// ChromiumKit analogue of `WKDownloadDelegate`'s
/// `download(_:decideDestinationUsing:suggestedFilename:)`.
NS_SWIFT_NAME(ChromiumDownloadDelegate)
@protocol ChromiumDownloadDelegate <NSObject>
/// A download is about to begin. Provide the full destination file URL
/// (including file name) via `completionHandler`, or `nil` to cancel the
/// download. Called on the MAIN THREAD; `completionHandler` may be invoked
/// asynchronously (e.g. after a save panel) and must be called on the main
/// thread.
- (void)webView:(ChromiumView*)webView
    decideDestinationForDownload:(ChromiumDownload*)download
               suggestedFilename:(NSString*)suggestedFilename
               completionHandler:(void (^)(NSURL* _Nullable destination))completionHandler
    NS_SWIFT_NAME(webView(_:decideDestinationFor:suggestedFilename:completionHandler:));
@end

#pragma mark - Keyboard

/// A key-down event that the page (renderer + JavaScript) did not handle,
/// delivered to `ChromiumView.keyboardHandler` — CEF's browser-process fallback
/// for keyboard shortcuts, and the analogue of a WKWebView key event bubbling
/// up to the app unhandled. Mirrors the useful fields of `NSEvent`.
NS_SWIFT_NAME(ChromiumKeyEvent)
@interface ChromiumKeyEvent : NSObject
/// The characters generated by the key, honoring modifiers — like
/// `NSEvent.characters` (e.g. "f").
@property (nonatomic, readonly, nullable) NSString* characters;
/// The characters generated by the key ignoring modifiers — like
/// `NSEvent.charactersIgnoringModifiers`.
@property (nonatomic, readonly, nullable) NSString* charactersIgnoringModifiers;
/// The active modifier keys, mapped to `NSEventModifierFlags`.
@property (nonatomic, readonly) NSEventModifierFlags modifierFlags;
/// The platform key code — `NSEvent.keyCode` on macOS.
@property (nonatomic, readonly) unsigned short keyCode;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_NAME(ChromiumWebView)
@interface ChromiumView : NSView

@property (nonatomic, copy, nullable) NSURL* URL;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly, nullable) NSString* title;
/// Current page favicon. A new instance is created every time the page's
/// favicon URL changes — `url` is fixed at construction, `image` lands
/// asynchronously when CEF's image loader finishes the download. Old
/// instances orphan naturally when the URL changes again, so a late
/// callback writing to one is harmless. KVO-observable.
@property (nonatomic, readonly, nullable) CEFFaviconRef* favicon;
@property (nonatomic, weak, nullable) id<ChromiumNavigationDelegate> navigationDelegate;
/// Delegate that chooses download destinations. When nil, downloads are
/// canceled (no default save handling).
@property (nonatomic, weak, nullable) id<ChromiumDownloadDelegate> downloadDelegate;

/// Invoked for key-down events the page did not handle — CEF's post-page
/// "unhandled key" callback (`CefKeyboardHandler::OnKeyEvent`), the fallback
/// path for browser-level shortcuts like Cmd+F / Cmd+P. Return YES to mark the
/// event handled and stop CEF's default processing; NO to let it proceed.
/// Called on the MAIN THREAD. Note: this is deliberately the post-page callback
/// (not `OnPreKeyEvent`), so a web app that handles the key itself keeps it —
/// matching WKWebView, where the page sees the event first.
@property (nonatomic, copy, nullable) BOOL (^keyboardHandler)(ChromiumKeyEvent* event);

/// Invoked before every resource request (main-frame navigations + every
/// subresource: images, scripts, stylesheets, XHR/fetch, …) hits the network —
/// CEF's `CefResourceRequestHandler::OnBeforeResourceLoad`. Return YES to CANCEL
/// (block) the request, NO to allow it. This is the CEF analogue of a
/// `WKContentRuleList` "block" action, the primitive for ad/tracker blocking.
/// `resourceType` is a lowercase string ("document", "image", "script",
/// "stylesheet", "xhr", "font", "media", …). IMPORTANT: called on a BACKGROUND
/// (CEF IO) thread, synchronously — the verdict must be thread-safe and fast (no
/// blocking work, no hop to the main thread). Set it before the first load; when
/// nil, CEF's default network path is used unchanged (no interception overhead).
@property (nonatomic, copy, nullable) BOOL (^resourceRequestBlocker)(NSURL* url, NSString* resourceType);

- (instancetype)initWithFrame:(NSRect)frame URL:(nullable NSURL*)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)c NS_UNAVAILABLE;

/// Allocates a "shell" ChromiumView that does NOT create its own CefBrowser —
/// returned from the `requestsNewTab` delegate so CEF can attach a popup
/// browser into it. Calling load:/goBack:/etc. is a no-op until CEF's
/// `OnAfterCreated` arrives with the popup browser.
+ (ChromiumView*)popupView NS_SWIFT_NAME(popupView());

- (void)load:(NSURL*)url NS_SWIFT_NAME(load(_:));
- (void)loadHTMLString:(NSString*)html baseURL:(nullable NSURL*)baseURL
    NS_SWIFT_NAME(loadHTMLString(_:baseURL:));

- (void)reload;
- (void)reloadFromOrigin;
- (void)stopLoading;
- (void)goBack;
- (void)goForward;

#pragma mark - Audio

/// Mute or unmute this browser's audio output — CEF's
/// `CefBrowserHost::SetAudioMuted`. Non-destructive: media keeps playing but is
/// silenced, so setting it back to `NO` resumes audio in place (unlike stopping
/// media or capturing the audio stream). This is the CEF analogue of
/// WKWebView's `setAllMediaPlaybackSuspended(_:)` "stop the noise" control.
/// Safe to call before the browser is created — it no-ops until CEF attaches,
/// and the getter reports `NO` until then.
@property (nonatomic, assign, getter=isAudioMuted) BOOL audioMuted;

/// JS eval. `completion` is called on the main thread. `result` is a Foundation
/// JSON value (NSString / NSNumber / NSDictionary / NSArray / NSNull) unwrapped
/// from the DevTools Protocol's `RemoteObject`.
- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^_Nullable)(id _Nullable result, NSError* _Nullable error))completion
    NS_SWIFT_NAME(evaluateJavaScript(_:completion:));

#pragma mark - JS → native message handlers

/// Register a named handler that receives messages posted from JS via
/// `window.webkit.messageHandlers.<name>.postMessage(body)` — the same shape
/// as WKWebView's script-message handlers. ChromiumKit installs a shim into
/// every document (current + future navigations) exposing exactly that
/// `window.webkit.messageHandlers.<name>` object, so page scripts written
/// against WKWebView work unchanged.
///
/// `body` is delivered to `handler` on the MAIN THREAD as a Foundation JSON
/// value (NSString / NSNumber / NSDictionary / NSArray / NSNull), unwrapped the
/// same way `evaluateJavaScript`'s result is: the page's `postMessage` argument
/// is JSON-serialized in the shim and re-parsed here. A non-JSON argument (e.g.
/// a bare string that isn't valid JSON) is delivered as that NSString verbatim.
///
/// Registering the same `name` twice replaces the previous handler. Handlers
/// survive navigations. Safe to call before the browser is created — the
/// registration is applied once CEF attaches.
- (void)addMessageHandlerName:(NSString*)name
                      handler:(void (^)(id _Nullable body))handler
    NS_SWIFT_NAME(addMessageHandler(name:handler:));

/// Remove a handler registered with `addMessageHandler(name:handler:)` and tear
/// down its `window.webkit.messageHandlers.<name>` shim for future documents.
- (void)removeMessageHandlerName:(NSString*)name
    NS_SWIFT_NAME(removeMessageHandler(name:));

#pragma mark - Document-start user scripts

/// Inject `source` at the start of every document, before the page's own
/// scripts run — the CEF equivalent of a `WKUserScript` with
/// `injectionTime = .atDocumentStart` (and `forMainFrameOnly = NO`: it runs in
/// the main frame and every subframe). It applies to all FUTURE document loads
/// (surviving navigation), in the order the scripts were added, and — matching
/// `WKUserScript` — does NOT re-run on the document that is already loaded.
/// Safe to call before the browser is created: the registration is applied once
/// CEF attaches and re-applied if the browser reattaches.
- (void)addUserScriptAtDocumentStart:(NSString*)source
    NS_SWIFT_NAME(addUserScript(atDocumentStart:));

/// Remove every document-start user script registered via
/// `addUserScript(atDocumentStart:)` so future documents no longer receive
/// them. Scripts that already ran in the current document cannot be un-run —
/// the same semantics as `WKUserContentController.removeAllUserScripts()`.
- (void)removeAllUserScripts NS_SWIFT_NAME(removeAllUserScripts());

#pragma mark - DevTools

/// Open / close Chromium DevTools for this browser.
/// Setting `YES` while already open is a no-op focus; setting `NO` while
/// closed is a no-op. DevTools open in a new floating native window.
@property (nonatomic, assign) BOOL isDevToolsOpen;

@end

#pragma mark - Cookies

/// A single HTTP cookie — the subset of `NSHTTPCookie` / `WKHTTPCookieStore`
/// fields CEF's cookie store round-trips. Used with `ChromiumCookieStore`.
NS_SWIFT_NAME(ChromiumCookie)
@interface ChromiumCookie : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* value;
/// If empty/nil a *host* cookie is created (visible only to the exact host).
/// A leading "." makes it a *domain* cookie visible to sub-domains.
@property (nonatomic, copy, nullable) NSString* domain;
/// Path scope. Defaults to "/" when nil.
@property (nonatomic, copy, nullable) NSString* path;
/// Only sent over HTTPS when YES.
@property (nonatomic, assign) BOOL secure;
/// Hidden from `document.cookie` (JS) when YES.
@property (nonatomic, assign) BOOL httpOnly;
/// Expiry date. nil = a session cookie (dropped when the store is discarded).
@property (nonatomic, copy, nullable) NSDate* expires;
- (instancetype)initWithName:(NSString*)name value:(NSString*)value
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Process-global cookie store backed by CEF's global `CefCookieManager`
/// (`CefRequestContext::GetGlobalContext()->GetDefaultCookieManager()`) — the
/// analogue of `WKWebsiteDataStore.default().httpCookieStore`. ChromiumKit uses
/// a single global request context, so there is ONE shared store per process
/// and cookies set here are visible to every `ChromiumWebView`.
///
/// All completion blocks are invoked on the MAIN THREAD. Requires CEF to be
/// initialized — call from inside/after `ChromiumApplication.run` (e.g. its
/// setup block), on the main thread.
NS_SWIFT_NAME(ChromiumCookieStore)
@interface ChromiumCookieStore : NSObject
+ (ChromiumCookieStore*)globalStore NS_SWIFT_NAME(global());
- (instancetype)init NS_UNAVAILABLE;

/// Set `cookie` for `url`. `completion` (optional) reports whether CEF accepted
/// it — it rejects malformed names/values/domains or an invalid URL.
- (void)setCookie:(ChromiumCookie*)cookie
           forURL:(NSURL*)url
       completion:(void (^_Nullable)(BOOL success))completion
    NS_SWIFT_NAME(setCookie(_:for:completion:));

/// Enumerate every cookie in the store; `completion` receives them (ordered by
/// longest path, then earliest creation) on the main thread.
- (void)getAllCookies:(void (^)(NSArray<ChromiumCookie*>* cookies))completion
    NS_SWIFT_NAME(getAllCookies(_:));

/// Delete every cookie for all hosts and domains — the cookie half of
/// `WKWebsiteDataStore.removeAllData()`. `completion` (optional) receives the
/// number deleted.
- (void)deleteAllCookies:(void (^_Nullable)(NSInteger deletedCount))completion
    NS_SWIFT_NAME(deleteAllCookies(_:));
@end

NS_ASSUME_NONNULL_END
