#!/usr/bin/env python3
"""hangrun.py <tag> <runs> KEY=VALUE... : runs the release binary offscreen N times, counts runs with a GPU hang.

Logs and <tag>.txt go to $OUT (default $TMPDIR/metal4-hang); BIN overrides the binary. Every KEY=VALUE is passed on
(METALRENDERER_BENCH is required: runs are offscreen benchmarks). A run with no results (a crash, a failed start)
counts as failed. Example (metal4-hang-handoff.md):
  hangrun.py base 60 METALRENDERER_BENCH=particles METALRENDERER_BENCH_ONLY=metal4 METALRENDERER_API=metal4
"""
import os, re, subprocess, sys, time
tag, runs, *kv = sys.argv[1:]
repo = subprocess.run(['git', '-C', os.path.dirname(os.path.abspath(__file__)), 'rev-parse', '--show-toplevel'],
                      capture_output=True, text=True).stdout.strip()
binary = os.environ.get('BIN', repo + '/.build/release/MetalRenderer')
out = os.environ.get('OUT', os.path.join(os.environ.get('TMPDIR', '/tmp'), 'metal4-hang'))
os.makedirs(out, exist_ok=True)
env = dict(os.environ)
for a in kv:
    k, v = a.split('=', 1); env[k] = v
assert 'METALRENDERER_BENCH' in env
hung = 0
summary = open(f'{out}/{tag}.txt', 'w')
for r in range(int(runs)):
    log = f'{out}/{tag}-{r}.log'
    t = time.time()
    with open(log, 'w') as f:
        try:
            subprocess.run([binary], env=env, stdout=f, stderr=subprocess.STDOUT, cwd=repo, timeout=900)
            status = 'ok'
        except subprocess.TimeoutExpired:
            status = 'TIMEOUT'
    text = open(log, errors='replace').read()
    n = text.count('Caused GPU Hang')
    if status == 'ok' and not re.search(r'^metal[34] |^[a-z]+ \d+ +\d+×', text, re.M) and 'GPU times are medians' not in text:
        status = 'NO-RESULTS'   # crashed or never rendered: not a clean run
    first = re.search(r'command buffer ([\w ]+?) failed', text)
    # which setting it was in: the last results row before the first failure
    before = text[:first.start()] if first else ''
    rows = re.findall(r'^benchmark: (.*)$', before, re.M)
    line = f'{tag} run {r}: {status} {time.time()-t:.0f}s hangs {n}' + (f' first {first.group(1)} after {rows[-1] if rows else "(start)"}' if first else '')
    hung += n > 0 or status != 'ok'
    print(line, flush=True); summary.write(line + '\n'); summary.flush()
line = f'== {tag}: {hung} of {runs} runs hung'
print(line); summary.write(line + '\n')
