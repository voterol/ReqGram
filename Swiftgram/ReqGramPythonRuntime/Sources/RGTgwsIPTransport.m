#import "RGTgwsIPTransport.h"
#import <Network/Network.h>
#import <Security/Security.h>
#include <stdlib.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>

static const NSUInteger maxMessage = 4 * 1024 * 1024 + 4;
NSArray<NSString *> *RGTgwsDCAddresses(NSInteger dc) {
    // Production seeds in TelegramCore/Sources/Network/Network.swift. Not test DCs.
    switch (dc == 203 ? 2 : dc) {
        case 1: return @[@"149.154.175.50", @"2001:b28:f23d:f001::a"];
        case 2: return @[@"149.154.167.50", @"95.161.76.100", @"2001:67c:4e8:f002::a"];
        case 3: return @[@"149.154.175.100", @"2001:b28:f23d:f003::a"];
        case 4: return @[@"149.154.167.91", @"2001:67c:4e8:f004::a"];
        case 5: return @[@"149.154.171.5", @"2001:b28:f23f:f005::a"];
        default: return @[];
    }
}
NSString *RGTgwsCanonicalHost(NSInteger dc, BOOL media) {
    dc = dc == 203 ? 2 : dc;
    if (dc < 1 || dc > 5) return nil;
    return [NSString stringWithFormat:@"kws%ld%@.web.telegram.org", (long)dc, media ? @"-1" : @""];
}
static BOOL token(NSString *value, NSString *expected) {
    for (NSString *part in [value componentsSeparatedByString:@","]) {
        if ([[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] caseInsensitiveCompare:expected] == NSOrderedSame) return YES;
    }
    return NO;
}
NSData *RGTgwsUpgradeRequest(NSString *host, NSString *key) {
    BOOL canonical = NO;
    for (NSInteger dc = 1; dc <= 5; dc++) {
        if ([host isEqual:RGTgwsCanonicalHost(dc, NO)] || [host isEqual:RGTgwsCanonicalHost(dc, YES)]) canonical = YES;
    }
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:key options:0];
    if (!canonical || decoded.length != 16 || ![[decoded base64EncodedStringWithOptions:0] isEqual:key]) return nil;
    NSString *request = [NSString stringWithFormat:@"GET /apiws HTTP/1.1\r\nHost: %@\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n", host, key];
    return [request dataUsingEncoding:NSASCIIStringEncoding];
}
BOOL RGTgwsValidateUpgrade(NSData *response, NSString *key) {
    if (response.length > 16384) return NO;
    NSString *text = [[NSString alloc] initWithData:response encoding:NSASCIIStringEncoding];
    if (![text hasSuffix:@"\r\n\r\n"]) return NO;
    NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
    if (![lines.firstObject hasPrefix:@"HTTP/1.1 101 "]) return NO;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i + 2 < lines.count; i++) {
        NSString *line = lines[i]; NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || !colon.location || [line hasPrefix:@" "] || [line hasPrefix:@"\t"]) return NO;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        if (headers[name]) return NO;
        headers[name] = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    NSData *source = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(source.bytes, (CC_LONG)source.length, digest);
    NSString *accept = [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
    return token(headers[@"upgrade"], @"websocket") && token(headers[@"connection"], @"upgrade") &&
        [headers[@"sec-websocket-accept"] isEqual:accept] && [headers[@"sec-websocket-protocol"] isEqual:@"binary"] &&
        !headers[@"sec-websocket-extensions"] && !headers[@"transfer-encoding"] && !headers[@"content-length"];
}
NSData *RGTgwsClientFrame(NSData *payload, uint8_t opcode) {
    if (payload.length > maxMessage || (opcode != 2 && opcode != 8 && opcode != 10) || (opcode != 2 && payload.length > 125)) return nil;
    uint8_t header[14] = {0x80 | opcode, 0x80}; NSUInteger h = 2;
    if (payload.length < 126) header[1] |= payload.length;
    else if (payload.length <= 65535) { header[1] |= 126; header[h++] = payload.length >> 8; header[h++] = payload.length; }
    else { header[1] |= 127; for (int i = 7; i >= 0; i--) header[h++] = ((uint64_t)payload.length >> (i * 8)) & 255; }
    uint8_t mask[4]; if (SecRandomCopyBytes(kSecRandomDefault, sizeof(mask), mask)) return nil;
    memcpy(header + h, mask, 4); h += 4;
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:h];
    NSMutableData *body = [payload mutableCopy]; uint8_t *bytes = body.mutableBytes;
    for (NSUInteger i = 0; i < body.length; i++) bytes[i] ^= mask[i % 4];
    [frame appendData:body]; return frame;
}
static NSError *failed(void) { return [NSError errorWithDomain:@"RGTgwsTransport" code:1 userInfo:nil]; }
static NSString *ipFailureCategory(nw_error_t error) {
    if (!error) return @"unknown";
    nw_error_domain_t domain = nw_error_get_error_domain(error);
    int code = nw_error_get_error_code(error);
    if (domain == nw_error_domain_tls) return @"tls";
    if (domain == nw_error_domain_dns) return @"dns";
    if (domain == nw_error_domain_posix) {
        switch (code) {
            case ETIMEDOUT: return @"timeout";
            case ECONNREFUSED: return @"refused";
            case ENETDOWN: case ENETUNREACH: case EHOSTUNREACH:
            case ENETRESET: case ECONNRESET: case ENOTCONN: return @"network";
            default: break;
        }
    }
    return @"unknown";
}

@implementation RGTgwsIPTransport {
    nw_connection_t _connection;
    dispatch_queue_t _network, _reader;
    NSLock *_lock;
    BOOL _cancelled;
    NSString *_host;
}
- (instancetype)initWithDC:(NSInteger)dc media:(BOOL)media addressIndex:(NSUInteger)index {
    NSArray *addresses = RGTgwsDCAddresses(dc);
    if (index >= addresses.count || !RGTgwsCanonicalHost(dc, media)) return nil;
    return [self initWithDC:dc media:media address:addresses[index]];
}
- (instancetype)initWithDC:(NSInteger)dc media:(BOOL)media address:(NSString *)address {
    if (!address.length || !RGTgwsCanonicalHost(dc, media)) return nil;
    if ((self = [super init])) {
        _host = RGTgwsCanonicalHost(dc, media); _lock = [[NSLock alloc] init];
        _network = dispatch_queue_create("reqgram.tgws.ip.network", DISPATCH_QUEUE_SERIAL);
        _reader = dispatch_queue_create("reqgram.tgws.ip.reader", DISPATCH_QUEUE_SERIAL);
        NSString *identity = _host;
        nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
            sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(tls);
            sec_protocol_options_set_tls_server_name(security, identity.UTF8String);
            // Default Network.framework system chain + peer-name validation.
            // Never install a verify/challenge callback or change trust anchors.
            sec_protocol_options_add_tls_application_protocol(security, "http/1.1");
        }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_endpoint_t endpoint = nw_endpoint_create_host(address.UTF8String, "443");
        _connection = nw_connection_create(endpoint, parameters);
        nw_connection_set_queue(_connection, _network);
    }
    return self;
}
- (BOOL)wait:(dispatch_semaphore_t)signal deadline:(NSTimeInterval)deadline {
    for (;;) {
        [_lock lock]; BOOL cancelled = _cancelled; [_lock unlock];
        if (cancelled || NSProcessInfo.processInfo.systemUptime >= deadline) { [self cancel]; return NO; }
        if (!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) return YES;
    }
}
- (void)cancel {
    [_lock lock]; _cancelled = YES; nw_connection_cancel(_connection); [_lock unlock];
}
- (void)finish { [self cancel]; dispatch_sync(_reader, ^{}); }
- (BOOL)write:(NSData *)bytes failureCategory:(NSString **)category {
    if (!bytes) return NO;
    dispatch_semaphore_t signal = dispatch_semaphore_create(0); __block BOOL ok = NO; __block nw_error_t failure = nil;
    void *ownedBytes = malloc(bytes.length);
    if (!ownedBytes) { if (category) *category = @"unknown"; return NO; }
    memcpy(ownedBytes, bytes.bytes, bytes.length);
    dispatch_data_t data = dispatch_data_create(ownedBytes, bytes.length, _network, DISPATCH_DATA_DESTRUCTOR_FREE);
    if (!data) { free(ownedBytes); if (category) *category = @"unknown"; return NO; }
    nw_connection_send(_connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        failure = error; ok = !error; dispatch_semaphore_signal(signal);
    });
    BOOL completed = [self wait:signal deadline:NSProcessInfo.processInfo.systemUptime + 15];
    if (category) *category = completed ? ipFailureCategory(failure) : @"timeout";
    return completed && ok;
}
- (BOOL)write:(NSData *)bytes { return [self write:bytes failureCategory:nil]; }
- (NSData *)read:(NSUInteger)length deadline:(NSTimeInterval)deadline {
    if (!length) return [NSData data];
    dispatch_semaphore_t signal = dispatch_semaphore_create(0); __block NSMutableData *result = nil;
    nw_connection_receive(_connection, (uint32_t)length, (uint32_t)length, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context; (void)complete;
        if (content && !error) {
            result = [NSMutableData data];
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                (void)region; (void)offset; [result appendBytes:buffer length:size]; return true;
            });
        }
        dispatch_semaphore_signal(signal);
    });
    return [self wait:signal deadline:deadline] && result.length == length ? result : nil;
}
- (BOOL)openWithCategory:(NSString **)category {
    if (category) *category = @"unknown";
    dispatch_semaphore_t signal = dispatch_semaphore_create(0); __block BOOL ready = NO, notified = NO; __block nw_error_t failure = nil;
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (!notified && (state == nw_connection_state_ready || state == nw_connection_state_failed || state == nw_connection_state_cancelled)) {
            notified = YES;
            failure = error;
            ready = state == nw_connection_state_ready; dispatch_semaphore_signal(signal);
        }
    });
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=connect start");
    nw_connection_start(_connection);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 15;
    if (![self wait:signal deadline:deadline]) {
        if (category) *category = @"timeout";
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=connect result=timeout");
        return NO;
    }
    if (!ready) {
        if (category) *category = ipFailureCategory(failure);
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=tls result=failed code=%{public}@", category && *category ? *category : @"unknown");
        return NO;
    }
    nw_connection_set_state_changed_handler(_connection, nil);
    uint8_t nonce[16]; if (SecRandomCopyBytes(kSecRandomDefault, sizeof(nonce), nonce)) { if (category) *category = @"unknown"; return NO; }
    NSString *key = [[NSData dataWithBytes:nonce length:sizeof(nonce)] base64EncodedStringWithOptions:0];
    NSData *request = RGTgwsUpgradeRequest(_host, key);
    if (!request) { if (category) *category = @"protocol"; os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=upgrade_write result=invalid_request"); return NO; }
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=upgrade_write start bytes=%lu", (unsigned long)request.length);
    if (![self write:request failureCategory:category]) { os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=upgrade_write result=failed code=%{public}@", category && *category ? *category : @"unknown"); return NO; }
    NSMutableData *response = [NSMutableData data]; NSTimeInterval responseDeadline = NSProcessInfo.processInfo.systemUptime + 15;
    while (response.length < 16384) {
        NSData *byte = [self read:1 deadline:responseDeadline]; if (!byte) { if (category) *category = @"timeout"; os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=upgrade_read result=timeout"); return NO; } [response appendData:byte];
        if (response.length >= 4 && !memcmp((const uint8_t *)response.bytes + response.length - 4, "\r\n\r\n", 4)) {
            BOOL valid = RGTgwsValidateUpgrade(response, key); if (!valid && category) *category = @"protocol"; os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws ip stage=upgrade_validate result=%{public}@", valid ? @"success" : @"failed"); return valid;
        }
    }
    if (category) *category = @"protocol";
    return NO;
}
- (BOOL)open { return [self openWithCategory:nil]; }
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *))completion {
    if (completion) completion(message.type == NSURLSessionWebSocketMessageTypeData && [self write:RGTgwsClientFrame(message.data, 2)] ? nil : failed());
}
- (BOOL)sendMessage:(NSURLSessionWebSocketMessage *)message failureCategory:(NSString **)category {
    if (message.type != NSURLSessionWebSocketMessageTypeData) { if (category) *category = @"protocol"; return NO; }
    NSData *frame = RGTgwsClientFrame(message.data, 2);
    if (!frame) { if (category) *category = @"unknown"; return NO; }
    return [self write:frame failureCategory:category];
}
- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))completion {
    dispatch_async(_reader, ^{
        NSMutableData *message = [NSMutableData data]; BOOL fragmented = NO; NSUInteger controls = 0, fragments = 0;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 300;
        for (;;) {
            NSData *header = [self read:2 deadline:deadline]; if (!header) break;
            const uint8_t *h = header.bytes; BOOL fin = h[0] & 128; uint8_t opcode = h[0] & 15; uint64_t length = h[1] & 127;
            if ((h[0] & 112) || (h[1] & 128)) break; // No extensions or server masking.
            if (length >= 126) {
                NSUInteger count = length == 126 ? 2 : 8;
                NSData *extended = [self read:count deadline:deadline]; if (!extended) break;
                const uint8_t *e = extended.bytes; length = 0;
                for (NSUInteger i = 0; i < count; i++) length = (length << 8) | e[i];
                if ((count == 2 && length < 126) || (count == 8 && (length <= 65535 || (e[0] & 128)))) break;
            }
            BOOL control = opcode >= 8;
            if (control ? (!fin || length > 125 || (opcode != 8 && opcode != 9 && opcode != 10)) :
                ((opcode != 0 && opcode != 2) || (opcode == 0 && !fragmented) || (opcode == 2 && fragmented) || length > maxMessage - message.length)) break;
            NSData *payload = [self read:(NSUInteger)length deadline:deadline]; if (!payload) break;
            if (control) {
                if (++controls > 1024 || opcode == 8) break; // Close is fail-closed, no reconnect.
                if (opcode == 9 && ![self write:RGTgwsClientFrame(payload, 10)]) break;
                continue;
            }
            [message appendData:payload]; fragmented = !fin;
            if (++fragments > 1024) break;
            if (fin) {
                if (!message.length) break;
                completion([[NSURLSessionWebSocketMessage alloc] initWithData:message], nil); return;
            }
        }
        [self cancel]; completion(nil, failed());
    });
}
@end
