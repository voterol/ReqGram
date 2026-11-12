#import <UIKit/UIKit.h>
#import "RGPythonRuntime.h"

@interface SmokeDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation SmokeDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    RGPythonRuntime *runtime = RGPythonRuntime.shared;
    [runtime evaluateExpression:@"6 * 7" completion:^(NSString *value, NSError *error) {
        if (error || ![value isEqual:@"42"]) { NSLog(@"FAIL expression: %@ %@", value, error); exit(1); }
        [runtime evaluateExpression:@"1 / 0" completion:^(NSString *value, NSError *error) {
            if (!error) { NSLog(@"FAIL missing Python exception"); exit(2); }
            [runtime setExecutionEnabled:NO];
            [runtime evaluateExpression:@"42" completion:^(NSString *value, NSError *error) {
                if (!error) { NSLog(@"FAIL lifecycle gate"); exit(3); }
                     [runtime evaluateExpression:@"__import__('reqgram_smoke').run_disabled()" completion:^(NSString *value, NSError *disabledError) {
                         if (disabledError) { NSLog(@"FAIL disabled host gate: %@", disabledError); exit(4); }
                         [runtime setExecutionEnabled:YES];
                         [runtime evaluateExpression:@"__import__('reqgram_smoke').run()" completion:^(NSString *value, NSError *error) {
                             if (error) { NSLog(@"FAIL bundled module: %@", error); exit(4); }
                             NSLog(@"REQGRAM_PYTHON_SMOKE_PASS %@", value);
                             exit(0);
                         }];
                     }];
            }];
        }];
    }];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeDelegate.class)); }
}
