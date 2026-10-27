import { test, expect } from '../fixtures';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Downloads land where Playwright looks; uploads go in without a panel.
test.describe('files', () => {
  test('a download', async ({ page, server }) => {
    await page.goto(server.url('/downloads.html'));
    const [download] = await Promise.all([page.waitForEvent('download'), page.click('#file')]);
    expect(download.suggestedFilename()).toBe('hello.txt');
    const file = await download.path();
    expect(fs.readFileSync(file!, 'utf8')).toBe('Hello from Search');
    const kept = path.join(os.tmpdir(), `search-download-${Date.now()}.txt`);
    await download.saveAs(kept);
    expect(fs.readFileSync(kept, 'utf8')).toBe('Hello from Search');
    fs.rmSync(kept);
  });

  test('setInputFiles, with no panel', async ({ page }) => {
    await page.setContent('<input type="file" id="f">');
    const file = path.join(os.tmpdir(), `search-upload-${Date.now()}.txt`);
    fs.writeFileSync(file, 'upload');
    await page.setInputFiles('#f', file);
    expect(await page.$eval('#f', (e: HTMLInputElement) => e.files![0].name)).toBe(path.basename(file));
    fs.rmSync(file);
  });

  test('the file chooser event', async ({ page }) => {
    await page.setContent('<input type="file" id="f">');
    const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.click('#f')]);
    expect(chooser.isMultiple()).toBe(false);
    await chooser.setFiles({ name: 'a.txt', mimeType: 'text/plain', buffer: Buffer.from('a') });
    expect(await page.$eval('#f', (e: HTMLInputElement) => e.files![0].name)).toBe('a.txt');
  });
});
