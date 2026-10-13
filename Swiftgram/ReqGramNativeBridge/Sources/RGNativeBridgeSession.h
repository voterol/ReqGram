#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Per-plugin-session Objective-C bridge. All returned object handles are owned
/// by this instance and become invalid when close is called.
@interface RGNativeBridgeSession : NSObject
- (NSDictionary<NSString *, id> *)requestOperation:(NSString *)operation payload:(NSData * _Nullable)payload;
- (void)close;
@end

NS_ASSUME_NONNULL_END
