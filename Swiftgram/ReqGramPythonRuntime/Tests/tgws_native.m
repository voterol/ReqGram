#import "RGTgwsCrypto.h"
#import "RGTgwsService.h"
#import <CommonCrypto/CommonCrypto.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#if RG_TGWS_TESTING
@interface RGTgwsService (LifecycleTesting)
- (void)tgwsTestEnqueueControl:(dispatch_block_t)block;
- (void)tgwsTestBeforePublication:(dispatch_block_t)block;
@end
#endif

#define CHECK(v) do { if (!(v)) { fprintf(stderr, "FAIL line %d\n", __LINE__); exit(1); } } while (0)
static NSData *hex(NSString *text) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < text.length; i += 2) {
        unsigned int v; [[NSScanner scannerWithString:[text substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v];
        uint8_t b = v; [d appendBytes:&b length:1];
    }
    return d;
}
static NSData *key(NSData *pre, NSData *secret) {
    NSMutableData *d = [pre mutableCopy]; [d appendData:secret];
    uint8_t hash[32]; CC_SHA256(d.bytes, (CC_LONG)d.length, hash);
    return [NSData dataWithBytes:hash length:32];
}
static NSData *reversed(NSData *data) {
    NSMutableData *out = [NSMutableData dataWithLength:data.length];
    for (NSUInteger i = 0; i < data.length; i++) ((uint8_t *)out.mutableBytes)[i] = ((const uint8_t *)data.bytes)[data.length - 1 - i];
    return out;
}
static void cryptoTests(void) {
    // NIST SP800-38A F.5.5 AES-256 CTR vector, including a non-block split.
    NSData *k = hex(@"603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    NSData *iv = hex(@"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
    NSData *plain = hex(@"6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
    NSData *expected = hex(@"601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5");
    RGTgwsCTR *cipher = [[RGTgwsCTR alloc] initWithKey:k iv:iv];
    NSMutableData *actual = [[cipher update:[plain subdataWithRange:NSMakeRange(0, 7)]] mutableCopy];
    [actual appendData:[cipher update:[plain subdataWithRange:NSMakeRange(7, 25)]]];
    CHECK([actual isEqual:expected]);
    NSData *secret = hex(@"00112233445566778899aabbccddeeff");
    NSString *rejectionCode = nil;
    CHECK(![RGTgwsCrypto handshake:[NSMutableData dataWithLength:63] secret:secret rejectionCode:&rejectionCode]);
    CHECK([rejectionCode isEqual:@"invalid_length"]);
    rejectionCode = nil;
    CHECK(![RGTgwsCrypto handshake:[NSMutableData dataWithLength:64] secret:[NSMutableData dataWithLength:15] rejectionCode:&rejectionCode]);
    CHECK([rejectionCode isEqual:@"invalid_length"]);

    // Independent interoperability fixture.  This ciphertext was generated
    // outside RGTgwsCrypto with the pinned Flowseal formula:
    // SHA256(prekey + secret), AES-256-CTR (big-endian counter), and the
    // plaintext tail dddddddd/0200/3412.  Do not regenerate this fixture with
    // the implementation under test: its purpose is to catch a shared
    // key/offset/endianness mistake in the self-generated vectors below.
    NSData *referenceInit = hex(@"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738ef6e4612f8ec09d7");
    RGTgwsCrypto *referenceContext = [RGTgwsCrypto handshake:referenceInit secret:secret];
    CHECK(referenceContext && referenceContext.dc == 2 && !referenceContext.media && referenceContext.protocolByte == 0xdd);

    for (NSNumber *protoNumber in @[@0xef, @0xee, @0xdd]) {
        uint8_t proto = protoNumber.unsignedCharValue;
        NSMutableData *init = [NSMutableData dataWithLength:64];
    uint8_t *b = init.mutableBytes;
        for (NSUInteger i = 0; i < 64; i++) b[i] = (uint8_t)(i + 1);
        memset(b + 56, proto, 4); b[60] = 0xfe; b[61] = 0xff; // media DC2
        NSData *pre = [init subdataWithRange:NSMakeRange(8, 48)];
        RGTgwsCTR *clientUp = [[RGTgwsCTR alloc] initWithKey:key([pre subdataWithRange:NSMakeRange(0, 32)], secret)
            iv:[pre subdataWithRange:NSMakeRange(32, 16)]];
        NSData *encrypted = [clientUp update:init];
        memcpy(b + 56, (const uint8_t *)encrypted.bytes + 56, 8);
        RGTgwsCrypto *ctx = [RGTgwsCrypto handshake:init secret:secret];
        CHECK(ctx && ctx.dc == 2 && ctx.media && ctx.protocolByte == proto);
        CHECK(![RGTgwsCrypto handshake:init secret:[NSMutableData dataWithLength:16]]);
        NSData *relayPre = [ctx.relayInit subdataWithRange:NSMakeRange(8, 48)];
        RGTgwsCTR *remoteUp = [[RGTgwsCTR alloc] initWithKey:[relayPre subdataWithRange:NSMakeRange(0, 32)] iv:[relayPre subdataWithRange:NSMakeRange(32, 16)]];
        NSData *relayPlain = [remoteUp update:ctx.relayInit];
        CHECK(((const uint8_t *)relayPlain.bytes)[56] == proto);
        CHECK(((const uint8_t *)relayPlain.bytes)[60] == 0xfe);
        NSData *upPlain;
        NSData *up = [ctx up:[clientUp update:plain] plaintext:&upPlain];
        CHECK([upPlain isEqual:plain] && [[remoteUp update:up] isEqual:plain]);
        NSData *remoteRev = reversed(relayPre), *clientRev = reversed(pre);
        RGTgwsCTR *remoteDown = [[RGTgwsCTR alloc] initWithKey:[remoteRev subdataWithRange:NSMakeRange(0, 32)] iv:[remoteRev subdataWithRange:NSMakeRange(32, 16)]];
        RGTgwsCTR *clientDown = [[RGTgwsCTR alloc] initWithKey:key([clientRev subdataWithRange:NSMakeRange(0, 32)], secret) iv:[clientRev subdataWithRange:NSMakeRange(32, 16)]];
        CHECK([[clientDown update:[ctx down:[remoteDown update:plain]]] isEqual:plain]);
        NSData *packet = proto == 0xef ? hex(@"0141424344") : hex(@"0400000041424344");
        RGTgwsSplitter *splitter = [[RGTgwsSplitter alloc] initWithProtocol:proto];
        CHECK([splitter appendCipher:[packet subdataWithRange:NSMakeRange(0, 2)] plain:[packet subdataWithRange:NSMakeRange(0, 2)]].count == 0);
        NSData *tail = [packet subdataWithRange:NSMakeRange(2, packet.length - 2)];
        CHECK([[[splitter appendCipher:tail plain:tail] firstObject] isEqual:packet]);
        NSData *bad = proto == 0xef ? hex(@"00") : hex(@"ffffff7f");
        CHECK(![splitter appendCipher:bad plain:bad]);
    }
}
static void pump(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    CHECK(done());
}
static NSData *config(NSInteger port) {
    return [NSJSONSerialization dataWithJSONObject:@{@"port":@(port), @"secret":@"00112233445566778899aabbccddeeff"} options:0 error:nil];
}
static void serviceTests(void) {
    RGTgwsService *s = RGTgwsService.shared;
    __block BOOL invalid = NO;
    [s startWithConfigJSON:[@"{\"port\":true,\"secret\":\"private-test-value\"}" dataUsingEncoding:NSUTF8StringEncoding] event:^(NSDictionary *e) {
        CHECK([e[@"code"] isEqual:@"invalid_config"]); CHECK([e description].length < 100); invalid = YES;
    }];
    pump(^BOOL{ return invalid; });
    // Reuse one port across every restart, including server-closed connections
    // that leave TIME_WAIT behind. No valid handshake or upstream I/O occurs.
    int probe = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(!bind(probe, (struct sockaddr *)&addr, sizeof(addr)));
    socklen_t size = sizeof(addr); CHECK(!getsockname(probe, (struct sockaddr *)&addr, &size)); close(probe);
    NSInteger port = ntohs(addr.sin_port);
    for (int cycle = 0; cycle < 5; cycle++) {
        __block BOOL ready = NO, stopped = NO, completed = NO, joined = NO, duplicate = NO, rejected = NO;
        [s startWithConfigJSON:config(port) event:^(NSDictionary *e) {
            if ([e[@"state"] isEqual:@"ready"]) { CHECK([e[@"host"] isEqual:@"127.0.0.1"]); ready = YES; }
            else if ([e[@"state"] isEqual:@"stopped"]) stopped = YES;
            else if ([e[@"state"] isEqual:@"client_handshake_rejected"]) rejected = YES;
            else CHECK(NO);
        }];
        pump(^BOOL{ return ready; });
        // Address reuse must not permit a second live listener on this port.
        probe = socket(AF_INET, SOCK_STREAM, 0); CHECK(probe >= 0);
        int one = 1; CHECK(!setsockopt(probe, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)));
        errno = 0;
        CHECK(bind(probe, (struct sockaddr *)&addr, sizeof(addr)) == -1);
        CHECK(errno == EADDRINUSE);
        close(probe);
        [s startWithConfigJSON:config(port) event:^(NSDictionary *e) { CHECK([e[@"code"] isEqual:@"already_running"]); duplicate = YES; }];
        pump(^BOOL{ return duplicate; });
        int invalidClient = socket(AF_INET, SOCK_STREAM, 0);
        CHECK(!connect(invalidClient, (struct sockaddr *)&addr, sizeof(addr)));
        uint8_t invalidInit[64] = {0};
        CHECK(send(invalidClient, invalidInit, sizeof(invalidInit), 0) == sizeof(invalidInit));
        pump(^BOOL{ return rejected; });
        struct timeval timeout = {5, 0};
        CHECK(!setsockopt(invalidClient, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)));
        uint8_t byte; CHECK(recv(invalidClient, &byte, 1, 0) == 0); close(invalidClient);
        int client = socket(AF_INET, SOCK_STREAM, 0); CHECK(!connect(client, (struct sockaddr *)&addr, sizeof(addr)));
        uint8_t partial = 1; CHECK(send(client, &partial, 1, 0) == 1);
        // Never complete a valid handshake: this test cannot contact Telegram.
        [s stopWithCompletion:^{ completed = YES; }];
        [s stopWithCompletion:^{ joined = YES; }];
        pump(^BOOL{ return stopped && completed && joined; }); close(client);
    }
}
#if RG_TGWS_TESTING
static void lifecycleTests(void) {
    RGTgwsService *s = RGTgwsService.shared;
    int probe = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(!bind(probe, (struct sockaddr *)&addr, sizeof(addr)));
    socklen_t length = sizeof(addr); CHECK(!getsockname(probe, (struct sockaddr *)&addr, &length)); close(probe);
    NSInteger port = ntohs(addr.sin_port);
    // Stalls use semaphores, never timing sleeps. Cover queued starts, starts
    // past initial epoch validation, and explicit stop of pending starts.
    for (int phase = 0; phase < 3; phase++) {
        dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
        dispatch_block_t stall = ^{
            dispatch_semaphore_signal(entered);
            CHECK(!dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        };
        if (phase == 1) [s tgwsTestBeforePublication:stall];
        else [s tgwsTestEnqueueControl:stall];
        __block BOOL cancelled = NO, completed = NO;
        [s startWithConfigJSON:config(port) event:^(NSDictionary *e) {
            CHECK([e[@"state"] isEqual:@"error"] && [e[@"code"] isEqual:@"start_cancelled"]);
            cancelled = YES;
        }];
        CHECK(!dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        if (phase != 2) {
            [NSNotificationCenter.defaultCenter postNotificationName:@"UIApplicationWillResignActiveNotification" object:nil];
            // An inactive start is refused immediately; rapid activation must
            // not resurrect the older generation already on the control queue.
            __block BOOL rejected = NO;
            [s startWithConfigJSON:config(port) event:^(NSDictionary *e) {
                CHECK([e[@"code"] isEqual:@"not_foreground"]); rejected = YES;
            }];
            pump(^BOOL{ return rejected; });
            [NSNotificationCenter.defaultCenter postNotificationName:@"UIApplicationDidBecomeActiveNotification" object:nil];
        }
        [s stopWithCompletion:^{ completed = YES; }];
        dispatch_semaphore_signal(release);
        pump(^BOOL{ return cancelled && completed; });
        if (phase == 1) [s tgwsTestBeforePublication:nil];
        // The cancelled start must never have published or retained a socket.
        probe = socket(AF_INET, SOCK_STREAM, 0);
        CHECK(!bind(probe, (struct sockaddr *)&addr, sizeof(addr))); close(probe);
    }
    // Publication wins first, but ready is still queued on main. Suspend before
    // servicing callbacks: stale ready must be suppressed and teardown emitted.
    __block BOOL stopped = NO, completed = NO;
    dispatch_semaphore_t published = dispatch_semaphore_create(0);
    [s startWithConfigJSON:config(port) event:^(NSDictionary *e) {
        CHECK([e[@"state"] isEqual:@"stopped"]); stopped = YES;
    }];
    [s tgwsTestEnqueueControl:^{ dispatch_semaphore_signal(published); }];
    CHECK(!dispatch_semaphore_wait(published, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    [NSNotificationCenter.defaultCenter postNotificationName:@"UIApplicationDidEnterBackgroundNotification" object:nil];
    [s stopWithCompletion:^{ completed = YES; }];
    pump(^BOOL{ return stopped && completed; });
    [NSNotificationCenter.defaultCenter postNotificationName:@"UIApplicationDidBecomeActiveNotification" object:nil];
    // Existing service tests below verify fresh starts still work after fencing.
    puts("tgws deterministic lifecycle fencing: PASS");
}
#endif
static void websocketAcceptTest(BOOL valid) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in address = {0}; address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(!bind(listener, (struct sockaddr *)&address, sizeof(address)) && !listen(listener, 1));
    socklen_t length = sizeof(address); CHECK(!getsockname(listener, (struct sockaddr *)&address, &length));
    dispatch_group_t worker = dispatch_group_create();
    dispatch_group_async(worker, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int fd = accept(listener, NULL, NULL); CHECK(fd >= 0);
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        struct timeval timeout = {5, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        NSMutableData *request = [NSMutableData data];
        while (request.length < 8192) {
            uint8_t byte; if (recv(fd, &byte, 1, 0) != 1) break;
            [request appendBytes:&byte length:1];
            if (request.length >= 4 && !memcmp((const uint8_t *)request.bytes + request.length - 4, "\r\n\r\n", 4)) break;
        }
        NSString *text = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
        NSString *keyValue = nil;
        for (NSString *line in [text componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"sec-websocket-key:"])
                keyValue = [[line substringFromIndex:18] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        CHECK(keyValue != nil);
        NSData *acceptInput = [[keyValue stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] dataUsingEncoding:NSASCIIStringEncoding];
        uint8_t hash[20]; CC_SHA1(acceptInput.bytes, (CC_LONG)acceptInput.length, hash);
        NSString *acceptValue = valid ? [[NSData dataWithBytes:hash length:20] base64EncodedStringWithOptions:0] : @"AAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        NSData *response = [[NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\nSec-WebSocket-Protocol: binary\r\n\r\n", acceptValue] dataUsingEncoding:NSASCIIStringEncoding];
        CHECK(send(fd, response.bytes, response.length, 0) == (ssize_t)response.length);
        uint8_t frame[] = {0x82, 1, 0x42};
        send(fd, frame, sizeof(frame), 0);
        uint8_t buf[64]; recv(fd, buf, sizeof(buf), 0);
        close(fd); close(listener);
    });
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%u/mock", ntohs(address.sin_port)]];
    NSURLSessionWebSocketTask *ws = [session webSocketTaskWithURL:url protocols:@[@"binary"]];
    __block BOOL finished = NO;
    [ws resume];
    [ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        CHECK(valid ? (error == nil && [message.data isEqual:hex(@"42")]) : (error != nil && message == nil));
        dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    }];
    pump(^BOOL{ return finished; });
    [ws cancel]; [session invalidateAndCancel];
    CHECK(!dispatch_group_wait(worker, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)));
}
int main(void) {
    @autoreleasepool {
        cryptoTests();
#if RG_TGWS_TESTING
        lifecycleTests();
#endif
        serviceTests(); websocketAcceptTest(YES); websocketAcceptTest(NO);
        puts("tgws native offline tests: PASS");
    }
    return 0;
}
