#import "RGTgwsCrypto.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <os/log.h>

@implementation RGTgwsCTR {
    CCCryptorRef _cryptor;
}
- (instancetype)initWithKey:(NSData *)key iv:(NSData *)iv {
    if (key.length != 32 || iv.length != 16) return nil;
    if ((self = [super init])) {
        if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES,
            ccNoPadding, iv.bytes, key.bytes, key.length, NULL, 0, 0,
            kCCModeOptionCTR_BE, &_cryptor) != kCCSuccess) return nil;
    }
    return self;
}
- (NSData *)update:(NSData *)data {
    NSMutableData *out = [NSMutableData dataWithLength:data.length];
    size_t written = 0;
    if (CCCryptorUpdate(_cryptor, data.bytes, data.length, out.mutableBytes,
        out.length, &written) != kCCSuccess || written != data.length) return nil;
    return out;
}
- (void)dealloc { if (_cryptor) CCCryptorRelease(_cryptor); }
@end

static NSData *slice(NSData *d, NSUInteger offset, NSUInteger length) {
    return [d subdataWithRange:NSMakeRange(offset, length)];
}
static NSData *reverse(NSData *d) {
    NSMutableData *r = [NSMutableData dataWithLength:d.length];
    const uint8_t *p = d.bytes; uint8_t *q = r.mutableBytes;
    for (NSUInteger i = 0; i < d.length; i++) q[i] = p[d.length - i - 1];
    return r;
}
static NSData *hashKey(NSData *key, NSData *secret) {
    NSMutableData *d = [key mutableCopy]; [d appendData:secret];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
static RGTgwsCTR *ctr(NSData *keyIV, NSData *secret) {
    NSData *key = slice(keyIV, 0, 32);
    return [[RGTgwsCTR alloc] initWithKey:secret ? hashKey(key, secret) : key iv:slice(keyIV, 32, 16)];
}

@implementation RGTgwsCrypto {
    RGTgwsCTR *_clientDecrypt, *_clientEncrypt, *_relayEncrypt, *_relayDecrypt;
}
+ (instancetype)handshake:(NSData *)handshake secret:(NSData *)secret {
    return [self handshake:handshake secret:secret rejectionCode:NULL];
}
+ (instancetype)handshake:(NSData *)handshake secret:(NSData *)secret rejectionCode:(NSString **)rejectionCode {
    if (rejectionCode) *rejectionCode = nil;
    if (handshake.length != 64 || secret.length != 16) {
        if (rejectionCode) *rejectionCode = @"invalid_length";
        return nil;
    }
    NSData *pre = slice(handshake, 8, 48);
    RGTgwsCTR *dec = ctr(pre, secret);
    NSData *plain = [dec update:handshake];
    if (!plain) {
        if (rejectionCode) *rejectionCode = @"decrypt_failed";
        return nil;
    }
    const uint8_t *p = plain.bytes;
    uint8_t proto = p[56];
    BOOL prefixMatches = memcmp(handshake.bytes, plain.bytes, 56) == 0;
    BOOL protocolRepeats = p[57] == proto && p[58] == proto && p[59] == proto;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO,
                     "tgws handshake_check prefix_match=%{public}@ proto=%02x repeats=%{public}@ dc_raw=%d",
                     prefixMatches ? @"yes" : @"no", proto, protocolRepeats ? @"yes" : @"no", (int)((int16_t)((uint16_t)p[60] | ((uint16_t)p[61] << 8))));
    if ((proto != 0xef && proto != 0xee && proto != 0xdd) ||
        !protocolRepeats) {
        if (rejectionCode) *rejectionCode = @"invalid_protocol";
        return nil;
    }
    int16_t index = (int16_t)((uint16_t)p[60] | ((uint16_t)p[61] << 8));
    NSInteger dc = labs(index);
    // Smallest production runtime: no test-DC or FakeTLS support.
    if (!((dc >= 1 && dc <= 5) || dc == 203)) {
        if (rejectionCode) *rejectionCode = @"unsupported_dc";
        return nil;
    }
    NSMutableData *relay = [NSMutableData dataWithLength:64];
    uint8_t *r = relay.mutableBytes;
    for (;;) {
        if (SecRandomCopyBytes(kSecRandomDefault, 64, r) != errSecSuccess) return nil;
        if (r[0] == 0xef || !memcmp(r, "HEAD", 4) || !memcmp(r, "POST", 4) ||
            !memcmp(r, "GET ", 4) || !memcmp(r, "\xee\xee\xee\xee", 4) ||
            !memcmp(r, "\xdd\xdd\xdd\xdd", 4) || !memcmp(r, "\x16\x03\x01\x02", 4) ||
            !memcmp(r + 4, "\0\0\0\0", 4)) continue;
        break;
    }
    NSData *relayPre = slice(relay, 8, 48);
    RGTgwsCTR *enc = ctr(relayPre, nil);
    uint8_t zero[64] = {0};
    NSData *stream = [enc update:[NSData dataWithBytes:zero length:64]];
    if (!stream) return nil;
    const uint8_t *s = stream.bytes;
    for (NSUInteger i = 56; i < 60; i++) r[i] = proto ^ s[i];
    r[60] = p[60] ^ s[60]; r[61] = p[61] ^ s[61];
    r[62] ^= s[62]; r[63] ^= s[63];
    RGTgwsCrypto *result = [[self alloc] init];
    result->_dc = dc; result->_media = index < 0; result->_protocolByte = proto;
    result->_relayInit = [relay copy];
    result->_clientDecrypt = dec; // Already advanced by the 64-byte init.
    result->_clientEncrypt = ctr(reverse(pre), secret);
    result->_relayEncrypt = enc; // Already advanced by the 64-byte init.
    result->_relayDecrypt = ctr(reverse(relayPre), nil);
    if (!result->_clientEncrypt || !result->_relayDecrypt) return nil;
    return result;
}
- (NSData *)up:(NSData *)data plaintext:(NSData **)plain {
    *plain = [_clientDecrypt update:data];
    return *plain ? [_relayEncrypt update:*plain] : nil;
}
- (NSData *)down:(NSData *)data {
    NSData *plain = [_relayDecrypt update:data];
    return plain ? [_clientEncrypt update:plain] : nil;
}
@end

@implementation RGTgwsSplitter {
    uint8_t _proto;
    NSMutableData *_cipher, *_plain;
}
- (instancetype)initWithProtocol:(uint8_t)protocolByte {
    if ((self = [super init])) {
        _proto = protocolByte; _cipher = [NSMutableData data]; _plain = [NSMutableData data];
    }
    return self;
}
- (NSArray<NSData *> *)appendCipher:(NSData *)cipher plain:(NSData *)plain {
    const NSUInteger limit = 4 * 1024 * 1024;
    if (cipher.length != plain.length || _plain.length + plain.length > limit + 65536) return nil;
    [_cipher appendData:cipher]; [_plain appendData:plain];
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger offset = 0;
    const uint8_t *p = _plain.bytes;
    while (offset < _plain.length) {
        NSUInteger available = _plain.length - offset, header, length;
        if (_proto == 0xef) {
            header = (p[offset] == 0x7f || p[offset] == 0xff) ? 4 : 1;
            if (available < header) break;
            length = header == 1 ? (p[offset] & 0x7f) * 4 :
                (p[offset + 1] | (p[offset + 2] << 8) | (p[offset + 3] << 16)) * 4;
        } else if (_proto == 0xee || _proto == 0xdd) {
            header = 4; if (available < 4) break;
            length = ((uint32_t)p[offset] | ((uint32_t)p[offset + 1] << 8) |
                ((uint32_t)p[offset + 2] << 16) | ((uint32_t)p[offset + 3] << 24)) & 0x7fffffff;
        } else return nil;
        if (!length || length > limit) return nil;
        if (available < header + length) break;
        [parts addObject:slice(_cipher, offset, header + length)]; offset += header + length;
    }
    if (offset) {
        [_cipher replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
        [_plain replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    }
    return parts;
}
@end
