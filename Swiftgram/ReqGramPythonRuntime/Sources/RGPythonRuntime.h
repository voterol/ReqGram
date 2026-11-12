#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Process-wide interpreter. Bundled trusted code only; NOT a Python sandbox.
@interface RGPythonRuntime : NSObject
+ (instancetype)shared;
- (instancetype)init NS_UNAVAILABLE;
/// Completion runs on the main queue. Initialization is lazy, on a serial queue.
- (void)evaluateExpression:(NSString *)expression completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion;
/// Gates future evaluations; does not interrupt running code or finalize CPython.
- (void)setExecutionEnabled:(BOOL)enabled;
/// Host is bound to this module, not a mutable global plugin identity. Not a sandbox.
- (void)runPlugin:(NSString *)moduleName directory:(NSString *)directory start:(BOOL)start host:(NSDictionary * (^)(NSString *, NSData * _Nullable))host boundary:(BOOL (^)(BOOL))boundary completion:(void (^)(NSError * _Nullable))completion;
/// One event per serial queue turn. takeEvent is the final session admission gate;
/// nil cancels delivery. Completion runs on the runtime queue, never main.
- (void)deliverEvent:(NSString *)moduleName takeEvent:(NSData * _Nullable (^)(void))takeEvent boundary:(BOOL (^)(BOOL))boundary completion:(void (^)(NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
