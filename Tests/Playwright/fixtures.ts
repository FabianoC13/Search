import { test as base, chromium, type Browser, type BrowserContext, type Page } from '@playwright/test';
import http from 'node:http';
import type { AddressInfo } from 'node:net';

// How the specs reach Search (see playwright.config.ts).
export const mode = (process.env.SEARCH_MODE ?? 'attach') as 'attach' | 'launch';
const endpoint = process.env.SEARCH_CDP ?? 'http://127.0.0.1:9222';
// SEARCH_APP=chrome: Playwright's own Chromium, the baseline the same specs
// are measured against (./playwright.sh baseline).
const app = process.env.SEARCH_APP ?? '/Applications/Search Beta.app/Contents/MacOS/Search';
const executable = app === 'chrome' ? undefined : app;
// SEARCH_HEADLESS=1: headless, which for Search is unseen — Chromium as ever,
// every window off every screen.
const headless = process.env.SEARCH_HEADLESS === '1';

/// A server on this Mac with the pages the specs need.
export type Server = { origin: string; url: (path: string) => string };

const pages: Record<string, { type?: string; body: string; headers?: Record<string, string> }> = {
  '/': { body: '<title>Home</title><h1>Home</h1>' },
  '/title.html': { body: '<title>Woof</title><p>Woof</p>' },
  '/popup.html': {
    body: `<title>Opener</title>
      <a id="blank" target="_blank" href="/title.html">blank</a>
      <a id="noopener" target="_blank" rel="noopener" href="/title.html">noopener</a>
      <form id="post" method="post" action="/echo" target="_blank"><input name="word" value="posted"><button>send</button></form>`,
  },
  '/download': {
    type: 'application/octet-stream',
    body: 'Hello from Search',
    headers: { 'Content-Disposition': 'attachment; filename="hello.txt"' },
  },
  '/downloads.html': { body: '<a id="file" href="/download">file</a><a id="slow" href="/slow-download">slow</a>' },
  '/cookie': { body: 'set', headers: { 'Set-Cookie': 'flavour=oat; Path=/' } },
  '/leave.html': {
    body: `<title>Leave</title><script>addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = ''; })</script>
      <input id="i">`,
  },
};

export const test = base.extend<{ context: BrowserContext; page: Page }, { search: Browser; server: Server }>({
  search: [async ({}, use) => {
    const browser = mode === 'launch'
      ? await chromium.launch({ executablePath: executable, headless })
      : await chromium.connectOverCDP(endpoint);
    await use(browser);
    await browser.close();
  }, { scope: 'worker' }],

  server: [async ({}, use) => {
    const server = http.createServer((request, response) => {
      const path = (request.url ?? '/').split('?')[0];
      if (path === '/slow-download') {
        // A download that never ends on its own: one to cancel.
        response.writeHead(200, {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition': 'attachment; filename="slow.bin"',
        });
        response.write(Buffer.alloc(4096));
        const timer = setInterval(() => response.write(Buffer.alloc(16)), 200);
        response.on('close', () => clearInterval(timer));
        return;
      }
      if (path === '/echo') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', () => {
          response.writeHead(200, { 'Content-Type': 'text/html' });
          response.end(`<title>Echo</title><pre id="echo">${request.method} ${body}</pre>`);
        });
        return;
      }
      const page = pages[path];
      if (!page) {
        response.writeHead(404);
        response.end('not here');
        return;
      }
      response.writeHead(200, { 'Content-Type': page.type ?? 'text/html', ...(page.headers ?? {}) });
      response.end(page.body);
    });
    await new Promise<void>(done => server.listen(0, '127.0.0.1', done));
    const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    await use({ origin, url: path => origin + path });
    await new Promise(done => server.close(done));
  }, { scope: 'worker' }],

  // Attach: your Search's own context, its pages your tabs. Launch: a
  // context of its own, as each of Playwright's tests gets.
  context: async ({ search }, use) => {
    const context = mode === 'launch' ? await search.newContext() : search.contexts()[0];
    await use(context);
    if (mode === 'launch') await context.close();
  },

  page: async ({ context }, use) => {
    const page = await context.newPage();
    await use(page);
    await page.close().catch(() => {});
  },
});

export { expect } from '@playwright/test';
