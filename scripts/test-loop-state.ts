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
  return fs.realpathSync(repo);
}

function runLoop(repo: string, args: string[], expectedCode = 0): string {
  const result = spawnSync('bash', [SCRIPT, '--repo', repo, ...args], {
    encoding: 'utf8',
  });
  const combined = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  assert.equal(result.status, expectedCode, combined);
  return combined;
}

function statePath(repo: string, task: string): string {
  return path.join(repo, '.ship', 'tasks', task, 'loop.json');
}

function readState(repo: string, task: string) {
  return JSON.parse(fs.readFileSync(statePath(repo, task), 'utf8'));
}

function recordTokens(repo: string, task: string): string[] {
  const state = readState(repo, task);
  return ['--cycle', state.cycle, '--round', String(state.round + 1)];
}

function failureEvidence(repo: string, task: string): string[] {
  const relative = `.ship/tasks/${task}/failure.log`;
  fs.writeFileSync(path.join(repo, relative), 'Assertion failed: expected task result\n');
  return ['--evidence', relative];
}

function passArgs(repo: string, task: string, slug: string): string[] {
  return ['--task', task, 'record', ...recordTokens(repo, task),
    '--stage', 'ship-review', '--outcome', 'pass', '--slug', slug];
}

function rejectLoop(repo: string, task: string, args: string[], message?: RegExp): void {
  const stateFile = statePath(repo, task);
  const before = fs.existsSync(stateFile) ? fs.readFileSync(stateFile) : null;
  const exclude = path.join(repo, '.git/info/exclude');
  const excludeBefore = fs.readFileSync(exclude);
  const output = runLoop(repo, args, 1);
  if (message) assert.match(output, message);
  assert.deepEqual(fs.existsSync(stateFile) ? fs.readFileSync(stateFile) : null, before);
  assert.deepEqual(fs.readFileSync(exclude), excludeBefore);
}

function handoffFixture(repo: string, task: string, slug = task): { tree: string; records: string[] } {
  fs.writeFileSync(path.join(repo, 'implementation.txt'), 'task implementation\n');
  // Only test fixtures are staged. No commit or signing configuration is needed.
  execFileSync('git', ['-C', repo, 'add', '--', 'implementation.txt']);
  const tree = execFileSync('git', ['-C', repo, 'write-tree'], { encoding: 'utf8' }).trim();
  const loop = fs.existsSync(statePath(repo, task)) ? readState(repo, task) : null;
  const records = ['verify', 'review'].map((kind, index) => {
    const relative = `.ship/${kind}/${slug}.md`;
    fs.mkdirSync(path.dirname(path.join(repo, relative)), { recursive: true });
    fs.writeFileSync(path.join(repo, relative), [
      `> Status: ${index === 0 ? 'PASS' : 'READY'}`,
      '> Date: 2026-01-01 12:00',
      `> Tree: ${tree}`,
      '> Commit: pending',
      `> Slug: ${slug}`,
      `> Task: ${task}`,
      `> Cycle: ${loop?.cycle ?? 'none'}`,
      `> Round: ${loop ? loop.round + 1 : 'none'}`,
      '> Scope: task-final fixture; metadata does not attest command execution',
      '',
    ].join('\n'));
    return relative;
  });
  return { tree, records };
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
    assert.doesNotMatch(out, /mode-contract/);
    assert.equal(fs.existsSync(path.join(repo, '.ship')), false);
  });

  it('status echoes the execution contract for each mode', () => {
    const contracts = [
      ['single', /不派发子 Agent/],
      ['builder-critic', /全新上下文.*判别性测试/],
      ['multi-agent', /Verifier.*Auditor/],
    ] as const;
    for (const [mode, contract] of contracts) {
      const task = `contract-${mode}`;
      runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', mode]);
      const out = runLoop(repo, ['--task', task, 'status', '--stage', 'ship-verify']);
      assert.match(out, new RegExp(`mode-contract: ${mode}`));
      assert.match(out, contract);
    }
  });

  it('AC5 keeps the existing tasks rule and user entries when migrating on write', () => {
    const exclude = path.join(repo, '.git/info/exclude');
    const userRules = '# /.ship/\r\n/.ship/tasks/\r\n/.ship/private/';
    fs.writeFileSync(exclude, `/.ship/\r\n${userRules}`);
    runLoop(repo, ['--task', 'x', 'status']);
    assert.equal(fs.readFileSync(exclude, 'utf8'), `/.ship/\r\n${userRules}`);
    runLoop(repo, ['--task', 'x', 'init', '--level', 'L1', '--mode', 'single']);
    assert.equal(fs.readFileSync(exclude, 'utf8'), userRules);
    assert.equal(spawnSync('git', ['-C', repo, 'check-ignore', '-q', '.ship/specs/x.md']).status, 1);
    assert.equal(spawnSync('git', ['-C', repo, 'check-ignore', '-q', '.ship/tasks/x/loop.json']).status, 0);
  });

  it('AC5 appends only tasks after an unterminated user entry', () => {
    const exclude = path.join(repo, '.git/info/exclude');
    fs.writeFileSync(exclude, 'mine');
    runLoop(repo, ['--task', 'x', 'init', '--level', 'L1', '--mode', 'single']);
    assert.equal(fs.readFileSync(exclude, 'utf8'), 'mine\n/.ship/tasks/\n');
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
      runLoop(repo, ['--task', 'corrupt', 'record', '--stage', 'ship-review', '--outcome', 'pass',
        '--slug', 'corrupt', '--cycle', 'a'.repeat(32), '--round', '1'], 1);
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

  it('record pass checks real handoff evidence and converges only the selected task', () => {
    runLoop(repo, ['--task', 'ok-task', 'init', '--level', 'L1', '--mode', 'single', '--max-rounds', '2']);
    runLoop(repo, ['--task', 'other-task', 'init', '--level', 'L2', '--mode', 'builder-critic']);
    const otherBefore = fs.readFileSync(statePath(repo, 'other-task'));
    const { tree, records } = handoffFixture(repo, 'ok-task', 'release-candidate');
    const indexBefore = execFileSync('git', ['-C', repo, 'ls-files', '--stage']);
    const out = runLoop(repo, passArgs(repo, 'ok-task', 'release-candidate'));
    assert.match(out, /CONVERGED/);
    assert.match(out, /1\/2/);
    const state = readState(repo, 'ok-task');
    assert.equal(state.status, 'CONVERGED');
    assert.equal(state.stall_count, 0);
    assert.equal(state.last_error_hash, '');
    assert.deepEqual(state.history, [{
      round: 1, stage: 'ship-review', outcome: 'pass', error_hash: '',
      evidence: records.join('; '), slug: 'release-candidate', tree,
    }]);
    assert.deepEqual(fs.readFileSync(statePath(repo, 'other-task')), otherBefore);
    assert.deepEqual(execFileSync('git', ['-C', repo, 'ls-files', '--stage']), indexBefore);
    assert.notEqual(spawnSync('git', ['-C', repo, 'rev-parse', '--verify', 'HEAD']).status, 0);
    rejectLoop(repo, 'ok-task', passArgs(repo, 'ok-task', 'release-candidate'), /CONVERGED/);
    rejectLoop(repo, 'ok-task', ['--task', 'ok-task', 'escalate', '--target', 'user', '--reason', 'noop']);
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
      ...recordTokens(repo, 'max-trip'),
      ...failureEvidence(repo, 'max-trip'),
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
        ...recordTokens(repo, 'max-trip'),
        ...failureEvidence(repo, 'max-trip'),
      ],
      2,
    );
    assert.match(out2, /TRIPPED/);
    assert.match(out2, /2\/2/);
    assert.deepEqual(readState(repo, 'max-trip').history.map((entry: { outcome: string }) => entry.outcome), ['fail', 'blocked']);
    assert.equal(readState(repo, 'max-trip').history[0].evidence, path.join(repo, '.ship/tasks/max-trip/failure.log'));
    rejectLoop(repo, 'max-trip', passArgs(repo, 'max-trip', 'max-trip'), /TRIPPED/);
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
      ...recordTokens(repo, 'stall-trip'),
      ...failureEvidence(repo, 'stall-trip'),
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
        ...recordTokens(repo, 'stall-trip'),
        ...failureEvidence(repo, 'stall-trip'),
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

    runLoop(repo, ['--task', 'life', 'record', '--stage', 'ship-verify', '--outcome', 'fail', '--error-sig', 'boom',
      ...recordTokens(repo, 'life'), ...failureEvidence(repo, 'life')], 2);
    const escOut = runLoop(repo, ['--task', 'life', 'escalate', '--target', 'ship-plan', '--reason', '需要重审并发锁契约']);
    assert.match(escOut, /ESCALATED/);
    assert.match(escOut, /ship-plan/);

    rejectLoop(repo, 'life', passArgs(repo, 'life', 'life'), /ESCALATED/);
    const resetOut = runLoop(repo, ['--task', 'life', 'reset', '--level', 'L3', '--mode', 'multi-agent', '--max-rounds', '2']);
    assert.match(resetOut, /ACTIVE/);
    assert.match(resetOut, /L3/);
    assert.match(resetOut, /0\/2/);
    const newState = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.notEqual(newState.cycle, oldCycle);
    assert.deepEqual(newState.history, []);
  });

  it('direct reset cannot bypass escalation after a trip', () => {
    const task = 'tripped-reset';
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic', '--max-rounds', '1']);
    runLoop(repo, ['--task', task, 'record', '--stage', 'ship-verify', '--outcome', 'fail', '--error-sig', 'boom',
      ...recordTokens(repo, task), ...failureEvidence(repo, task)], 2);
    rejectLoop(repo, task, ['--task', task, 'reset', '--level', 'L3', '--mode', 'multi-agent'], /TRIPPED.*escalate/);
  });

  it('commit gate blocks active, tripped and escalated attempts despite matching records', () => {
    const task = 'gate-blocked';
    const gate = ['--task', task, 'gate', '--slug', task];
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic', '--max-rounds', '1']);
    handoffFixture(repo, task);
    rejectLoop(repo, task, gate, /ACTIVE/);
    rejectLoop(repo, task, [...gate, '--no-loop', '--allow-legacy'], /已启用/);
    runLoop(repo, ['--task', task, 'record', '--stage', 'ship-verify', '--outcome', 'fail', '--error-sig', 'boom',
      ...recordTokens(repo, task), ...failureEvidence(repo, task)], 2);
    rejectLoop(repo, task, gate, /TRIPPED/);
    runLoop(repo, ['--task', task, 'escalate', '--target', 'user', '--reason', 'needs decision']);
    rejectLoop(repo, task, gate, /ESCALATED/);
  });

  it('commit gate requires an explicit no-loop decision for an uninitialized task', () => {
    const task = 'uninitialized-gate';
    const gate = ['--task', task, 'gate', '--slug', task];
    handoffFixture(repo, task);
    rejectLoop(repo, task, gate, /UNINITIALIZED/);
    assert.match(runLoop(repo, [...gate, '--no-loop']), /PASS gate/);
    assert.equal(fs.existsSync(statePath(repo, task)), false);
  });

  it('commit gate rejects Loop evidence after local state is lost', () => {
    const task = 'lost-state';
    const gate = ['--task', task, 'gate', '--slug', task];
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic']);
    handoffFixture(repo, task);
    runLoop(repo, passArgs(repo, task, task));
    fs.unlinkSync(statePath(repo, task));
    rejectLoop(repo, task, gate, /UNINITIALIZED/);
    rejectLoop(repo, task, [...gate, '--no-loop', '--allow-legacy'], /BLOCKED:.*Cycle/);
  });

  it('commit gate only accepts the slug and tree actually recorded as converged', () => {
    const task = 'gate-ready';
    const gate = ['--task', task, 'gate', '--slug', task];
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic']);
    const { tree, records } = handoffFixture(repo, task);
    runLoop(repo, passArgs(repo, task, task));
    const stateBefore = fs.readFileSync(statePath(repo, task));
    assert.match(runLoop(repo, gate), new RegExp(`PASS gate .*tree=${tree}`));
    assert.deepEqual(fs.readFileSync(statePath(repo, task)), stateBefore);
    rejectLoop(repo, task, ['--task', task, 'gate', '--slug', 'different-slug'], /slug/);

    fs.writeFileSync(path.join(repo, 'implementation.txt'), 'updated task implementation\n');
    execFileSync('git', ['-C', repo, 'add', '--', 'implementation.txt']);
    const changedTree = execFileSync('git', ['-C', repo, 'write-tree'], { encoding: 'utf8' }).trim();
    for (const relative of records) {
      const record = path.join(repo, relative);
      fs.writeFileSync(record, fs.readFileSync(record, 'utf8').replace(tree, changedTree));
    }
    rejectLoop(repo, task, gate, /收敛.*Tree/);
  });

  it('commit gate fails when the staged tree changes after convergence', () => {
    const task = 'gate-drift';
    const gate = ['--task', task, 'gate', '--slug', task];
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic']);
    const { tree } = handoffFixture(repo, task);
    runLoop(repo, passArgs(repo, task, task));
    assert.match(runLoop(repo, gate), new RegExp(`PASS gate .*tree=${tree}`));
    fs.writeFileSync(path.join(repo, 'extra.txt'), 'staged after gate\n');
    execFileSync('git', ['-C', repo, 'add', '--', 'extra.txt']);
    rejectLoop(repo, task, gate, /Tree/);
  });

  it('contradictory loop state is rejected before status or gate trusts it', () => {
    const task = 'bad-state';
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic', '--max-rounds', '2']);
    const base = readState(repo, task);
    const entry = (round: number, outcome: string) => ({
      round, stage: 'ship-review', outcome, error_hash: '', evidence: 'e.md', slug: task, tree: 'a'.repeat(40),
    });
    const cases = [
      { ...base, status: 'CONVERGED', round: 2, max_rounds: 1, history: [entry(2, 'pass')] },
      { ...base, status: 'CONVERGED', round: 2, max_rounds: 2, history: [entry(1, 'pass'), entry(2, 'fail')] },
      { ...base, status: 'ACTIVE', round: 1, history: [entry(1, 'pass')] },
    ];
    for (const contradictory of cases) {
      fs.writeFileSync(statePath(repo, task), JSON.stringify(contradictory), 'utf8');
      runLoop(repo, ['--task', task, 'status'], 1);
      runLoop(repo, ['--task', task, 'gate', '--slug', task], 1);
    }
  });

  it('uninitialized mutations are rejected without creating state or changing excludes', () => {
    const task = 'uninitialized';
    const tokens = ['--cycle', 'a'.repeat(32), '--round', '1'];
    const actions = [
      ['record', '--stage', 'ship-review', '--outcome', 'pass', '--slug', task, ...tokens],
      ...['fail', 'blocked'].map((outcome) => ['record', '--stage', 'ship-verify', '--outcome', outcome,
        '--error-sig', 'failure', '--evidence', 'missing.log', ...tokens]),
      ['escalate', '--target', 'user', '--reason', 'needs decision'],
      ['reset', '--level', 'L1', '--mode', 'single'],
    ];
    for (const args of actions) {
      rejectLoop(repo, task, ['--task', task, ...args], /尚未初始化/);
      assert.equal(fs.existsSync(path.join(repo, '.ship')), false);
    }
  });

  it('pass requires a safe slug and rejects failure-only arguments', () => {
    const task = 'pass-args';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    handoffFixture(repo, task);
    const base = passArgs(repo, task, task).slice(0, -2);
    for (const extra of [[], ['--slug', ''], ['--slug', '../escape'], ['--slug', 'white space'],
      ['--slug', task, '--error-sig', 'failure'], ['--slug', task, '--evidence', 'arbitrary.log']]) {
      rejectLoop(repo, task, [...base, ...extra]);
    }
  });

  it('verify PASS only continues review and no other stage can converge the task', () => {
    const task = 'review-only';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    handoffFixture(repo, task);
    for (const stage of ['ship-arena', 'ship-auto', 'ship-grill', 'ship-spec', 'ship-plan',
      'ship-tdd', 'ship-fix', 'ship-verify', 'ship-commit', 'ship-finish']) {
      rejectLoop(repo, task, passArgs(repo, task, task).map((arg) => arg === 'ship-review' ? stage : arg),
        /仅 ship-review.*ship-verify PASS 应继续 ship-review/);
    }
    assert.equal(readState(repo, task).round, 0);
    runLoop(repo, passArgs(repo, task, task));
    assert.equal(readState(repo, task).status, 'CONVERGED');
  });

  for (const kind of ['verify', 'review']) {
    for (const invalid of ['missing', 'empty', 'FAIL', 'PARTIAL', 'BLOCKED', 'INCOMPLETE', 'stale tree']) {
      it(`pass rejects ${kind} evidence with ${invalid}`, () => {
        const task = 'bad-evidence';
        runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
        const { tree } = handoffFixture(repo, task);
        const record = path.join(repo, `.ship/${kind}/${task}.md`);
        if (invalid === 'missing') {
          fs.unlinkSync(record);
        } else if (invalid === 'empty') {
          fs.writeFileSync(record, '');
        } else {
          const original = fs.readFileSync(record, 'utf8');
          fs.writeFileSync(record, invalid === 'stale tree'
            ? original.replace(tree, '0'.repeat(tree.length))
            : original.replace(/> Status: \w+/, `> Status: ${invalid}`));
        }
        // A rejected record must not even migrate legacy local exclude entries.
        fs.writeFileSync(path.join(repo, '.git/info/exclude'), '/.ship/\n');
        const indexBefore = execFileSync('git', ['-C', repo, 'ls-files', '--stage']);
        rejectLoop(repo, task, passArgs(repo, task, task), /BLOCKED:/);
        assert.deepEqual(execFileSync('git', ['-C', repo, 'ls-files', '--stage']), indexBefore);
      });
    }
  }

  for (const dirty of ['unstaged', 'untracked']) {
    it(`pass rejects a ${dirty} dirty tree`, () => {
      const task = 'dirty';
      runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
      handoffFixture(repo, task);
      fs.writeFileSync(path.join(repo, dirty === 'unstaged' ? 'implementation.txt' : 'untracked.txt'), 'new code\n');
      rejectLoop(repo, task, passArgs(repo, task, task), /BLOCKED:.*不干净/);
    });
  }

  it('pass rejects a newly staged tree against stale records without staging evidence', () => {
    const task = 'changed-index';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    handoffFixture(repo, task);
    fs.writeFileSync(path.join(repo, 'implementation.txt'), 'changed staged code\n');
    execFileSync('git', ['-C', repo, 'add', '--', 'implementation.txt']);
    const indexBefore = execFileSync('git', ['-C', repo, 'ls-files', '--stage']);
    rejectLoop(repo, task, passArgs(repo, task, task), /BLOCKED:.*Tree/);
    assert.deepEqual(execFileSync('git', ['-C', repo, 'ls-files', '--stage']), indexBefore);
  });

  it('pass preserves the checker boundary when evidence is staged', () => {
    const task = 'staged-evidence';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    const { records } = handoffFixture(repo, task);
    execFileSync('git', ['-C', repo, 'add', '--', ...records]);
    const indexBefore = execFileSync('git', ['-C', repo, 'ls-files', '--stage']);
    rejectLoop(repo, task, passArgs(repo, task, task), /BLOCKED:.*证据不能混入/);
    assert.deepEqual(execFileSync('git', ['-C', repo, 'ls-files', '--stage']), indexBefore);
  });

  for (const outcome of ['fail', 'blocked']) {
    it(`${outcome} requires a nonempty error signature and a nonempty regular evidence file`, () => {
      const task = 'failure-args';
      runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic']);
      const evidence = failureEvidence(repo, task);
      const dir = path.join(repo, '.ship/tasks', task);
      fs.writeFileSync(path.join(dir, 'empty.log'), '');
      fs.symlinkSync(path.join(dir, 'failure.log'), path.join(dir, 'link.log'));
      const base = ['--task', task, 'record', ...recordTokens(repo, task),
        '--stage', 'ship-verify', '--outcome', outcome];
      for (const extra of [
        [], evidence, ['--error-sig', '', ...evidence], ['--error-sig', ' \t\n ', ...evidence],
        ['--error-sig', 'error'], ['--error-sig', 'error', '--evidence', ''],
        ['--error-sig', 'error', '--evidence', ' \t '],
        ...['missing.log', 'empty.log', 'link.log'].map((name) =>
          ['--error-sig', 'error', '--evidence', path.join(dir, name)]),
        ['--error-sig', 'error', '--evidence', dir],
        ['--error-sig', 'error', ...evidence, '--slug', task],
      ]) {
        rejectLoop(repo, task, [...base, ...extra]);
      }
      runLoop(repo, [...base, '--error-sig', 'error', '--evidence', path.join(dir, 'failure.log')]);
      const state = readState(repo, task);
      assert.equal(state.status, 'ACTIVE');
      assert.match(state.history[0].error_hash, /^[a-f0-9]{16}$/);
      assert.equal(state.history[0].evidence, path.join(dir, 'failure.log'));
      assert.equal(state.history[0].slug, undefined);
      assert.equal(state.history[0].tree, undefined);
    });
  }

  it('record requires current cycle and exactly the next positive safe round', () => {
    const task = 'tokens';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    handoffFixture(repo, task);
    const cycle = readState(repo, task).cycle;
    const base = ['--task', task, 'record', '--stage', 'ship-review', '--outcome', 'pass', '--slug', task];
    for (const tokens of [[], ['--round', '1'], ['--cycle', cycle],
      ...['', 'wrong', '0'.repeat(32)].map((value) => ['--cycle', value, '--round', '1']),
      ...['', '0', '-1', '1.5', 'NaN', '1e0', '9007199254740993', '2'].map((round) => ['--cycle', cycle, '--round', round]),
    ]) {
      rejectLoop(repo, task, [...base, ...tokens]);
    }
  });

  it('duplicate round is rejected while active and a later valid pass clears failure state', () => {
    const task = 'duplicate';
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic', '--max-rounds', '3']);
    const args = ['--task', task, 'record', ...recordTokens(repo, task), '--stage', 'ship-verify',
      '--outcome', 'fail', '--error-sig', 'failure', ...failureEvidence(repo, task)];
    runLoop(repo, args);
    assert.equal(readState(repo, task).status, 'ACTIVE');
    rejectLoop(repo, task, args, /cycle\/round 已过期或不匹配/);
    handoffFixture(repo, task);
    runLoop(repo, passArgs(repo, task, task));
    const state = readState(repo, task);
    assert.equal(state.status, 'CONVERGED');
    assert.equal(state.round, 2);
    assert.equal(state.history.length, 2);
    assert.equal(state.stall_count, 0);
    assert.equal(state.last_error_hash, '');
  });

  it('reset rejects results from the old cycle even when round matches', () => {
    const task = 'stale-cycle';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    const tokens = recordTokens(repo, task);
    const evidence = failureEvidence(repo, task);
    handoffFixture(repo, task);
    runLoop(repo, ['--task', task, 'reset', '--level', 'L2', '--mode', 'builder-critic']);
    for (const outcome of ['pass', 'fail', 'blocked']) {
      rejectLoop(repo, task, ['--task', task, 'record', ...tokens, '--stage', 'ship-review', '--outcome', outcome,
        ...(outcome === 'pass' ? ['--slug', task] : ['--error-sig', 'failure', ...evidence])],
      /cycle\/round 已过期或不匹配/);
    }
    rejectLoop(repo, task, passArgs(repo, task, task), /BLOCKED:.*Cycle/);
    handoffFixture(repo, task);
    runLoop(repo, passArgs(repo, task, task));
    assert.equal(readState(repo, task).round, 1);
  });

  it('record pass rejects same-tree evidence for a different task', () => {
    const task = 'expected-task';
    const other = 'other-task';
    const slug = 'shared-slug';
    for (const id of [task, other]) {
      runLoop(repo, ['--task', id, 'init', '--level', 'L2', '--mode', 'builder-critic']);
    }
    handoffFixture(repo, other, slug);
    rejectLoop(repo, task, passArgs(repo, task, slug), /BLOCKED:.*Task/);
  });

  it('record pass rejects same-cycle evidence for another round', () => {
    const task = 'expected-round';
    runLoop(repo, ['--task', task, 'init', '--level', 'L2', '--mode', 'builder-critic']);
    handoffFixture(repo, task);
    runLoop(repo, ['--task', task, 'record', '--stage', 'ship-verify', '--outcome', 'fail', '--error-sig', 'boom',
      ...recordTokens(repo, task), ...failureEvidence(repo, task)]);
    rejectLoop(repo, task, passArgs(repo, task, task), /BLOCKED:.*Round/);
  });

  it('slug cycle and round are record-only and escalation targets are restricted', () => {
    const task = 'action-args';
    runLoop(repo, ['--task', task, 'init', '--level', 'L1', '--mode', 'single']);
    for (const actionArgs of [['status'], ['init', '--level', 'L1', '--mode', 'single'],
      ['reset', '--level', 'L1', '--mode', 'single'], ['escalate', '--target', 'user', '--reason', 'decision']]) {
      for (const extra of [['--slug', task], ['--cycle', readState(repo, task).cycle], ['--round', '1']]) {
        rejectLoop(repo, task, ['--task', task, ...actionArgs, ...extra], /仅用于 record/);
      }
    }
    for (const target of ['ship-auto', 'ship-review', 'team', ' user ']) {
      rejectLoop(repo, task, ['--task', task, 'escalate', '--target', target, '--reason', 'decision'], /仅支持 ship-plan \| user/);
    }
    runLoop(repo, ['--task', task, 'escalate', '--target', 'user', '--reason', 'decision']);
    assert.deepEqual(readState(repo, task).escalation, { target: 'user', reason: 'decision' });
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
