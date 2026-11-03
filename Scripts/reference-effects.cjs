const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require('../sekai-scenario-player/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const out = process.argv[3] ? path.resolve(process.argv[3]) : path.join(root, '.build/TestArtifacts/Effects');
fs.mkdirSync(out, { recursive: true });
const constant = (value) => ({ m: 0, s: value, n: 0 });
const curve = (a, b) => ({ k: [[0, a, 0, b - a], [1, b, b - a, 0]] });
const minMax = (a, b) => ({ m: 3, s: b, n: a });
const color = { m: 1, g: { c: [[0, 1, 0.5, 0.25], [1, 0.2, 0.6, 1]], a: [[0, 0.9], [1, 0.2]], f: 0 } };
const node = (name, parent, children, extra = {}) => ({ name, active: 1, layer: 5, parent, children, pos: [0, 0, 0], rot: [0, 0, 0, 1], scale: [1, 1, 1], ...extra });
const ps = (shapeType) => ({
    lengthInSec: 1.1, simulationSpeed: 1, looping: 1, playOnAwake: 1, moveWithTransform: shapeType % 2,
    startDelay: constant(0),
    InitialModule: { maxNumParticles: 150, startLifetime: minMax(0.3, 0.9), startSpeed: minMax(0.02, 0.2), startSize: minMax(0.02, 0.08), size3D: 1, startSizeY: constant(0.04), startRotation: minMax(-1, 1), randomizeRotationDirection: 0.3, startColor: color, gravityModifier: constant(0.01) },
    ShapeModule: { enabled: 1, type: shapeType, radius: { value: 0.2 }, radiusThickness: 0.7, arc: { value: 230 }, angle: 25, length: 0.3, m_Position: { x: 0.1, y: -0.05, z: 0 }, m_Rotation: { x: 10, y: 20, z: 30 }, m_Scale: { x: 1.1, y: 0.9, z: 1 }, randomDirectionAmount: 0.1, sphericalDirectionAmount: 0.2, randomPositionAmount: 0.02 },
    EmissionModule: { enabled: 1, rateOverTime: constant(5), m_Bursts: [{ time: 0, cycleCount: 0, repeatInterval: 0.15, probability: 0.8, countCurve: constant(2) }] },
    VelocityModule: { enabled: 1, x: constant(0.01), y: { m: 1, s: 0.1, c: curve(0, 1) }, z: constant(-0.01), radial: constant(0.02), speedModifier: constant(0.9) },
    ClampVelocityModule: { enabled: 1, dampen: 0.2, magnitude: constant(0.15), separateAxis: shapeType % 2, x: constant(0.12), y: constant(0.14), z: constant(0.11), drag: constant(0.02) },
    NoiseModule: { enabled: 1, strength: constant(0.01), frequency: 0.5, scrollSpeed: constant(0.2) },
    RotationModule: { enabled: 1, curve: constant(0.1) },
    SizeModule: { enabled: 1, separateAxes: 1, curve: { m: 1, s: 1, c: curve(0.5, 1.2) }, y: constant(0.8) },
    SizeBySpeedModule: { enabled: 1, range: { x: 0, y: 1 }, curve: { m: 1, s: 1, c: curve(0.8, 1.1) } },
    ColorModule: { enabled: 1, gradient: color },
    UVModule: { enabled: 1, tilesX: 4, tilesY: 2, cycles: 2, animationType: shapeType % 2, rowMode: 1, frameOverTime: { m: 1, s: 1, c: curve(0, 1) }, startFrame: constant(0.1) },
    CustomDataModule: { enabled: 1, vector0_0: { m: 1, s: 1, c: curve(0, 1) } }
});
const types = [0, 1, 2, 3, 4, 7, 8, 9, 10, 11, 17, 12, 5];
const nodes = [node('root', -1, types.map((_, i) => i + 1))];
for (const [index, shape] of types.entries()) {
    nodes.push(node('emitter' + shape, 0, [], {
        pos: [index * 5 - 30, index * 3, 0], scale: [0.8, 1.2, 1], ps: ps(shape),
        psr: { materials: ['particle'], m_RenderMode: index % 2, m_LengthScale: 1.5, m_VelocityScale: 0.2, pivot: [0.1, -0.1, 0], m_MinParticleSize: 0.001, m_MaxParticleSize: 0.5, m_UseCustomVertexStreams: 1, m_VertexStreams: '001f', m_SortingOrder: 210 + index, m_SortingLayerID: -348333445 }
    }));
}
const subIndex = nodes.length;
nodes[0].children.push(subIndex);
nodes.push(node('sub', 0, [], { ps: ps(12), psr: { materials: ['add'], m_SortingLayerID: 109347411, m_SortingOrder: 240, pivot: [0, 0, 0] } }));
nodes[1].ps.SubModule = { enabled: 1, subEmitters: [{ emitter: subIndex, type: 0, properties: 0, emitProbability: 1 }, { emitter: subIndex, type: 2, properties: 15, emitProbability: 1 }] };
const spriteIndex = nodes.length;
nodes[0].children.push(spriteIndex);
nodes.push(node('sprite', 0, [], { pos: [100, -50, 0], sprite: { sprite: 'sprite', color: [0.2, 0.5, 1, 0.8], order: 230, materials: ['multiply'], flip: [1, 0] } }));
const imageIndex = nodes.length;
nodes[0].children.push(imageIndex);
nodes.push(node('image', 0, [], { rect: { amin: [0.5, 0.5], amax: [0.5, 0.5], apos: [30, 40], size: [120, 80], pivot: [0.5, 0.5] }, image: { sprite: 'sprite', color: [1, 1, 1, 1], material: 'alpha' }, canvas: { m_SortingOrder: 250, m_SortingLayerID: -348333445 } }));
nodes[0].animator = { default: 'start', states: { start: { name: 'Play', clip: 'show', speed: 1, trans: [{ to: 'loop', exit: true, exitTime: 1, conds: [] }] }, loop: { name: 'Loop', clip: 'loop', speed: 1, trans: [] }, stop: { name: 'Stop', clip: 'hide', speed: 1, trans: [] } } };
let fixture = {
    name: 'coverage', unit: 540, roots: [0], nodes,
    materials: { particle: { shader: 'Sekai/Particles/Additive+AlphaBlend', tex: { _MainTex: { file: 'particle.png', st: [0.8, 0.7, 0.1, 0.2] } } }, add: { shader: 'Mobile/Particles/Additive' }, multiply: { shader: 'UI/Multiply' }, alpha: { shader: 'UI/Default' } },
    sprites: { sprite: { tex: 'sprite.png', rect: [8, 4, 32, 24], ppu: 100, pivot: [0.5, 0.5] } }, meshes: {},
    clips: {
        show: { len: 0.6, loop: false, curves: [{ kind: 'float', path: 'image', attr: 'm_Color.a', curve: curve(0.2, 1) }, { kind: 'position', path: 'sprite', keys: [[0, [100, -50, 0], [0, 0, 0], [0, 0, 0]], [0.6, [140, -30, 0], [0, 0, 0], [0, 0, 0]]] }] },
        loop: { len: 1, loop: true, curves: [{ kind: 'euler', path: 'sprite', keys: [[0, [0, 0, 0], [0, 0, 0], [0, 0, 20]], [1, [0, 0, 20], [0, 0, 20], [0, 0, 0]]] }] },
        hide: { len: 0.3, loop: false, curves: [{ kind: 'float', path: 'image', attr: 'm_Color.a', curve: curve(1, 0) }] }
    }
};
if (process.argv[2]) fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
class Buffer { constructor(data) { this.data = data; } update(data) { this.data = data; } }
class Geometry { constructor() { this.buffers = {}; } addAttribute(name, data) { this.buffers[name] = data instanceof Buffer ? data : new Buffer(data); return this; } addIndex(data) { this.index = data instanceof Buffer ? data : new Buffer(data); return this; } getBuffer(name) { return this.buffers[name]; } getIndex() { return this.index; } }
class Texture { constructor(base, rect) { this.baseTexture = base; this.width = rect?.width ?? base.width; this.height = rect?.height ?? base.height; } static from() { return new Texture({ width: 64, height: 64, valid: true }); } }
Texture.WHITE = new Texture({ width: 1, height: 1, valid: true });
class MeshMaterial { constructor(texture, options) { this.uniforms = options.uniforms; } }
class Mesh { constructor(geometry, shader) { this.geometry = geometry; this.shader = shader; } }
class Sprite { constructor(texture) { this.texture = texture; this.position = { set: (x, y) => { this.x = x; this.y = y; } }; this.anchor = { set() {} }; } }
const PIXI = { Buffer, Geometry, Texture, MeshMaterial, Mesh, Sprite, Container: class {}, Program: { from() { return {}; } }, BLEND_MODES: { NORMAL: 0, ADD: 1, MULTIPLY: 2 }, ALPHA_MODES: { PMA: 0, NPM: 1 }, Rectangle: class { constructor(x, y, width, height) { Object.assign(this, { x, y, width, height }); } }, Color: class { constructor(value) { this.value = value; } toNumber() { return this.value; } } };
const context = { exports: {}, PIXI, fileUrl: (x) => x, preferred: (x) => x, HttpError: class extends Error {}, console };
context.Math = Object.create(Math);
let randomState = 1n;
context.Math.random = () => {
    randomState ^= BigInt.asUintN(64, randomState << 13n);
    randomState ^= randomState >> 7n;
    randomState ^= BigInt.asUintN(64, randomState << 17n);
    randomState = BigInt.asUintN(64, randomState);
    return Number(randomState >> 11n) / 9007199254740992;
};
let source = fs.readFileSync(path.join(root, 'sekai-scenario-player/src/scenario/particles.ts'), 'utf8');
source = source.replace(/^import .*;\s*$/gm, '') + '\nexport { evalCurve, evalMM, evalGrad, evalMMG };';
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText;
vm.runInNewContext(compiled, context);
const instance = new context.exports.FxInstance(fixture, 'fixture');
const frames = [];
for (let frame = 0; frame < 45; frame++) {
    if (frame === 30) instance.stop();
    instance.update(1 / 30);
    if (![0, 4, 14, 29, 34, 44].includes(frame)) continue;
    frames.push({ frame, state: instance.state, sprites: [...instance.sprites.entries()].map(([node, spr]) => ({ node, visible: spr.visible, position: [spr.x, spr.y], width: spr.width, height: spr.height, rotation: spr.rotation, tint: spr.tint, alpha: spr.alpha })), emitters: [...instance.emitters.entries()].map(([node, em]) => ({ node, particles: em.particles.map(p => ({ position: p.p, velocity: p.v, age: p.age, life: p.life, size: p.size, rotation: p.rot, color: p.color, randoms: p.r })), positions: Array.from(em.mesh.geometry.getBuffer('aVertexPosition').data), uv: Array.from(em.mesh.geometry.getBuffer('aTextureCoord').data), colors: Array.from(em.mesh.geometry.getBuffer('aColor').data), keep: Array.from(em.mesh.geometry.getBuffer('aKeep').data) })) });
    frames[frames.length - 1] = JSON.parse(JSON.stringify(frames.at(-1)));
}
fs.writeFileSync(path.join(out, 'coverage.json'), JSON.stringify(fixture));
fs.writeFileSync(path.join(out, 'reference.json'), JSON.stringify(frames));
console.log('Reference Shuriken baseline:', frames.length, 'frames,', frames.at(-1).emitters.reduce((n, x) => n + x.particles.length, 0), 'surviving particles.');
let cameraSource = fs.readFileSync(path.join(root, 'sekai-scenario-player/src/scenario/camera.ts'), 'utf8').replace(/^import .*;\s*$/gm, '');
const cameraContext = { exports: {}, PIXI: { ...PIXI, Filter: class {} }, Math: context.Math, console };
vm.runInNewContext(ts.transpileModule(cameraSource, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText, cameraContext);
const camera = cameraContext.exports;
const timings = {
    easing: Object.entries(camera.EASE).map(([name, fn]) => ({ name, samples: [0, 0.1, 0.25, 0.5, 0.9, 1].map(t => [t, fn(t)]) })),
    shakes: [0.2, 1, 5].flatMap(duration => [false, true].map(ignoreZ => {
        randomState = 1n;
        const sample = camera.makeShake(duration, 10, 16, 90, true, ignoreZ);
        return { duration, ignoreZ, samples: Array.from({ length: 20 }, (_, i) => { const t = i / 19 * duration; return [t, ...sample(t)]; }) }; })),
    wipes: ['LeftIn', 'LeftOut', 'RightIn', 'RightOut', 'TopIn', 'TopOut', 'BottomIn', 'BottomOut'].map(name => ({ name, ...camera.sideFade(name) })),
    dolly: ['Zoom：1.1, Blur：0, Dist：-5', 'Zoom:0.8, Blur:2.8, Dist:-5', 'Zoom:1', 'Blur:3'].map(value => ({ value, parsed: camera.parseDolly(value) }))
};
fs.writeFileSync(path.join(out, 'timing-reference.json'), JSON.stringify(timings));
