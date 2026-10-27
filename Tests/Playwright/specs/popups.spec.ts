import { test, expect } from '../fixtures';

// A popup is Chromium's own, in a tab of Search's: it keeps its opener.
test.describe('popups', () => {
  test('a link with a target is a popup of the page', async ({ page, server }) => {
    await page.goto(server.url('/popup.html'));
    const [popup] = await Promise.all([page.waitForEvent('popup'), page.click('#blank')]);
    await popup.waitForLoadState();
    await expect(popup).toHaveTitle('Woof');
    expect(await popup.opener()).toBe(page);
    await popup.close();
  });

  test('window.open from a script, with no click behind it', async ({ page, server }) => {
    await page.goto(server.url('/'));
    const [popup] = await Promise.all([
      page.waitForEvent('popup'),
      page.evaluate(url => { window.open(url); }, server.url('/title.html')),
    ]);
    await popup.waitForLoadState();
    await expect(popup).toHaveTitle('Woof');
    expect(await popup.evaluate(() => !!window.opener)).toBe(true);
    await popup.close();
  });

  test('noopener is honoured, and still a popup to Playwright', async ({ page, server }) => {
    await page.goto(server.url('/popup.html'));
    const [popup] = await Promise.all([page.waitForEvent('popup'), page.click('#noopener')]);
    await popup.waitForLoadState();
    expect(await popup.evaluate(() => window.opener)).toBe(null);
    await popup.close();
  });

  test('a form posted to a new window keeps its body', async ({ page, server }) => {
    await page.goto(server.url('/popup.html'));
    const [popup] = await Promise.all([page.waitForEvent('popup'), page.click('#post button')]);
    await popup.waitForLoadState();
    await expect(popup.locator('#echo')).toHaveText('POST word=posted');
    await popup.close();
  });

  test('a sized popup, written into from its opener', async ({ page, server }) => {
    await page.goto(server.url('/'));
    const [popup] = await Promise.all([
      page.waitForEvent('popup'),
      page.evaluate(() => {
        const w = window.open('', 'sized', 'width=400,height=300')!;
        w.document.write('<title>Written</title><p>hi</p>');
        w.document.close();
      }),
    ]);
    await expect(popup).toHaveTitle('Written');
    await popup.close();
  });
});
