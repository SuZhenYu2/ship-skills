import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const STRATEGIES: Record<string, string> = {
  'ship-arena': '配置任务开关',
  'ship-auto': '只读导航',
  'ship-grill': '独立分析需求缺口，由 Lead 合并追问',
  'ship-spec': '独立分析验收条件，由 Lead 汇总 Spec',
  'ship-plan': '双候选方案比选',
  'ship-tdd': '测试设计与高风险策略比选，不并行业务实现',
  'ship-fix': '独立根因假设证伪与修复方案比选',
  'ship-verify': '同一最终快照独立验证，事实不投票',
  'ship-review': '独立双视角审查，有效 BLOCKER 或未接受的 MAJOR 必须阻断',
  'ship-commit': 'Lead 串行提交门禁，代码提交和证据提交分别授权',
  'ship-finish': '独立复核交付证据，Git 收尾仅由 Lead 串行执行',
};

const ACTIONS = new Set(['on', 'off', 'status', 'check'] as const);
type Action = 'on' | 'off' | 'status' | 'check';

interface ArenaState {
  version: 1;
  enabled: boolean;
  policy: 'selective';
  candidates: 2;
  generation?: string;
}

interface ParsedArgs {
  repo: string;
  task?: string;
  stage?: string;
  generation?: string;
  input?: string;
  candidate?: string;
  action?: Action;
}

function fail(message: string): never {
  process.stderr.write(`[ERROR] ${message}\n`);
  process.exit(1);
}

function parseCliArgs(argv: string[]): ParsedArgs {
  const parsed: ParsedArgs = { repo: '.' };
  const valueFlags = new Set(['--repo', '--task', '--stage', '--generation', '--input', '--candidate']);

  let i = 0;
  while (i < argv.length) {
    const token = argv[i];
    if (token === '-h' || token === '--help') {
      process.stdout.write(
        'Usage: arena-state.sh --repo <root> --task <id> [--stage <stage>] <on|off|status|check> [--generation <hex>] [--input <json> --candidate <json>]\n',
      );
      process.exit(0);
    }
    if (valueFlags.has(token)) {
      if (i + 1 >= argv.length) {
        fail(`参数 ${token} 缺少取值。`);
      }
      const value = argv[i + 1];
      i += 2;
      if (token === '--repo') parsed.repo = value;
      else if (token === '--task') parsed.task = value;
      else if (token === '--stage') parsed.stage = value;
      else if (token === '--generation') parsed.generation = value;
      else if (token === '--input') parsed.input = value;
      else if (token === '--candidate') parsed.candidate = value;
      continue;
    }
    if (token.startsWith('-')) {
      fail(`未知参数：${token}`);
    }
    if (parsed.action) {
      fail(`多余的位置参数：${token}`);
    }
    if (!ACTIONS.has(token as Action)) {
      fail(`未知操作：${token}（仅支持 on | off | status | check）`);
    }
    parsed.action = token as Action;
    i += 1;
  }

  if (!parsed.action) {
    fail('必须指定操作：on | off | status | check。');
  }
  if (parsed.task === undefined) {
    fail('必须提供 --task 参数。');
  }
  return parsed;
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
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return false;
    throw err;
  }
}

function validateState(raw: unknown): ArenaState {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    fail('arena 配置格式或版本无效；请明确修复后重试，不会静默覆盖。');
  }
  const obj = raw as Record<string, unknown>;
  const keys = Object.keys(obj);
  const baseKeys = ['version', 'enabled', 'policy', 'candidates'];
  const validWithoutGen = keys.length === 4 && baseKeys.every((k) => k in obj);
  const validWithGen = keys.length === 5 && baseKeys.every((k) => k in obj) && 'generation' in obj;

  if (
    (!validWithoutGen && !validWithGen) ||
    !Number.isInteger(obj.version) ||
    obj.version !== 1 ||
    typeof obj.enabled !== 'boolean' ||
    obj.policy !== 'selective' ||
    !Number.isInteger(obj.candidates) ||
    obj.candidates !== 2
  ) {
    fail('arena 配置格式或版本无效；请明确修复后重试，不会静默覆盖。');
  }
  if ('generation' in obj && (typeof obj.generation !== 'string' || !/^[0-9a-f]{32}$/.test(obj.generation))) {
    fail('arena generation 格式无效。');
  }
  return obj as unknown as ArenaState;
}

function atomicWriteJson(filePath: string, data: ArenaState): void {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  const tempPath = path.join(dir, `.arena-${process.pid}-${randomUUID().replace(/-/g, '')}.tmp`);
  try {
    fs.writeFileSync(tempPath, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
    fs.renameSync(tempPath, filePath);
  } finally {
    if (fs.existsSync(tempPath)) {
      fs.unlinkSync(tempPath);
    }
  }
}

function checkCandidate(repo: string, args: ParsedArgs, isGit: boolean): void {
  function readObject(file: string): Record<string, unknown> {
    const value: unknown = JSON.parse(fs.readFileSync(path.resolve(repo, file), 'utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail('交接文件必须为 JSON 对象。');
    return value as Record<string, unknown>;
  }

  const input = readObject(args.input as string);
  const candidate = readObject(args.candidate as string);
  if (input.repo !== repo || input.task !== args.task || input.generation !== args.generation ||
      typeof input.stage !== 'string' || !Object.hasOwn(STRATEGIES, input.stage) ||
      (args.stage !== undefined && input.stage !== args.stage) ||
      typeof input.run_id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(input.run_id)) {
    fail('派发输入的仓库、任务、阶段、run_id 或 generation 无效。');
  }
  for (const key of ['repo', 'task', 'stage', 'run_id', 'generation']) {
    if (candidate[key] !== input[key]) fail(`候选 ${key} 与当前派发输入不一致。`);
  }
  for (const value of [input.snapshot, candidate.snapshot]) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail('snapshot 必须为对象。');
    const snapshot = value as Record<string, unknown>;
    if (typeof snapshot.head !== 'string' ||
        (isGit
          ? !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(snapshot.head)
          : snapshot.head !== 'none') ||
        typeof snapshot.worktree !== 'string' || !/^[0-9a-f]{64}$/.test(snapshot.worktree)) {
      fail(isGit
        ? 'snapshot 需要完整 HEAD 与 SHA-256 工作区指纹。'
        : '非 Git snapshot 需要 head=none 与 SHA-256 工作区指纹。');
    }
  }
  const expected = input.snapshot as Record<string, unknown>;
  const actual = candidate.snapshot as Record<string, unknown>;
  if (expected.head !== actual.head || expected.worktree !== actual.worktree) {
    fail('候选输入快照已失效。');
  }
  if (typeof candidate.conclusion !== 'string' || !candidate.conclusion.trim()) fail('候选结论不能为空。');
  for (const key of ['evidence', 'risks', 'assumptions', 'verification']) {
    const value = candidate[key];
    if (!Array.isArray(value) || value.some((item) => typeof item !== 'string' || !item.trim()) ||
        ((key === 'evidence' || key === 'verification') && value.length === 0)) {
      fail(`候选 ${key} 无效；证据和验证方式不能为空。`);
    }
  }
  process.stdout.write('候选交接字段校验通过；不证明证据真实、权限隔离或最终交付通过。\n');
}

function main(): void {
  const args = parseCliArgs(process.argv.slice(2));
  const task = args.task as string;
  const action = args.action as Action;

  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(task) || task.length > 100) {
    fail('task 必须为不超过 100 字符的小写字母、数字及分隔短横线。');
  }
  if (args.stage !== undefined && !Object.hasOwn(STRATEGIES, args.stage)) {
    fail(`未知 ship 阶段：${args.stage}`);
  }
  if ((action === 'check') !== Boolean(args.generation)) {
    fail('check 必须提供 --generation；其他操作不得提供该参数。');
  }
  if (args.input !== undefined || args.candidate !== undefined) {
    if (action !== 'check' || !args.input || !args.candidate) {
      fail('--input 与 --candidate 必须成对提供，且仅用于 check。');
    }
  }

  try {
    const repo = fs.realpathSync(args.repo);
    if (!fs.statSync(repo).isDirectory()) {
      fail('--repo 必须指向目录。');
    }
    let isGit = true;
    let topLevel = repo;
    try {
      topLevel = fs.realpathSync(runGit(repo, ['rev-parse', '--show-toplevel']));
    } catch {
      isGit = false;
    }
    if (topLevel !== repo) {
      fail('--repo 必须指向项目根目录（Git 工作区根或非 Git 项目根）。');
    }

    const shipDir = path.join(repo, '.ship');
    const tasksDir = path.join(shipDir, 'tasks');
    const taskDir = path.join(tasksDir, task);
    const statePath = path.join(taskDir, 'arena.json');

    for (const item of [shipDir, tasksDir, taskDir, statePath]) {
      if (isSymlinkIfExists(item)) {
        fail(`状态路径不能包含符号链接：${item}`);
      }
    }

    let state: ArenaState = {
      version: 1,
      enabled: false,
      policy: 'selective',
      candidates: 2,
    };
    if (fs.existsSync(statePath)) {
      const parsed: unknown = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      state = validateState(parsed);
    }

    if (action === 'check') {
      if (!state.enabled || !state.generation || state.generation !== args.generation) {
        fail('候选批次已失效或未绑定；禁止接收旧结果。');
      }
      if (args.input && args.candidate) checkCandidate(repo, args, isGit);
    }

    if (action === 'on' || action === 'off') {
      if (isGit) {
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
      state.enabled = action === 'on';
      state.generation = randomUUID().replace(/-/g, '');
      atomicWriteJson(statePath, state);
    }

    const label = args.stage ?? 'ship';
    const enabledText = state.enabled ? 'ON' : 'OFF';
    const strategy =
      state.enabled && args.stage
        ? STRATEGIES[args.stage]
        : state.enabled
          ? 'selective'
          : '标准流程';

    process.stdout.write(`[${label}] Arena: ${enabledText} | 范围: ${task} | 计划策略: ${strategy}\n`);
    process.stdout.write(`generation=${state.generation ?? '未绑定批次；请显式 on 后再派发候选'}\n`);
    if (!isGit) process.stdout.write('vcs=none\n');
    if (action === 'on' || action === 'off') {
      process.stdout.write(
        state.enabled
          ? '从下一阶段生效；不包含 Git 写操作授权。\n'
          : '停止派发新候选；已运行候选请求取消，不支持时忽略其后续输出。不回滚已有产物。\n',
      );
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    fail(`无法读取或更新 arena 状态：${message}`);
  }
}

main();
