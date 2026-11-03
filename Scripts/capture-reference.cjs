const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require('../.build/browser/node_modules/playwright');
const root = path.resolve(__dirname, '..');
process.chdir(root);

(async () => {
    const executable = process.env.ASTRAY_BROWSER_PATH || ['/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => fs.existsSync(p));
    if (!executable) throw new Error('Set ASTRAY_BROWSER_PATH to an installed Chromium browser executable.');
    const port = 5191;
    const server = spawn(process.execPath, ['sekai-scenario-player/node_modules/vite/bin/vite.js', '--config', 'Scripts/reference-vite.config.mjs', '--port', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] });
    let browser;
    try {
        await new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('Reference server startup timed out')), 15000);
            server.on('exit', code => { clearTimeout(timeout); reject(new Error('Reference server exited: ' + code)); });
            server.stdout.on('data', chunk => { if (chunk.toString().includes('Local:')) { clearTimeout(timeout); resolve(); } });
            server.stderr.on('data', chunk => process.stderr.write(chunk));
        });
        browser = await chromium.launch({ executablePath: executable, headless: true, args: ['--use-angle=metal'] });
        const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        page.on('response', response => { if (response.status() >= 400) errors.push(response.url() + ': HTTP ' + response.status()); });
        await page.goto(`http://127.0.0.1:${port}/Tests/ReferenceComparison.html`);
        await page.waitForFunction(() => window.ready === true, { timeout: 45000 });
        if (errors.length) throw new Error(errors.join('\n'));
        await page.screenshot({ path: '.build/TestArtifacts/Haruki/reference-pose.png' });
        const state = await page.evaluate(() => {
            const gl = window.reference.app.renderer.gl;
            const extension = gl.getExtension('WEBGL_debug_renderer_info');
            return { renderer: gl.getParameter(extension.UNMASKED_RENDERER_WEBGL), models: window.reference.stage.modelCache.size, coreVersion: window.Live2DCubismCore.Version.csmGetVersion() };
        });
        if (/swiftshader|software/i.test(state.renderer)) throw new Error('Reference comparison requires a hardware GPU.');
        fs.writeFileSync('.build/TestArtifacts/Haruki/browser.json', JSON.stringify(state, null, 2));
        console.log('Reference hardware renderer:', state.renderer);
    } finally {
        if (browser) await browser.close();
        server.kill('SIGTERM');
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
