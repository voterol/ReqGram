#import <Foundation/Foundation.h>

// Internal, fixed production routes only. No caller-supplied endpoint or identity.
NSArray<NSString *> *RGTgwsDCAddresses(NSInteger dc);
NSString *RGTgwsCanonicalHost(NSInteger dc, BOOL media);
NSData *RGTgwsUpgradeRequest(NSString *canonicalHost, NSString *key);
BOOL RGTgwsValidateUpgrade(NSData *response, NSString *key);
NSData *RGTgwsClientFrame(NSData *payload, uint8_t opcode);

@interface RGTgwsIPTransport : NSObject
- (instancetype)initWithDC:(NSInteger)dc media:(BOOL)media addressIndex:(NSUInteger)index;
- (instancetype)initWithDC:(NSInteger)dc media:(BOOL)media address:(NSString *)address;
- (BOOL)open;
// Returns only bounded categories accepted by the service event contract.
- (BOOL)openWithCategory:(NSString **)category;
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *))completion;
- (BOOL)sendMessage:(NSURLSessionWebSocketMessage *)message failureCategory:(NSString **)category;
- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))completion;
- (void)cancel;
- (void)finish; // Worker-only cancellation barrier; never under the run lock.
@end
