import { test, expect } from '../fixtures';

// Screenshots and viewports: the size asked for is the size drawn.
test.describe('screens', () => {
  test('a screenshot at the viewport set', async ({ page, server }) => {
    await page.setViewportSize({ width: 640, height: 480 });
    await page.goto(server.url('/'));
    const shot = await page.screenshot();
    // PNG: width and height at bytes 16 and 20.
    expect(shot.readUInt32BE(16)).toBe(640 * (await page.evaluate(() => devicePixelRatio)));
    expect(await page.evaluate(() => [innerWidth, innerHeight])).toEqual([640, 480]);
  });

  test('a screenshot of a page behind another', async ({ context, server }) => {
    const behind = await context.newPage();
    await behind.goto(server.url('/title.html'));
    const front = await context.newPage();
    await front.goto(server.url('/'));
    const shot = await behind.screenshot();
    expect(shot.length).toBeGreaterThan(1000);
    await front.close();
    await behind.close();
  });

  test('a full page screenshot', async ({ page }) => {
    await page.setContent('<div style="height:3000px;background:linear-gradient(red,blue)"></div>');
    const shot = await page.screenshot({ fullPage: true });
    expect(shot.readUInt32BE(20) / (await page.evaluate(() => devicePixelRatio))).toBeGreaterThanOrEqual(3000);
  });

  test('a page a tool drives is at 100%, whatever the site is kept at', async ({ page, server }) => {
    await page.goto(server.url('/'));
    // At 100% the pixel ratio is the screen's own, a whole number; zoomed,
    // it isn't (125% on a Retina screen is 2.5).
    expect(Number.isInteger(await page.evaluate(() => devicePixelRatio))).toBe(true);
  });
});
