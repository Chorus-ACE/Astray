const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const root = path.resolve(__dirname, '..');
const output = path.join(root, '.build/TestArtifacts/Cleista');
const recorded = path.join(root, 'Tests/Fixtures/cleista-reference.json');
fs.mkdirSync(output, { recursive: true });
if (!fs.existsSync(path.join(root, 'cleista/fulltext-processing.js'))) {
    fs.copyFileSync(recorded, path.join(output, 'reference.json'));
    console.log('Cleista baseline: using the recorded user-supplied JavaScript results.');
    return;
}
const urls = new Map();
function moduleURL(name) {
    if (urls.has(name)) return urls.get(name);
    const source = fs.readFileSync(path.join(root, 'cleista', name), 'utf8')
        .replace(/from\s+(['"])\.\/([^'"]+)\1/g, (_, quote, dependency) => `from '${moduleURL(dependency)}'`);
    const url = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
    urls.set(name, url);
    return url;
}

function element(document, tag = '') {
    return { tag, ownerDocument: document, style: {}, dataset: {}, children: [], text: '',
        appendChild(child) { this.children.push(child); },
        set textContent(value) { this.text = value; this.children = []; },
    };
}
function color(value) {
    if (!value) return null;
    const hex = value.slice(1).padEnd(8, 'f');
    return [0, 2, 4, 6].map(i => parseInt(hex.slice(i, i + 2), 16) / 255);
}

(async () => {
    const { processNativeFulltext } = await import(moduleURL('fulltext-processing.js'));
    const { renderNativeFulltext } = await import(moduleURL('fulltext-richtext.js'));
    const { nativeFulltextCapacity } = await import(moduleURL('fulltext-sequence.js'));
    const lip = await import(moduleURL('lipsync.js'));
    const { retainCharacterShader } = await import(moduleURL('character-shader-state.js'));
    const { nativeFulltextStyles } = await import(moduleURL('fulltext-styles.js'));
    const { evalCubismCurve } = await import(moduleURL('cubism-curve.js'));
    const samples = [
        '', '普通の文字😀e\u0301', String.raw`改行\n復帰\rタブ\t垂直\v`,
        String.raw`\u65E5\u672C\U0001F31F`, String.raw`\uD83D\uDE00`,
        String.raw`\\n literal`, String.raw`\UFFFFFFFF end`, '終端\0非表示',
        'A<BR>B<br>C<NBSP>D<ZWSP>E', '</b>plain', '<unknown>plain</unknown>',
        '<style="Title">題名</style>\n<style=Quote>引用\n二行</style>',
        '<style=H1>大見出し <style=C2>内側</style> 続き</style>',
        '<b>A<i>B<u>C</u>D</i>E</b>', '<color=#12ab34>A<color=#abcd5678>B</color>C</color>',
        '<size=2em>大</size><size=75%>小</size><size=0%>空</size>',
        '<align=right><margin=10%>右寄せ</margin></align>',
        '<link="ID_01"><u>リンク😀</u></link>', '<style=missing>保存</style>',
        '<b>one</b></b><color=#bad>literal</color>',
        ...nativeFulltextStyles.map(s => `<style="${s.name.toLowerCase()}">日本語 ABC</style>`),
    ];
    const text = samples.map(source => {
        const document = { createElement(tag) { return element(document, tag); },
            createDocumentFragment() { return element(document); } };
        const output = element(document);
        renderNativeFulltext(output, source, (node, value) => { node.textContent = value; });
        const glyphs = [];
        function collect(node, parent = {}) {
            const style = { ...parent, ...node.style };
            for (const value of node.text) glyphs.push({ value, scale: parseFloat(style.fontSize || '1'),
                color: color(style.color), bold: style.fontWeight === '700', italic: style.fontStyle === 'italic',
                underline: style.textDecoration === 'underline', alignment: style.textAlign || null,
                margin: parseFloat(style.marginInline || '0') / 100, link: node.dataset.nativeLink || null });
            for (const child of node.children) collect(child, style);
        }
        collect(output);
        const processed = processNativeFulltext(source);
        return { source, expanded: processed.text, processingCount: processed.processingCount,
            plain: glyphs.map(g => g.value).join(''), glyphs };
    });
    const voices = [];
    for (const rms of [0, 0.01, 0.04, 0.055, 0.06, 0.1, 0.25, 0.5, 1])
        for (const scale of [0.25, 1, 1.5, 2])
            voices.push({ rms, scale, target: lip.gameLipTarget(rms, scale, Math.fround(Math.fround(scale) * Math.fround(lip.LIP_POWK))) });
    const operations = [
        ['attach', 1, 'blur', '2'], ['attach', 1, 'blur', '3'], ['attach', 2, 'monitor'],
        ['detach', 1, 'none'], ['attach', 3, '', 'bundle'], ['attach', 2, 'hologram', 'overlay'],
    ];
    const shaders = new Map();
    const shaderStates = operations.map(([op, id, kind, intensity]) => {
        retainCharacterShader(shaders, op, id, kind, intensity);
        return { op, id, kind, intensity: intensity ?? '',
            state: [...shaders].map(([id, value]) => ({ id, kind: value.type || value, intensity: value.intensityRaw || '' })) };
    });
    let capacity = 0;
    const capacities = [0, 1, 12, 2, 33, 8].map(count => ({ count, capacity: capacity = nativeFulltextCapacity(capacity, count) }));
    const curves = [
        [0, -20, 0, 1, 20],
        [0, -20, 1, 0.1, 30, 0.7, -10, 1, 20],
        [0, -20, 2, 0.5, 20, 0, 1, 5],
        [0, -20, 3, 0.5, 20, 0, 1, 5],
    ].map(segments => ({ segments, samples: [0, 0.1, 0.3, 0.499, 0.5, 0.9, 1, 1.5]
        .map(time => ({ time, value: evalCubismCurve(segments, time) })) }));
    const sources = Object.fromEntries([...urls.keys()].map(name => [name,
        crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'cleista', name))).digest('hex')]));
    const fixture = { sources, text, voices, flap: lip.FLAP_PATTERN, capacities, shaderStates, curves };
    fs.writeFileSync(path.join(output, 'reference.json'), JSON.stringify(fixture, null, 2));
    if (process.argv.includes('--record')) fs.writeFileSync(recorded, JSON.stringify(fixture) + '\n');
    console.log(`Cleista baseline: ${text.length} text cases, ${voices.length} voice targets, ${lip.FLAP_PATTERN.length} mouth poses and character shader transitions.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
