// Shows that a recursive file watcher on a superproject reports files that a submodule's own
// .gitignore ignores, such as build output, even though git sees the submodule as clean.
// A Git client that filters watcher events only with the superproject's root .gitignore would
// therefore refresh on every build step inside a submodule.
//
// Usage: node repro-ignored-build-events.js <superproject> [submodule-path=subs/sub05]
// Run `npm install` first (it installs nsfw and ignore).
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ignore = require('ignore');
const nsfw = require('nsfw');

const [superPath, submodulePath = 'subs/sub05'] = process.argv.slice(2);
if (!superPath) {
  console.error('Usage: node repro-ignored-build-events.js <superproject> [submodule-path]');
  process.exit(1);
}

const WATCH_DEBOUNCE_MS = 2000;
const WRITE_FOR_MS = 12000;
const WRITE_EVERY_MS = 250;

const git = (cwd, args) => execFileSync('git', args, { cwd }).toString().trim();
const submodule = path.join(superPath, submodulePath);

// Give the submodule a committed .gitignore with build/ in it, once.
if (git(submodule, ['log', '-1', '--format=%s']) !== 'Ignore build output') {
  fs.writeFileSync(path.join(submodule, '.gitignore'), 'build/\n');
  git(submodule, ['add', '.gitignore']);
  git(submodule, ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'Ignore build output']);
  git(superPath, ['add', submodulePath]);
  git(superPath, ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', `Bump ${submodulePath}`]);
}

const readIgnoreFilter = (folder) => {
  const rules = ignore();
  try {
    rules.add(fs.readFileSync(path.join(folder, '.gitignore'), 'utf8'));
  } catch {
    // No .gitignore: nothing is ignored.
  }
  return rules;
};

const parentRules = readIgnoreFilter(superPath);
const submoduleRules = readIgnoreFilter(submodule);
const submodulePrefix = `${submodulePath.split(path.sep).join('/')}/`;
const toPosix = (value) => value.split(path.sep).join('/');
const isDotGit = (relativePath) => relativePath === '.git' || relativePath.startsWith('.git/');
// The watcher also reports a folder by its bare path, without a trailing slash, and a pattern
// such as `build/` only matches a path that ends in one.
const isIgnored = (rules, relativePath) => rules.ignores(relativePath) || rules.ignores(`${relativePath}/`);

let batches = 0;
let keptByParentRulesOnly = 0;
let keptWithSubmoduleRules = 0;

(async () => {
  const watcher = await nsfw(superPath, (events) => {
    batches += 1;
    const relativePaths = events
      .map((event) => toPosix(path.relative(superPath, path.join(event.directory, event.file ?? event.newFile))))
      .filter((relativePath) => !isDotGit(relativePath));

    const parentOnly = relativePaths.filter((relativePath) => !isIgnored(parentRules, relativePath));
    const withSubmodule = parentOnly.filter((relativePath) =>
      !(relativePath.startsWith(submodulePrefix) &&
        isIgnored(submoduleRules, relativePath.slice(submodulePrefix.length)))
    );
    if (parentOnly.length > 0) {
      keptByParentRulesOnly += 1;
    }
    if (withSubmodule.length > 0) {
      keptWithSubmoduleRules += 1;
    }
  }, { debounceMS: WATCH_DEBOUNCE_MS });
  await watcher.start();

  const buildDir = path.join(submodule, 'build');
  fs.mkdirSync(buildDir, { recursive: true });
  const start = Date.now();
  let written = 0;
  while (Date.now() - start < WRITE_FOR_MS) {
    fs.writeFileSync(path.join(buildDir, `out${written % 20}.o`), `object ${written}\n`);
    written += 1;
    await new Promise((resolve) => setTimeout(resolve, WRITE_EVERY_MS));
  }
  await new Promise((resolve) => setTimeout(resolve, WATCH_DEBOUNCE_MS + 1000));

  console.log(`Files written into ${submodulePath}/build: ${written}`);
  console.log(`git sees ${submodulePath} as clean: ${git(submodule, ['status', '--porcelain']) === ''}`);
  console.log(`Watcher event batches: ${batches}`);
  console.log(`Batches with a change, filtering with the superproject's .gitignore only: ${keptByParentRulesOnly}`);
  console.log(`Batches with a change, also applying the submodule's own .gitignore: ${keptWithSubmoduleRules}`);
  // Stopping nsfw can hang on Windows, so exit once the counts are printed.
  process.exit(0);
})();
