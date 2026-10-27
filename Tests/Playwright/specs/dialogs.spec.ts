import { test, expect } from '../fixtures';

// alert, confirm, prompt and leaving: Playwright answers them, and Search's
// own sheet goes with the answer.
test.describe('dialogs', () => {
  test('alert, accepted', async ({ page }) => {
    page.once('dialog', dialog => {
      expect(dialog.type()).toBe('alert');
      expect(dialog.message()).toBe('hello');
      dialog.accept();
    });
    await page.evaluate(() => alert('hello'));
  });

  test('confirm, both ways', async ({ page }) => {
    page.once('dialog', dialog => dialog.accept());
    expect(await page.evaluate(() => confirm('sure?'))).toBe(true);
    page.once('dialog', dialog => dialog.dismiss());
    expect(await page.evaluate(() => confirm('sure?'))).toBe(false);
  });

  test('prompt, with an answer', async ({ page }) => {
    page.once('dialog', dialog => {
      expect(dialog.defaultValue()).toBe('given');
      dialog.accept('answered');
    });
    expect(await page.evaluate(() => prompt('name?', 'given'))).toBe('answered');
  });

  test('nobody listening: dismissed, as Playwright does', async ({ page }) => {
    expect(await page.evaluate(() => confirm('nobody?'))).toBe(false);
  });

  test('leaving a page that asks', async ({ page, server }) => {
    await page.goto(server.url('/leave.html'));
    // A page asks only once it has been touched.
    await page.click('#i');
    page.once('dialog', dialog => {
      expect(dialog.type()).toBe('beforeunload');
      dialog.accept();
    });
    const closed = page.waitForEvent('close');
    await page.close({ runBeforeUnload: true });
    await closed;
  });
});
