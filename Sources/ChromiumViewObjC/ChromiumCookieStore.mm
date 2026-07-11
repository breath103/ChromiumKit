#import "ChromiumViewObjC.h"

#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "include/internal/cef_time.h"

// Process-global cookie access, bridging CEF's `CefCookieManager` (the global
// request context's default manager) to the Foundation `ChromiumCookie` value
// type. Set/get/delete map 1:1 to `WKHTTPCookieStore.setCookie` / `getAllCookies`
// / the cookie half of `WKWebsiteDataStore.removeAllData`.

@implementation ChromiumCookie
- (instancetype)initWithName:(NSString*)name value:(NSString*)value {
  if ((self = [super init])) {
    _name = [name copy];
    _value = [value copy];
  }
  return self;
}
@end

namespace {

NSString* nsStringFromCef(const cef_string_t& s) {
  CefString cs(&s);
  if (cs.empty()) return @"";
  return [NSString stringWithUTF8String:cs.ToString().c_str()];
}

// NSDate (unix seconds) -> cef_basetime_t (µs since the Windows epoch).
cef_basetime_t baseTimeFromDate(NSDate* date) {
  CefTime t;
  t.SetDoubleT(date.timeIntervalSince1970);
  cef_basetime_t bt = {};
  cef_time_to_basetime(&t, &bt);
  return bt;
}

NSDate* dateFromBaseTime(const cef_basetime_t& bt) {
  cef_time_t t = {};
  if (!cef_time_from_basetime(bt, &t)) return nil;
  double secs = CefTime(t).GetDoubleT();
  if (secs <= 0) return nil;
  return [NSDate dateWithTimeIntervalSince1970:secs];
}

ChromiumCookie* cookieFromCef(const CefCookie& c) {
  ChromiumCookie* out =
      [[ChromiumCookie alloc] initWithName:nsStringFromCef(c.name)
                                     value:nsStringFromCef(c.value)];
  out.domain = nsStringFromCef(c.domain);
  out.path = nsStringFromCef(c.path);
  out.secure = c.secure ? YES : NO;
  out.httpOnly = c.httponly ? YES : NO;
  out.expires = c.has_expires ? dateFromBaseTime(c.expires) : nil;
  return out;
}

// Collects visited cookies and delivers them once CEF finishes the visit.
// CefCookieVisitor gives no explicit "done" signal and never calls Visit when
// the store is empty, so completion fires from the destructor — which CEF runs
// on the UI thread after the last cookie (or immediately for an empty store).
class _CookieCollector : public CefCookieVisitor {
 public:
  explicit _CookieCollector(void (^completion)(NSArray*))
      : completion_(completion), results_([NSMutableArray array]) {}
  ~_CookieCollector() override {
    NSArray* results = results_;
    void (^completion)(NSArray*) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(results); });
  }
  bool Visit(const CefCookie& cookie, int, int, bool& /*deleteCookie*/) override {
    [results_ addObject:cookieFromCef(cookie)];
    return true;
  }

 private:
  void (^completion_)(NSArray*);
  NSMutableArray* results_;
  IMPLEMENT_REFCOUNTING(_CookieCollector);
};

class _SetCookieCallback : public CefSetCookieCallback {
 public:
  explicit _SetCookieCallback(void (^completion)(BOOL)) : completion_(completion) {}
  void OnComplete(bool success) override {
    void (^completion)(BOOL) = completion_;
    BOOL ok = success ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
  }

 private:
  void (^completion_)(BOOL);
  IMPLEMENT_REFCOUNTING(_SetCookieCallback);
};

class _DeleteCookiesCallback : public CefDeleteCookiesCallback {
 public:
  explicit _DeleteCookiesCallback(void (^completion)(NSInteger))
      : completion_(completion) {}
  void OnComplete(int num_deleted) override {
    void (^completion)(NSInteger) = completion_;
    NSInteger n = num_deleted;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(n); });
  }

 private:
  void (^completion_)(NSInteger);
  IMPLEMENT_REFCOUNTING(_DeleteCookiesCallback);
};

}  // namespace

@interface ChromiumCookieStore ()
- (instancetype)initPrivate;
@end

@implementation ChromiumCookieStore

+ (ChromiumCookieStore*)globalStore {
  static ChromiumCookieStore* shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[ChromiumCookieStore alloc] initPrivate]; });
  return shared;
}

// The global manager is fetched per call (not cached): fetching before CEF is
// initialized would cache a null, whereas GetGlobalManager is cheap and returns
// the same singleton once the context exists.
- (instancetype)initPrivate {
  return [super init];
}

- (void)setCookie:(ChromiumCookie*)cookie
           forURL:(NSURL*)url
       completion:(void (^_Nullable)(BOOL))completion {
  CefRefPtr<CefCookieManager> manager =
      CefCookieManager::GetGlobalManager(nullptr);
  if (!manager) {
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
    return;
  }

  CefCookie cef;
  CefString(&cef.name).FromString(cookie.name.UTF8String);
  CefString(&cef.value).FromString(cookie.value.UTF8String);
  if (cookie.domain.length) CefString(&cef.domain).FromString(cookie.domain.UTF8String);
  CefString(&cef.path).FromString((cookie.path ?: @"/").UTF8String);
  cef.secure = cookie.secure ? 1 : 0;
  cef.httponly = cookie.httpOnly ? 1 : 0;
  if (cookie.expires) {
    cef.has_expires = 1;
    cef.expires = baseTimeFromDate(cookie.expires);
  } else {
    cef.has_expires = 0;
  }

  CefRefPtr<CefSetCookieCallback> cb =
      completion ? new _SetCookieCallback(completion) : nullptr;
  bool accepted = manager->SetCookie(CefString(url.absoluteString.UTF8String),
                                     cef, cb);
  // An invalid URL / inaccessible store returns false synchronously without
  // ever invoking the callback — report that here so `completion` always fires.
  if (!accepted && completion) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
  }
}

- (void)getAllCookies:(void (^)(NSArray<ChromiumCookie*>*))completion {
  CefRefPtr<CefCookieManager> manager =
      CefCookieManager::GetGlobalManager(nullptr);
  if (!manager) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
    return;
  }
  // The collector delivers via its destructor; if VisitAllCookies fails it is
  // released here and still fires completion with an empty array.
  manager->VisitAllCookies(new _CookieCollector(completion));
}

- (void)deleteAllCookies:(void (^_Nullable)(NSInteger))completion {
  CefRefPtr<CefCookieManager> manager =
      CefCookieManager::GetGlobalManager(nullptr);
  if (!manager) {
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(0); });
    return;
  }
  CefRefPtr<CefDeleteCookiesCallback> cb =
      completion ? new _DeleteCookiesCallback(completion) : nullptr;
  // Empty url + empty name = every cookie for all hosts and domains.
  bool ok = manager->DeleteCookies(CefString(), CefString(), cb);
  if (!ok && completion) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(0); });
  }
}

@end
