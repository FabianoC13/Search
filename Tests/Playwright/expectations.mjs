// What passes against Playwright's own Chromium and fails against Search:
// two JSON reports of Playwright's suite (./playwright.sh suite-baseline and
// suite), compared test by test. Written to stdout, for expectations.txt.
//
// Usage: node expectations.mjs baseline.json search.json RELEASE
import fs from 'node:fs';

const [baselineFile, searchFile, release] = process.argv.slice(2);

/// Every test in a report: "project › file:line › titles" to its outcome,
/// and the first line of what went wrong.
function outcomes(file) {
  const report = JSON.parse(fs.readFileSync(file, 'utf8'));
  const found = new Map();
  const walk = (suite, titles) => {
    const here = suite.title && !suite.title.endsWith('.ts') ? [...titles, suite.title] : titles;
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests ?? []) {
        const key = [test.projectName, `${spec.file}:${spec.line}`, ...here, spec.title].filter(Boolean).join(' › ');
        const last = test.results?.[test.results.length - 1];
        const error = (last?.error?.message ?? '').replace(/\u001b\[[0-9;]*m/g, '').split('\n').find(line => line.trim()) ?? '';
        found.set(key, { status: test.status, error: error.trim(), file: spec.file });
      }
    }
    for (const child of suite.suites ?? []) walk(child, here);
  };
  for (const suite of report.suites ?? []) walk(suite, []);
  return found;
}

const baseline = outcomes(baselineFile);
const search = outcomes(searchFile);
const passes = status => status === 'expected' || status === 'flaky';
const failing = [...baseline]
  .filter(([key, result]) => passes(result.status) && search.has(key) && search.get(key).status === 'unexpected')
  .map(([key]) => [key, search.get(key)]);
const ran = [...search.values()].filter(result => result.status !== 'skipped').length;
const passed = [...search.values()].filter(result => passes(result.status)).length;

console.log(`# Playwright ${release}'s own tests: those that pass against Playwright's Chromium`);
console.log('# and fail against Search Beta (./playwright.sh expectations). One a line, with');
console.log('# the first line of its error; the aim is none.');
console.log(`# Search: ${passed} of ${ran} run passed. Failing here and not in the baseline: ${failing.length}.`);
let file = '';
for (const [key, result] of failing.sort(([a], [b]) => a.localeCompare(b))) {
  if (result.file !== file) {
    file = result.file;
    console.log(`\n## ${file}`);
  }
  console.log(`${key}\n    ${result.error}`);
}
