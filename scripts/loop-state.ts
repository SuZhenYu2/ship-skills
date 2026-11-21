import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const STAGES = new Set([
  'ship-arena',
  'ship-auto',
  'ship-grill',
  'ship-spec',
  'ship-plan',
  'ship-tdd',
  'ship-fix',
  'ship-verify',
  'ship-review',
  'ship-commit',
  'ship-finish',
]);

const LEVELS = new Set(['L1', 'L2', 'L3'] as const);
const MODES = new Set(['single', 'builder-critic', 'multi-agent'] as const);
const STATUSES = new Set(['ACTIVE', 'CONVERGED', 'TRIPPED', 'ESCALATED'] as const);
const OUTCOMES = new Set(['pass', 'fail', 'blocked'] as const);
const ACTIONS = new Set(['init', 'status', 'record', 'escalate', 'reset'] as const);

type Level = 'L1' | 'L2' | 'L3';
type Mode = 'single' | 'builder-critic' | 'multi-agent';
type LoopStatus = 'ACTIVE' | 'CONVERGED' | 'TRIPPED' | 'ESCALATED';
type Outcome = 'pass' | 'fail' | 'blocked';
type Action = 'init' | 'status' | 'record' | 'escalate' | 'reset';

interface HistoryEntry {
  round: number;
  stage: string;
  outcome: Outcome;
  error_hash: string;
  evidence: string;
}

interface EscalationInfo {
  target: string;
  reason: string;
}

interface LoopState {
  version: 1;
  task: string;
  cycle: string;
  level: Level;
  mode: Mode;
  status: LoopStatus;
  round: number;
  max_rounds: number;
  stall_count: number;
  last_error_hash: string;
  history: HistoryEntry[];
  escalation?: EscalationInfo;
  trip_reason?: string;
}

interface ParsedArgs {
  repo: string;
  task?: string;
  stage?: string;
  level?: string;
  mode?: string;
  maxRounds?: number;
  outcome?: string;
  errorSig?: string;
  evidence?: string;
  target?: string;
  reason?: string;
  action?: Action;
}

function fail(message: string, code = 1): never {
  process.stderr.write(`[ERROR] ${message}\n`);
  process.exit(code);
}

function parseCliArgs(argv: string[]): ParsedArgs {
  const parsed: ParsedArgs = { repo: '.' };
  const valueFlags = new Set([
    '--repo',
    '--task',
    '--stage',
    '--level',
    '--mode',
    '--max-rounds',
    '--outcome',
    '--error-sig',
    '--evidence',
    '--target',
    '--reason',
  ]);

  let i = 0;
  while (i < argv.length) {
    const token = argv[i];
    if (token === '-h' || token === '--help') {
      process.stdout.write(
        'Usage: loop-state.sh --repo <root> --task <id> [--stage <stage>] <init|status|record|escalate|reset> [options]\n',
      );
      process.exit(0);
    }
    if (valueFlags.has(token)) {
      if (i + 1 >= argv.length) {
        fail(`参数 ${token} 缺少取值。`);
      }
      const value = argv[i + 1];
      i += 2;
      switch (token) {
        case '--repo':
          parsed.repo = value;
          break;
        case '--task':
          parsed.task = value;
          break;
        case '--stage':
          parsed.stage = value;
          break;
        case '--level':
          parsed.level = value;
          break;
        case '--mode':
          parsed.mode = value;
          break;
        case '--max-rounds': {
          if (!/^-?\d+$/.test(value)) {
            fail('--max-rounds 必须为整数。');
          }
          parsed.maxRounds = Number.parseInt(value, 10);
          break;
        }
        case '--outcome':
          parsed.outcome = value;
          break;
        case '--error-sig':
          parsed.errorSig = value;
          break;
        case '--evidence':
          parsed.evidence = value;
          break;
        case '--target':
          parsed.target = value;
          break;
        case '--reason':
          parsed.reason = value;
          break;
      }
      continue;
    }
    if (token.startsWith('-')) {
      fail(`未知参数：${token}`);
    }
    if (parsed.action) {
      fail(`多余的位置参数：${token}`);
    }
    if (!ACTIONS.has(token as Action)) {
      fail(`未知操作：${token}（仅支持 init | status | record | escalate | reset）`);
    }
    parsed.action = token as Action;
    i += 1;
  }

  if (!parsed.action) {
    fail('必须指定操作：init | status | record | escalate | reset。');
  }
  if (parsed.task === undefined) {
    fail('必须提供 --task 参数。');
  }
  return parsed;
}

function normalizeErrorHash(sig?: string): string {
  if (!sig) return '';
  const normalized = sig.trim().split(/\s+/).join(' ');
  if (!normalized) return '';
  return createHash('sha256').update(normalized, 'utf8').digest('hex').slice(0, 16);
}

function runGit(repo: string, args: string[]): string {
  return execFileSync('git', ['-C', repo, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
}

function isSymlinkIfExists(targetPath: string): boolean {
  try {
    return fs.lstatSync(targetPath).isSymbolicLink();
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') return false;
    throw err;
  }
}

function ensureLocalExclude(repo: string): void {
  const excludeRaw = runGit(repo, ['rev-parse', '--git-path', 'info/exclude']);
  const excludePath = path.isAbsolute(excludeRaw) ? excludeRaw : path.join(repo, excludeRaw);
  const existing = fs.existsSync(excludePath) ? fs.readFileSync(excludePath, 'latin1') : '';
  const tasks = '/.ship/tasks/';
  let hasTasks = existing.split(/\r?\n/).includes(tasks);
  let updated = existing.split(/(?<=\n)/).map((line) => {
    if (line.replace(/\r?\n$/, '') !== '/.ship/') return line;
    if (hasTasks) return '';
    hasTasks = true;
    return line.replace('/.ship/', tasks);
  }).join('');
  if (!hasTasks) {
    const eol = existing.includes('\r\n') ? '\r\n' : '\n';
    updated += `${existing && !existing.endsWith('\n') ? eol : ''}${tasks}${eol}`;
  }
  if (updated !== existing) {
    fs.mkdirSync(path.dirname(excludePath), { recursive: true });
    fs.writeFileSync(excludePath, updated, 'latin1');
  }
}

function atomicWriteJson(filePath: string, data: LoopState): void {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  const tempPath = path.join(dir, `.loop-${process.pid}-${randomUUID().replace(/-/g, '')}.tmp`);
  try {
    fs.writeFileSync(tempPath, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
    fs.renameSync(tempPath, filePath);
  } finally {
    if (fs.existsSync(tempPath)) {
      fs.unlinkSync(tempPath);
    }
  }
}

function validateState(raw: unknown, expectedTask: string): LoopState {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    fail('loop 配置格式无效；请修复后重试，不会静默覆盖。');
  }
  const obj = raw as Record<string, unknown>;
  const requiredKeys = [
    'version',
    'task',
    'cycle',
    'level',
    'mode',
    'status',
    'round',
    'max_rounds',
    'stall_count',
    'last_error_hash',
    'history',
  ];
  const allowedKeys = new Set([...requiredKeys, 'escalation', 'trip_reason']);
  for (const key of requiredKeys) {
    if (!(key in obj)) {
      fail('loop 配置字段缺失；请修复后重试，不会静默覆盖。');
    }
  }
  for (const key of Object.keys(obj)) {
    if (!allowedKeys.has(key)) {
      fail('loop 配置包含未知字段；请修复后重试，不会静默覆盖。');
    }
  }
  if (!Number.isInteger(obj.version) || obj.version !== 1) {
    fail('loop 配置版本无效；仅支持 version=1。');
  }
  if (obj.task !== expectedTask) {
    fail('loop 配置中的 task 字段与目标任务不一致。');
  }
  if (typeof obj.cycle !== 'string' || !/^[0-9a-f]{32}$/.test(obj.cycle)) {
    fail('loop cycle 格式无效。');
  }
  if (typeof obj.level !== 'string' || !LEVELS.has(obj.level as Level)) {
    fail('loop level 字段无效。');
  }
  if (typeof obj.mode !== 'string' || !MODES.has(obj.mode as Mode)) {
    fail('loop mode 字段无效。');
  }
  if (typeof obj.status !== 'string' || !STATUSES.has(obj.status as LoopStatus)) {
    fail('loop status 字段无效。');
  }
  if (!Number.isInteger(obj.round) || (obj.round as number) < 0) {
    fail('loop round 字段无效。');
  }
  if (
    !Number.isInteger(obj.max_rounds) ||
    (obj.max_rounds as number) < 1 ||
    (obj.max_rounds as number) > 5
  ) {
    fail('loop max_rounds 字段无效（允许 1..5）。');
  }
  if (!Number.isInteger(obj.stall_count) || (obj.stall_count as number) < 0) {
    fail('loop stall_count 字段无效。');
  }
  if (typeof obj.last_error_hash !== 'string') {
    fail('loop last_error_hash 字段无效。');
  }
  if (!Array.isArray(obj.history)) {
    fail('loop history 字段无效。');
  }
  return obj as unknown as LoopState;
}

function printBanner(stageLabel: string, taskId: string, state: LoopState | null): void {
  if (state === null) {
    process.stdout.write(
      `[${stageLabel}] Loop: UNINITIALIZED | 范围: ${taskId} | 难度: - | 模式: - | 轮次: 0/0\n`,
    );
    process.stdout.write('cycle=未初始化；请先执行 init\n');
    return;
  }
  process.stdout.write(
    `[${stageLabel}] Loop: ${state.status} | 范围: ${taskId} | 难度: ${state.level} | 模式: ${state.mode} | 轮次: ${state.round}/${state.max_rounds}\n`,
  );
  process.stdout.write(`cycle=${state.cycle}\n`);
}

function main(): void {
  const args = parseCliArgs(process.argv.slice(2));
  const task = args.task as string;
  const action = args.action as Action;

  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(task) || task.length > 100) {
    fail('task 必须为不超过 100 字符的小写字母、数字及分隔短横线。');
  }
  if (args.stage !== undefined && !STAGES.has(args.stage)) {
    fail(`未知 ship 阶段：${args.stage}`);
  }
  if (args.level !== undefined && !LEVELS.has(args.level as Level)) {
    fail(`未知难度级别：${args.level}（仅支持 L1 | L2 | L3）`);
  }
  if (args.mode !== undefined && !MODES.has(args.mode as Mode)) {
    fail(`未知执行模式：${args.mode}（仅支持 single | builder-critic | multi-agent）`);
  }
  if (args.outcome !== undefined && !OUTCOMES.has(args.outcome as Outcome)) {
    fail(`未知结果类型：${args.outcome}（仅支持 pass | fail | blocked）`);
  }
  if (args.maxRounds !== undefined && (args.maxRounds < 1 || args.maxRounds > 5)) {
    fail('--max-rounds 必须在 1 到 5 之间。');
  }

  if (action === 'init' || action === 'reset') {
    if (!args.level || !args.mode) {
      fail(`${action} 必须提供 --level 与 --mode。`);
    }
    if (
      args.outcome !== undefined ||
      args.errorSig !== undefined ||
      args.evidence !== undefined ||
      args.target !== undefined ||
      args.reason !== undefined
    ) {
      fail(`${action} 不接受 record/escalate 专属参数。`);
    }
  } else if (action === 'status') {
    if (
      args.level !== undefined ||
      args.mode !== undefined ||
      args.maxRounds !== undefined ||
      args.outcome !== undefined ||
      args.errorSig !== undefined ||
      args.evidence !== undefined ||
      args.target !== undefined ||
      args.reason !== undefined
    ) {
      fail('status 仅支持 --repo、--task 与可选 --stage。');
    }
  } else if (action === 'record') {
    if (!args.stage || !args.outcome) {
      fail('record 必须提供 --stage 与 --outcome。');
    }
    if (
      args.level !== undefined ||
      args.mode !== undefined ||
      args.maxRounds !== undefined ||
      args.target !== undefined ||
      args.reason !== undefined
    ) {
      fail('record 不接受 init/reset/escalate 专属参数。');
    }
  } else if (action === 'escalate') {
    if (!args.target || !args.target.trim() || !args.reason || !args.reason.trim()) {
      fail('escalate 必须提供非空的 --target 与 --reason。');
    }
    if (
      args.level !== undefined ||
      args.mode !== undefined ||
      args.maxRounds !== undefined ||
      args.outcome !== undefined ||
      args.errorSig !== undefined ||
      args.evidence !== undefined
    ) {
      fail('escalate 不接受 init/reset/record 专属参数。');
    }
  }

  try {
    const repo = fs.realpathSync(args.repo);
    const topLevel = fs.realpathSync(runGit(repo, ['rev-parse', '--show-toplevel']));
    if (topLevel !== repo) {
      fail('--repo 必须指向 Git 工作区根目录。');
    }

    const shipDir = path.join(repo, '.ship');
    const tasksDir = path.join(shipDir, 'tasks');
    const taskDir = path.join(tasksDir, task);
    const statePath = path.join(taskDir, 'loop.json');

    for (const item of [shipDir, tasksDir, taskDir, statePath]) {
      if (isSymlinkIfExists(item)) {
        fail(`状态路径不能包含符号链接：${item}`);
      }
    }

    let state: LoopState | null = null;
    if (fs.existsSync(statePath)) {
      const parsedJson: unknown = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      state = validateState(parsedJson, task);
    }

    const label = args.stage ?? 'ship';

    if (action === 'status') {
      printBanner(label, task, state);
      process.exit(0);
    }

    if (action === 'init') {
      if (state !== null) {
        fail('任务 loop 状态已存在；如需重开新周期，请显式使用 reset。');
      }
      ensureLocalExclude(repo);
      const nextState: LoopState = {
        version: 1,
        task,
        cycle: randomUUID().replace(/-/g, ''),
        level: args.level as Level,
        mode: args.mode as Mode,
        status: 'ACTIVE',
        round: 0,
        max_rounds: args.maxRounds ?? 2,
        stall_count: 0,
        last_error_hash: '',
        history: [],
      };
      atomicWriteJson(statePath, nextState);
      printBanner(label, task, nextState);
      process.exit(0);
    }

    if (state === null) {
      fail(`任务 ${task} 尚未初始化 loop 状态；请先执行 init。`);
    }

    if (action === 'reset') {
      ensureLocalExclude(repo);
      const nextState: LoopState = {
        version: 1,
        task,
        cycle: randomUUID().replace(/-/g, ''),
        level: args.level as Level,
        mode: args.mode as Mode,
        status: 'ACTIVE',
        round: 0,
        max_rounds: args.maxRounds ?? 2,
        stall_count: 0,
        last_error_hash: '',
        history: [],
      };
      atomicWriteJson(statePath, nextState);
      printBanner(label, task, nextState);
      process.exit(0);
    }

    if (action === 'escalate') {
      if (state.status !== 'TRIPPED' && state.status !== 'ACTIVE') {
        fail(`当前状态为 ${state.status}，不允许执行 escalate。`);
      }
      ensureLocalExclude(repo);
      state.status = 'ESCALATED';
      state.escalation = {
        target: (args.target as string).trim(),
        reason: (args.reason as string).trim(),
      };
      atomicWriteJson(statePath, state);
      printBanner(label, task, state);
      process.stdout.write(
        `已记录升级：target=${state.escalation.target} | reason=${state.escalation.reason}\n`,
      );
      process.exit(0);
    }

    if (action === 'record') {
      if (state.status !== 'ACTIVE') {
        fail(`当前状态为 ${state.status}，禁止继续 record；请先 escalate 或经确认后 reset。`);
      }
      ensureLocalExclude(repo);
      state.round += 1;
      const outcome = args.outcome as Outcome;
      const errHash = outcome !== 'pass' ? normalizeErrorHash(args.errorSig) : '';
      state.history.push({
        round: state.round,
        stage: args.stage as string,
        outcome,
        error_hash: errHash,
        evidence: args.evidence ?? '',
      });

      let exitCode = 0;
      let tripMsg = '';

      if (outcome === 'pass') {
        state.status = 'CONVERGED';
        state.stall_count = 0;
        state.last_error_hash = '';
      } else {
        if (errHash && errHash === state.last_error_hash) {
          state.stall_count += 1;
        } else if (errHash) {
          state.stall_count = 1;
          state.last_error_hash = errHash;
        } else {
          state.stall_count = 0;
          state.last_error_hash = '';
        }

        if (state.stall_count >= 2) {
          state.status = 'TRIPPED';
          tripMsg = `连续 ${state.stall_count} 轮出现相同错误签名（${errHash}），触发停滞硬熔断；请立即停止重试并执行 escalate。`;
          state.trip_reason = tripMsg;
          exitCode = 2;
        } else if (state.round >= state.max_rounds) {
          state.status = 'TRIPPED';
          tripMsg = `已达最大轮次上限（${state.round}/${state.max_rounds}），触发轮次硬熔断；请立即停止重试并执行 escalate。`;
          state.trip_reason = tripMsg;
          exitCode = 2;
        }
      }

      atomicWriteJson(statePath, state);
      printBanner(label, task, state);
      if (tripMsg) {
        process.stdout.write(`[TRIPPED] ${tripMsg}\n`);
      }
      process.exit(exitCode);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    fail(`无法读取或更新 loop 状态：${message}`);
  }
}

main();
