#import "Brightness.h"
#import <AppKit/AppKit.h>

@interface HSBrightnessController ()
@property (nonatomic, readwrite) NSInteger percent;
@property (nonatomic, strong) NSWindow *shadeWindow;
@property (nonatomic) CGDirectDisplayID screenDisplayID;
@end

@implementation HSBrightnessController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    id saved = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"brightnessPercent"];
    NSInteger value = saved ? [saved integerValue] : 100;
    _percent = MAX(20, MIN(100, value));
    return self;
}

- (NSScreen *)screenForDisplay:(CGDirectDisplayID)display {
    CGDirectDisplayID mirrorMaster = CGDisplayMirrorsDisplay(display);
    CGDirectDisplayID screenID = mirrorMaster == kCGNullDirectDisplay
        ? display : mirrorMaster;
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue == screenID) return screen;
    }
    return nil;
}

- (BOOL)placeShadeOnDisplay:(CGDirectDisplayID)display
                      error:(NSError **)error {
    if (self.percent >= 100) {
        [self.shadeWindow orderOut:nil];
        return YES;
    }
    NSScreen *screen = display == kCGNullDirectDisplay
        ? nil : [self screenForDisplay:display];
    if (!screen) {
        [self.shadeWindow orderOut:nil];
        if (error) *error = [NSError errorWithDomain:
            @"local.josu.HalfScreen.brightness" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"The U28E590 screen is unavailable right now."}];
        return NO;
    }
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    CGDirectDisplayID screenID = number.unsignedIntValue;
    if (!self.shadeWindow) {
        self.shadeWindow = [[NSWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered defer:NO];
        self.shadeWindow.releasedWhenClosed = NO;
        self.shadeWindow.opaque = NO;
        self.shadeWindow.hasShadow = NO;
        self.shadeWindow.ignoresMouseEvents = YES;
        self.shadeWindow.level = NSScreenSaverWindowLevel - 1;
        self.shadeWindow.collectionBehavior =
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary |
            NSWindowCollectionBehaviorStationary;
    }
    self.shadeWindow.backgroundColor = [NSColor
        colorWithCalibratedWhite:0
                          alpha:(100.0 - (double)self.percent) / 100.0];
    BOOL moved = self.screenDisplayID != screenID ||
                 !NSEqualRects(self.shadeWindow.frame, screen.frame);
    if (moved) [self.shadeWindow setFrame:screen.frame display:NO];
    self.screenDisplayID = screenID;
    if (moved || !self.shadeWindow.isVisible) {
        [self.shadeWindow orderFrontRegardless];
    }
    return YES;
}

- (BOOL)applyPercent:(NSInteger)percent
          toDisplay:(CGDirectDisplayID)display
              error:(NSError **)error {
    NSInteger old = self.percent;
    self.percent = MAX(20, MIN(100, percent));
    if (![self placeShadeOnDisplay:display error:error]) {
        self.percent = old;
        return NO;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:self.percent
                                               forKey:@"brightnessPercent"];
    return YES;
}

- (void)maintainForDisplay:(CGDirectDisplayID)display {
    [self placeShadeOnDisplay:display error:NULL];
}

- (void)restoreForDisplay:(CGDirectDisplayID)display {
    [self.shadeWindow orderOut:nil];
}

@end
