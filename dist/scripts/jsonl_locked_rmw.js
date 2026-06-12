#!/usr/bin/env node
'use strict';

// jsonl_locked_rmw.js — 通用 jsonl file-RMW 引擎 (sidecar-lock 协议 Node 侧, spec jsonl_concurrency_protocol.md v2.1)。
//
// 🔴 调用契约: 本脚本**必须在 flock 持锁下被调用** (调用方负责锁):
//     flock -F -w <T> -E <CONFLICT_RC> <data>.lock node jsonl_locked_rmw.js <op> <data_path> <payload_file>
//   - flock(1) = flock(2) BSD whole-file lock, 与 Python fcntl.flock 同 inode 跨语言互斥 (spec §2 实证)。
//   - 锁在 sidecar <data>.lock (稳定 inode), data 文件可 in-place 或 rename (INV-4)。
//   - flock 超时 (-w) → flock 自身 exit=<CONFLICT_RC> (本脚本不被执行) → 调用方据此 throw (INV-5 不降级)。
//
// 本脚本 (锁内) 做: 读全部 data 行 → transform(op, payload) → 原子写 (tmp+fsync+rename)。纯文件引擎, 不依赖 daemon 内存。
// Python 侧 §3.3 locked_rmw 两端同形; 跨语言一致性靠 §7 共享验收测试 (drift guard), 非"看起来一样"。
//
// payload 经**文件**传 (避免 argv 长度限/shell 转义): payload_file = JSON。
// op:
//   append  payload={record}                          → 末尾加一行 (热路径, 但仍全量重写保原子; 大文件可优化为锁内 O_APPEND, 见注)
//   append_idem payload={record, idempotency_key, window_ms?, now_ms?}
//                                                      → 锁内先查窗口内同 key 的 live 记录, 命中则不重复 append (deduped),
//                                                        否则 append. 原子去重 (comms-P1 防 hook 双触秒级重复, 避 check-then-append TOCTOU)
//   update  payload={id, mutation, expectedRevision?}  → 找 id, 校验 revision, merge mutation, revision+1
//   prune   payload={now_ms}                           → 删 ripe tombstone (status∈cancelled/deleted && cleanup_after<now)
// 退出码: 0 ok / 3 NOT_FOUND / 4 REVISION_CONFLICT / 5 BAD_OP / 6 IO。结果 JSON 打 stdout。

const fs = require('fs');

function readAll(dataPath) {
  const out = [];
  let raw = '';
  try { raw = fs.readFileSync(dataPath, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  for (const line of raw.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try { out.push(JSON.parse(s)); } catch (_) { /* 容忍 trailing 半行 / 坏行, 跳过 */ }
  }
  return out;
}

// 原子写: tmp + fsync + rename (锁在 sidecar, data rename 安全, INV-4 + INV-6 durability)
function atomicWrite(dataPath, records) {
  const tmp = `${dataPath}.rmw.${process.pid}.${Date.now()}`;
  const body = records.map(r => JSON.stringify(r)).join('\n') + (records.length ? '\n' : '');
  const fd = fs.openSync(tmp, 'w');
  try {
    fs.writeSync(fd, body);
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  fs.renameSync(tmp, dataPath);
  // rename 后 fsync 目录 (INV-6, 确保 rename 持久)
  try { const dfd = fs.openSync(require('path').dirname(dataPath), 'r'); fs.fsyncSync(dfd); fs.closeSync(dfd); } catch (_) {}
}

function main() {
  const [op, dataPath, payloadFile] = process.argv.slice(2);
  if (!op || !dataPath) { process.stdout.write(JSON.stringify({ ok: false, code: 'BAD_OP', error: 'usage: <op> <data_path> <payload_file>' })); process.exit(5); }
  let payload = {};
  if (payloadFile) { try { payload = JSON.parse(fs.readFileSync(payloadFile, 'utf8')); } catch (e) { process.stdout.write(JSON.stringify({ ok: false, code: 'BAD_OP', error: 'payload read: ' + e.message })); process.exit(5); } }

  let records;
  try { records = readAll(dataPath); } catch (e) { process.stdout.write(JSON.stringify({ ok: false, code: 'IO', error: e.message })); process.exit(6); }

  let result;
  if (op === 'append') {
    if (!payload.record) { process.stdout.write(JSON.stringify({ ok: false, code: 'BAD_OP', error: 'append 须 payload.record' })); process.exit(5); }
    records.push(payload.record);
    result = { ok: true, op, id: payload.record.id };
  } else if (op === 'append_idem') {
    // 锁内原子去重 append (comms-P1): 窗口内同 idempotency_key 的 live 记录命中 → 不重复 append, 返 deduped.
    // 终态(failed/rejected/expired/dead)不算 live (允许重发); created_at 须 number(ms) 才参与窗口判定 (否则视为不命中=append).
    if (!payload.record) { process.stdout.write(JSON.stringify({ ok: false, code: 'BAD_OP', error: 'append_idem 须 payload.record' })); process.exit(5); }
    const key = payload.idempotency_key || payload.record.idempotency_key;
    const windowMs = payload.window_ms || 30000;
    const now = payload.now_ms || Date.now();
    if (key) {
      const dup = records.find(r => r.idempotency_key === key
        && r.status !== 'failed' && r.status !== 'rejected' && r.status !== 'expired' && r.status !== 'dead'
        && typeof r.created_at === 'number' && (now - r.created_at) <= windowMs);
      if (dup) { process.stdout.write(JSON.stringify({ ok: true, op, deduped: true, id: dup.id })); process.exit(0); }
    }
    records.push(payload.record);
    result = { ok: true, op, id: payload.record.id, deduped: false };
  } else if (op === 'update') {
    const idx = records.findIndex(r => r.id === payload.id);
    if (idx < 0) { process.stdout.write(JSON.stringify({ ok: false, code: 'NOT_FOUND', id: payload.id })); process.exit(3); }
    const cur = records[idx];
    if (payload.expectedRevision !== undefined && payload.expectedRevision !== null && (cur.revision || 0) !== payload.expectedRevision) {
      process.stdout.write(JSON.stringify({ ok: false, code: 'REVISION_CONFLICT', id: payload.id, stored: cur.revision || 0, expected: payload.expectedRevision, current: cur }));
      process.exit(4);
    }
    const merged = { ...cur, ...(payload.mutation || {}), revision: (cur.revision || 0) + 1, updated_at: payload.now_iso || new Date().toISOString() };
    records[idx] = merged;
    result = { ok: true, op, id: payload.id, revision: merged.revision, record: merged };
  } else if (op === 'prune') {
    const now = payload.now_ms || Date.now();
    let pruned = 0;
    const kept = records.filter(r => {
      const isTomb = r.status === 'cancelled' || r.status === 'deleted';
      const cleanup = r.cleanup_after ? Date.parse(r.cleanup_after) : NaN;
      if (isTomb && Number.isFinite(cleanup) && cleanup < now) { pruned++; return false; }
      return true;
    });
    records = kept;
    result = { ok: true, op, pruned };
  } else {
    process.stdout.write(JSON.stringify({ ok: false, code: 'BAD_OP', error: `unknown op '${op}'` }));
    process.exit(5);
  }

  try { atomicWrite(dataPath, records); } catch (e) { process.stdout.write(JSON.stringify({ ok: false, code: 'IO', error: 'write: ' + e.message })); process.exit(6); }
  process.stdout.write(JSON.stringify(result));
  process.exit(0);
}

main();
