#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ServiceManagement/ServiceManagement.h>
#include <dlfcn.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <unistd.h>

// macOS exposes mode switching publicly, but creating a display with an
// arbitrary logical size uses the private CGVirtualDisplay class family.
// These declarations describe the runtime classes; no private framework is
// linked. The virtual-display and mirroring approach is informed by the
// MIT-licensed hidpi-mirror project (see THIRD_PARTY_LICENSES.md).
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static const uint32_t kSamsungVendor = 0x4c2d;
static const uint32_t kU28Model = 0x0c4d;
static const size_t kSignalWidth = 1920;
static const size_t kSignalHeight = 2160;
static CGDirectDisplayID FindTargetDisplay(void);
static NSString *ModeDescription(CGDirectDisplayID display);

// CoreGraphics' public mode list omits the U28E590's advertised 1920x2160
// timing on macOS 26. The older CGS mode list includes it. These private
// declarations follow the MIT-licensed Hammerspoon screen extension.
typedef struct {
    uint32_t modeNumber, flags, width, height, depth;
    uint8_t unknown[170];
    uint16_t frequency;
    uint8_t moreUnknown[16];
    float density;
} HSPrivateMode;
typedef void (*HSGetModeCount)(CGDirectDisplayID, int *);
typedef void (*HSGetCurrentMode)(CGDirectDisplayID, int *);
typedef void (*HSGetModeDescription)(CGDirectDisplayID, int, HSPrivateMode *, int);
typedef void (*HSConfigureMode)(CGDisplayConfigRef, CGDirectDisplayID, int);

static int PrivateModeIndex(CGDirectDisplayID display, size_t width,
                            size_t height, double density) {
    HSGetModeCount getCount = (HSGetModeCount)dlsym(RTLD_DEFAULT,
                                                  "CGSGetNumberOfDisplayModes");
    HSGetModeDescription getDescription = (HSGetModeDescription)dlsym(
        RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    if (!getCount || !getDescription) return -1;
    int count = 0;
    getCount(display, &count);
    if (count < 0 || count > 1024) return -1;
    int best = -1;
    int bestRateDistance = INT_MAX;
    for (int i = 0; i < count; i++) {
        HSPrivateMode mode = {0};
        getDescription(display, i, &mode, sizeof(mode));
        if (mode.width != width || mode.height != height ||
            fabs(mode.density - density) > 0.01) continue;
        int distance = abs((int)mode.frequency - 60);
        if (best < 0 || distance < bestRateDistance) {
            best = i;
            bestRateDistance = distance;
        }
    }
    return best;
}

static int CurrentPrivateModeIndex(CGDirectDisplayID display) {
    HSGetCurrentMode getCurrent = (HSGetCurrentMode)dlsym(
        RTLD_DEFAULT, "CGSGetCurrentDisplayMode");
    if (!getCurrent || display == kCGNullDirectDisplay) return -1;
    int index = -1;
    getCurrent(display, &index);
    return index;
}

static BOOL CurrentPrivateMode(CGDirectDisplayID display,
                               HSPrivateMode *description) {
    HSGetModeDescription getDescription = (HSGetModeDescription)dlsym(
        RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    int index = CurrentPrivateModeIndex(display);
    if (index < 0 || !getDescription) return NO;
    memset(description, 0, sizeof(*description));
    getDescription(display, index, description, sizeof(*description));
    return description->width > 0 && description->height > 0;
}

static NSString *FullStatusDescription(void) {
    CGDirectDisplayID physical = FindTargetDisplay();
    if (physical == kCGNullDirectDisplay) return @"U28E590 is disconnected";
    CGDirectDisplayID master = CGDisplayMirrorsDisplay(physical);
    if (master != kCGNullDirectDisplay) {
        HSPrivateMode logical = {0};
        HSPrivateMode output = {0};
        if (CurrentPrivateMode(master, &logical) &&
            CurrentPrivateMode(physical, &output)) {
            return [NSString stringWithFormat:
                @"Custom: looks like %u × %u (HiDPI); output %u × %u",
                logical.width, logical.height, output.width, output.height];
        }
    }
    return ModeDescription(physical);
}

static CGError SetPrivateMode(CGDirectDisplayID display, int index,
                              CGConfigureOption option) {
    HSConfigureMode configure = (HSConfigureMode)dlsym(RTLD_DEFAULT,
                                                       "CGSConfigureDisplayMode");
    if (!configure || index < 0) return kCGErrorFailure;
    CGDisplayConfigRef config;
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result != kCGErrorSuccess) return result;
    configure(config, display, index);
    return CGCompleteDisplayConfiguration(config, option);
}

static CGDirectDisplayID FindTargetDisplay(void) {
    CGDirectDisplayID displays[32];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) {
        return kCGNullDirectDisplay;
    }
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = displays[i];
        if (CGDisplayIsBuiltin(display)) continue;
        if (CGDisplayVendorNumber(display) == kSamsungVendor &&
            CGDisplayModelNumber(display) == kU28Model) {
            return display;
        }
    }
    return kCGNullDirectDisplay;
}

static CGDisplayModeRef CopyMode(CGDirectDisplayID display,
                                 size_t width, size_t height,
                                 size_t pixelWidth, size_t pixelHeight) {
    const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
    const void *values[] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(
        NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, options);
    CFRelease(options);
    if (!modes) return NULL;
    CGDisplayModeRef best = NULL;
    double bestDistance = DBL_MAX;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(mode) != width ||
            CGDisplayModeGetHeight(mode) != height ||
            CGDisplayModeGetPixelWidth(mode) != pixelWidth ||
            CGDisplayModeGetPixelHeight(mode) != pixelHeight) continue;
        double rate = CGDisplayModeGetRefreshRate(mode);
        double distance = fabs(rate - 60.0);
        if (!best || distance < bestDistance) {
            best = mode;
            bestDistance = distance;
        }
    }
    if (best) CFRetain(best);
    CFRelease(modes);
    return best;
}

static NSString *ModeDescription(CGDirectDisplayID display) {
    if (display == kCGNullDirectDisplay) return @"U28E590 is disconnected";
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return @"Display mode is unavailable";
    NSString *text = [NSString stringWithFormat:@"Looks like %zu × %zu · %zu × %zu pixels",
                      CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                      CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)];
    CFRelease(mode);
    return text;
}

@interface HSDisplayController : NSObject
@property (nonatomic, strong) CGVirtualDisplay *virtualDisplay;
@property (nonatomic) CGDirectDisplayID virtualID;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSInteger looksWidth;
@property (nonatomic) NSInteger looksHeight;
@property (nonatomic) BOOL customActive;
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL resumeWhenConnected;
@property (nonatomic, copy) void (^onChange)(void);
- (BOOL)useBuiltInLarge:(NSError **)error;
- (BOOL)useNative:(NSError **)error;
- (BOOL)useCustomWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error;
- (void)maintain;
- (void)stop;
- (NSString *)status;
@end

@implementation HSDisplayController

- (NSError *)errorWithText:(NSString *)text {
    return [NSError errorWithDomain:@"local.josu.HalfScreen"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

- (void)notifyChange {
    if (self.onChange) self.onChange();
}

- (void)unmirrorAndRelease {
    CGDirectDisplayID target = FindTargetDisplay();
    if (target != kCGNullDirectDisplay && self.virtualID != 0 &&
        CGDisplayMirrorsDisplay(target) == self.virtualID) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(config, target,
                                              kCGNullDirectDisplay);
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    self.generation++;
    self.virtualDisplay = nil;
    self.virtualID = 0;
    self.customActive = NO;
}

- (BOOL)applyDirectWidth:(size_t)width height:(size_t)height
              pixelWidth:(size_t)pixelWidth pixelHeight:(size_t)pixelHeight
                   error:(NSError **)error {
    CGDirectDisplayID target = FindTargetDisplay();
    if (target == kCGNullDirectDisplay) {
        if (error) *error = [self errorWithText:@"U28E590 is not connected."];
        return NO;
    }
    double density = (double)pixelWidth / (double)width;
    int index = PrivateModeIndex(target, width, height, density);
    CGError result = SetPrivateMode(target, index, kCGConfigurePermanently);
    if (result == kCGErrorSuccess) return YES;
    CGDisplayModeRef mode = CopyMode(target, width, height,
                                    pixelWidth, pixelHeight);
    if (mode) {
        result = CGDisplaySetDisplayMode(target, mode, NULL);
        CFRelease(mode);
    }
    if (result != kCGErrorSuccess) {
        if (error) *error = [self errorWithText:
            [NSString stringWithFormat:@"macOS rejected the display mode (%d).", result]];
        return NO;
    }
    return YES;
}

- (BOOL)useBuiltInLarge:(NSError **)error {
    self.resumeWhenConnected = NO;
    BOOL hadVirtual = self.virtualDisplay != nil;
    [self unmirrorAndRelease];
    if (hadVirtual) usleep(400000);
    BOOL ok = [self applyDirectWidth:960 height:1080
                         pixelWidth:kSignalWidth pixelHeight:kSignalHeight
                              error:error];
    [self notifyChange];
    return ok;
}

- (BOOL)useNative:(NSError **)error {
    self.resumeWhenConnected = NO;
    BOOL hadVirtual = self.virtualDisplay != nil;
    [self unmirrorAndRelease];
    if (hadVirtual) usleep(400000);
    BOOL ok = [self applyDirectWidth:kSignalWidth height:kSignalHeight
                         pixelWidth:kSignalWidth pixelHeight:kSignalHeight
                              error:error];
    [self notifyChange];
    return ok;
}

- (BOOL)createVirtualWidth:(NSInteger)width height:(NSInteger)height
                    error:(NSError **)error {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !settingsClass || !modeClass || !displayClass) {
        if (error) *error = [self errorWithText:
            @"This macOS version does not expose virtual display support."];
        return NO;
    }
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.name = @"HalfScreen custom size";
    descriptor.queue = dispatch_get_main_queue();
    descriptor.sizeInMillimeters = CGSizeMake(310.5, 341.3);
    descriptor.maxPixelsWide = (unsigned int)(width * 2);
    descriptor.maxPixelsHigh = (unsigned int)(height * 2);
    descriptor.redPrimary = CGPointMake(0.680, 0.320);
    descriptor.greenPrimary = CGPointMake(0.265, 0.690);
    descriptor.bluePrimary = CGPointMake(0.150, 0.060);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.vendorID = 0xB33F;
    descriptor.productID = 0x3000 + ((width * 31 + height) & 0x0FFF);
    descriptor.serialNum = 2;
    NSUInteger generation = ++self.generation;
    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id ignoredA, id ignoredB) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.generation != generation) return;
            strongSelf.virtualDisplay = nil;
            strongSelf.virtualID = 0;
            strongSelf.customActive = NO;
            [strongSelf notifyChange];
        });
    };
    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        if (error) *error = [self errorWithText:@"Could not create a virtual display."];
        return NO;
    }
    self.virtualDisplay = display;
    self.virtualID = display.displayID;

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    NSMutableArray *modes = [NSMutableArray array];
    [modes addObject:[[modeClass alloc] initWithWidth:(unsigned int)width * 2
                                               height:(unsigned int)height * 2
                                          refreshRate:60]];
    const double fractions[] = {0.8, 0.67, 0.5};
    for (size_t i = 0; i < sizeof(fractions) / sizeof(fractions[0]); i++) {
        [modes addObject:[[modeClass alloc]
            initWithWidth:(unsigned int)llround((double)width * 2 * fractions[i])
                   height:(unsigned int)llround((double)height * 2 * fractions[i])
              refreshRate:60]];
    }
    settings.modes = modes;
    if (![display applySettings:settings]) {
        [self unmirrorAndRelease];
        if (error) *error = [self errorWithText:
            @"macOS rejected the virtual display settings."];
        return NO;
    }
    return YES;
}

- (void)establishMirrorWithAttempts:(NSInteger)attempts {
    if (!self.customActive || !self.virtualDisplay) return;
    CGDirectDisplayID target = FindTargetDisplay();
    if (target == kCGNullDirectDisplay) return;
    if (CGDisplayMirrorsDisplay(target) == self.virtualID) {
        self.applying = NO;
        [self notifyChange];
        return;
    }
    CGDisplayModeRef wanted = CopyMode(self.virtualID,
                                      (size_t)self.looksWidth,
                                      (size_t)self.looksHeight,
                                      (size_t)self.looksWidth * 2,
                                      (size_t)self.looksHeight * 2);
    if (!wanted && attempts > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                       dispatch_get_main_queue(), ^{
            [self establishMirrorWithAttempts:attempts - 1];
        });
        return;
    }
    CGDisplayConfigRef config;
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result == kCGErrorSuccess) {
        if (wanted) CGConfigureDisplayWithDisplayMode(config, self.virtualID,
                                                      wanted, NULL);
        result = CGConfigureDisplayMirrorOfDisplay(config, target,
                                                   self.virtualID);
        if (result == kCGErrorSuccess) {
            result = CGCompleteDisplayConfiguration(config,
                                                    kCGConfigureForSession);
        } else {
            CGCancelDisplayConfiguration(config);
        }
    }
    if (wanted) CFRelease(wanted);
    if (result != kCGErrorSuccess) {
        self.applying = NO;
        [self unmirrorAndRelease];
        NSError *ignored = nil;
        [self useBuiltInLarge:&ignored];
        [self notifyChange];
        return;
    }
    NSUInteger generation = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                   dispatch_get_main_queue(), ^{
        if (!self.customActive || self.generation != generation) return;
        CGDirectDisplayID physical = FindTargetDisplay();
        if (physical == kCGNullDirectDisplay) {
            [self unmirrorAndRelease];
            self.applying = NO;
            [self notifyChange];
            return;
        }
        int index = PrivateModeIndex(physical, kSignalWidth, kSignalHeight, 1.0);
        CGError physicalResult = SetPrivateMode(physical, index,
                                               kCGConfigureForSession);
        if (physicalResult != kCGErrorSuccess) {
            [self unmirrorAndRelease];
            NSError *ignored = nil;
            [self useBuiltInLarge:&ignored];
        }
        self.applying = NO;
        [self notifyChange];
    });
}

- (BOOL)useCustomWidth:(NSInteger)width height:(NSInteger)height
                error:(NSError **)error {
    if (width < 640 || height < 600 || width > 1920 || height > 2160) {
        if (error) *error = [self errorWithText:
            @"Enter a logical size from 640–1920 wide and 600–2160 high."];
        return NO;
    }
    [self unmirrorAndRelease];
    if (![self applyDirectWidth:kSignalWidth height:kSignalHeight
                    pixelWidth:kSignalWidth pixelHeight:kSignalHeight
                         error:error]) {
        return NO;
    }
    if (![self createVirtualWidth:width height:height error:error]) {
        NSError *ignored = nil;
        [self useBuiltInLarge:&ignored];
        return NO;
    }
    self.looksWidth = width;
    self.looksHeight = height;
    self.customActive = YES;
    self.resumeWhenConnected = YES;
    self.applying = YES;
    [[NSUserDefaults standardUserDefaults] setInteger:width forKey:@"looksWidth"];
    [[NSUserDefaults standardUserDefaults] setInteger:height forKey:@"looksHeight"];
    [self notifyChange];
    [self establishMirrorWithAttempts:12];
    return YES;
}

- (void)maintain {
    if (self.applying) return;
    CGDirectDisplayID target = FindTargetDisplay();
    if (target == kCGNullDirectDisplay) {
        if (self.customActive) {
            [self unmirrorAndRelease];
            [self notifyChange];
        }
        return;
    }
    if (!self.customActive && self.resumeWhenConnected) {
        NSError *ignored = nil;
        [self useCustomWidth:self.looksWidth height:self.looksHeight
                      error:&ignored];
        return;
    }
    if (self.virtualDisplay &&
        CGDisplayMirrorsDisplay(target) != self.virtualID) {
        [self establishMirrorWithAttempts:4];
        return;
    }
    if (self.customActive && self.virtualDisplay) {
        int wanted = PrivateModeIndex(target, kSignalWidth, kSignalHeight, 1.0);
        if (wanted >= 0 && CurrentPrivateModeIndex(target) != wanted) {
            SetPrivateMode(target, wanted, kCGConfigureForSession);
        }
    }
}

- (void)stop {
    self.resumeWhenConnected = NO;
    if (self.customActive) {
        NSError *ignored = nil;
        [self useBuiltInLarge:&ignored];
    } else {
        [self unmirrorAndRelease];
    }
}

- (NSString *)status {
    CGDirectDisplayID target = FindTargetDisplay();
    if (target == kCGNullDirectDisplay) return @"U28E590 is disconnected";
    if (self.applying) return @"Applying custom size…";
    if (self.customActive && self.virtualDisplay &&
        CGDisplayMirrorsDisplay(target) == self.virtualID) {
        return [NSString stringWithFormat:@"Custom: looks like %ld × %ld (HiDPI)",
                (long)self.looksWidth, (long)self.looksHeight];
    }
    return ModeDescription(target);
}

@end

@interface HSAppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *widthField;
@property (nonatomic, strong) NSTextField *heightField;
@property (nonatomic, strong) NSButton *aspectButton;
@property (nonatomic, strong) NSButton *loginButton;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) HSDisplayController *displays;
@property (nonatomic, strong) NSTimer *watchdog;
@end

@implementation HSAppDelegate

- (NSInteger)numberInField:(NSTextField *)field {
    NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet]
                                 invertedSet];
    NSString *digits = [[field.stringValue
        componentsSeparatedByCharactersInSet:notDigits]
        componentsJoinedByString:@""];
    return digits.integerValue;
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = [NSFont systemFontOfSize:size];
    return label;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    button.target = self;
    button.action = action;
    return button;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.displays = [[HSDisplayController alloc] init];
    __weak typeof(self) weakSelf = self;
    self.displays.onChange = ^{ [weakSelf refreshStatus]; };

    NSRect frame = NSMakeRect(0, 0, 540, 365);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"HalfScreen";
    [self.window center];
    NSView *content = self.window.contentView;

    NSTextField *title = [self label:@"U28E590 · split monitor"
                                 frame:NSMakeRect(24, 316, 490, 31) size:23];
    title.font = [NSFont boldSystemFontOfSize:23];
    [content addSubview:title];
    self.statusLabel = [self label:@"Checking display…"
                              frame:NSMakeRect(24, 282, 490, 24) size:14];
    [content addSubview:self.statusLabel];
    [content addSubview:[self label:@"Output stays at 1920 × 2160 so the image fills its half."
                                frame:NSMakeRect(24, 251, 490, 21) size:12]];

    [content addSubview:[self button:@"Large text · 960 × 1080"
                                frame:NSMakeRect(24, 205, 245, 32)
                               action:@selector(largePressed:)]];
    [content addSubview:[self button:@"More space · 1920 × 2160"
                                frame:NSMakeRect(275, 205, 239, 32)
                               action:@selector(nativePressed:)]];

    NSTextField *custom = [self label:@"Custom screen size (looks like)"
                                    frame:NSMakeRect(24, 166, 350, 22) size:14];
    custom.font = [NSFont boldSystemFontOfSize:14];
    [content addSubview:custom];
    self.widthField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 128, 80, 28)];
    self.heightField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 128, 80, 28)];
    NSInteger width = [[NSUserDefaults standardUserDefaults] integerForKey:@"looksWidth"];
    NSInteger height = [[NSUserDefaults standardUserDefaults] integerForKey:@"looksHeight"];
    if (width < 640 || width > 1920) width = 1200;
    if (height < 600 || height > 2160) height = 1350;
    self.widthField.integerValue = width;
    self.heightField.integerValue = height;
    self.widthField.delegate = self;
    [content addSubview:self.widthField];
    [content addSubview:[self label:@"×" frame:NSMakeRect(110, 130, 20, 22) size:16]];
    [content addSubview:self.heightField];
    [content addSubview:[self button:@"Apply custom"
                                frame:NSMakeRect(310, 125, 204, 32)
                               action:@selector(customPressed:)]];
    self.aspectButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 93, 275, 24)];
    self.aspectButton.title = @"Fill the half monitor (8:9)";
    self.aspectButton.buttonType = NSButtonTypeSwitch;
    self.aspectButton.state = NSControlStateValueOn;
    self.aspectButton.target = self;
    self.aspectButton.action = @selector(aspectChanged:);
    [content addSubview:self.aspectButton];
    [content addSubview:[self label:@"Custom sizes need HalfScreen open. Other shapes may show bars."
                                frame:NSMakeRect(24, 65, 490, 20) size:11]];

    self.loginButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 24, 250, 25)];
    self.loginButton.title = @"Open HalfScreen at login";
    self.loginButton.buttonType = NSButtonTypeSwitch;
    if (@available(macOS 13.0, *)) {
        self.loginButton.state = [SMAppService mainAppService].status ==
            SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.loginButton.target = self;
    self.loginButton.action = @selector(loginChanged:);
    [content addSubview:self.loginButton];

    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"▣";
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Show HalfScreen" action:@selector(showWindow:)
           keyEquivalent:@""];
    [menu addItemWithTitle:@"Large text" action:@selector(largePressed:)
           keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit HalfScreen" action:@selector(quitPressed:)
           keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) item.target = self;
    self.statusItem.menu = menu;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self refreshStatus];
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:4
                                                    target:self
                                                  selector:@selector(watchdogTick:)
                                                  userInfo:nil repeats:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self.displays stop];
}

- (void)refreshStatus {
    self.statusLabel.stringValue = [self.displays status];
}

- (void)showError:(NSError *)error {
    if (!error) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Could not change the screen size";
    alert.informativeText = error.localizedDescription;
    [alert runModal];
}

- (void)largePressed:(id)sender {
    NSError *error = nil;
    [self.displays useBuiltInLarge:&error];
    [self showError:error];
}

- (void)nativePressed:(id)sender {
    NSError *error = nil;
    [self.displays useNative:&error];
    [self showError:error];
}

- (void)customPressed:(id)sender {
    NSInteger width = [self numberInField:self.widthField];
    NSInteger height = [self numberInField:self.heightField];
    if (self.aspectButton.state == NSControlStateValueOn) {
        height = (NSInteger)llround((double)width * 9.0 / 8.0);
        self.heightField.integerValue = height;
    }
    NSError *error = nil;
    [self.displays useCustomWidth:width height:height error:&error];
    [self showError:error];
}

- (void)aspectChanged:(id)sender {
    if (self.aspectButton.state == NSControlStateValueOn) {
        self.heightField.integerValue =
            (NSInteger)llround((double)[self numberInField:self.widthField] * 9.0 / 8.0);
    }
    self.heightField.enabled = self.aspectButton.state != NSControlStateValueOn;
}

- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object == self.widthField &&
        self.aspectButton.state == NSControlStateValueOn) {
        self.heightField.integerValue =
            (NSInteger)llround((double)[self numberInField:self.widthField] * 9.0 / 8.0);
    }
}

- (void)loginChanged:(id)sender {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = self.loginButton.state == NSControlStateValueOn
            ? [[SMAppService mainAppService] registerAndReturnError:&error]
            : [[SMAppService mainAppService] unregisterAndReturnError:&error];
        if (!ok) {
            self.loginButton.state = self.loginButton.state == NSControlStateValueOn
                ? NSControlStateValueOff : NSControlStateValueOn;
            [self showError:error];
        }
    }
}

- (void)watchdogTick:(NSTimer *)timer {
    [self.displays maintain];
    [self refreshStatus];
}

- (void)showWindow:(id)sender {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)quitPressed:(id)sender { [NSApp terminate:nil]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--status") == 0) {
            CGDirectDisplayID target = FindTargetDisplay();
            puts(FullStatusDescription().UTF8String);
            return target == kCGNullDirectDisplay ? 1 : 0;
        }
        if (argc == 2 && (strcmp(argv[1], "--large") == 0 ||
                          strcmp(argv[1], "--native") == 0)) {
            HSDisplayController *controller = [[HSDisplayController alloc] init];
            NSError *error = nil;
            BOOL ok = strcmp(argv[1], "--large") == 0
                ? [controller useBuiltInLarge:&error]
                : [controller useNative:&error];
            if (!ok) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return ok ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--modes") == 0) {
            CGDirectDisplayID target = FindTargetDisplay();
            if (target == kCGNullDirectDisplay) return 1;
            const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
            const void *values[] = { kCFBooleanTrue };
            CFDictionaryRef options = CFDictionaryCreate(
                NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(target, options);
            CFRelease(options);
            if (!modes) return 1;
            for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                printf("%zu x %zu; pixels %zu x %zu; %.2f Hz\n",
                       CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                       CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode),
                       CGDisplayModeGetRefreshRate(mode));
            }
            CFRelease(modes);
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--private-modes") == 0) {
            CGDirectDisplayID target = FindTargetDisplay();
            if (target == kCGNullDirectDisplay) return 1;
            HSGetModeCount getCount = (HSGetModeCount)dlsym(
                RTLD_DEFAULT, "CGSGetNumberOfDisplayModes");
            HSGetModeDescription getDescription = (HSGetModeDescription)dlsym(
                RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
            if (!getCount || !getDescription) return 2;
            int count = 0;
            getCount(target, &count);
            for (int i = 0; i < count; i++) {
                HSPrivateMode mode = {0};
                getDescription(target, i, &mode, sizeof(mode));
                printf("%d: %u x %u @ %.1fx %u Hz\n", i, mode.width,
                       mode.height, mode.density, mode.frequency);
            }
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--private-current") == 0) {
            CGDirectDisplayID target = FindTargetDisplay();
            if (target == kCGNullDirectDisplay) return 1;
            printf("%d\n", CurrentPrivateModeIndex(target));
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        NSMenu *mainMenu = [[NSMenu alloc] init];
        NSMenuItem *appItem = [[NSMenuItem alloc] init];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"HalfScreen"];
        [appMenu addItemWithTitle:@"Quit HalfScreen"
                          action:@selector(terminate:)
                   keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        [mainMenu addItem:appItem];
        app.mainMenu = mainMenu;
        HSAppDelegate *delegate = [[HSAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
