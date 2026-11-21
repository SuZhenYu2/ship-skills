import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, beforeEach, describe, it } from 'node:test';

const ROOT = path.resolve(import.meta.dirname, '..');
const DEFAULT_SCRIPT = path.join(ROOT, 'scripts', 'arena-state.sh');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-arena-ts-test-'));

after(() => {
  fs.rmSync(TMP, { recursive: true, force: true });
});

function createRepo(name: string): string {
  const repo = path.join(TMP, `${name}-${Math.random().toString(16).slice(2, 8)}`);
  fs.mkdirSync(repo, { recursive: true });
  execFileSync('git', ['init', '-q', repo], { stdio: 'ignore' });
  return repo;
}

function runState(repo: string, args: string[], ok = true, scriptPath = DEFAULT_SCRIPT): string {
  const result = spawnSync('bash', [scriptPath, '--repo', repo, ...args], {
    encoding: 'utf8',
  });
  const combined = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  assert.equal(result.status === 0, ok, combined);
  return combined;
}

describe('arena-state.ts', () => {
  let repo = '';

  beforeEach((t) => {
    repo = createRepo(t.name.replace(/[^a-zA-Z0-9_-]/g, '_'));
  });

  it('default off without writing', () => {
    assert.match(runState(repo, ['--task', 'order-cancel', 'status']), /OFF/);
    assert.equal(fs.existsSync(path.join(repo, '.ship')), false);
  });

  it('on/off roundtrip and task isolation', () => {
    assert.match(runState(repo, ['--task', 'order-cancel', 'on']), /ON/);
    const statePath = path.join(repo, '.ship', 'tasks', 'order-cancel', 'arena.json');
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    const { generation, ...rest } = state;
    assert.deepEqual(rest, { version: 1, enabled: true, policy: 'selective', candidates: 2 });
    assert.ok(generation);
    assert.match(runState(repo, ['--task', 'other', 'status']), /OFF/);
    assert.match(runState(repo, ['--task', 'order-cancel', 'off']), /OFF/);
    assert.equal(JSON.parse(fs.readFileSync(statePath, 'utf8')).enabled, false);
    const gitStatus = execFileSync('git', ['-C', repo, 'status', '--porcelain'], { encoding: 'utf8' });
    assert.equal(gitStatus, '');
  });

  it('missing or unsafe task rejected', () => {
    runState(repo, ['on'], false);
    for (const task of ['../escape', '/tmp/escape', 'Upper', '.', '']) {
      runState(repo, ['--task', task, 'on'], false);
    }
    assert.equal(fs.existsSync(path.join(repo, '.ship')), false);
  });

  it('invalid config is not silent off', () => {
    runState(repo, ['--task', 'test', 'on']);
    const statePath = path.join(repo, '.ship', 'tasks', 'test', 'arena.json');
    const badContents = [
      '{',
      'null',
      '[]',
      '{"version":1,"enabled":"false","policy":"selective","candidates":2}',
      '{"version":2,"enabled":true,"policy":"selective","candidates":2}',
    ];
    for (const content of badContents) {
      fs.writeFileSync(statePath, content, 'utf8');
      runState(repo, ['--task', 'test', 'status'], false);
      runState(repo, ['--task', 'test', 'on'], false);
      assert.equal(fs.readFileSync(statePath, 'utf8'), content);
    }
  });

  it('stage banner is plan not execution claim', () => {
    runState(repo, ['--task', 'test', 'on']);
    const planOut = runState(repo, ['--task', 'test', 'status', '--stage', 'ship-plan']);
    assert.match(planOut, /ship-plan/);
    assert.match(planOut, /ON/);
    assert.match(planOut, /计划策略/);
    assert.match(planOut, /双候选/);
    const commitOut = runState(repo, ['--task', 'test', 'status', '--stage', 'ship-commit']);
    assert.match(commitOut, /Lead/);
    runState(repo, ['--task', 'test', 'status', '--stage', 'unknown'], false);
  });

  it('symlink escape rejected', () => {
    const outside = path.join(TMP, `outside-${Math.random().toString(16).slice(2, 8)}`);
    fs.mkdirSync(outside, { recursive: true });
    fs.symlinkSync(outside, path.join(repo, '.ship'), 'dir');
    runState(repo, ['--task', 'test', 'on'], false);
    assert.deepEqual(fs.readdirSync(outside), []);
  });

  it('installed script and stage hooks', () => {
    const installed = path.join(TMP, `installed-${Math.random().toString(16).slice(2, 8)}`);
    execFileSync('bash', [path.join(ROOT, 'scripts', 'install.sh'), '--target', 'codex', '--codex-dir', installed], {
      stdio: 'ignore',
    });
    const skills = fs
      .readdirSync(installed)
      .filter((name) => name.startsWith('ship-'))
      .map((name) => path.join(installed, name));
    assert.equal(skills.length, 11);
    for (const skill of skills) {
      const text = fs.readFileSync(path.join(skill, 'SKILL.md'), 'utf8');
      assert.match(text, /references\/arena-policy\.md/);
      assert.match(text, /scripts\/arena-state\.sh/);
      assert.equal(fs.existsSync(path.join(skill, 'references', 'arena-policy.md')), true);
      assert.equal(fs.existsSync(path.join(skill, 'scripts', 'arena-state.ts')), true);
    }
    const installedScript = path.join(installed, 'ship-arena', 'scripts', 'arena-state.sh');
    assert.match(runState(repo, ['--task', 'installed', 'on'], true, installedScript), /ON/);
    assert.match(runState(repo, ['--task', 'other', 'status'], true, installedScript), /OFF/);
  });

  it('old generation rejected after off/on', () => {
    runState(repo, ['--task', 'test', 'on']);
    const statePath = path.join(repo, '.ship', 'tasks', 'test', 'arena.json');
    const generation = JSON.parse(fs.readFileSync(statePath, 'utf8')).generation ?? 'missing';
    runState(repo, ['--task', 'test', 'check', '--generation', generation]);
    runState(repo, ['--task', 'test', 'off']);
    runState(repo, ['--task', 'test', 'check', '--generation', generation], false);
    runState(repo, ['--task', 'test', 'on']);
    runState(repo, ['--task', 'test', 'check', '--generation', generation], false);
    const current = JSON.parse(fs.readFileSync(statePath, 'utf8')).generation;
    assert.notEqual(current, generation);
    runState(repo, ['--task', 'test', 'check', '--generation', current]);
    runState(repo, ['--task', 'test', 'status']);
    assert.equal(JSON.parse(fs.readFileSync(statePath, 'utf8')).generation, current);
  });

  it('legacy enabled config requires explicit reenable', () => {
    const statePath = path.join(repo, '.ship', 'tasks', 'legacy', 'arena.json');
    fs.mkdirSync(path.dirname(statePath), { recursive: true });
    fs.writeFileSync(
      statePath,
      JSON.stringify({ version: 1, enabled: true, policy: 'selective', candidates: 2 }),
      'utf8',
    );
    assert.match(runState(repo, ['--task', 'legacy', 'status']), /未绑定批次/);
    runState(repo, ['--task', 'legacy', 'check', '--generation', 'old'], false);
    runState(repo, ['--task', 'legacy', 'on']);
    assert.ok(JSON.parse(fs.readFileSync(statePath, 'utf8')).generation);
  });

  it('check requires task local generation', () => {
    runState(repo, ['--task', 'test', 'check'], false);
    runState(repo, ['--task', 'test', 'on']);
    const statePath = path.join(repo, '.ship', 'tasks', 'test', 'arena.json');
    const generation = JSON.parse(fs.readFileSync(statePath, 'utf8')).generation ?? 'missing';
    runState(repo, ['--task', 'other', 'on']);
    runState(repo, ['--task', 'other', 'check', '--generation', generation], false);
  });

  it('worktree supported', () => {
    execFileSync(
      'git',
      [
        '-C',
        repo,
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        '-c',
        'commit.gpgsign=false',
        'commit',
        '--allow-empty',
        '-qm',
        'baseline',
      ],
      { stdio: 'ignore' },
    );
    const worktree = path.join(TMP, `wt-${Math.random().toString(16).slice(2, 8)}`);
    execFileSync('git', ['-C', repo, 'worktree', 'add', '-qb', 'test-arena', worktree], {
      stdio: 'ignore',
    });
    assert.match(runState(worktree, ['--task', 'linked', 'on']), /ON/);
    assert.match(runState(worktree, ['--task', 'linked', 'status']), /ON/);
  });

  it('non-git target rejected', () => {
    const other = path.join(TMP, `non-git-${Math.random().toString(16).slice(2, 8)}`);
    fs.mkdirSync(other, { recursive: true });
    runState(other, ['--task', 'test', 'on'], false);
    assert.equal(fs.existsSync(path.join(other, '.ship')), false);
  });
});
