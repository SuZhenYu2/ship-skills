import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, beforeEach, describe, it } from 'node:test';

const ROOT = path.resolve(import.meta.dirname, '..');
const SCRIPT = path.join(ROOT, 'scripts', 'loop-state.sh');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-loop-ts-test-'));

after(() => {
  fs.rmSync(TMP, { recursive: true, force: true });
});

function createRepo(name: string): string {
  const repo = path.join(TMP, `${name}-${Math.random().toString(16).slice(2, 8)}`);
  fs.mkdirSync(repo, { recursive: true });
  execFileSync('git', ['init', '-q', repo], { stdio: 'ignore' });
  return repo;
}

function runLoop(repo: string, args: string[], expectedCode = 0): string {
  const result = spawnSync('bash', [SCRIPT, '--repo', repo, ...args], {
    encoding: 'utf8',
  });
  const combined = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  assert.equal(result.status, expectedCode, combined);
  return combined;
}

describe('loop-state.ts', () => {
  let repo = '';

  beforeEach((t) => {
    repo = createRepo(t.name.replace(/[^a-zA-Z0-9_-]/g, '_'));
  });

  it('uninitialized status does not write files', () => {
    const out = runLoop(repo, ['--task', 'order-cancel', 'status', '--stage', 'ship-auto']);
    assert.match(out, /UNINITIALIZED/);
    assert.match(out, /\[ship-auto\]/);
    assert.equal(fs.existsSync(path.join(repo, '.ship')), false);
  });

  it('init status and task isolation keep git working tree clean', () => {
    const out = runLoop(repo, ['--task', 'order-cancel', 'init', '--level', 'L2', '--mode', 'builder-critic']);
    assert.match(out, /ACTIVE/);
    assert.match(out, /L2/);
    assert.match(out, /builder-critic/);
    assert.match(out, /0\/2/);

    const statePath = path.join(repo, '.ship', 'tasks', 'order-cancel', 'loop.json');
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.equal(state.version, 1);
    assert.equal(state.task, 'order-cancel');
    assert.equal(state.level, 'L2');
    assert.equal(state.mode, 'builder-critic');
    assert.equal(state.status, 'ACTIVE');
    assert.equal(state.round, 0);
    assert.equal(state.max_rounds, 2);
    assert.equal(state.cycle.length, 32);

    const otherOut = runLoop(repo, ['--task', 'other-task', 'status']);
    assert.match(otherOut, /UNINITIALIZED/);

    const gitStatus = execFileSync('git', ['-C', repo, 'status', '--porcelain'], {
      encoding: 'utf8',
    });
    assert.equal(gitStatus, '');
  });

  it('init rejects duplicate and unsafe task names', () => {
    runLoop(repo, ['--task', 'dup-task', 'init', '--level', 'L1', '--mode', 'single']);
    runLoop(repo, ['--task', 'dup-task', 'init', '--level', 'L1', '--mode', 'single'], 1);
    for (const badTask of ['../escape', '/tmp/escape', 'Upper', '.', '', '-leading', 'trailing-']) {
      runLoop(repo, ['--task', badTask, 'init', '--level', 'L1', '--mode', 'single'], 1);
    }
  });

  it('invalid config hard fails without overwriting', () => {
    runLoop(repo, ['--task', 'corrupt', 'init', '--level', 'L2', '--mode', 'builder-critic']);
    const statePath = path.join(repo, '.ship', 'tasks', 'corrupt', 'loop.json');
    const badPayloads = [
      '{',
      'null',
      '[]',
      JSON.stringify({ version: 2, task: 'corrupt' }),
      JSON.stringify({
        version: 1,
        task: 'wrong-task',
        cycle: 'a'.repeat(32),
        level: 'L2',
        mode: 'builder-critic',
        status: 'ACTIVE',
        round: 0,
        max_rounds: 2,
        stall_count: 0,
        last_error_hash: '',
        history: [],
      }),
    ];
    for (const content of badPayloads) {
      fs.writeFileSync(statePath, content, 'utf8');
      runLoop(repo, ['--task', 'corrupt', 'status'], 1);
      runLoop(repo, ['--task', 'corrupt', 'record', '--stage', 'ship-verify', '--outcome', 'pass'], 1);
      assert.equal(fs.readFileSync(statePath, 'utf8'), content);
    }
  });

  it('symlink escape is rejected', () => {
    const outside = path.join(TMP, `outside-${Math.random().toString(16).slice(2, 8)}`);
    fs.mkdirSync(outside, { recursive: true });
    fs.symlinkSync(outside, path.join(repo, '.ship'), 'dir');
    runLoop(repo, ['--task', 'sym', 'init', '--level', 'L1', '--mode', 'single'], 1);
    assert.deepEqual(fs.readdirSync(outside), []);
  });

  it('non-git target is rejected', () => {
    const other = path.join(TMP, `non-git-${Math.random().toString(16).slice(2, 8)}`);
    fs.mkdirSync(other, { recursive: true });
    runLoop(other, ['--task', 'test', 'init', '--level', 'L1', '--mode', 'single'], 1);
    assert.equal(fs.existsSync(path.join(other, '.ship')), false);
  });

  it('linked worktree is supported', () => {
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
    execFileSync('git', ['-C', repo, 'worktree', 'add', '-qb', 'test-loop', worktree], {
      stdio: 'ignore',
    });
    assert.match(runLoop(worktree, ['--task', 'linked', 'init', '--level', 'L2', '--mode', 'builder-critic']), /ACTIVE/);
    assert.match(runLoop(worktree, ['--task', 'linked', 'status']), /ACTIVE/);
  });

  it('record pass converges and blocks further record or escalate', () => {
    runLoop(repo, ['--task', 'ok-task', 'init', '--level', 'L1', '--mode', 'single', '--max-rounds', '2']);
    const out = runLoop(repo, [
      '--task',
      'ok-task',
      'record',
      '--stage',
      'ship-verify',
      '--outcome',
      'pass',
      '--evidence',
      '.ship/verify/ok-task.md',
    ]);
    assert.match(out, /CONVERGED/);
    assert.match(out, /1\/2/);
    runLoop(repo, ['--task', 'ok-task', 'record', '--stage', 'ship-verify', '--outcome', 'pass'], 1);
    runLoop(repo, ['--task', 'ok-task', 'escalate', '--target', 'user', '--reason', 'noop'], 1);
  });

  it('record trips on max rounds with exit code 2', () => {
    runLoop(repo, ['--task', 'max-trip', 'init', '--level', 'L2', '--mode', 'builder-critic', '--max-rounds', '2']);
    const out1 = runLoop(repo, [
      '--task',
      'max-trip',
      'record',
      '--stage',
      'ship-verify',
      '--outcome',
      'fail',
      '--error-sig',
      'Error A on line 10',
    ]);
    assert.match(out1, /ACTIVE/);
    assert.match(out1, /1\/2/);

    const out2 = runLoop(
      repo,
      [
        '--task',
        'max-trip',
        'record',
        '--stage',
        'ship-review',
        '--outcome',
        'blocked',
        '--error-sig',
        'Error B on line 42',
      ],
      2,
    );
    assert.match(out2, /TRIPPED/);
    assert.match(out2, /2\/2/);
    runLoop(repo, ['--task', 'max-trip', 'record', '--stage', 'ship-verify', '--outcome', 'pass'], 1);
  });

  it('record trips early on same normalized error stall', () => {
    runLoop(repo, ['--task', 'stall-trip', 'init', '--level', 'L3', '--mode', 'multi-agent', '--max-rounds', '4']);
    runLoop(repo, [
      '--task',
      'stall-trip',
      'record',
      '--stage',
      'ship-verify',
      '--outcome',
      'fail',
      '--error-sig',
      'AssertionError:   timeout   expected CANCELLED',
    ]);
    const out = runLoop(
      repo,
      [
        '--task',
        'stall-trip',
        'record',
        '--stage',
        'ship-verify',
        '--outcome',
        'fail',
        '--error-sig',
        '  AssertionError: timeout expected CANCELLED  ',
      ],
      2,
    );
    assert.match(out, /TRIPPED/);
    assert.match(out, /2\/4/);
    assert.match(out, /停滞硬熔断/);
  });

  it('escalate and reset cycle lifecycle', () => {
    runLoop(repo, ['--task', 'life', 'init', '--level', 'L2', '--mode', 'builder-critic', '--max-rounds', '1']);
    const statePath = path.join(repo, '.ship', 'tasks', 'life', 'loop.json');
    const oldCycle = JSON.parse(fs.readFileSync(statePath, 'utf8')).cycle;

    runLoop(repo, ['--task', 'life', 'record', '--stage', 'ship-verify', '--outcome', 'fail', '--error-sig', 'boom'], 2);
    const escOut = runLoop(repo, ['--task', 'life', 'escalate', '--target', 'ship-plan', '--reason', '需要重审并发锁契约']);
    assert.match(escOut, /ESCALATED/);
    assert.match(escOut, /ship-plan/);

    runLoop(repo, ['--task', 'life', 'record', '--stage', 'ship-verify', '--outcome', 'pass'], 1);
    const resetOut = runLoop(repo, ['--task', 'life', 'reset', '--level', 'L3', '--mode', 'multi-agent', '--max-rounds', '2']);
    assert.match(resetOut, /ACTIVE/);
    assert.match(resetOut, /L3/);
    assert.match(resetOut, /0\/2/);
    const newState = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.notEqual(newState.cycle, oldCycle);
    assert.deepEqual(newState.history, []);
  });

  it('cross-action arguments are rejected', () => {
    runLoop(repo, ['--task', 'argcheck', 'status', '--level', 'L1'], 1);
    runLoop(repo, ['--task', 'argcheck', 'init', '--level', 'L1', '--mode', 'single', '--outcome', 'pass'], 1);
    runLoop(repo, ['--task', 'argcheck', 'init', '--level', 'L1', '--mode', 'single', '--max-rounds', '9'], 1);
    runLoop(repo, ['--task', 'argcheck', 'init', '--level', 'L1', '--mode', 'single']);
    runLoop(repo, ['--task', 'argcheck', 'record', '--stage', 'unknown', '--outcome', 'pass'], 1);
    runLoop(repo, ['--task', 'argcheck', 'escalate', '--target', ' ', '--reason', 'empty target'], 1);
  });
});
