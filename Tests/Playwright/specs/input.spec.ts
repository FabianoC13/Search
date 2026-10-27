import { test, expect } from '../fixtures';

// Buttons, the keyboard, the pointer: the page sees what it would in Chrome.
test.describe('input', () => {
  test('click a button', async ({ page }) => {
    await page.setContent('<button onclick="this.textContent = \'clicked\'">press</button>');
    await page.click('button');
    await expect(page.locator('button')).toHaveText('clicked');
  });

  test('double click and right click reach the page', async ({ page }) => {
    await page.setContent(`<div id="d" style="width:200px;height:100px">x</div><script>
      const d = document.getElementById('d'); window.seen = [];
      d.addEventListener('dblclick', () => seen.push('dblclick'));
      d.addEventListener('contextmenu', e => { seen.push('contextmenu'); });
    </script>`);
    await page.dblclick('#d');
    await page.click('#d', { button: 'right' });
    expect(await page.evaluate(() => (window as any).seen)).toEqual(['dblclick', 'contextmenu']);
  });

  test('fill and type', async ({ page }) => {
    await page.setContent('<input id="i"><textarea id="t"></textarea>');
    await page.fill('#i', 'hello');
    await page.locator('#t').pressSequentially('typed');
    expect(await page.inputValue('#i')).toBe('hello');
    expect(await page.inputValue('#t')).toBe('typed');
  });

  test('keyboard shortcuts go to the page, not to Search', async ({ page }) => {
    await page.setContent(`<input id="i" value="select me"><script>
      window.keys = []; addEventListener('keydown', e => {
        if (!['Meta', 'Control', 'Shift', 'Alt'].includes(e.key)) keys.push((e.metaKey ? 'Meta+' : '') + e.key);
      });
    </script>`);
    await page.focus('#i');
    // ⌘A selects the field's text; ⌘W and ⌘T would close or open Search's tabs.
    await page.keyboard.press('ControlOrMeta+a');
    await page.keyboard.press('Meta+w');
    await page.keyboard.press('Meta+t');
    const select = process.platform === 'darwin' ? 'Meta+a' : 'a';
    expect(await page.evaluate(() => (window as any).keys)).toEqual([select, 'Meta+w', 'Meta+t']);
    expect(await page.evaluate(() => {
      const input = document.getElementById('i') as HTMLInputElement;
      return input.selectionEnd! - input.selectionStart!;
    })).toBe('select me'.length);
    expect(page.isClosed()).toBe(false);
  });

  test('hover', async ({ page }) => {
    await page.setContent('<style>#h:hover { color: rgb(255, 0, 0) }</style><a id="h" href="#">over</a>');
    await page.hover('#h');
    expect(await page.$eval('#h', e => getComputedStyle(e).color)).toBe('rgb(255, 0, 0)');
  });

  test('drag and drop', async ({ page }) => {
    await page.setContent(`
      <div id="from" draggable="true" style="width:80px;height:80px;background:#ccc">drag</div>
      <div id="to" style="width:120px;height:120px;margin-top:40px;background:#eee">drop</div>
      <script>
        const to = document.getElementById('to');
        to.addEventListener('dragover', e => e.preventDefault());
        to.addEventListener('drop', e => { e.preventDefault(); to.textContent = 'dropped'; });
      </script>`);
    await page.dragAndDrop('#from', '#to');
    await expect(page.locator('#to')).toHaveText('dropped');
  });

  test('a select is set without a menu left on the screen', async ({ page }) => {
    await page.setContent('<select id="s"><option>one</option><option>two</option></select>');
    await page.click('#s');
    await page.selectOption('#s', 'two');
    expect(await page.inputValue('#s')).toBe('two');
    // And the page still takes input: no menu is holding the keyboard.
    await page.keyboard.press('Escape');
    await page.setContent('<button onclick="this.textContent = \'ok\'">b</button>');
    await page.click('button');
    await expect(page.locator('button')).toHaveText('ok');
  });
});
