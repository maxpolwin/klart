import { defineConfig, Plugin, IndexHtmlTransformContext } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

// Inject a Content-Security-Policy appropriate to the mode. Dev needs inline
// scripts (React refresh preamble) and websockets (HMR); the packaged app gets
// a strict policy with no inline scripts and no network access.
function cspPlugin(): Plugin {
  return {
    name: 'noschen-csp',
    transformIndexHtml(_html: string, ctx: IndexHtmlTransformContext) {
      const isDev = !!ctx.server;
      const scriptSrc = isDev ? "'self' 'unsafe-inline'" : "'self'";
      const connectSrc = isDev ? "'self' ws://localhost:* http://localhost:*" : "'self'";
      const csp = [
        "default-src 'self'",
        `script-src ${scriptSrc}`,
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        `connect-src ${connectSrc}`,
        "object-src 'none'",
        "frame-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
      ].join('; ');

      return [
        {
          tag: 'meta',
          attrs: { 'http-equiv': 'Content-Security-Policy', content: csp },
          injectTo: 'head-prepend' as const,
        },
      ];
    },
  };
}

export default defineConfig({
  plugins: [react(), cspPlugin()],
  base: './',
  root: 'src/renderer',
  build: {
    outDir: '../../dist/renderer',
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src/renderer'),
    },
  },
  server: {
    port: 5173,
  },
});
