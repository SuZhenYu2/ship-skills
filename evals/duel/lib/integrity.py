import hashlib
import json
import os
import re


TASK_ITEMS = dict(zip(('T01', 'T02', 'T03', 'T04', 'T05', 'T06'),
                      ('A1 A2 A3', 'B1 B2 B3 B4', 'C1 C2 C3 C4 C5',
                       'D1 D2 D3', 'E1 E2 E3', 'F1 F2 F3')))
TASK_ITEMS.update({f'H{i:02d}': 'H1 H2 H3 H4' for i in range(1, 11)})


def item_ids(task):
    return ('G1 G2 G3 G4 ' + TASK_ITEMS[task]).split()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def json_value(text):
    def unique(pairs):
        result = dict(pairs)
        require(len(result) == len(pairs), 'JSON 字段重复')
        return result

    return json.loads(text, object_pairs_hook=unique)


def read_object(path):
    try:
        data = json_value(path.read_text(encoding='utf-8'))
        require(isinstance(data, dict), '必须是 JSON 对象')
        return data
    except (OSError, ValueError) as exc:
        raise ValueError(f'{path.name}: {exc}') from exc


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]+', value) is not None


def allocation(root):
    data = read_object(root / 'sealed/allocation.json')
    rows, raters = data.get('runs'), data.get('raters', ['r1'])
    require(isinstance(raters, list) and raters and all(map(identifier, raters))
            and len(set(raters)) == len(raters), 'allocation.raters 必须为非空、不重复的 ID 列表')
    require(isinstance(rows, list) and rows, 'allocation.runs 必须为非空列表')
    runs, cells = {}, set()
    for row in rows:
        require(isinstance(row, dict), 'allocation.runs 存在非对象记录')
        code, arm, task, repeat = (row.get(k) for k in ('code', 'arm', 'task', 'repeat'))
        require(identifier(code) and identifier(arm) and isinstance(task, str) and task in TASK_ITEMS
                and type(repeat) is int and repeat > 0, 'allocation.runs 存在无效记录')
        cell = arm, task, repeat
        require(code not in runs and cell not in cells, f'allocation.runs 重复运行或格：{code}')
        runs[code] = row
        cells.add(cell)
    return runs, raters


def run_state(root, code):
    rd = root / 'runs' / code
    if not (rd / 'done').is_file():
        return {}, {}, ['缺少 done']
    records, reasons = [], []
    for name in ('execution.json', 'manipulation.json'):
        try:
            records.append(read_object(rd / name))
        except ValueError:
            records.append({})
            reasons.append(f'{name} 缺失或不可读')
    execution, manipulation = records
    if execution.get('status') != 'ok':
        reasons.append('execution.status 非 ok')
    if type(execution.get('exit_code')) is not int or execution['exit_code'] != 0:
        reasons.append('execution.exit_code 非 0')
    if manipulation.get('discovery_ok') is not True:
        reasons.append('manipulation.discovery_ok 非 true')
    return execution, manipulation, reasons


def validate_score(data, task, packet):
    require(isinstance(data, dict) and set(data) == {'outcome', 'summary', 'items'}
            and data['outcome'] in ('completed', 'needs_input', 'aborted')
            and isinstance(data['summary'], str) and isinstance(data['items'], list), '评分格式无效')
    expected, seen = set(item_ids(task)), set()
    for item in data['items']:
        require(isinstance(item, dict) and set(item) == {'id', 'score', 'evidence'}, '评分条目字段无效')
        id_, score, quote = (item[k] for k in ('id', 'score', 'evidence'))
        require(isinstance(id_, str) and id_ in expected and id_ not in seen, '评分条目 ID 未分配或重复')
        require(type(score) is int and score in (0, 1), f'{id_} 分数必须为整数 0 或 1')
        require(isinstance(quote, str) and ((quote.strip() and quote in packet) or (score == 0 and quote == '')),
                f'{id_} evidence 必须原样出现在 packet.md；仅 0 分允许空引文')
        seen.add(id_)
    require(seen == expected, '缺少评分条目：' + ', '.join(sorted(expected - seen)))
    return sum(item['score'] for item in data['items']) / len(expected)


def reconcile(root, runs, raters, valid):
    run_dir = root / 'runs'
    if run_dir.is_dir():
        extras = {p.name for p in run_dir.iterdir() if p.is_dir()} - runs.keys()
        require(not extras, '未分配的运行目录：' + ', '.join(sorted(extras)))

    packet_dir = root / 'blind'
    packets = {p.parent.name: p for p in packet_dir.glob('*/packet.md') if p.is_file()}
    for code in sorted(packets.keys() - runs.keys()):
        raise ValueError(f'未分配的盲包：blind/{code}/packet.md')
    for code in sorted(valid - packets.keys()):
        raise ValueError(f'有效运行缺少盲包：blind/{code}/packet.md')

    key_path = root / 'sealed/blind_key.jsonl'
    seen = set()
    try:
        text = key_path.read_text(encoding='utf-8') if key_path.exists() or packets else ''
        for line in text.splitlines():
            if not line.strip():
                continue
            row = json_value(line)
            code = row.get('code') if isinstance(row, dict) else None
            require(identifier(code) and code in packets and code not in seen, '盲包映射未知或重复')
            repeat = row.get('repeat', runs[code]['repeat'])
            require(all(row.get(k) == runs[code][k] for k in ('arm', 'task'))
                    and type(repeat) is int and repeat == runs[code]['repeat'], f'{code} 与分配不符')
            seen.add(code)
        require(seen == packets.keys(), '缺少盲包映射：' + ', '.join(sorted(packets.keys() - seen)))
    except (OSError, ValueError) as exc:
        raise ValueError(f'blind_key.jsonl: {exc}') from exc

    scores = root / 'scores'
    expected = {scores / rater / f'{code}.json' for code in valid for rater in raters}
    actual = {p for p in scores.rglob('*.json') if p.is_file()}
    for path in sorted(actual - expected):
        raise ValueError(f'未分配或无效运行的评分：{path.relative_to(root)}')
    for path in sorted(expected - actual):
        raise ValueError(f'缺少评分：{path.relative_to(root)}')
    result = {}
    for code in sorted(valid):
        packet = packets[code].read_text(encoding='utf-8')
        result[code] = []
        for rater in raters:
            path = scores / rater / f'{code}.json'
            try:
                result[code].append(validate_score(read_object(path), runs[code]['task'], packet))
            except ValueError as exc:
                raise ValueError(f'{path.relative_to(root)}: {exc}') from exc
    return result


def lock_digest(root, runs):
    paths = [root / 'sealed' / name for name in ('allocation.json', 'arms.json', 'blind_key.jsonl')]
    paths.extend(root / 'runs' / code / name for code in runs
                 for name in ('done', 'execution.json', 'manipulation.json', 'checks.json', 'isolation.json'))
    for name in ('blind', 'scores'):
        paths.extend(p for p in (root / name).rglob('*') if p.is_file())
    digest = hashlib.sha256()
    for path in sorted(paths):
        if path.is_file():
            name = str(path.relative_to(root)).encode('utf-8')
            digest.update(len(name).to_bytes(8, 'big') + name)
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def create_lock(path, digest):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump({'version': 1, 'digest': digest}, out, indent=2)
