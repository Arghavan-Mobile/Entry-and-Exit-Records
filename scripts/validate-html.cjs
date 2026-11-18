const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const files = ['index.html', 'admin.html'];
let failed = false;

for (const file of files) {
  const html = fs.readFileSync(file, 'utf8');
  const ids = [...html.matchAll(/\\bid="([^"]+)"/g)].map(match => match[1]);
  const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
  const idSet = new Set(ids);
  const refs = [...html.matchAll(/\\$\\('([^']+)'\\)/g)].map(match => match[1]);
  const missing = [...new Set(refs.filter(id => !idSet.has(id)))];

  if (duplicates.length || missing.length) {
    failed = true;
    console.error(file + ': DOM id validation failed');
    if (duplicates.length) console.error('Duplicate IDs: ' + duplicates.join(', '));
    if (missing.length) console.error('Missing IDs: ' + missing.join(', '));
  }

  const scripts = [...html.matchAll(/<script\\b[^>]*>([\\s\\S]*?)<\\/script>/gi)]
    .map(match => match[1])
    .filter(source => source.trim().length > 0);

  scripts.forEach((source, index) => {
    const temp = path.join(os.tmpdir(), 'arghavan-' + path.basename(file) + '-' + index + '.js');
    fs.writeFileSync(temp, source);
    const result = spawnSync(process.execPath, ['--check', temp], { stdio: 'inherit' });
    fs.rmSync(temp, { force: true });
    if (result.status !== 0) {
      failed = true;
      console.error(file + ': inline script ' + (index + 1) + ' has a syntax error');
    }
  });

  console.log(file + ': ' + scripts.length + ' inline script(s), ' + ids.length + ' DOM IDs checked');
}

if (failed) process.exit(1);
console.log('Static HTML and inline JavaScript validation passed.');
