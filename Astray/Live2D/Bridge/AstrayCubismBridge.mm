#import "AstrayCubismBridge.h"
#import <TargetConditionals.h>

#if !TARGET_OS_VISION
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include "CubismFramework.hpp"
#include "Model/CubismMoc.hpp"
#include "Model/CubismModel.hpp"
#include "Id/CubismIdManager.hpp"
#include "Motion/CubismMotion.hpp"
#include "Motion/CubismMotionManager.hpp"
#include "Motion/CubismExpressionMotion.hpp"
#include "Motion/CubismExpressionMotionManager.hpp"
#include "Physics/CubismPhysics.hpp"
#include "Effect/CubismPose.hpp"
#include "Utils/CubismDebug.hpp"

using namespace Live2D::Cubism::Framework;

namespace {
class Allocator final : public ICubismAllocator {
public:
    void *Allocate(csmSizeType size) override { return std::malloc(size); }
    void Deallocate(void *memory) override { std::free(memory); }
    void *AllocateAligned(csmSizeType size, csmUint32 alignment) override {
        void *pointer = nullptr;
        return posix_memalign(&pointer, std::max<size_t>(alignment, sizeof(void *)), size) == 0 ? pointer : nullptr;
    }
    void DeallocateAligned(void *memory) override { std::free(memory); }
};

Allocator allocator;

void initializeFramework() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CubismFramework::StartUp(&allocator);
        CubismFramework::Initialize();
    });
}

void motionEventFired(const CubismMotionQueueManager *, const csmString &value, void *) {
    // Match CubismUserModel's default handler; event dispatch requires a non-null callback.
    CubismLogInfo("%s", value.GetRawString());
}

float facialCurveValue(NSArray<NSNumber *> *segments, double time) {
    double previousTime = [segments[0] doubleValue];
    double previousValue = [segments[1] doubleValue];
    if (time <= previousTime) { return (float)previousValue; }
    for (NSUInteger index = 2; index + 2 < segments.count;) {
        int kind = [segments[index] intValue];
        NSUInteger length = kind == 1 ? 7 : 3;
        if (index + length > segments.count) { break; }
        double endTime = [segments[index + length - 2] doubleValue];
        double endValue = [segments[index + length - 1] doubleValue];
        if (time < endTime) {
            if (kind == 2) { return (float)previousValue; }
            if (kind == 3) { return (float)endValue; }
            if (kind == 0) {
                double weight = endTime > previousTime ? (time - previousTime) / (endTime - previousTime) : 0;
                return (float)(previousValue + (endValue - previousValue) * weight);
            }
            auto bezier = [](double a, double b, double c, double d, double t) {
                double inverse = 1 - t;
                return inverse * inverse * inverse * a + 3 * inverse * inverse * t * b
                    + 3 * inverse * t * t * c + t * t * t * d;
            };
            double low = 0, high = 1;
            for (int iteration = 0; iteration < 12; ++iteration) {
                double middle = (low + high) / 2;
                double sample = bezier(previousTime, [segments[index + 1] doubleValue],
                    [segments[index + 3] doubleValue], endTime, middle);
                if (sample < time) { low = middle; } else { high = middle; }
            }
            return (float)bezier(previousValue, [segments[index + 2] doubleValue],
                [segments[index + 4] doubleValue], endValue, (low + high) / 2);
        }
        previousTime = endTime;
        previousValue = endValue;
        index += length;
    }
    return (float)previousValue;
}

NSError *failure(NSString *detail) {
    return [NSError errorWithDomain:@"Astray.Cubism" code:1 userInfo:@{NSLocalizedDescriptionKey: detail}];
}
}

@interface ASRCubismDrawable ()
@property(nonatomic) NSInteger identifier;
@property(nonatomic) NSInteger textureIndex;
@property(nonatomic) NSInteger renderOrder;
@property(nonatomic) NSInteger blendMode;
@property(nonatomic) BOOL isVisible;
@property(nonatomic) BOOL isCulling;
@property(nonatomic) BOOL isMaskInverted;
@property(nonatomic) float opacity;
@property(nonatomic) simd_float4 multiplyColor;
@property(nonatomic) simd_float4 screenColor;
@property(nonatomic, strong) NSData *positions;
@property(nonatomic, strong) NSData *textureCoordinates;
@property(nonatomic, strong) NSData *indices;
@property(nonatomic, strong) NSArray<NSNumber *> *masks;
@property(nonatomic) NSInteger vertexCount;
@property(nonatomic) const void *positionBytes;
@property(nonatomic) simd_float4 bounds;
@property(nonatomic) BOOL verticesChanged;
@end

@implementation ASRCubismDrawable
@end

@interface ASRCubismParameter ()
@property(nonatomic, readwrite) NSString *identifier;
@property(nonatomic, readwrite) float minimum;
@property(nonatomic, readwrite) float maximum;
@property(nonatomic, readwrite) float defaultValue;
@property(nonatomic, readwrite) float value;
@end
@implementation ASRCubismParameter
@end

@implementation ASRCubismModel {
    CubismMoc *_moc;
    CubismModel *_model;
    CubismPhysics *_physics;
    CubismPose *_pose;
    CubismMotionManager *_body;
    CubismMotionManager *_facial;
    CubismExpressionMotionManager *_expression;
    std::map<std::string, ACubismMotion *> _motions;
    std::map<std::string, ACubismMotion *> _facials;
    NSDictionary<NSString *, NSNumber *> *_parameterIndices;
    NSDictionary<NSString *, NSString *> *_parameterAliases;
    NSDictionary<NSString *, NSArray<NSNumber *> *> *_held;
    NSDictionary<NSString *, NSDictionary *> *_facialValues;
    NSDictionary<NSString *, NSNumber *> *_facialFrom;
    NSDictionary<NSString *, NSNumber *> *_facialCurrent;
    double _facialTime;
    double _facialFade;
    double _facialDuration;
    NSString *_bodyName;
    NSString *_facialName;
    double _blinkAt;
    float _previousMouth;
    NSArray<ASRCubismDrawable *> *_renderDrawables;
    simd_float2 _maximumDrawableExtent;
    BOOL _hasRenderChanges;
}

- (instancetype)initWithMoc:(NSData *)moc physics:(NSData *)physics pose:(NSData *)pose error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }
    initializeFramework();
    _moc = CubismMoc::Create((const csmByte *)moc.bytes, (csmSizeInt)moc.length, true);
    if (!_moc || !(_model = _moc->CreateModel())) {
        if (error) { *error = failure(@"Cubism Core rejected the MOC3 model."); }
        return nil;
    }
    _body = new CubismMotionManager();
    _facial = new CubismMotionManager();
    _expression = new CubismExpressionMotionManager();
    _body->SetEventCallback(motionEventFired);
    _facial->SetEventCallback(motionEventFired);
    _expression->SetEventCallback(motionEventFired);
    if (physics) { _physics = CubismPhysics::Create((const csmByte *)physics.bytes, (csmSizeInt)physics.length); }
    if (pose) { _pose = CubismPose::Create((const csmByte *)pose.bytes, (csmSizeInt)pose.length); }
    _facialValues = @{};
    _breathEnabled = YES;
    _blinkEnabled = YES;
    _parameterOverrides = @{};
    NSMutableDictionary *indices = [NSMutableDictionary dictionary];
    NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
    for (int i = 0; i < _model->GetParameterCount(); ++i) {
        NSString *identifier = [NSString stringWithUTF8String:_model->GetParameterId(i)->GetString().GetRawString()];
        indices[identifier] = @(i);
        aliases[[[identifier stringByReplacingOccurrencesOfString:@"_" withString:@""] lowercaseString]] = identifier;
    }
    _parameterIndices = indices;
    _parameterAliases = aliases;
    _model->SaveParameters();
    return self;
}

- (void)dealloc {
    delete _body;
    delete _facial;
    delete _expression;
    for (auto &motion : _motions) { ACubismMotion::Delete(motion.second); }
    for (auto &motion : _facials) { ACubismMotion::Delete(motion.second); }
    if (_physics) { CubismPhysics::Delete(_physics); }
    if (_pose) { CubismPose::Delete(_pose); }
    if (_moc) {
        if (_model) { _moc->DeleteModel(_model); }
        CubismMoc::Delete(_moc);
    }
}

- (NSArray<ASRCubismParameter *> *)parameters {
    NSMutableArray *result = [NSMutableArray array];
    for (int i = 0; i < _model->GetParameterCount(); ++i) {
        ASRCubismParameter *parameter = [ASRCubismParameter new];
        parameter.identifier = [NSString stringWithUTF8String:_model->GetParameterId(i)->GetString().GetRawString()];
        parameter.minimum = _model->GetParameterMinimumValue(i);
        parameter.maximum = _model->GetParameterMaximumValue(i);
        parameter.defaultValue = _model->GetParameterDefaultValue(i);
        parameter.value = _model->GetParameterValue(i);
        [result addObject:parameter];
    }
    return result;
}

- (float)canvasWidth { return _model->GetCanvasWidth(); }
- (float)canvasHeight { return _model->GetCanvasHeight(); }
- (BOOL)isMotionPlaying { return !_body->IsFinished(); }

- (BOOL)loadMotion:(NSData *)data name:(NSString *)name facial:(BOOL)facial error:(NSError **)error {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:NSDictionary.class]) { return NO; }
    // Some converted clips retain Cubism 2 IDs (PARAM_ARM_R_1) while the MOC
    // uses Cubism 3 IDs (ParamArmR1). Match only existing model parameters.
    NSMutableDictionary *normalized = [json mutableCopy];
    for (NSString *collection in @[@"Curves", @"Parameters"]) {
        if (![json[collection] isKindOfClass:NSArray.class]) { continue; }
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *item in json[collection]) {
            NSMutableDictionary *copy = [item mutableCopy];
            NSString *identifier = item[@"Id"];
            if ([identifier isKindOfClass:NSString.class]) {
                NSString *alias = _parameterAliases[[[identifier stringByReplacingOccurrencesOfString:@"_" withString:@""] lowercaseString]];
                if (alias) { copy[@"Id"] = alias; }
            }
            [items addObject:copy];
        }
        normalized[collection] = items;
    }
    json = normalized;
    // Preserve authored numeric spelling for the SDK's JSON reader while
    // replacing only identifier tokens.
    NSMutableString *source = [[NSMutableString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"\"Id\"\\s*:\\s*\"([^\"]+)\"" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [pattern matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSRange range = [match rangeAtIndex:1];
        NSString *identifier = [source substringWithRange:range];
        NSString *alias = _parameterAliases[[[identifier stringByReplacingOccurrencesOfString:@"_" withString:@""] lowercaseString]];
        if (alias) { [source replaceCharactersInRange:range withString:alias]; }
    }
    NSData *normalizedData = [source dataUsingEncoding:NSUTF8StringEncoding];
    bool expression = [json[@"Type"] isEqual:@"Live2D Expression"];
    ACubismMotion *motion = expression
        ? (ACubismMotion *)CubismExpressionMotion::Create((const csmByte *)normalizedData.bytes, (csmSizeInt)normalizedData.length)
        : (ACubismMotion *)CubismMotion::Create((const csmByte *)normalizedData.bytes, (csmSizeInt)normalizedData.length);
    if (!motion) {
        if (error) { *error = failure([@"Invalid motion: " stringByAppendingString:name]); }
        return NO;
    }
    motion->SetFadeInTime(facial ? 0.25f : 0.5f);
    motion->SetFadeOutTime(facial ? 0.25f : 0.5f);
    if (!expression) { static_cast<CubismMotion *>(motion)->SetLoop(false); }
    auto &table = facial ? _facials : _motions;
    auto key = std::string(name.UTF8String);
    if (table.count(key)) {
        ACubismMotion::Delete(motion);
        return YES;
    }
    table[key] = motion;
    if (facial && !expression) {
        NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
        for (NSDictionary *curve in json[@"Curves"]) {
            NSArray *segments = curve[@"Segments"];
            NSString *identifier = curve[@"Id"];
            if ([curve[@"Target"] isEqual:@"Parameter"] && ![identifier isEqual:@"ParamMouthOpenY"] && segments.count >= 2) {
                parameters[identifier] = segments;
            }
        }
        NSMutableDictionary *values = [_facialValues mutableCopy];
        values[name] = @{@"curves": parameters, @"duration": json[@"Meta"][@"Duration"] ?: @0};
        _facialValues = values;
    }
    return YES;
}

- (void)playMotion:(NSString *)motion facial:(NSString *)facial instant:(BOOL)instant {
    auto body = _motions.find(std::string(motion.UTF8String));
    if (motion.length && body != _motions.end()) {
        body->second->SetFadeInTime(instant ? 0 : ([_bodyName isEqual:motion] ? 0.125f : 0.5f));
        _body->StartMotionPriority(body->second, false, 3);
        _bodyName = motion;
    }
    auto expression = _facials.find(std::string(facial.UTF8String));
    if (facial.length && expression != _facials.end() && (instant || ![_facialName isEqual:facial])) {
        expression->second->SetFadeInTime(instant ? 0 : 0.25f);
        if (dynamic_cast<CubismExpressionMotion *>(expression->second)) {
            _facial->StopAllMotions();
            _expression->StartMotion(expression->second, false);
            _held = nil;
            _facialCurrent = nil;
        } else {
            _expression->StopAllMotions();
            _facial->StartMotionPriority(expression->second, false, 3);
            _held = _facialValues[facial][@"curves"];
            _facialDuration = [_facialValues[facial][@"duration"] doubleValue];
            NSMutableDictionary *from = [NSMutableDictionary dictionary];
            for (NSString *identifier in _held) {
                from[identifier] = _facialCurrent[identifier] ?: @(_model->GetParameterValue(
                    CubismFramework::GetIdManager()->GetId(identifier.UTF8String)));
            }
            _facialFrom = from;
            _facialTime = 0;
            _facialFade = instant ? 0 : 0.25;
        }
        _facialName = facial;
    }
}

- (void)stopMotion {
    _body->StopAllMotions();
    _bodyName = nil;
    for (int i = 0; i < _model->GetParameterCount(); ++i) {
        _model->SetParameterValue(i, _model->GetParameterDefaultValue(i));
    }
    _model->SaveParameters();
}

- (void)clearFacial {
    _facial->StopAllMotions();
    _expression->StopAllMotions();
    _facialName = nil;
    _held = nil;
    _facialFrom = nil;
    _facialCurrent = nil;
    _facialTime = 0;
    _facialFade = 0;
    _facialDuration = 0;
}

- (void)applyParameterOverrides {
    if (_locksTransform) {
        for (NSString *identifier in @[@"ParamSize", @"ParamScale", @"ParamScaleX", @"ParamScaleY", @"ParamPositionX", @"ParamPositionY"]) {
            NSNumber *index = _parameterIndices[identifier];
            if (index) { _model->SetParameterValue(index.intValue, _model->GetParameterDefaultValue(index.intValue)); }
        }
    }
    for (NSString *identifier in _parameterOverrides) {
        NSString *resolved = _parameterAliases[[[identifier stringByReplacingOccurrencesOfString:@"_" withString:@""] lowercaseString]] ?: identifier;
        NSNumber *index = _parameterIndices[resolved];
        float value = _parameterOverrides[identifier].floatValue;
        if (index && std::isfinite(value)) {
            int i = index.intValue;
            _model->SetParameterValue(i, std::max(_model->GetParameterMinimumValue(i),
                std::min(_model->GetParameterMaximumValue(i), value)));
        }
    }
}

- (void)update:(double)delta time:(double)time mouth:(float)mouth {
    _model->LoadParameters();
    _body->UpdateMotion(_model, (float)delta);
    _model->SaveParameters();
    _facial->UpdateMotion(_model, (float)delta);
    _expression->UpdateMotion(_model, (float)delta);
    auto ids = CubismFramework::GetIdManager();
    _facialTime += delta;
    double facialWeight = _facialFade > 0 ? (1 - std::cos(std::min(1.0, _facialTime / _facialFade) * M_PI)) / 2 : 1;
    double facialTime = _facialDuration > 0 ? std::min(_facialTime, _facialDuration) : _facialTime;
    // Keep the evaluated facial pose after queue completion without freezing its first keyframe.
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    for (NSString *identifier in _held) {
        float target = facialCurveValue(_held[identifier], facialTime);
        float from = [_facialFrom[identifier] floatValue];
        float value = from + (target - from) * (float)facialWeight;
        _model->SetParameterValue(ids->GetId(identifier.UTF8String), value);
        current[identifier] = @(value);
    }
    _facialCurrent = current;
    if (_blinkEnabled) {
        if (_blinkAt == 0) { _blinkAt = time + 1 + arc4random_uniform(4001) / 1000.0; }
        double phase = -M_PI_2 + (time - _blinkAt) * 10;
        if (time >= _blinkAt && phase <= M_PI_2) {
            float eye = (float)std::abs(std::sin(phase));
            for (auto name : {"ParamEyeLOpen", "ParamEyeROpen"}) {
                auto identifier = ids->GetId(name);
                _model->SetParameterValue(identifier, _model->GetParameterValue(identifier) * eye);
            }
        } else if (phase > M_PI_2) { _blinkAt = time + 1 + arc4random_uniform(4001) / 1000.0; }
    } else { _blinkAt = 0; }
    if (_breathEnabled) {
        _model->SetParameterValue(ids->GetId("ParamBreath"), (float)((std::sin(time * M_PI * 2 / 3) * 0.5 + 0.5) * 0.5));
    }
    if (_breathSwayEnabled) {
        // Match DoriKit Live2DView: blend each target into the authored pose
        // at half weight instead of adding an offset to the animation.
        _model->SetParameterValue(ids->GetId("ParamAngleX"), (float)std::sin(time * M_PI * 2 / 6.5345) * 7.5f, 0.5f);
        _model->SetParameterValue(ids->GetId("ParamAngleY"), (float)std::sin(time * M_PI * 2 / 3.5345) * 4.0f, 0.5f);
        _model->SetParameterValue(ids->GetId("ParamAngleZ"), (float)std::sin(time * M_PI * 2 / 5.5345) * 5.0f, 0.5f);
        _model->SetParameterValue(ids->GetId("ParamBodyAngleX"), (float)std::sin(time * M_PI * 2 / 15.5345) * 2.0f, 0.5f);
    }
    float baseWeight = _previousMouth >= 0.1f ? (std::abs(mouth - _previousMouth) < 0.1f ? 0.2f : 0.25f) : 0.6f;
    float weight = 1 - std::pow(1 - baseWeight, (float)std::min(0.25, std::max(0.0, delta)) * 60);
    _previousMouth += (mouth - _previousMouth) * weight;
    _model->SetParameterValue(ids->GetId("ParamMouthOpenY"), _previousMouth);
    [self applyParameterOverrides];
    if (_physics) { _physics->Evaluate(_model, (float)delta); }
    if (_pose) { _pose->UpdateParameters(_model, (float)delta); }
    // Physics may write parameters too, so apply overrides once more afterward.
    [self applyParameterOverrides];
    _model->Update();
}

- (NSArray<ASRCubismDrawable *> *)drawables {
    NSMutableArray *result = [NSMutableArray array];
    const int *orders = _model->GetDrawableRenderOrders();
    const int **masks = _model->GetDrawableMasks();
    const int *counts = _model->GetDrawableMaskCounts();
    for (int i = 0; i < _model->GetDrawableCount(); ++i) {
        ASRCubismDrawable *drawable = [ASRCubismDrawable new];
        drawable.identifier = i;
        drawable.textureIndex = _model->GetDrawableTextureIndex(i);
        drawable.renderOrder = orders[i];
        drawable.blendMode = _model->GetDrawableBlendMode(i);
        drawable.isVisible = _model->GetDrawableDynamicFlagIsVisible(i);
        drawable.isCulling = _model->GetDrawableCulling(i);
        drawable.isMaskInverted = _model->GetDrawableInvertedMask(i);
        drawable.opacity = _model->GetDrawableOpacity(i) * _model->GetModelOpacity();
        auto multiply = _model->GetDrawableMultiplyColor(i);
        auto screen = _model->GetDrawableScreenColor(i);
        drawable.multiplyColor = simd_make_float4(multiply.X, multiply.Y, multiply.Z, multiply.W);
        drawable.screenColor = simd_make_float4(screen.X, screen.Y, screen.Z, screen.W);
        int vertices = _model->GetDrawableVertexCount(i);
        drawable.positions = [NSData dataWithBytes:_model->GetDrawableVertexPositions(i) length:vertices * sizeof(float) * 2];
        drawable.vertexCount = vertices;
        drawable.positionBytes = drawable.positions.bytes;
        drawable.textureCoordinates = [NSData dataWithBytes:_model->GetDrawableVertexUvs(i) length:vertices * sizeof(float) * 2];
        drawable.indices = [NSData dataWithBytes:_model->GetDrawableVertexIndices(i) length:_model->GetDrawableVertexIndexCount(i) * sizeof(uint16_t)];
        NSMutableArray *maskIndices = [NSMutableArray array];
        for (int j = 0; j < counts[i]; ++j) { [maskIndices addObject:@(masks[i][j])]; }
        drawable.masks = maskIndices;
        [result addObject:drawable];
    }
    return result;
}

- (NSArray<ASRCubismDrawable *> *)renderDrawables {
    BOOL first = _renderDrawables == nil;
    if (first) {
        _renderDrawables = [self drawables];
        for (ASRCubismDrawable *drawable in _renderDrawables) { drawable.positions = [drawable.positions mutableCopy]; }
    }
    _hasRenderChanges = first;
    const int *orders = _model->GetDrawableRenderOrders();
    for (ASRCubismDrawable *drawable in _renderDrawables) {
        int index = (int)drawable.identifier;
        float opacity = _model->GetDrawableOpacity(index) * _model->GetModelOpacity();
        BOOL visible = _model->GetDrawableDynamicFlagIsVisible(index);
        auto multiply = _model->GetDrawableMultiplyColor(index);
        auto screen = _model->GetDrawableScreenColor(index);
        simd_float4 multiplyColor = simd_make_float4(multiply.X, multiply.Y, multiply.Z, multiply.W);
        simd_float4 screenColor = simd_make_float4(screen.X, screen.Y, screen.Z, screen.W);
        int vertexCount = _model->GetDrawableVertexCount(index);
        auto positions = _model->GetDrawableVertexPositions(index);
        size_t positionSize = vertexCount * sizeof(float) * 2;
        // CubismModel::Update clears Core's dirty flags; compare with our last rendered pose instead.
        drawable.verticesChanged = first || (positionSize > 0 && std::memcmp(drawable.positions.bytes, positions, positionSize) != 0);
        _hasRenderChanges |= drawable.verticesChanged || drawable.opacity != opacity || drawable.isVisible != visible
            || drawable.renderOrder != orders[index] || simd_any(drawable.multiplyColor != multiplyColor)
            || simd_any(drawable.screenColor != screenColor);
        drawable.opacity = opacity;
        drawable.isVisible = visible;
        drawable.renderOrder = orders[index];
        drawable.multiplyColor = multiplyColor;
        drawable.screenColor = screenColor;
        drawable.vertexCount = vertexCount;
        drawable.positionBytes = positions;
        if (drawable.verticesChanged && drawable.vertexCount > 0) {
            std::memcpy([(NSMutableData *)drawable.positions mutableBytes], positions, positionSize);
            simd_float2 minimum = simd_make_float2(positions[0].X, positions[0].Y);
            simd_float2 maximum = minimum;
            for (int vertex = 1; vertex < drawable.vertexCount; ++vertex) {
                simd_float2 point = simd_make_float2(positions[vertex].X, positions[vertex].Y);
                minimum = simd_min(minimum, point);
                maximum = simd_max(maximum, point);
            }
            drawable.bounds = simd_make_float4(minimum.x, minimum.y, maximum.x, maximum.y);
            _maximumDrawableExtent = simd_max(_maximumDrawableExtent, simd_max(simd_abs(minimum), simd_abs(maximum)));
        }
    }
    return _renderDrawables;
}

- (simd_float2)maximumDrawableExtent { return _maximumDrawableExtent; }
- (BOOL)hasRenderChanges { return _hasRenderChanges; }
- (void)updateRenderDrawables { (void)self.renderDrawables; }

- (void)reset {
    _body->StopAllMotions();
    _facial->StopAllMotions();
    _expression->StopAllMotions();
    for (int i = 0; i < _model->GetParameterCount(); ++i) {
        _model->SetParameterValue(i, _model->GetParameterDefaultValue(i));
    }
    _model->SaveParameters();
    if (_physics) { _physics->Reset(); }
    if (_pose) { _pose->Reset(_model); }
    _bodyName = nil;
    _facialName = nil;
    _held = nil;
    _facialFrom = nil;
    _facialCurrent = nil;
    _facialTime = 0;
    _facialFade = 0;
    _facialDuration = 0;
    _blinkAt = 0;
    _previousMouth = 0;
}
@end
#else
@implementation ASRCubismParameter
@end
@implementation ASRCubismDrawable
@end
@implementation ASRCubismModel
- (instancetype)initWithMoc:(NSData *)moc physics:(NSData *)physics pose:(NSData *)pose error:(NSError **)error {
    if (error) { *error = [NSError errorWithDomain:@"Astray.Cubism" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Live2D does not distribute Cubism Core for visionOS in Native R4.1."}]; }
    return nil;
}
- (NSArray *)parameters { return @[]; }
- (float)canvasWidth { return 0; }
- (float)canvasHeight { return 0; }
- (BOOL)isMotionPlaying { return NO; }
- (NSArray *)drawables { return @[]; }
- (NSArray *)renderDrawables { return @[]; }
- (simd_float2)maximumDrawableExtent { return simd_make_float2(0, 0); }
- (BOOL)hasRenderChanges { return NO; }
- (void)updateRenderDrawables {}
- (BOOL)loadMotion:(NSData *)data name:(NSString *)name facial:(BOOL)facial error:(NSError **)error { return NO; }
- (void)playMotion:(NSString *)motion facial:(NSString *)facial instant:(BOOL)instant {}
- (void)stopMotion {}
- (void)clearFacial {}
- (void)update:(double)delta time:(double)time mouth:(float)mouth {}
- (void)reset {}
@end
#endif

#if !TARGET_OS_VISION
namespace Live2D { namespace Cubism { namespace Framework { namespace Rendering {
// Astray owns Metal resources per renderer, without an SDK renderer singleton.
void CubismRenderer::StaticRelease() {}
}}}}
#endif
