#import "ChromiumViewObjC.h"
#include <crt_externs.h>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

@interface _CEFNSApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end
@implementation _CEFNSApplication
- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)v { handlingSendEvent_ = v; }
- (void)sendEvent:(NSEvent*)e {
  CefScopedSendingEvent s;
  [super sendEvent:e];
}
- (void)terminate:(id)sender { CefQuitMessageLoop(); }
@end

namespace {

static CEFSetupBlock g_setup_block = nil;
static bool g_use_mock_keychain = false;

class _CEFApp : public CefApp, public CefBrowserProcessHandler {
 public:
  _CEFApp() = default;
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  // Append global Chromium switches before any process starts. `--use-mock-keychain`
  // makes OSCrypt skip the macOS Keychain (no "Chromium Safe Storage" prompt).
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (g_use_mock_keychain) {
      command_line->AppendSwitch("use-mock-keychain");
    }
  }
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (g_setup_block) {
      g_setup_block();
      g_setup_block = nil;
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(_CEFApp);
  DISALLOW_COPY_AND_ASSIGN(_CEFApp);
};

}  // namespace

@implementation ChromiumApplication

+ (int)runWithSetup:(CEFSetupBlock)setup {
  return [self runWithConfiguration:nil setup:setup];
}

+ (int)runWithConfiguration:(ChromiumConfiguration*)config setup:(CEFSetupBlock)setup {
  int argc = *_NSGetArgc();
  char** argv = *_NSGetArgv();
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  CefMainArgs main_args(argc, argv);
  @autoreleasepool {
    [_CEFNSApplication sharedApplication];
    CefSettings settings;
    settings.no_sandbox = config ? config.sandboxDisabled : YES;
    if (config.userAgent.length) {
      CefString(&settings.user_agent).FromString(config.userAgent.UTF8String);
    }
    if (config.locale.length) {
      CefString(&settings.locale).FromString(config.locale.UTF8String);
    }
    if (config.cachePath) {
      CefString(&settings.root_cache_path)
          .FromString(config.cachePath.path.UTF8String);
    }
    g_setup_block = [setup copy];
    g_use_mock_keychain = config ? config.useMockKeychain : false;
    CefRefPtr<_CEFApp> app(new _CEFApp);
    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
      return CefGetExitCode();
    }
    CefRunMessageLoop();
    CefShutdown();
  }
  return 0;
}

+ (int)runHelper {
  return [self runHelperWithArgc:*_NSGetArgc() argv:*_NSGetArgv()];
}

+ (int)runWithSetup:(CEFSetupBlock)setup argc:(int)argc argv:(char**)argv {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  CefMainArgs main_args(argc, argv);
  @autoreleasepool {
    [_CEFNSApplication sharedApplication];
    CefSettings settings;
    settings.no_sandbox = true;
    g_setup_block = [setup copy];
    CefRefPtr<_CEFApp> app(new _CEFApp);
    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
      return CefGetExitCode();
    }
    CefRunMessageLoop();
    CefShutdown();
  }
  return 0;
}

+ (int)runHelperWithArgc:(int)argc argv:(char**)argv {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}

@end
