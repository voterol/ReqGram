#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Native, streaming port of Flowseal's obfuscated MTProto handshake/bridge.
// CTR contexts must never be shared between connections or directions.
@interface RGTgwsCTR : NSObject
- (nullable instancetype)initWithKey:(NSData *)key iv:(NSData *)iv;
- (nullable NSData *)update:(NSData *)data;
@end

@interface RGTgwsCrypto : NSObject
@property(nonatomic, readonly) NSInteger dc;
@property(nonatomic, readonly) BOOL media;
@property(nonatomic, readonly) uint8_t protocolByte;
@property(nonatomic, readonly) NSData *relayInit;
+ (nullable instancetype)handshake:(NSData *)handshake secret:(NSData *)secret;
+ (nullable instancetype)handshake:(NSData *)handshake secret:(NSData *)secret rejectionCode:(NSString * _Nullable * _Nullable)rejectionCode;
- (nullable NSData *)up:(NSData *)data plaintext:(NSData * _Nullable * _Nonnull)plain;
- (nullable NSData *)down:(NSData *)data;
@end

// Bounds incomplete packets as well as complete ones. Malformed lengths fail
// closed, rather than upstream's unframed passthrough fallback.
@interface RGTgwsSplitter : NSObject
- (instancetype)initWithProtocol:(uint8_t)protocolByte;
- (nullable NSArray<NSData *> *)appendCipher:(NSData *)cipher plain:(NSData *)plain;
@end
NS_ASSUME_NONNULL_END
