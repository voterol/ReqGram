#import "RGTgwsIPTransport.h"
#include <arpa/inet.h>
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d\n", __LINE__); abort(); } } while (0)

@interface RGTgwsIPTransport (Offline)
- (NSData *)read:(NSUInteger)length deadline:(NSTimeInterval)deadline;
- (BOOL)write:(NSData *)data;
@end
@interface Fixture : RGTgwsIPTransport
@property NSData *input;
@property NSUInteger offset;
@property NSMutableArray<NSData *> *writes;
@end
@implementation Fixture
- (NSData *)read:(NSUInteger)length deadline:(NSTimeInterval)deadline {
    (void)deadline;
    if (length > self.input.length - self.offset) return nil;
    NSData *result = [self.input subdataWithRange:NSMakeRange(self.offset, length)]; self.offset += length; return result;
}
- (BOOL)write:(NSData *)data { if (!data) return NO; [self.writes addObject:data]; return YES; }
@end
static BOOL receives(NSData *input, NSData **output, NSArray **writes) {
    Fixture *transport = [[Fixture alloc] initWithDC:2 media:NO addressIndex:0];
    transport.input = input; transport.writes = [NSMutableArray array];
    dispatch_semaphore_t signal = dispatch_semaphore_create(0); __block NSData *received = nil;
    [transport receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        if (!error) received = message.data; dispatch_semaphore_signal(signal);
    }];
    CHECK(!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    [transport finish]; if (output) *output = received; if (writes) *writes = transport.writes;
    return received != nil;
}
static NSData *bytes(const uint8_t *data, NSUInteger length) { return [NSData dataWithBytes:data length:length]; }
int main(void) {
    @autoreleasepool {
        NSArray *expected = @[@[@"149.154.175.50", @"2001:b28:f23d:f001::a"],
            @[@"149.154.167.50", @"95.161.76.100", @"2001:67c:4e8:f002::a"],
            @[@"149.154.175.100", @"2001:b28:f23d:f003::a"],
            @[@"149.154.167.91", @"2001:67c:4e8:f004::a"],
            @[@"149.154.171.5", @"2001:b28:f23f:f005::a"]];
        for (NSInteger dc = 1; dc <= 5; dc++) {
            CHECK([RGTgwsDCAddresses(dc) isEqual:expected[dc - 1]]);
            CHECK([RGTgwsCanonicalHost(dc, NO) isEqual:[NSString stringWithFormat:@"kws%ld.web.telegram.org", (long)dc]]);
            CHECK([RGTgwsCanonicalHost(dc, YES) isEqual:[NSString stringWithFormat:@"kws%ld-1.web.telegram.org", (long)dc]]);
            for (NSNumber *media in @[@NO, @YES]) {
                NSString *host = RGTgwsCanonicalHost(dc, media.boolValue);
                NSString *request = [[NSString alloc] initWithData:RGTgwsUpgradeRequest(host, @"dGhlIHNhbXBsZSBub25jZQ==") encoding:NSASCIIStringEncoding];
                CHECK([request hasPrefix:@"GET /apiws HTTP/1.1\r\n"]);
                CHECK([request containsString:[NSString stringWithFormat:@"\r\nHost: %@\r\n", host]]);
                CHECK([request containsString:@"Sec-WebSocket-Protocol: binary\r\n"]);
            }
            for (NSString *ip in RGTgwsDCAddresses(dc)) { uint8_t address[16]; CHECK(inet_pton(AF_INET, ip.UTF8String, address) == 1 || inet_pton(AF_INET6, ip.UTF8String, address) == 1); }
        }
        CHECK([RGTgwsDCAddresses(203) isEqual:RGTgwsDCAddresses(2)]);
        CHECK([RGTgwsCanonicalHost(203, YES) isEqual:@"kws2-1.web.telegram.org"]);
        CHECK(!RGTgwsCanonicalHost(6, NO) && !RGTgwsDCAddresses(-2).count);
        CHECK(![[RGTgwsIPTransport alloc] initWithDC:2 media:NO addressIndex:3]);
        CHECK(!RGTgwsUpgradeRequest(@"149.154.167.50", @"dGhlIHNhbXBsZSBub25jZQ=="));
        CHECK(!RGTgwsUpgradeRequest(@"evil.web.telegram.org", @"dGhlIHNhbXBsZSBub25jZQ=="));
        CHECK(!RGTgwsUpgradeRequest(@"kws2.web.telegram.org", @"bad\r\nInjected: yes"));
        NSString *valid = @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: binary\r\n\r\n";
        NSString *key = @"dGhlIHNhbXBsZSBub25jZQ==";
        CHECK(RGTgwsValidateUpgrade([valid dataUsingEncoding:NSASCIIStringEncoding], key));
        for (NSArray *change in @[@[@"101", @"200"], @[@"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", @"bad"], @[@"binary", @"text"], @[@"Upgrade: WebSocket", @"Upgrade: h2"], @[@"\r\n\r\n", @"\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"], @[@"\r\n\r\n", @"\r\nSec-WebSocket-Protocol: binary\r\n\r\n"]]) {
            CHECK(!RGTgwsValidateUpgrade([[valid stringByReplacingOccurrencesOfString:change[0] withString:change[1]] dataUsingEncoding:NSASCIIStringEncoding], key));
        }
        for (NSNumber *size in @[@0, @1, @125, @126, @65535, @65536, @(4 * 1024 * 1024 + 4)]) {
            NSMutableData *payload = [NSMutableData dataWithLength:size.unsignedIntegerValue]; memset(payload.mutableBytes, 0x5a, payload.length);
            NSData *frame = RGTgwsClientFrame(payload, 2); CHECK(frame);
            const uint8_t *f = frame.bytes; CHECK(f[0] == 0x82 && (f[1] & 0x80));
            NSUInteger h = payload.length < 126 ? 2 : payload.length <= 65535 ? 4 : 10;
            for (NSUInteger i = 0; i < payload.length; i++) CHECK((f[h + 4 + i] ^ f[h + i % 4]) == 0x5a);
        }
        CHECK(!RGTgwsClientFrame([NSMutableData dataWithLength:4 * 1024 * 1024 + 5], 2));
        CHECK(!RGTgwsClientFrame([NSMutableData dataWithLength:126], 10));
        NSData *output = nil; NSArray *writes = nil;
        const uint8_t binary[] = {0x82, 2, 1, 2}; CHECK(receives(bytes(binary, sizeof(binary)), &output, NULL)); CHECK(output.length == 2);
        const uint8_t fragmented[] = {0x02, 1, 1, 0x89, 1, 3, 0x80, 1, 2};
        CHECK(receives(bytes(fragmented, sizeof(fragmented)), &output, &writes)); CHECK(output.length == 2 && writes.count == 1); CHECK(((const uint8_t *)[writes[0] bytes])[0] == 0x8a);
        const uint8_t invalid[][10] = {{0x81, 1, 1}, {0xc2, 1, 1}, {0x82, 0x81, 1}, {0x80, 1, 1}, {0x82, 126, 0, 1, 1}, {0x82, 127, 0x80}, {0x09, 0}, {0x88, 0}, {0x82, 0}, {0x82, 127, 0, 0, 0, 0, 0, 0x40, 0, 5}};
        for (NSUInteger i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) CHECK(!receives(bytes(invalid[i], 10), NULL, NULL));
        puts("tgws IP mapping, upgrade, masked framing and bounded receive: PASS (offline)");
    }
    return 0;
}
