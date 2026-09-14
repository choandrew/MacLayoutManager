#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>

#include <dlfcn.h>
#include <string.h>

#import "HelperProtocol.h"

/// The app's login item. ServiceManagement is linked by name only, so it loads
/// on the first menu open or first launch rather than with the app, and never
/// unloads because it holds Objective-C classes. `mainAppService` resolves
/// through the main bundle, so this runs in the app rather than the helper.
static SMAppService *MLMLoginItem(void) {
  if (dlopen("/System/Library/Frameworks/ServiceManagement.framework/"
             "ServiceManagement",
             RTLD_LAZY | RTLD_LOCAL) == NULL) {
    return nil;
  }
  return [NSClassFromString(@"SMAppService") mainAppService];
}

/// After a reconfiguration macOS keeps moving windows between displays for a
/// moment, and it calls back once per affected display. Waiting for quiet
/// restores once, onto the settled arrangement.
static const int64_t MLMDisplaySettleDelay = 2 * NSEC_PER_SEC;
static const uint64_t MLMDisplaySettleLeeway = NSEC_PER_SEC / 2;

static NSString *const MLMHelperFailed = @"MacLayoutManager's helper failed.";
/// Set when the first launch registers the login item, so an opt-out sticks.
static NSString *const MLMLoginItemOfferedKey = @"login_item_offered";

typedef enum {
  /// The first `list`: without a library every later command fails the same
  /// way, so the app reports it and quits.
  MLMRunKindLaunch,
  /// A menu action: the user is waiting on the outcome.
  MLMRunKindUser,
  /// Auto-restore: nobody asked, so nothing interrupts.
  MLMRunKindBackground,
} MLMRunKind;

/// A screen split into a tall pane and two stacked ones, drawn rather than
/// loaded from SF Symbols, whose catalog costs the resident process about
/// 500 KB.
static NSImage *MLMStatusImage(void) {
  NSImage *image = [NSImage
       imageWithSize:NSMakeSize(18, 18)
             flipped:NO
      drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        NSBezierPath *layout = [NSBezierPath
            bezierPathWithRoundedRect:NSMakeRect(2.625, 3.625, 12.75, 10.75)
                              xRadius:2
                              yRadius:2];
        [layout moveToPoint:NSMakePoint(8.25, 3.625)];
        [layout lineToPoint:NSMakePoint(8.25, 14.375)];
        [layout moveToPoint:NSMakePoint(8.25, 9)];
        [layout lineToPoint:NSMakePoint(15.375, 9)];
        layout.lineWidth = 1.25;
        [NSColor.blackColor setStroke];
        [layout stroke];
        return YES;
      }];
  image.template = YES;
  image.accessibilityDescription = @"MacLayoutManager";
  return image;
}

static void MLMAppendRect(NSMutableArray<NSString *> *arguments, NSRect rect,
                          CGFloat mainHeight) {
  CGFloat values[4] = {rect.origin.x, mainHeight - NSMaxY(rect),
                       rect.size.width, rect.size.height};
  for (size_t index = 0; index < 4; index++) {
    [arguments addObject:[NSString stringWithFormat:@"%.17g", values[index]]];
  }
}

/// The helper's display arguments, or nil when any screen lacks an identity.
/// Accessibility coordinates put the origin at the main display's top-left
/// with y down, where AppKit's sit at its bottom-left with y up.
static NSArray<NSString *> *MLMDisplayArguments(void) {
  NSArray<NSScreen *> *screens = NSScreen.screens;
  if (screens.count == 0)
    return nil;
  CGFloat mainHeight = screens[0].frame.size.height;
  NSMutableArray<NSString *> *arguments = [NSMutableArray
      arrayWithCapacity:screens.count * MLMDisplayArgumentCount];
  for (NSScreen *screen in screens) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (![number isKindOfClass:NSNumber.class])
      return nil;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(number.unsignedIntValue);
    if (uuid == NULL)
      return nil;
    NSString *identifier = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    if (identifier == nil)
      return nil;
    [arguments addObject:identifier];
    [arguments addObject:screen.localizedName];
    MLMAppendRect(arguments, screen.frame, mainHeight);
    MLMAppendRect(arguments, screen.visibleFrame, mainHeight);
  }
  return arguments;
}

@interface MLMAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate> {
  NSStatusItem *_statusItem;
  MLMLibrary _library;
  dispatch_queue_t _helperQueue;
  dispatch_source_t _settleTimer;
  uint32_t _menuOpenings;
}
- (void)displaysChanged;
@end

static void MLMDisplayReconfigured(CGDirectDisplayID display,
                                   CGDisplayChangeSummaryFlags flags,
                                   void *userInfo) {
  (void)display;
  if (flags & kCGDisplayBeginConfigurationFlag)
    return;
  MLMAppDelegate *delegate = (__bridge MLMAppDelegate *)userInfo;
  dispatch_async(dispatch_get_main_queue(), ^{
    [delegate displaysChanged];
  });
}

@implementation MLMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  // Serial because every run reads the layouts file and may rewrite it.
  _helperQueue =
      dispatch_queue_create("com.choandrew.MacLayoutManager.helper",
                            dispatch_queue_attr_make_with_qos_class(
                                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));

  _statusItem = [NSStatusBar.systemStatusBar
      statusItemWithLength:NSSquareStatusItemLength];
  _statusItem.autosaveName = @"MacLayoutManager";
  _statusItem.button.image = MLMStatusImage();
  // An attached menu keeps native press-drag-release tracking. It stays empty
  // while closed: items are built on open and dropped after close.
  NSMenu *menu = [NSMenu new];
  menu.delegate = self;
  _statusItem.menu = menu;

  CGDisplayRegisterReconfigurationCallback(MLMDisplayReconfigured,
                                           (__bridge void *)self);
  [self runHelper:@[ @MLMVerbList ] kind:MLMRunKindLaunch];
  if (!AXIsProcessTrusted())
    [self requestAccessibility:nil];

  // First launch only, and not retried if registration fails.
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if (![defaults boolForKey:MLMLoginItemOfferedKey]) {
    [defaults setBool:true forKey:MLMLoginItemOfferedKey];
    [self setLoginItem:true userInitiated:false];
  }
}

- (void)displaysChanged {
  if (_settleTimer == nil) {
    _settleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_main_queue());
    __weak MLMAppDelegate *weakSelf = self;
    dispatch_source_set_event_handler(_settleTimer, ^{
      [weakSelf autoRestore];
    });
    dispatch_resume(_settleTimer);
  }
  dispatch_source_set_timer(
      _settleTimer, dispatch_time(DISPATCH_TIME_NOW, MLMDisplaySettleDelay),
      DISPATCH_TIME_FOREVER, MLMDisplaySettleLeeway);
}

/// Spawns nothing unless a layout could match, since most reconfigurations
/// happen on machines with no auto-restore layout at all.
- (void)autoRestore {
  bool wanted = false;
  for (uint8_t index = 0; index < _library.count && !wanted; index++)
    wanted = _library.layouts[index].autoRestore;
  if (wanted && AXIsProcessTrusted()) {
    [self runHelperOnDisplays:@[ @MLMVerbAutoRestore ]
                         kind:MLMRunKindBackground];
  }
}

- (void)runHelperOnDisplays:(NSArray<NSString *> *)arguments
                       kind:(MLMRunKind)kind {
  NSArray<NSString *> *displays = MLMDisplayArguments();
  if (displays == nil) {
    if (kind == MLMRunKindUser)
      NSBeep();
    return;
  }
  [self runHelper:[arguments arrayByAddingObjectsFromArray:displays] kind:kind];
}

- (void)runHelper:(NSArray<NSString *> *)arguments kind:(MLMRunKind)kind {
  NSString *helper = [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:@"Contents/Helpers/MacLayoutHelper"];
  // The helper inherits the spawning thread's QoS and carries it into the apps
  // it messages, so a click runs user-initiated and background work stays
  // utility.
  qos_class_t qos =
      kind == MLMRunKindUser ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
  dispatch_async(
      _helperQueue,
      dispatch_block_create_with_qos_class(
          DISPATCH_BLOCK_ENFORCE_QOS_CLASS, qos, 0, ^{
            @autoreleasepool {
              // Heap: the result is about 25 KB and outlives this block.
              MLMHelperResult *result = calloc(1, sizeof(*result));
              const char **argv = calloc(arguments.count + 2, sizeof(*argv));
              bool succeeded = false;
              if (result != NULL && argv != NULL) {
                argv[0] = helper.fileSystemRepresentation;
                for (NSUInteger index = 0; index < arguments.count; index++)
                  argv[index + 1] = arguments[index].UTF8String;
                succeeded = MLMRunHelper(argv, result);
              }
              free(argv);
              dispatch_async(dispatch_get_main_queue(), ^{
                [self merge:succeeded ? result : NULL kind:kind];
                free(result);
              });
            }
          }));
}

/// `result` is NULL when the run itself failed.
- (void)merge:(const MLMHelperResult *)result kind:(MLMRunKind)kind {
  if (result != NULL && result->hasLibrary)
    _library = result->library;
  NSString *message = result == NULL ? MLMHelperFailed
                      : result->message[0] == '\0'
                          ? nil
                          : [NSString stringWithUTF8String:result->message];

  switch (kind) {
  case MLMRunKindLaunch:
    if (result != NULL && result->hasLibrary)
      return;
    [self alert:@"Couldn't load layouts" info:message];
    [NSApp terminate:nil];
    break;
  case MLMRunKindUser:
    if (message != nil)
      [self alert:message info:@""];
    break;
  case MLMRunKindBackground:
    break;
  }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
  _menuOpenings++;
  [menu removeAllItems];
  [menu addItem:[self item:@"Save Current Layout…"
                    action:@selector(saveLayout:)
                    layout:nil]];

  if (_library.count > 0) {
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Restore"]];
    NSMenu *manage = [NSMenu new];
    for (uint8_t index = 0; index < _library.count; index++) {
      const MLMLayoutSummary *layout = &_library.layouts[index];
      NSString *name = [NSString stringWithUTF8String:layout->name];
      NSString *displays = [NSString stringWithUTF8String:layout->displays];

      NSMenuItem *restore = [self item:name
                                action:@selector(restoreLayout:)
                                layout:name];
      NSString *subtitle =
          layout->autoRestore
              ? [@"Auto-restores · " stringByAppendingString:displays]
              : displays;
      restore.subtitle = subtitle.length > 0 ? subtitle : nil;
      [menu addItem:restore];

      NSMenuItem *autoRestore = [self item:@"Auto-Restore on These Displays"
                                    action:@selector(toggleAutoRestore:)
                                    layout:name];
      autoRestore.state =
          layout->autoRestore ? NSControlStateValueOn : NSControlStateValueOff;
      NSMenu *actions = [NSMenu new];
      actions.itemArray = @[
        autoRestore,
        NSMenuItem.separatorItem,
        [self item:@"Rename…" action:@selector(renameLayout:) layout:name],
        [self item:@"Delete…" action:@selector(deleteLayout:) layout:name],
      ];
      [manage addItem:[self submenuItem:name menu:actions]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self submenuItem:@"Manage Layouts" menu:manage]];
  }

  [menu addItem:NSMenuItem.separatorItem];
  if (!AXIsProcessTrusted()) {
    [menu addItem:[self item:@"Grant Accessibility Access…"
                      action:@selector(requestAccessibility:)
                      layout:nil]];
  }
  // Read from ServiceManagement on every open, because System Settings can
  // change it behind the app's back. Mixed means registered but not approved.
  NSMenuItem *login = [self item:@"Launch at Login"
                          action:@selector(toggleLaunchAtLogin:)
                          layout:nil];
  switch (MLMLoginItem().status) {
  case SMAppServiceStatusEnabled:
    login.state = NSControlStateValueOn;
    break;
  case SMAppServiceStatusRequiresApproval:
    login.state = NSControlStateValueMixed;
    break;
  case SMAppServiceStatusNotRegistered:
  case SMAppServiceStatusNotFound:
    login.state = NSControlStateValueOff;
    break;
  }
  [menu addItem:login];
  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit MacLayoutManager"
                                                action:@selector(terminate:)
                                         keyEquivalent:@""];
  quit.target = NSApp;
  [menu addItem:quit];
}

/// The chosen item's action still needs its item, so the items go on a later
/// pass, and only if the menu has not been opened again since.
- (void)menuDidClose:(NSMenu *)menu {
  uint32_t opening = _menuOpenings;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_menuOpenings != opening)
      return;
    [menu removeAllItems];
  });
}

- (NSMenuItem *)item:(NSString *)title
              action:(SEL)action
              layout:(NSString *)name {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:@""];
  item.target = self;
  item.representedObject = name;
  return item;
}

- (NSMenuItem *)submenuItem:(NSString *)title menu:(NSMenu *)submenu {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:nil
                                         keyEquivalent:@""];
  item.submenu = submenu;
  return item;
}

- (const MLMLayoutSummary *)layoutNamed:(NSString *)name {
  const char *text = name.UTF8String;
  for (uint8_t index = 0; index < _library.count; index++) {
    if (strcmp(_library.layouts[index].name, text) == 0)
      return &_library.layouts[index];
  }
  return NULL;
}

- (void)saveLayout:(NSMenuItem *)sender {
  (void)sender;
  if (![self ensureAccessibility])
    return;
  NSString *name = [self promptForName:@"Save Current Layout"
                               initial:@""
                                action:@"Save"];
  if (name == nil)
    return;
  // Trimmed only to spot a replacement; the helper owns name validation.
  NSString *trimmed = [name
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  NSString *command = @MLMVerbAdd;
  if ([self layoutNamed:trimmed] != NULL) {
    NSString *message = [NSString stringWithFormat:@"Replace “%@”?", trimmed];
    if (![self confirm:message
                  info:@"Its saved windows will be replaced with the current "
                       @"ones."
                action:@"Replace"
             accessory:nil]) {
      return;
    }
    command = @MLMVerbReplace;
  }
  [self runHelperOnDisplays:@[ command, name ] kind:MLMRunKindUser];
}

- (void)restoreLayout:(NSMenuItem *)sender {
  if (![self ensureAccessibility])
    return;
  [self runHelperOnDisplays:@[ @MLMVerbRestore, sender.representedObject ]
                       kind:MLMRunKindUser];
}

- (void)toggleAutoRestore:(NSMenuItem *)sender {
  NSString *name = sender.representedObject;
  const MLMLayoutSummary *layout = [self layoutNamed:name];
  if (layout == NULL)
    return;
  [self runHelper:@[
    @MLMVerbSetAutoRestore, name, layout->autoRestore ? @"0" : @"1"
  ]
             kind:MLMRunKindUser];
}

- (void)renameLayout:(NSMenuItem *)sender {
  NSString *name = sender.representedObject;
  NSString *newName = [self promptForName:@"Rename Layout"
                                  initial:name
                                   action:@"Rename"];
  if (newName == nil)
    return;
  [self runHelper:@[ @MLMVerbRename, name, newName ] kind:MLMRunKindUser];
}

- (void)deleteLayout:(NSMenuItem *)sender {
  NSString *name = sender.representedObject;
  NSString *message = [NSString stringWithFormat:@"Delete “%@”?", name];
  if (![self confirm:message
                info:@"This can't be undone."
              action:@"Delete"
           accessory:nil]) {
    return;
  }
  [self runHelper:@[ @MLMVerbDelete, name ] kind:MLMRunKindUser];
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
  (void)sender;
  SMAppService *loginItem = MLMLoginItem();
  switch (loginItem.status) {
  case SMAppServiceStatusEnabled:
    [self setLoginItem:false userInitiated:true];
    break;
  case SMAppServiceStatusRequiresApproval:
    [loginItem.class openSystemSettingsLoginItems];
    break;
  case SMAppServiceStatusNotRegistered:
  case SMAppServiceStatusNotFound:
    [self setLoginItem:true userInitiated:true];
    break;
  }
}

/// Registering with launchd is a synchronous XPC round trip, so it runs off the
/// main thread. A toggle that needs approval opens Login Items settings, and
/// one that fails beeps.
- (void)setLoginItem:(bool)enabled userInitiated:(bool)userInitiated {
  qos_class_t qos =
      userInitiated ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
  dispatch_async(dispatch_get_global_queue(qos, 0), ^{
    SMAppService *loginItem = MLMLoginItem();
    NSError *error = nil;
    bool succeeded = enabled ? [loginItem registerAndReturnError:&error]
                             : [loginItem unregisterAndReturnError:&error];
    bool needsApproval = loginItem.status == SMAppServiceStatusRequiresApproval;
    if (!userInitiated)
      return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (needsApproval) {
        [loginItem.class openSystemSettingsLoginItems];
      } else if (!succeeded) {
        NSBeep();
      }
    });
  });
}

- (void)requestAccessibility:(id)sender {
  (void)sender;
  AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)
                                    @{@"AXTrustedCheckOptionPrompt" : @YES});
}

- (bool)ensureAccessibility {
  if (AXIsProcessTrusted())
    return true;
  [self requestAccessibility:nil];
  return false;
}

/// The text as typed, or nil if cancelled.
- (NSString *)promptForName:(NSString *)message
                    initial:(NSString *)initial
                     action:(NSString *)action {
  NSTextField *field =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  field.stringValue = initial;
  field.placeholderString = @"Layout name";
  return [self confirm:message info:@"" action:action accessory:field]
             ? field.stringValue
             : nil;
}

/// Shows a modal alert and returns whether the user chose `action` over
/// Cancel.
- (bool)confirm:(NSString *)message
           info:(NSString *)info
         action:(NSString *)action
      accessory:(NSView *)accessory {
  NSAlert *alert = [NSAlert new];
  alert.messageText = message;
  alert.informativeText = info;
  alert.accessoryView = accessory;
  [alert addButtonWithTitle:action];
  [alert addButtonWithTitle:@"Cancel"];
  alert.window.initialFirstResponder = accessory;
  [NSApp activate];
  return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)alert:(NSString *)message info:(NSString *)info {
  NSAlert *alert = [NSAlert new];
  alert.messageText = message;
  alert.informativeText = info;
  [NSApp activate];
  [alert runModal];
}

@end

int main(void) {
  @autoreleasepool {
    NSApplication *application = NSApplication.sharedApplication;
    MLMAppDelegate *delegate = [MLMAppDelegate new];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}
