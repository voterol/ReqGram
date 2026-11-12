#import "RGTgwsService.h"
#import "RGTgwsCrypto.h"
#import "RGTgwsIPTransport.h"
#import <os/log.h>
#import <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <stdatomic.h>
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

// Pinned native port, not an upstream launcher. See TGWSPROXY_RUNTIME.md.
@interface RGTgwsRun : NSObject <NSURLSessionWebSocketDelegate>
@property NSLock *lock;
@property BOOL stopping;
@property BOOL teardownScheduled; // Owned by the service control queue.
@property NSMutableSet<NSNumber *> *fds;
@property NSMutableSet<NSURLSessionWebSocketTask *> *websockets;
@property NSMutableSet<NSURLSessionWebSocketTask *> *openedWebsockets;
@property NSMutableDictionary<NSNumber *, dispatch_semaphore_t> *openingSignals;
@property NSMutableDictionary<NSNumber *, NSError *> *openingErrors;
@property NSMutableSet<RGTgwsIPTransport *> *ipTransports;
@property NSURLSession *session;
@property dispatch_group_t workers;
@property NSData *secret;
@property BOOL cfProxyEnabled;
@property NSArray<NSString *> *cfProxyDomains;
@property NSArray<NSString *> *cfWorkerDomains;
@property NSDictionary<NSString *, NSString *> *dcRedirects;
@property NSUInteger bufferKB;
@property NSUInteger poolSize;
@property(copy) RGTgwsEvent event;
- (BOOL)isStopping;
- (void)emit:(NSString *)state code:(nullable NSString *)code port:(NSInteger)port;
@end
@implementation RGTgwsRun
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
    (void)session;
    [self.lock lock];
    dispatch_semaphore_t signal = self.openingSignals[@(task.taskIdentifier)];
    if (signal && [protocol isEqual:@"binary"]) {
        [self.openedWebsockets addObject:task];
    } else if (signal) {
        self.openingErrors[@(task.taskIdentifier)] = [NSError errorWithDomain:@"RGTgwsWebSocket" code:1 userInfo:nil];
    }
    [self.lock unlock];
    if (signal) dispatch_semaphore_signal(signal);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    [self.lock lock];
    dispatch_semaphore_t signal = self.openingSignals[@(task.taskIdentifier)];
    if (signal && error) self.openingErrors[@(task.taskIdentifier)] = error;
    [self.lock unlock];
    if (signal) dispatch_semaphore_signal(signal);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
- (BOOL)isStopping { [_lock lock]; BOOL v = _stopping; [_lock unlock]; return v; }
- (NSString *)sanitizedState:(NSString *)state {
    static NSSet<NSString *> *allowedStates;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ allowedStates = [NSSet setWithArray:@[@"ready", @"error", @"stopped", @"client_handshake_rejected", @"upstream_attempt", @"upstream_connect_failed", @"upstream_connected"]]; });
    return [allowedStates containsObject:state] ? state : nil;
}
- (NSString *)sanitizedCode:(NSString *)code forState:(NSString *)state {
    NSArray<NSString *> *allowed = nil;
    if ([state isEqualToString:@"client_handshake_rejected"]) {
        allowed = @[@"invalid_length", @"decrypt_failed", @"invalid_protocol", @"unsupported_dc"];
    } else if ([state isEqualToString:@"upstream_attempt"]) {
        allowed = @[@"hostname", @"ip"];
    } else if ([state isEqualToString:@"upstream_connect_failed"]) {
        allowed = @[@"timeout", @"dns", @"tls", @"refused", @"network", @"protocol", @"unknown"];
    } else if ([state isEqualToString:@"error"]) {
        allowed = @[@"not_foreground", @"start_cancelled", @"already_running", @"invalid_config", @"listener_failed", @"secure_random_unavailable", @"runtime_error"];
    } else {
        return nil;
    }
    return [allowed containsObject:code] ? code : nil;
}
- (NSString *)sanitizedStage:(NSString *)stage forState:(NSString *)state {
    if (![state isEqualToString:@"upstream_connect_failed"]) return nil;
    NSArray<NSString *> *allowed = @[@"connect", @"tls", @"upgrade_write", @"upgrade_read", @"upgrade_validate", @"send"];
    return [allowed containsObject:stage] ? stage : nil;
}
- (void)emit:(NSString *)state code:(NSString *)code port:(NSInteger)port {
    NSString *safeState = [self sanitizedState:state];
    if (!safeState) return;
    NSMutableDictionary *e = [@{@"state":safeState} mutableCopy];
    NSString *safeCode = [self sanitizedCode:code forState:safeState];
    if (safeCode) e[@"code"] = safeCode;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws event %{public}@%{public}@", safeState, safeCode ? [@"/" stringByAppendingString:safeCode] : @"");
    if (port) { e[@"host"] = @"127.0.0.1"; e[@"port"] = @(port); }
    dispatch_async(dispatch_get_main_queue(), ^{ self.event(e); });
}
@end

// Socket lifetime is owned by its worker; stop only shuts down under the lock,
// never closes a descriptor which the OS could reuse before worker cleanup.
static void closeClient(RGTgwsRun *run, int fd) {
    [run.lock lock]; [run.fds removeObject:@(fd)]; close(fd); [run.lock unlock];
}
static BOOL socketIO(RGTgwsRun *run, int fd, void *bytes, size_t length, BOOL writing, NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    size_t offset = 0;
    while (offset < length && !run.isStopping) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return NO;
        struct pollfd p = {fd, writing ? POLLOUT : POLLIN, 0};
        int ready = poll(&p, 1, 100);
        if (ready < 0) { if (errno == EINTR) continue; return NO; }
        if (!ready) continue;
        ssize_t n = writing ? send(fd, (uint8_t *)bytes + offset, length - offset, 0) :
            recv(fd, (uint8_t *)bytes + offset, length - offset, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            return NO;
        }
        offset += n;
    }
    return offset == length;
}
typedef NS_ENUM(NSUInteger, RGTgwsWaitResult) {
    RGTgwsWaitCompleted,
    RGTgwsWaitTimedOut,
    RGTgwsWaitStopped
};
static RGTgwsWaitResult awaitWS(RGTgwsRun *run, dispatch_semaphore_t sem, NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!run.isStopping && NSProcessInfo.processInfo.systemUptime < deadline) {
        if (!dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) return RGTgwsWaitCompleted;
    }
    return run.isStopping ? RGTgwsWaitStopped : RGTgwsWaitTimedOut;
}
static NSString *wsFailureCategory(NSError *error) {
    if (!error) return @"timeout";
    if ([error.domain isEqualToString:@"RGTgwsWebSocket"]) return @"protocol";
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorTimedOut: return @"timeout";
            case NSURLErrorCannotFindHost:
            case NSURLErrorDNSLookupFailed: return @"dns";
            case NSURLErrorSecureConnectionFailed:
            case NSURLErrorServerCertificateUntrusted:
            case NSURLErrorServerCertificateHasBadDate:
            case NSURLErrorServerCertificateHasUnknownRoot:
            case NSURLErrorServerCertificateNotYetValid: return @"tls";
            case NSURLErrorCannotConnectToHost: return @"refused";
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorInternationalRoamingOff:
            case NSURLErrorDataNotAllowed: return @"network";
            case NSURLErrorBadServerResponse:
            case NSURLErrorCannotParseResponse: return @"protocol";
            default: break;
        }
    }
    return @"unknown";
}
static NSString *tgwsSecretFingerprint(NSData *secret) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(secret.bytes, (CC_LONG)secret.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:16];
    for (NSUInteger i = 0; i < 8; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static BOOL validHostname(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 || value.length > 253 || [value containsString:@"/"] || [value containsString:@":"]) return NO;
    for (NSString *label in [value componentsSeparatedByString:@"."]) {
        if (!label.length || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"]) return NO;
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
        if ([[label stringByTrimmingCharactersInSet:allowed] length]) return NO;
    }
    return YES;
}
static BOOL validIPv4(NSString *value) {
    struct in_addr address; return [value isKindOfClass:NSString.class] && inet_pton(AF_INET, value.UTF8String, &address) == 1;
}
static BOOL validInteger(NSNumber *value, NSInteger low, NSInteger high) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && value.doubleValue >= low && value.doubleValue <= high && floor(value.doubleValue) == value.doubleValue;
}
static NSURL *routeURL(NSString *host, NSString *path) {
    NSString *escaped = [host stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    return escaped ? [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@%@", escaped, path]] : nil;
}
static _Atomic(uint64_t) tgwsClientSequence = 0;

@protocol RGTgwsMessageSender <NSObject>
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *error))completion;
@end

static BOOL sendWS(RGTgwsRun *run, id<RGTgwsMessageSender> ws, NSData *data, NSString **category) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:data] completionHandler:^(NSError *error) {
        failure = error; ok = error == nil; dispatch_semaphore_signal(sem);
    }];
    RGTgwsWaitResult result = awaitWS(run, sem, 15);
    if (result != RGTgwsWaitCompleted) {
        if (category) *category = result == RGTgwsWaitTimedOut ? @"timeout" : nil;
        return NO;
    }
    if (category) *category = wsFailureCategory(failure);
    return ok;
}
static void handleClient(RGTgwsRun *run, int fd) {
    @autoreleasepool {
        uint64_t clientID = atomic_fetch_add(&tgwsClientSequence, 1) + 1;
        uint8_t init[64];
        NSURLSessionWebSocketTask *ws = nil;
        RGTgwsIPTransport *ip = nil;
        do {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu handshake_read_start expected=64 timeout_s=10", clientID);
        if (!socketIO(run, fd, init, sizeof(init), NO, 10)) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu handshake_read_failed", clientID);
            break;
        }
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu handshake_read_complete bytes=64", clientID);
        NSString *handshakeCode = nil;
        RGTgwsCrypto *crypto = [RGTgwsCrypto handshake:[NSData dataWithBytes:init length:64] secret:run.secret rejectionCode:&handshakeCode];
        if (!crypto) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu handshake_rejected code=%{public}@", clientID, handshakeCode ?: @"unknown");
            [run emit:@"client_handshake_rejected" code:handshakeCode port:0];
            break;
        }
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu handshake_accepted dc=%ld media=%{public}@ proto=%02x", clientID, (long)crypto.dc, crypto.media ? @"yes" : @"no", crypto.protocolByte);
        NSInteger dc = crypto.dc == 203 ? 2 : crypto.dc;
        // Hostname path always first. No post-open replay or direct fallback.
        NSArray<NSString *> *canonicalHosts = crypto.media
            ? @[[NSString stringWithFormat:@"kws%ld-1.web.telegram.org", (long)dc],
                [NSString stringWithFormat:@"kws%ld.web.telegram.org", (long)dc]]
            : @[[NSString stringWithFormat:@"kws%ld.web.telegram.org", (long)dc]];
        NSMutableArray<NSURL *> *routes = [NSMutableArray array];
        if (run.cfProxyEnabled) {
            for (NSString *base in run.cfProxyDomains) {
                NSString *host = [NSString stringWithFormat:@"kws%ld.%@", (long)dc, base];
                NSURL *url = routeURL(host, @"/apiws"); if (url) [routes addObject:url];
            }
        }
        for (NSString *worker in run.cfWorkerDomains) {
            NSString *dst = run.dcRedirects[[NSString stringWithFormat:@"%ld", (long)dc]] ?: RGTgwsDCAddresses(dc).firstObject;
            NSString *query = [NSString stringWithFormat:@"/apiws?dst=%@&dc=%ld", dst, (long)dc];
            NSURL *url = routeURL(worker, query); if (url) [routes addObject:url];
        }
        for (NSString *host in canonicalHosts) { NSURL *url = routeURL(host, @"/apiws"); if (url) [routes addObject:url]; }
        NSString *failureCategory = nil;
        BOOL connected = NO;
        BOOL mayFallback = YES;
        for (NSURL *url in routes) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu upstream_attempt kind=hostname index=%lu", clientID, (unsigned long)[routes indexOfObject:url]);
            [run emit:@"upstream_attempt" code:@"hostname" port:0];
            ws = [run.session webSocketTaskWithURL:url protocols:@[@"binary"]];
            ws.maximumMessageSize = 4 * 1024 * 1024 + 4;
            [run.lock lock];
            if (run.stopping) { [run.lock unlock]; break; }
            dispatch_semaphore_t opening = dispatch_semaphore_create(0);
            run.openingSignals[@(ws.taskIdentifier)] = opening;
            [run.websockets addObject:ws]; [run.lock unlock];
            // URLSession implements RFC6455 Upgrade/Accept verification and
            // system TLS hostname/trust validation. No custom trust or
            // redirect delegate.
            [ws resume];
            RGTgwsWaitResult openResult = awaitWS(run, opening, 15);
            [run.lock lock];
            BOOL opened = [run.openedWebsockets containsObject:ws];
            NSError *openingError = run.openingErrors[@(ws.taskIdentifier)];
            [run.openingSignals removeObjectForKey:@(ws.taskIdentifier)];
            [run.openingErrors removeObjectForKey:@(ws.taskIdentifier)];
            [run.lock unlock];
            failureCategory = openResult == RGTgwsWaitCompleted ? wsFailureCategory(openingError) : @"timeout";
            if (opened && sendWS(run, (id<RGTgwsMessageSender>)ws, crypto.relayInit, &failureCategory)) {
                connected = YES;
                break;
            }
            [ws cancel];
            [run.lock lock]; [run.websockets removeObject:ws]; [run.openedWebsockets removeObject:ws]; [run.lock unlock];
            ws = nil;
            // Fail closed on application send failure, cancellation or unknown errors.
            mayFallback = !opened && (!failureCategory || [@[@"timeout", @"dns", @"tls", @"refused", @"network", @"protocol"] containsObject:failureCategory]);
            if (run.isStopping || !mayFallback) break;
        }
        if (!connected && mayFallback && !run.isStopping) {
            for (NSString *host in canonicalHosts) {
                BOOL media = [host isEqual:RGTgwsCanonicalHost(dc, YES)];
                for (NSUInteger i = 0; i < RGTgwsDCAddresses(dc).count && !run.isStopping; i++) {
                    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu upstream_attempt kind=ip address_index=%lu", clientID, (unsigned long)i);
                    [run emit:@"upstream_attempt" code:@"ip" port:0];
                    NSString *redirect = run.dcRedirects[[NSString stringWithFormat:@"%ld", (long)dc]];
                    ip = redirect.length ? [[RGTgwsIPTransport alloc] initWithDC:dc media:media address:redirect] : [[RGTgwsIPTransport alloc] initWithDC:dc media:media addressIndex:i];
                    [run.lock lock];
                    if (run.stopping) { [run.lock unlock]; [ip cancel]; ip = nil; break; }
                    [run.ipTransports addObject:ip]; [run.lock unlock];
                    NSString *ipCategory = nil;
                    if ([ip openWithCategory:&ipCategory]) {
                        // Upgrade completed: relay-init failure must never replay on another route.
                        connected = [ip sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:crypto.relayInit] failureCategory:&ipCategory];
                        failureCategory = ipCategory;
                        mayFallback = NO;
                    } else {
                        failureCategory = ipCategory;
                    }
                    if (connected) break;
                    [ip cancel]; [run.lock lock]; [run.ipTransports removeObject:ip]; [run.lock unlock]; ip = nil;
                    if (!mayFallback) break;
                }
                if (connected || !mayFallback || run.isStopping) break;
            }
        }
        if (!connected) {
            if (!run.isStopping) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu upstream_failed code=%{public}@", clientID, failureCategory ?: @"unknown");
        [run emit:@"upstream_connect_failed" code:failureCategory port:0];
            }
            break;
        }
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws client=%llu upstream_connected", clientID);
        [run emit:@"upstream_connected" code:nil port:0];
        RGTgwsSplitter *splitter = [[RGTgwsSplitter alloc] initWithProtocol:crypto.protocolByte];
        dispatch_semaphore_t received = nil;
        __block NSURLSessionWebSocketMessage *message = nil;
        __block NSError *receiveError = nil;
        NSTimeInterval lastActivity = NSProcessInfo.processInfo.systemUptime;
        while (!run.isStopping) {
            @autoreleasepool {
                if (!received) {
                    received = dispatch_semaphore_create(0);
                    dispatch_semaphore_t signal = received;
                    void (^handler)(NSURLSessionWebSocketMessage *, NSError *) = ^(NSURLSessionWebSocketMessage *m, NSError *e) {
                        message = m; receiveError = e; dispatch_semaphore_signal(signal);
                    };
                    if (ip) [ip receiveMessageWithCompletionHandler:handler];
                    else [ws receiveMessageWithCompletionHandler:handler];
                }
                if (!dispatch_semaphore_wait(received, DISPATCH_TIME_NOW)) {
                    if (receiveError || message.type != NSURLSessionWebSocketMessageTypeData || !message.data.length) break;
                    NSData *data = [crypto down:message.data];
                    if (!data || !socketIO(run, fd, (void *)data.bytes, data.length, YES, 15)) break;
                    message = nil; receiveError = nil; received = nil;
                    lastActivity = NSProcessInfo.processInfo.systemUptime;
                }
                struct pollfd p = {fd, POLLIN, 0};
                int ready = poll(&p, 1, 50);
                if (ready < 0) { if (errno == EINTR) continue; break; }
                if (ready > 0) {
                    uint8_t buffer[65536]; ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
                    if (n <= 0) { if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue; break; }
                    NSData *plain = nil;
                    NSData *cipher = [crypto up:[NSData dataWithBytes:buffer length:(NSUInteger)n] plaintext:&plain];
                    NSArray *parts = cipher ? [splitter appendCipher:cipher plain:plain] : nil;
                    if (!parts) break;
                    BOOL ok = YES;
                    for (NSData *part in parts) if (!sendWS(run, ip ? (id<RGTgwsMessageSender>)ip : (id<RGTgwsMessageSender>)ws, part, NULL)) { ok = NO; break; }
                    if (!ok) break;
                    lastActivity = NSProcessInfo.processInfo.systemUptime;
                }
                if (NSProcessInfo.processInfo.systemUptime - lastActivity > 300) break;
            }
        }
        } while (NO);
        if (ws) {
            [ws cancel]; [run.lock lock]; [run.websockets removeObject:ws]; [run.openedWebsockets removeObject:ws]; [run.lock unlock];
        }
        if (ip) { [ip cancel]; [ip finish]; [run.lock lock]; [run.ipTransports removeObject:ip]; [run.lock unlock]; }
        closeClient(run, fd);
    }
}

static void tgwsLifecycleLog(NSString *phase, uint64_t epoch, BOOL foreground, BOOL hasRun) {
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO,
                     "tgws lifecycle phase=%{public}@ epoch=%llu foreground=%{public}@ run=%{public}@",
                     phase, epoch, foreground ? @"yes" : @"no", hasRun ? @"yes" : @"no");
}

@implementation RGTgwsService {
    dispatch_queue_t _control, _clients;
    RGTgwsRun *_run;
    NSLock *_lifecycleLock;
    uint64_t _foregroundEpoch;
    BOOL _foreground, _lifecycleInitialized;
    RGTgwsRun *_publishedRun; // Only accessed under _lifecycleLock.
#if RG_TGWS_TESTING
    dispatch_block_t _beforePublication;
#endif
}
+ (instancetype)shared {
    static RGTgwsService *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; }); return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _control = dispatch_queue_create("reqgram.tgws.control", DISPATCH_QUEUE_SERIAL);
        _clients = dispatch_queue_create("reqgram.tgws.clients", DISPATCH_QUEUE_CONCURRENT);
        _lifecycleLock = [[NSLock alloc] init];
#if !TARGET_OS_IOS
        _foreground = YES; _lifecycleInitialized = YES;
#endif
        // Foundation-only target; UIKit posts these notifications on iOS.
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspend:)
            name:@"UIApplicationWillResignActiveNotification" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspend:)
            name:@"UIApplicationDidEnterBackgroundNotification" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(activate:)
            name:@"UIApplicationDidBecomeActiveNotification" object:nil];
    }
    return self;
}
- (void)activate:(NSNotification *)notification {
    [_lifecycleLock lock];
    _foreground = YES; _lifecycleInitialized = YES; ++_foregroundEpoch;
    [_lifecycleLock unlock];
    tgwsLifecycleLog(@"activate", _foregroundEpoch, _foreground, _publishedRun != nil);
}
// Caller holds lifecycle lock. Lock order is lifecycle -> run, never reverse.
- (void)cancelPublishedRun {
    RGTgwsRun *run = _publishedRun;
    if (!run) return;
    [run.lock lock]; run.stopping = YES;
    for (NSNumber *fd in run.fds) shutdown(fd.intValue, SHUT_RDWR);
    for (NSURLSessionWebSocketTask *ws in run.websockets) [ws cancel];
    for (RGTgwsIPTransport *ip in run.ipTransports) [ip cancel];
    [run.lock unlock];
}
- (void)suspend:(NSNotification *)notification {
    // Invalidate before enqueueing teardown: queued starts cannot survive even
    // a suspend/activate cycle while the control queue is stalled.
    [_lifecycleLock lock];
    _foreground = NO; _lifecycleInitialized = YES; ++_foregroundEpoch;
    [self cancelPublishedRun];
    [_lifecycleLock unlock];
    tgwsLifecycleLog(@"suspend", _foregroundEpoch, _foreground, _publishedRun != nil);
    [self stopWithCompletion:^{}];
}
#if RG_TGWS_TESTING
// Compiled only into the offline harness, not the shipped bridge.
- (void)tgwsTestEnqueueControl:(dispatch_block_t)block { dispatch_async(_control, block); }
- (void)tgwsTestBeforePublication:(dispatch_block_t)block {
    dispatch_sync(_control, ^{ self->_beforePublication = [block copy]; });
}
#endif
- (void)startWithConfigJSON:(NSData *)configJSON event:(RGTgwsEvent)event {
#if TARGET_OS_IOS
    if (!NSThread.isMainThread) {
        NSData *copy = [configJSON copy];
        [_lifecycleLock lock]; uint64_t submittedEpoch = _foregroundEpoch; [_lifecycleLock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_lifecycleLock lock];
            BOOL current = self->_foregroundEpoch == submittedEpoch;
            [self->_lifecycleLock unlock];
            if (!current) { event(@{@"state":@"error", @"code":@"start_cancelled"}); return; }
            [self startWithConfigJSON:copy event:event];
        });
        return;
    }
    // UIKit is consulted only on main, once; notification state is authoritative
    // thereafter (willResignActive may precede UIApplication's state change).
    [_lifecycleLock lock];
    if (!_lifecycleInitialized) {
        _foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        _lifecycleInitialized = YES;
    }
    [_lifecycleLock unlock];
#endif
    [_lifecycleLock lock];
    BOOL foreground = _foreground;
    uint64_t epoch = _foregroundEpoch;
    BOOL hasRun = _publishedRun != nil;
    [_lifecycleLock unlock];
    tgwsLifecycleLog(@"start_submit", epoch, foreground, hasRun);
    if (!foreground) {
        dispatch_async(dispatch_get_main_queue(), ^{ event(@{@"state":@"error", @"code":@"not_foreground"}); });
        return;
    }
    NSData *input = [configJSON copy]; RGTgwsEvent callback = [event copy];
    dispatch_async(_control, ^{
        void (^error)(NSString *) = ^(NSString *code) {
            dispatch_async(dispatch_get_main_queue(), ^{ callback(@{@"state":@"error", @"code":code}); });
        };
        [self->_lifecycleLock lock];
        BOOL current = self->_foreground && self->_foregroundEpoch == epoch;
        [self->_lifecycleLock unlock];
        if (!current) { error(@"start_cancelled"); return; }
        if (self->_run) { tgwsLifecycleLog(@"start_rejected_running", epoch, foreground, YES); error(@"already_running"); return; }
        id config = input.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
        NSSet *keys = [NSSet setWithArray:@[@"port", @"secret", @"cfProxyEnabled", @"cfProxyDomains", @"cfWorkerDomains", @"dcRedirects", @"bufferKB", @"poolSize"]];
        if (![config isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:[(NSDictionary *)config allKeys]] isSubsetOfSet:keys] ||
            ![config[@"port"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)config[@"port"]) == CFBooleanGetTypeID() ||
            ![config[@"secret"] isKindOfClass:NSString.class]) { error(@"invalid_config"); return; }
        BOOL cfEnabled = config[@"cfProxyEnabled"] ? [config[@"cfProxyEnabled"] isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)config[@"cfProxyEnabled"]) == CFBooleanGetTypeID() && [config[@"cfProxyEnabled"] boolValue] : YES;
        NSArray *defaultCFDomains = @[@"pclead.co.uk", @"offshor.co.uk", @"cakeisalie.co.uk", @"noskomnadzor.co.uk", @"lovetrue.co.uk", @"sorokdva.co.uk", @"pyatdesyatdva.co.uk", @"kartoshka.co.uk", @"sorokodin.co.uk", @"pyatdesyatodin.co.uk", @"notelega.co.uk", @"ebally.co.uk", @"nebally.co.uk", @"havegreatday.co.uk", @"pomogite.co.uk", @"fixtelega.co.uk", @"sadnews.co.uk", @"onedaychamp.co.uk", @"stopblocking.co.uk", @"nothingthere.co.uk"];
        NSArray *configuredCFDomains = config[@"cfProxyDomains"];
        NSArray *cfDomains = (configuredCFDomains == nil || configuredCFDomains.count == 0) ? defaultCFDomains : configuredCFDomains;
        NSArray *workerDomains = config[@"cfWorkerDomains"] ?: @[];
        NSDictionary *redirects = config[@"dcRedirects"] ?: @{@"2": @"149.154.167.220", @"4": @"149.154.167.220"};
        NSNumber *buffer = config[@"bufferKB"] ?: @256, *pool = config[@"poolSize"] ?: @4;
        BOOL validArrays = [cfDomains isKindOfClass:NSArray.class] && [workerDomains isKindOfClass:NSArray.class] && [redirects isKindOfClass:NSDictionary.class] && cfDomains.count <= 64 && workerDomains.count <= 64 && redirects.count <= 8 && validInteger(buffer, 16, 4096) && validInteger(pool, 1, 64);
        for (id domain in [cfDomains arrayByAddingObjectsFromArray:workerDomains]) validArrays = validArrays && validHostname(domain);
        for (id key in redirects) validArrays = validArrays && [key isKindOfClass:NSString.class] && [@[@"1", @"2", @"3", @"4", @"5", @"203"] containsObject:key] && validIPv4(redirects[key]);
        if (!validArrays) { error(@"invalid_config"); return; }
        double portValue = [config[@"port"] doubleValue];
        NSString *hex = config[@"secret"];
        if (portValue < 1024 || portValue > 65535 || floor(portValue) != portValue || hex.length != 32 ||
            [hex rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) {
            error(@"invalid_config"); return;
        }
        NSMutableData *secret = [NSMutableData dataWithLength:16];
        for (NSUInteger i = 0; i < 16; i++) {
            unsigned int v = 0; [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i * 2, 2)]] scanHexInt:&v];
            ((uint8_t *)secret.mutableBytes)[i] = v;
        }
#if RG_TGWS_TESTING
        if (self->_beforePublication) self->_beforePublication();
#endif
        // Binding, publication and worker registration form one lifecycle
        // transaction. Suspension either wins before bind or cancels the
        // published run synchronously before its notification handler returns.
        [self->_lifecycleLock lock];
        if (!self->_foreground || self->_foregroundEpoch != epoch) {
            [self->_lifecycleLock unlock]; error(@"start_cancelled"); return;
        }
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        if (listener < 0) { [self->_lifecycleLock unlock]; error(@"listener_failed"); return; }
        // A closed client can leave the loopback port in TIME_WAIT. Reuse the
        // address for recovery, but never enable SO_REUSEPORT/shared listeners.
        if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one))) {
            close(listener); [self->_lifecycleLock unlock]; error(@"listener_failed"); return;
        }
        setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        fcntl(listener, F_SETFL, O_NONBLOCK);
        struct sockaddr_in address = {0}; address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons((uint16_t)portValue);
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 16)) {
            close(listener); [self->_lifecycleLock unlock]; error(@"listener_failed"); return;
        }
        RGTgwsRun *run = [[RGTgwsRun alloc] init];
        run.lock = [[NSLock alloc] init]; run.fds = [NSMutableSet setWithObject:@(listener)];
        run.websockets = [NSMutableSet set]; run.openedWebsockets = [NSMutableSet set]; run.openingSignals = [NSMutableDictionary dictionary]; run.openingErrors = [NSMutableDictionary dictionary]; run.ipTransports = [NSMutableSet set]; run.workers = dispatch_group_create(); run.secret = secret; run.event = callback;
        run.cfProxyEnabled = cfEnabled; run.cfProxyDomains = cfDomains; run.cfWorkerDomains = workerDomains; run.dcRedirects = redirects; run.bufferKB = buffer.unsignedIntegerValue; run.poolSize = pool.unsignedIntegerValue;
        NSURLSessionConfiguration *sessionConfig = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        sessionConfig.connectionProxyDictionary = @{}; // Never inherit a client/global proxy and recurse.
        sessionConfig.timeoutIntervalForRequest = 15; sessionConfig.timeoutIntervalForResource = 3600;
        run.session = [NSURLSession sessionWithConfiguration:sessionConfig delegate:run delegateQueue:nil];
        self->_run = run;
        self->_publishedRun = run;
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "tgws native_config port=%ld secret_fp=%{public}@", (long)portValue, tgwsSecretFingerprint(secret));
        tgwsLifecycleLog(@"run_published", epoch, self->_foreground, YES);
        dispatch_group_enter(run.workers);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_lifecycleLock lock];
            BOOL ready = self->_foreground && self->_foregroundEpoch == epoch && self->_publishedRun == run;
            [self->_lifecycleLock unlock];
            if (ready) callback(@{@"state":@"ready", @"host":@"127.0.0.1", @"port":@((NSInteger)portValue)});
        });
        dispatch_async(self->_clients, ^{
            BOOL failed = NO;
            while (!run.isStopping) {
                struct pollfd p = {listener, POLLIN, 0}; int ready = poll(&p, 1, 100);
                if (ready < 0) { if (errno == EINTR) continue; failed = YES; break; }
                if (!ready) continue;
                int fd = accept(listener, NULL, NULL);
                if (fd < 0) { if (errno == EAGAIN || errno == EINTR) continue; failed = !run.isStopping; break; }
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); fcntl(fd, F_SETFL, O_NONBLOCK);
                [run.lock lock];
                if (run.stopping || run.fds.count >= 17) { close(fd); [run.lock unlock]; continue; }
                [run.fds addObject:@(fd)]; dispatch_group_enter(run.workers); [run.lock unlock];
                dispatch_async(self->_clients, ^{ handleClient(run, fd); dispatch_group_leave(run.workers); });
            }
            closeClient(run, listener);
            if (failed) {
                [run emit:@"error" code:@"listener_failed" port:0];
                [self stopWithCompletion:^{}];
            }
            dispatch_group_leave(run.workers);
        });
        [self->_lifecycleLock unlock];
    });
}
- (void)stopWithCompletion:(dispatch_block_t)completion {
    // Also cancels starts already submitted but not yet published.
    [_lifecycleLock lock]; ++_foregroundEpoch;
    tgwsLifecycleLog(@"stop_requested", _foregroundEpoch, _foreground, _publishedRun != nil);
    [self cancelPublishedRun]; [_lifecycleLock unlock];
    dispatch_async(_control, ^{
        RGTgwsRun *run = self->_run;
        if (!run) { tgwsLifecycleLog(@"stop_no_run", self->_foregroundEpoch, self->_foreground, NO); dispatch_async(dispatch_get_main_queue(), completion); return; }
        BOOL first = !run.teardownScheduled; run.teardownScheduled = YES;
        [run.lock lock]; run.stopping = YES;
        for (NSNumber *fd in run.fds) shutdown(fd.intValue, SHUT_RDWR);
        for (NSURLSessionWebSocketTask *ws in run.websockets) [ws cancel];
        for (RGTgwsIPTransport *ip in run.ipTransports) [ip cancel];
        [run.lock unlock];
        // IP transport owns a serial reader queue outside run.workers. Join a
        // stable snapshot before reporting teardown complete so no receive
        // callback survives the service barrier.
        [run.lock lock]; NSArray<RGTgwsIPTransport *> *transports = run.ipTransports.allObjects; [run.lock unlock];
        for (RGTgwsIPTransport *ip in transports) [ip finish];
        [run.session invalidateAndCancel];
        dispatch_group_notify(run.workers, self->_control, ^{
            if (first) {
                if (self->_run == run) self->_run = nil;
                [self->_lifecycleLock lock];
                if (self->_publishedRun == run) self->_publishedRun = nil;
                [self->_lifecycleLock unlock];
                run.secret = nil;
                [run emit:@"stopped" code:nil port:0];
                tgwsLifecycleLog(@"run_teardown_complete", self->_foregroundEpoch, self->_foreground, self->_publishedRun != nil);
            }
            dispatch_async(dispatch_get_main_queue(), completion);
        });
    });
}
@end
