import { test, expect, mode } from '../fixtures';

// browser.newContext(): a private window of Search's, signed in as nobody.
test.describe('contexts', () => {
  test('a new context is a window of its own, with its own cookies', async ({ search, server }) => {
    const one = await search.newContext();
    const two = await search.newContext();
    const a = await one.newPage();
    const b = await two.newPage();
    await a.goto(server.url('/cookie'));
    await b.goto(server.url('/'));
    expect((await one.cookies()).map(c => c.name)).toContain('flavour');
    expect((await two.cookies()).map(c => c.name)).not.toContain('flavour');
    await one.close();
    await two.close();
  });

  test('cookies added and cleared', async ({ search, server }) => {
    const context = await search.newContext();
    await context.addCookies([{ name: 'given', value: '1', url: server.origin }]);
    const page = await context.newPage();
    await page.goto(server.url('/'));
    expect(await page.evaluate(() => document.cookie)).toContain('given=1');
    await context.clearCookies();
    expect(await context.cookies()).toEqual([]);
    await context.close();
  });

  test('permissions granted to a context', async ({ search, server }) => {
    const context = await search.newContext();
    await context.grantPermissions(['geolocation'], { origin: server.origin });
    await context.setGeolocation({ latitude: 48.85, longitude: 2.35 });
    const page = await context.newPage();
    await page.goto(server.url('/'));
    const where = await page.evaluate(() => new Promise<number[]>((done, fail) =>
      navigator.geolocation.getCurrentPosition(p => done([p.coords.latitude, p.coords.longitude]), fail)));
    expect(where).toEqual([48.85, 2.35]);
    await context.close();
  });

  test('a grant is seen before the page asks, and every other permission refused', async ({ search, server }) => {
    const context = await search.newContext();
    await context.grantPermissions(['notifications'], { origin: server.origin });
    const page = await context.newPage();
    await page.goto(server.url('/'));
    const state = (name: string) => page.evaluate(n => navigator.permissions.query({ name: n as PermissionName }).then(s => s.state), name);
    expect(await page.evaluate(() => Notification.permission)).toBe('granted');
    expect(await state('notifications')).toBe('granted');
    expect(await state('geolocation')).toBe('denied');
    await context.clearPermissions();
    expect(await state('notifications')).not.toBe('granted');
    await context.close();
  });

  test('a download cancelled', async ({ search, server }) => {
    const context = await search.newContext({ acceptDownloads: true });
    const page = await context.newPage();
    await page.goto(server.url('/downloads.html'));
    const [download] = await Promise.all([page.waitForEvent('download'), page.click('#slow')]);
    expect(download.suggestedFilename()).toBe('slow.bin');
    await download.cancel();
    expect(await download.failure()).toBe('canceled');
    await context.close();
  });

  test('pages opened at once', async ({ search, server }) => {
    const context = await search.newContext();
    const pages = await Promise.all([1, 2, 3, 4].map(() => context.newPage()));
    expect(new Set(pages).size).toBe(4);
    await Promise.all(pages.map((page, i) => page.goto(server.url(`/?${i}`))));
    expect(context.pages().length).toBe(4);
    await context.close();
  });

  test('a popup stays in its context', async ({ search, server }) => {
    const context = await search.newContext();
    const page = await context.newPage();
    await page.goto(server.url('/popup.html'));
    const [popup] = await Promise.all([context.waitForEvent('page'), page.click('#blank')]);
    await popup.waitForLoadState();
    expect(popup.context()).toBe(context);
    expect(await popup.opener()).toBe(page);
    await context.close();
  });

  test('storage state carried to a new context', async ({ search, server }) => {
    const first = await search.newContext();
    const page = await first.newPage();
    await page.goto(server.url('/cookie'));
    await page.evaluate(() => localStorage.setItem('kept', 'yes'));
    const state = await first.storageState();
    await first.close();
    const second = await search.newContext({ storageState: state });
    const again = await second.newPage();
    await again.goto(server.url('/'));
    expect(await again.evaluate(() => localStorage.getItem('kept'))).toBe('yes');
    expect(await again.evaluate(() => document.cookie)).toContain('flavour=oat');
    await second.close();
  });

  test('downloads in a context of its own', async ({ search, server }) => {
    const context = await search.newContext({ acceptDownloads: true });
    const page = await context.newPage();
    await page.goto(server.url('/downloads.html'));
    const [download] = await Promise.all([page.waitForEvent('download'), page.click('#file')]);
    expect(download.suggestedFilename()).toBe('hello.txt');
    expect(await download.path()).toBeTruthy();
    await context.close();
  });

  test('closing a context closes its pages', async ({ search, server }) => {
    const context = await search.newContext();
    const page = await context.newPage();
    await page.goto(server.url('/'));
    const closed = page.waitForEvent('close');
    await context.close();
    await closed;
  });

  test('the default context is your Search', async ({ search }) => {
    test.skip(mode === 'launch', 'a launched Search has no tabs of yours');
    expect(search.contexts().length).toBeGreaterThanOrEqual(1);
  });
});
