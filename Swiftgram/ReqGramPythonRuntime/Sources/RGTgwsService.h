#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Events are delivered on main: ready or startup error; a running listener
// can subsequently emit error, then stopped. Client failures close that client.
// ready means loopback listener bound, NOT upstream connectivity verified.
// Errors are fixed codes, never remote exception text or secret/config values.
typedef void (^RGTgwsEvent)(NSDictionary<NSString *, id> *event);

@interface RGTgwsService : NSObject
+ (instancetype)shared;
// JSON object: {"port":1443,"secret":"<32 hex digits>"}.
// Unknown fields rejected. No remote code/config downloads, no direct fallback.
// Pending starts invalidated by stop/suspension report start_cancelled; a new
// activation never resurrects a previous foreground generation.
// Route secret for MTProxySettings is dd + secret (17-byte hex decoding).
- (void)startWithConfigJSON:(NSData *)configJSON event:(RGTgwsEvent)event;
// Main-queue events may also include bounded client-stage diagnostics:
// client_handshake_rejected, upstream_attempt, upstream_connect_failed, and
// upstream_connected. upstream_attempt has only `code` hostname or ip.
// A client_handshake_rejected event may include only invalid_length,
// decrypt_failed, invalid_protocol, or unsupported_dc.
// An upstream_connect_failed event may include one allowlisted `code`:
// timeout, dns, tls, refused, network, protocol, or unknown. They contain no
// payload, peer, URL, secret, or remote error.
// Asynchronous barrier: completion on main only after all listener/client
// workers exit. Keep fail-closed routing until this barrier on explicit disable.
- (void)stopWithCompletion:(dispatch_block_t)completion;
@end
NS_ASSUME_NONNULL_END
