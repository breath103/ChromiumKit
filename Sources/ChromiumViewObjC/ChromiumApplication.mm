#import "ChromiumViewObjC.h"
#include <atomic>
#include <cstdint>
#include <crt_externs.h>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

// External-message-pump mode: the HOST owns `[NSApp run]` and CEF is pumped via
// `CefDoMessageLoopWork()`. Gates both the run/quit path in
// `runWithConfiguration:` and the `-terminate:` behavior below. When NO,
// everything stays on the old `CefRunMessageLoop()` / `CefQuitMessageLoop()`
// path, unchanged. Declared at file scope so `-terminate:` (above the
// anonymous namespace) can read it.
static bool g_external_message_pump = false;

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
- (void)terminate:(id)sender {
  if (g_external_message_pump) {
    // The host owns the AppKit loop (`[NSApp run]`); `CefQuitMessageLoop()`
    // would NOT stop it. Stop the AppKit loop so `[NSApp run]` returns and
    // `CefShutdown()` can run. `-stop:` only takes effect after the loop
    // processes one more event, so post a dummy event to wake it promptly.
    [NSApp stop:sender];
    NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:YES];
  } else {
    CefQuitMessageLoop();
  }
}
@end

namespace {

static CEFSetupBlock g_setup_block = nil;
static bool g_use_mock_keychain = false;

// Coalesces external pump work. CEF calls `OnScheduleMessagePumpWork` on any
// thread with the delay until its next scheduled work; each call REPLACES the
// previous deadline (this is a level-triggered "soonest deadline" signal — the
// most recent call is authoritative, same as cefclient's KillTimer+SetTimer).
// We marshal the pump onto the main queue and stamp each schedule with a
// generation; a queued block only calls `CefDoMessageLoopWork()` if it is still
// the latest generation, so a burst of `delay_ms <= 0` requests collapses to a
// single pump instead of enqueuing unbounded `CefDoMessageLoopWork` calls.
static std::atomic<uint64_t> g_pump_generation{0};

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
  // External-message-pump callback (only invoked when
  // `settings.external_message_pump` is set). May be called on ANY thread, so
  // marshal the pump onto the main queue where `[NSApp run]` lives. See
  // `g_pump_generation` for the coalescing rationale.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    const uint64_t generation =
        g_pump_generation.fetch_add(1, std::memory_order_relaxed) + 1;
    void (^pump)(void) = ^{
      // Skip if a newer schedule superseded this one; otherwise this is the
      // authoritative next deadline — pump CEF.
      if (g_pump_generation.load(std::memory_order_relaxed) != generation) {
        return;
      }
      CefDoMessageLoopWork();
    };
    if (delay_ms <= 0) {
      dispatch_async(dispatch_get_main_queue(), pump);
    } else {
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
          dispatch_get_main_queue(), pump);
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
    g_external_message_pump = config ? config.externalMessagePump : false;
    if (g_external_message_pump) {
      settings.external_message_pump = true;
    }
    CefRefPtr<_CEFApp> app(new _CEFApp);
    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
      return CefGetExitCode();
    }
    if (g_external_message_pump) {
      // Host-run-loop mode: AppKit owns the loop and drains libdispatch + the
      // Swift main-actor executor; CEF is pumped via `CefDoMessageLoopWork()`
      // scheduled from `OnScheduleMessagePumpWork`. `-terminate:` calls
      // `[NSApp stop:]` so `[NSApp run]` returns here, then CEF shuts down.
      [NSApp run];
      CefShutdown();
    } else {
      CefRunMessageLoop();
      CefShutdown();
    }
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
