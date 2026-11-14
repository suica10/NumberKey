// Source-level work counts, not a Swift allocation profiler or latency benchmark.
// Run from any directory: node scripts/verify_rerank_mask.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const fixture = JSON.parse(readFileSync(new URL('../Tests/rerank_fixture.json', import.meta.url), 'utf8'));
const source = readFileSync(new URL('../Keyboard/RerankScorer.swift', import.meta.url), 'utf8');
assert(source.includes('var active = [Bool](repeating: false, count: n)'));
assert(source.includes('for i in 0..<n { active[i] = t < ids[i].count - 1 }'));
assert(!source.includes('let active: [Bool] = ids.map'));
let comparisons = 0;
function verify(strings) {
    // Swift uses Unicode scalars, not UTF-16 code units or grapheme clusters.
    const lengths = strings.map(s => Math.min([...s].length, 62) + 2);
    const steps = Math.max(0, ...lengths.map(n => n - 1));
    const reused = Array(strings.length).fill(false);
    for (let t = 0; t < steps; t++) {
        const fresh = lengths.map(n => t < n - 1);
        for (let i = 0; i < lengths.length; i++) reused[i] = t < lengths[i] - 1;
        assert.deepEqual(reused, fresh);
        comparisons += lengths.length;
    }
    return { before: steps, after: strings.length ? 1 : 0, writes: steps * strings.length };
}
let before = 0, after = 0, writes = 0;
for (const item of fixture) {
    const result = verify(item.candidates);
    before += result.before; after += result.after; writes += result.writes;
}
// Mixed lengths exercise true -> false transitions and the 62-scalar cap.
verify([]);
verify(Array.from({length: 66}, (_, i) => 'あ'.repeat(i)));
verify(['', '😀', 'e\u0301', '👨‍👩‍👧‍👦', 'あ'.repeat(100)]);
console.log(JSON.stringify({fixtureBatches: fixture.length, maskConstructionsBefore: before,
    maskConstructionsAfter: after, removed: before - after,
    fixtureBooleanWritesBeforeAndAfter: writes, predicateComparisons: comparisons,
    caveat: 'Source-level counts only. Swift tests, heap allocations, RSS and latency are not measured.'}, null, 2));
