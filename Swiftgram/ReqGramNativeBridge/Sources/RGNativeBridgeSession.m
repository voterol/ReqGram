#import "RGNativeBridgeSession.h"

#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <float.h>
#import <limits.h>
#import <math.h>

static const NSUInteger RGMaximumJSONBytes = 64 * 1024;
static const NSUInteger RGMaximumHandles = 256;

@interface RGNativeBridgeSession ()
@property(nonatomic) BOOL closed;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *handles;
@property(nonatomic, strong, nullable) MPVolumeView *volumeView;
@end

@implementation RGNativeBridgeSession

- (instancetype)init {
    self = [super init];
    if (self) { _handles = [[NSMutableDictionary alloc] init]; }
    return self;
}

- (NSDictionary *)error:(NSString *)code { return @{ @"error": code }; }

- (BOOL)isBooleanNumber:(NSNumber *)number {
    return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

- (id)JSONPayload:(NSData *)payload error:(NSString **)error {
    if (payload == nil || payload.length == 0 || payload.length > RGMaximumJSONBytes) {
        *error = @"invalid_payload"; return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![value isKindOfClass:[NSDictionary class]]) { *error = @"invalid_payload"; return nil; }
    return value;
}

- (NSDictionary *)onMain:(NSDictionary *(^)(void))work {
    if ([NSThread isMainThread]) { return work(); }
    __block NSDictionary *result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = work(); });
    return result;
}

- (NSDictionary *)requestOperation:(NSString *)operation payload:(NSData *)payload {
    return [self onMain:^NSDictionary *{
        @try {
            if (self.closed) { return [self error:@"session_inactive"]; }
            if ([operation isEqualToString:@"native.audio.output_volume"]) {
                if (payload != nil) { return [self error:@"invalid_payload"]; }
                return [self boundedResult:@{ @"value": @([AVAudioSession sharedInstance].outputVolume) }];
            }
            if ([operation isEqualToString:@"native.audio.set_output_volume"]) {
                NSString *failure = nil; NSDictionary *object = [self JSONPayload:payload error:&failure];
                if (!object || ![self exactKeys:object keys:@[@"value"]]) { return [self error:failure ?: @"invalid_payload"]; }
                NSNumber *number = [object[@"value"] isKindOfClass:[NSNumber class]] ? object[@"value"] : nil;
                double value = number.doubleValue;
                if (!number || [self isBooleanNumber:number] || !isfinite(value) || value < 0.0 || value > 1.0) { return [self error:@"invalid_payload"]; }
                if (!self.volumeView) {
                    self.volumeView = [[MPVolumeView alloc] initWithFrame:CGRectZero];
                    self.volumeView.hidden = YES;
                    UIWindow *window = nil;
                    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                            if (candidate.isKeyWindow) { window = candidate; break; }
                            if (!window) window = candidate;
                        }
                        if (window.isKeyWindow) break;
                    }
                    if (!window) { self.volumeView = nil; return [self error:@"volume_unavailable"]; }
                    [window addSubview:self.volumeView];
                }
                UISlider *slider = nil;
                for (UIView *view in self.volumeView.subviews) if ([view isKindOfClass:[UISlider class]]) { slider = (UISlider *)view; break; }
                if (!slider) { return [self error:@"volume_unavailable"]; }
                [slider setValue:(float)value animated:NO];
                [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
                return [self boundedResult:@{ @"requested_value": @(value) }];
            }
            NSString *failure = nil; NSDictionary *object = [self JSONPayload:payload error:&failure];
            if (!object) { return [self error:failure]; }
            if ([operation isEqualToString:@"native.release"]) {
                if (![self exactKeys:object keys:@[@"handle"]] || ![object[@"handle"] isKindOfClass:[NSString class]]) return [self error:@"invalid_payload"];
                if (!self.handles[object[@"handle"]]) return [self error:@"invalid_handle"];
                [self.handles removeObjectForKey:object[@"handle"]]; return @{};
            }
            if ([operation isEqualToString:@"native.get"] || [operation isEqualToString:@"native.set"]) {
                NSArray *keys = [operation hasSuffix:@".get"] ? @[@"handle", @"property"] : @[@"handle", @"property", @"value"];
                if (![self exactKeys:object keys:keys]) return [self error:@"invalid_payload"];
                id target = [self targetForHandle:object[@"handle"]]; NSString *property = object[@"property"];
                if (!target) return [self error:@"invalid_handle"];
                if (![property isKindOfClass:[NSString class]] || property.length == 0 || property.length > 128) return [self error:@"invalid_payload"];
                NSString *selector = [operation hasSuffix:@".get"] ? property : [NSString stringWithFormat:@"set%@%@:", [[property substringToIndex:1] uppercaseString], [property substringFromIndex:1]];
                NSArray *arguments = [operation hasSuffix:@".get"] ? @[] : @[object[@"value"] ?: NSNull.null];
                return [self invokeTarget:target selector:selector arguments:arguments];
            }
            if ([operation isEqualToString:@"native.class_call"] || [operation isEqualToString:@"native.instance_call"]) {
                NSString *targetKey = [operation hasSuffix:@"class_call"] ? @"class" : @"handle";
                if (![self exactKeys:object keys:@[targetKey, @"selector", @"arguments"]]) return [self error:@"invalid_payload"];
                id target;
                if ([targetKey isEqualToString:@"class"]) {
                    NSString *name = object[targetKey]; target = [name isKindOfClass:[NSString class]] ? NSClassFromString(name) : nil;
                    if (!target) return [self error:@"class_not_found"];
                } else { target = [self targetForHandle:object[targetKey]]; if (!target) return [self error:@"invalid_handle"]; }
                NSString *selector = object[@"selector"]; NSArray *arguments = object[@"arguments"];
                if (![selector isKindOfClass:[NSString class]] || selector.length == 0 || selector.length > 256 || ![arguments isKindOfClass:[NSArray class]] || arguments.count > 16) return [self error:@"invalid_payload"];
                return [self invokeTarget:target selector:selector arguments:arguments];
            }
            return [self error:@"unsupported_operation"];
        } @catch (__unused NSException *exception) { return [self error:@"native_exception"]; }
    }];
}

- (BOOL)exactKeys:(NSDictionary *)object keys:(NSArray<NSString *> *)keys {
    return object.count == keys.count && [[NSSet setWithArray:object.allKeys] isEqualToSet:[NSSet setWithArray:keys]];
}

- (id)targetForHandle:(id)value {
    return [value isKindOfClass:[NSString class]] ? self.handles[value] : nil;
}

- (const char *)unqualifiedType:(const char *)type {
    while (strchr("rnNoORV", *type)) type++;
    return type;
}

- (BOOL)setInvocation:(NSInvocation *)invocation argument:(id)value index:(NSUInteger)index type:(const char *)rawType {
    const char *type = [self unqualifiedType:rawType];
    if (type[0] == '@' && type[1] != '?') {
        id resolved = value == NSNull.null ? nil : value;
        if ([value isKindOfClass:[NSDictionary class]] && [self exactKeys:value keys:@[@"handle"]]) resolved = [self targetForHandle:value[@"handle"]];
        else if (value != NSNull.null && ![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) return NO;
        if (resolved == nil && value != NSNull.null) return NO;
        [invocation setArgument:&resolved atIndex:index]; return YES;
    }
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    NSNumber *number = value;
    BOOL boolean = [self isBooleanNumber:number];
    if (type[0] == 'B') {
        if (!boolean) return NO;
        BOOL v = number.boolValue; [invocation setArgument:&v atIndex:index]; return YES;
    }
    if (boolean) return NO;
    long double numeric = strtold(number.stringValue.UTF8String, NULL);
    if (!isfinite(numeric)) return NO;
#define RG_SIGNED_ARGUMENT(T, C, MINIMUM, MAXIMUM) \
    case C: { if (truncl(numeric) != numeric || numeric < (long double)(MINIMUM) || numeric > (long double)(MAXIMUM)) return NO; T v = (T)numeric; [invocation setArgument:&v atIndex:index]; return YES; }
#define RG_UNSIGNED_ARGUMENT(T, C, MAXIMUM) \
    case C: { if (truncl(numeric) != numeric || numeric < 0 || numeric > (long double)(MAXIMUM)) return NO; T v = (T)numeric; [invocation setArgument:&v atIndex:index]; return YES; }
    switch (type[0]) {
        RG_SIGNED_ARGUMENT(char, 'c', CHAR_MIN, CHAR_MAX)
        RG_UNSIGNED_ARGUMENT(unsigned char, 'C', UCHAR_MAX)
        RG_SIGNED_ARGUMENT(short, 's', SHRT_MIN, SHRT_MAX)
        RG_UNSIGNED_ARGUMENT(unsigned short, 'S', USHRT_MAX)
        RG_SIGNED_ARGUMENT(int, 'i', INT_MIN, INT_MAX)
        RG_UNSIGNED_ARGUMENT(unsigned int, 'I', UINT_MAX)
        RG_SIGNED_ARGUMENT(long, 'l', LONG_MIN, LONG_MAX)
        RG_UNSIGNED_ARGUMENT(unsigned long, 'L', ULONG_MAX)
        RG_SIGNED_ARGUMENT(long long, 'q', LLONG_MIN, LLONG_MAX)
        RG_UNSIGNED_ARGUMENT(unsigned long long, 'Q', ULLONG_MAX)
        case 'f': { if (fabsl(numeric) > FLT_MAX) return NO; float v = (float)numeric; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'd': { if (fabsl(numeric) > DBL_MAX) return NO; double v = (double)numeric; [invocation setArgument:&v atIndex:index]; return YES; }
        default: break;
    }
#undef RG_SIGNED_ARGUMENT
#undef RG_UNSIGNED_ARGUMENT
    return NO;
}

- (NSDictionary *)invokeTarget:(id)target selector:(NSString *)selectorName arguments:(NSArray *)arguments {
    SEL selector = NSSelectorFromString(selectorName);
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || ![target respondsToSelector:selector]) return [self error:@"selector_not_found"];
    if (signature.numberOfArguments != arguments.count + 2) return [self error:@"signature_mismatch"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target; invocation.selector = selector;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        if (![self setInvocation:invocation argument:arguments[index] index:index + 2 type:[signature getArgumentTypeAtIndex:index + 2]]) return [self error:@"unsupported_type"];
    }
    const char *returnType = [self unqualifiedType:signature.methodReturnType];
    BOOL supported = !strcmp(returnType, "v") || (strchr("cCsSiIlLqQfdB", returnType[0]) && returnType[1] == 0) || (returnType[0] == '@' && returnType[1] != '?');
    if (!supported) return [self error:@"unsupported_type"];
    [invocation invoke];
    if (!strcmp(returnType, "v")) return @{};
    if (returnType[0] == '@') { __unsafe_unretained id value = nil; [invocation getReturnValue:&value]; return [self resultForObject:value]; }
#define RG_RETURN(T, C, BOX) if (returnType[0] == C && returnType[1] == 0) { T v; [invocation getReturnValue:&v]; return [self boundedResult:@{ @"value": BOX }]; }
    RG_RETURN(char, 'c', @(v)) RG_RETURN(unsigned char, 'C', @(v)) RG_RETURN(short, 's', @(v)) RG_RETURN(unsigned short, 'S', @(v))
    RG_RETURN(int, 'i', @(v)) RG_RETURN(unsigned int, 'I', @(v)) RG_RETURN(long, 'l', @(v)) RG_RETURN(unsigned long, 'L', @(v))
    RG_RETURN(long long, 'q', @(v)) RG_RETURN(unsigned long long, 'Q', @(v)) RG_RETURN(float, 'f', @(v)) RG_RETURN(double, 'd', @(v)) RG_RETURN(BOOL, 'B', @(v))
#undef RG_RETURN
    return [self error:@"unsupported_type"];
}

- (NSDictionary *)resultForObject:(id)value {
    if (value == nil) return [self boundedResult:@{ @"value": NSNull.null }];
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSNull class]]) return [self boundedResult:@{ @"value": value }];
    if (self.handles.count >= RGMaximumHandles) return [self error:@"handle_limit"];
    NSString *handle = NSUUID.UUID.UUIDString.lowercaseString; self.handles[handle] = value;
    return [self boundedResult:@{ @"handle": handle, @"class": NSStringFromClass([value class]) }];
}

- (NSDictionary *)boundedResult:(NSDictionary *)result {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if (!data) return [self error:@"native_result_invalid"];
    return data.length <= RGMaximumJSONBytes ? result : [self error:@"result_too_large"];
}

- (void)close {
    [self onMain:^NSDictionary *{ self.closed = YES; [self.handles removeAllObjects]; [self.volumeView removeFromSuperview]; self.volumeView = nil; return @{}; }];
}

@end
