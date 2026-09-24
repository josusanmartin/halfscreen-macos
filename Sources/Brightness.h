#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface HSBrightnessController : NSObject
@property (nonatomic, readonly) NSInteger percent;
- (BOOL)applyPercent:(NSInteger)percent
          toDisplay:(CGDirectDisplayID)display
              error:(NSError **)error;
- (void)maintainForDisplay:(CGDirectDisplayID)display;
- (void)restoreForDisplay:(CGDirectDisplayID)display;
@end
