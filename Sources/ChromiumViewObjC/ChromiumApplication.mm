#import "ChromiumViewObjC.h"
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

// External message pump — a faithful port of cefclient's
// `MainMessageLoopExternalPump` (tests/shared/browser/) to libdispatch. CEF
// calls `OnScheduleMessagePumpWork` on ANY thread; we marshal onto the main
// queue (where `[NSApp run]` lives) and drive `CefDoMessageLoopWork()` there.
//
// The load-bearing detail — and the one the previous generation-coalescing
// version was missing — is the 30fps HEARTBEAT. cefclient's `DoWork()` re-arms
// a fallback timer after every pump, and clamps every requested delay to
// `kMaxTimerDelay` (33ms). CEF does NOT re-request a pump for every unit of
// in-flight async progress (network, renderer IPC, compositor frames); it
// relies on the host pumping at least ~30fps. Without the heartbeat CEF pumped
// a handful of times at startup, went idle, and a browser created later never
// even started its navigation → permanently blank window.
//
// Reentrancy: `CefDoMessageLoopWork()` can spin the native run loop, which
// drains libdispatch and can re-enter our pump. Nesting `CefDoMessageLoopWork()`
// is illegal, so we detect it and re-post the discarded work.
//
// All state below is touched on the main thread only (from the marshalled
// blocks), so no locking or atomics are needed.
static bool g_pump_is_active = false;
static bool g_pump_reentrancy_detected = false;
static bool g_pump_timer_pending = false;
static uint64_t g_pump_timer_generation = 0;

// Max wait between pumps: a 30fps heartbeat (cefclient's `kMaxTimerDelay`).
static const int64_t kPumpMaxTimerDelayMs = 1000 / 30;
// Placeholder delay meaning "arm the heartbeat" (cefclient's
// `kTimerDelayPlaceholder`); clamped to the heartbeat interval below.
static const int64_t kPumpTimerPlaceholder = INT32_MAX;

static void PumpDoWork();
static void PumpScheduleFromCef(int64_t delay_ms);

// Main thread. Cancels any armed heartbeat/timer: a bumped generation makes the
// pending `dispatch_after` block a no-op.
static void PumpKillTimer() {
  ++g_pump_timer_generation;
  g_pump_timer_pending = false;
}

// Main thread. Arms a one-shot timer (`delay_ms > 0`).
static void PumpSetTimer(int64_t delay_ms) {
  const uint64_t generation = ++g_pump_timer_generation;
  g_pump_timer_pending = true;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   if (g_pump_timer_generation != generation) {
                     return;  // superseded or killed
                   }
                   PumpKillTimer();  // OnTimerTimeout: kill then pump
                   PumpDoWork();
                 });
}

// Main thread. Mirrors `MainMessageLoopExternalPump::OnScheduleWork`.
static void PumpOnScheduleWork(int64_t delay_ms) {
  // Don't let the heartbeat placeholder override a shorter real timer.
  if (delay_ms == kPumpTimerPlaceholder && g_pump_timer_pending) {
    return;
  }
  PumpKillTimer();
  if (delay_ms <= 0) {
    PumpDoWork();
  } else {
    if (delay_ms > kPumpMaxTimerDelayMs) {
      delay_ms = kPumpMaxTimerDelayMs;  // never wait longer than the heartbeat
    }
    PumpSetTimer(delay_ms);
  }
}

// Main thread. Mirrors `PerformMessageLoopWork` — one guarded pump iteration.
// Returns true if a reentrant pump was detected and discarded.
static bool PumpPerformWork() {
  if (g_pump_is_active) {
    // `CefDoMessageLoopWork()` is already on the stack; discard this nested
    // pump and let the outer call re-post it.
    g_pump_reentrancy_detected = true;
    return false;
  }
  g_pump_reentrancy_detected = false;
  g_pump_is_active = true;
  CefDoMessageLoopWork();
  g_pump_is_active = false;
  return g_pump_reentrancy_detected;
}

// Main thread. Mirrors `MainMessageLoopExternalPump::DoWork`.
static void PumpDoWork() {
  const bool was_reentrant = PumpPerformWork();
  if (was_reentrant) {
    // Re-run the discarded work as soon as possible.
    PumpScheduleFromCef(0);
  } else if (!g_pump_timer_pending) {
    // Keep the heartbeat alive so in-flight async work keeps progressing.
    PumpScheduleFromCef(kPumpTimerPlaceholder);
  }
}

// Any thread. Mirrors `OnScheduleMessagePumpWork`: hop to the main queue, then
// schedule/pump there.
static void PumpScheduleFromCef(int64_t delay_ms) {
  dispatch_async(dispatch_get_main_queue(), ^{
    PumpOnScheduleWork(delay_ms);
  });
}

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
  // hand off to the main queue via `PumpScheduleFromCef`, where all the
  // scheduling/pumping (and its reentrancy guard) runs. See the pump helpers
  // above.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    PumpScheduleFromCef(delay_ms);
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
