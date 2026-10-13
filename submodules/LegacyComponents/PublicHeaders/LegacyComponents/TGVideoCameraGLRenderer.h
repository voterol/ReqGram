#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>

@class TGVideoCameraRendererBuffer;

@interface TGVideoCameraGLRenderer : NSObject

@property (nonatomic, readonly) __attribute__((NSObject)) CMFormatDescriptionRef outputFormatDescription;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@property (nonatomic, assign) AVCaptureVideoOrientation orientation;
#pragma clang diagnostic pop
@property (nonatomic, assign) bool mirror;
@property (nonatomic, assign) CGFloat opacity;
@property (nonatomic, readonly) bool hasPreviousPixelbuffer;

- (void)prepareForInputWithFormatDescription:(CMFormatDescriptionRef)inputFormatDescription outputRetainedBufferCountHint:(size_t)outputRetainedBufferCountHint;
- (void)reset;

- (TGVideoCameraRendererBuffer *)copyRenderedPixelBuffer:(TGVideoCameraRendererBuffer *)pixelBuffer;
- (void)setPreviousPixelBuffer:(TGVideoCameraRendererBuffer *)previousPixelBuffer;

@end
