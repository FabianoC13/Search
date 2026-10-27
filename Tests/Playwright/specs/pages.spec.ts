import { test, expect, mode } from '../fixtures';

// A tool's pages are Search's tabs, and behave as Chrome's.
test.describe('pages', () => {
  test('newPage opens a page that navigates', async ({ page, server }) => {
    await page.goto(server.url('/title.html'));
    await expect(page).toHaveTitle('Woof');
    expect(page.url()).toBe(server.url('/title.html'));
  });

  test('a new page starts on about:blank', async ({ page }) => {
    expect(page.url()).toBe('about:blank');
  });

  test('the context lists the page, and close takes it away', async ({ context, server }) => {
    const page = await context.newPage();
    await page.goto(server.url('/'));
    expect(context.pages()).toContain(page);
    const closed = page.waitForEvent('close');
    await page.close();
    await closed;
    expect(context.pages()).not.toContain(page);
  });

  test('back and forward', async ({ page, server }) => {
    await page.goto(server.url('/'));
    await page.goto(server.url('/title.html'));
    await page.goBack();
    await expect(page).toHaveTitle('Home');
    await page.goForward();
    await expect(page).toHaveTitle('Woof');
  });

  test('bringToFront, and a page behind another still works', async ({ context, server }) => {
    const first = await context.newPage();
    const second = await context.newPage();
    await first.goto(server.url('/'));
    await second.goto(server.url('/title.html'));
    // The first is behind the second now: it still runs requestAnimationFrame,
    // which Playwright's clicks wait on.
    const frames = await first.evaluate(() => new Promise<number>(done => {
      let count = 0;
      const tick = () => (++count === 3 ? done(count) : requestAnimationFrame(tick));
      requestAnimationFrame(tick);
    }));
    expect(frames).toBe(3);
    await first.bringToFront();
    expect(await first.evaluate(() => document.visibilityState)).toBe('visible');
    await first.close();
    await second.close();
  });

  test('page crash is the tool\'s to hear', async ({ page, server }) => {
    test.skip(mode === 'attach', 'crashing a page of your own Search is left to launch mode');
    await page.goto(server.url('/'));
    const crashed = page.waitForEvent('crash');
    await page.goto('chrome://crash').catch(() => {});
    await crashed;
  });
});
