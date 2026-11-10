#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface ASRCubismDrawable : NSObject
@property(nonatomic, readonly) NSInteger identifier;
@property(nonatomic, readonly) NSInteger textureIndex;
@property(nonatomic, readonly) NSInteger renderOrder;
@property(nonatomic, readonly) NSInteger blendMode;
@property(nonatomic, readonly) BOOL isVisible;
@property(nonatomic, readonly) BOOL isCulling;
@property(nonatomic, readonly) BOOL isMaskInverted;
@property(nonatomic, readonly) float opacity;
@property(nonatomic, readonly) simd_float4 multiplyColor;
@property(nonatomic, readonly) simd_float4 screenColor;
@property(nonatomic, readonly) NSData *positions;
@property(nonatomic, readonly) NSData *textureCoordinates;
@property(nonatomic, readonly) NSData *indices;
@property(nonatomic, readonly) NSArray<NSNumber *> *masks;
@property(nonatomic, readonly) NSInteger vertexCount;
@property(nonatomic, readonly) const void *positionBytes;
@property(nonatomic, readonly) simd_float4 bounds;
@property(nonatomic, readonly) BOOL verticesChanged;
@end

@interface ASRCubismParameter : NSObject
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) float minimum;
@property(nonatomic, readonly) float maximum;
@property(nonatomic, readonly) float defaultValue;
@property(nonatomic, readonly) float value;
@end

@interface ASRCubismModel : NSObject
- (nullable instancetype)initWithMoc:(NSData *)moc
                           physics:(nullable NSData *)physics
                              pose:(nullable NSData *)pose
                             error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSArray<ASRCubismParameter *> *parameters;
@property(nonatomic) BOOL breathEnabled;
@property(nonatomic) BOOL blinkEnabled;
@property(nonatomic) BOOL locksTransform;
@property(nonatomic) BOOL breathSwayEnabled;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *parameterOverrides;
@property(nonatomic, readonly) float canvasWidth;
@property(nonatomic, readonly) float canvasHeight;
@property(nonatomic, readonly) BOOL isMotionPlaying;
@property(nonatomic, readonly) NSArray<ASRCubismDrawable *> *drawables;
// Reused metadata and borrowed positions are valid until the next model update or release.
@property(nonatomic, readonly) NSArray<ASRCubismDrawable *> *renderDrawables;
@property(nonatomic, readonly) simd_float2 maximumDrawableExtent;
@property(nonatomic, readonly) BOOL hasRenderChanges;
- (void)updateRenderDrawables;
- (BOOL)loadMotion:(NSData *)data name:(NSString *)name facial:(BOOL)facial error:(NSError **)error;
- (void)playMotion:(NSString *)motion facial:(NSString *)facial instant:(BOOL)instant;
- (void)stopMotion;
- (void)clearFacial;
- (void)update:(double)delta time:(double)time mouth:(float)mouth;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
