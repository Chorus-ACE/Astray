import path from 'node:path';
export default {
    root: process.cwd(),
    cacheDir: '.build/ReferenceViteCache',
    resolve: { alias: { 'pixi.js': path.resolve('sekai-scenario-player/node_modules/pixi.js/lib/index.mjs') } },
    server: { host: '127.0.0.1', port: 5188, strictPort: true, fs: { allow: [process.cwd()] } }
};
