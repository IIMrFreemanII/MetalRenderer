#!/usr/bin/env python3
"""A car model's glTF (.glb) as CarPack reads it: its nodes with meshes, each one's world box (metres, the model's own
axes), triangles and materials; then its materials. For writing and checking a model's entry in CarPack.entries (which
nodes are the wheels, the doors, the hood, the glass, the lamps, and which are variants to leave out).

    Tools/cars/inspect.py Assets/Cars/skoda_karoq.glb [--all] [--grep door]

Only nodes with a mesh are listed (--all: every node), a variant's duplicates side by side with their boxes. Reads the
file only.
"""
import argparse
import json
import re
import struct


def read(path):
    with open(path, 'rb') as f:
        f.read(12)
        length, _ = struct.unpack('<II', f.read(8))
        return json.loads(f.read(length))


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def local(node):
    if 'matrix' in node:
        m = node['matrix']
        return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
    t = node.get('translation', [0, 0, 0])
    x, y, z, w = node.get('rotation', [0, 0, 0, 1])
    s = node.get('scale', [1, 1, 1])
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[r[i][0] * s[0], r[i][1] * s[1], r[i][2] * s[2], t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('path')
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--grep', default=None)
    a = parser.parse_args()
    j = read(a.path)
    nodes, meshes, accessors, materials = j['nodes'], j.get('meshes', []), j['accessors'], j.get('materials', [])
    rows = []

    def visit(i, parent, depth):
        node = nodes[i]
        world = matmul(parent, local(node))
        name = node.get('name', f'node {i}')
        if 'mesh' in node:
            lo, hi, tris, mats = [1e9] * 3, [-1e9] * 3, 0, set()
            for p in meshes[node['mesh']]['primitives']:
                acc = accessors[p['attributes']['POSITION']]
                if 'indices' in p:
                    tris += accessors[p['indices']]['count'] // 3
                if 'material' in p:
                    mats.add(materials[p['material']].get('name', '?'))
                mn, mx = acc.get('min'), acc.get('max')
                if mn is None:
                    continue
                for cx in (mn[0], mx[0]):
                    for cy in (mn[1], mx[1]):
                        for cz in (mn[2], mx[2]):
                            q = [sum(world[r][k] * v for k, v in enumerate((cx, cy, cz, 1))) for r in range(3)]
                            lo = [min(lo[k], q[k]) for k in range(3)]
                            hi = [max(hi[k], q[k]) for k in range(3)]
            rows.append((depth, name, lo, hi, tris, sorted(mats)))
        elif a.all:
            rows.append((depth, name, None, None, 0, []))
        for c in node.get('children', []):
            visit(c, world, depth + 1)

    identity = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    for r in j['scenes'][j.get('scene', 0)]['nodes']:
        visit(r, identity, 0)
    total = 0
    for depth, name, lo, hi, tris, mats in rows:
        if a.grep and not re.search(a.grep, name, re.I):
            continue
        total += tris
        box = '' if lo is None else ' x %6.2f..%6.2f  y %6.2f..%6.2f  z %6.2f..%6.2f' % (lo[0], hi[0], lo[1], hi[1], lo[2], hi[2])
        print('%s%-44s%s %7d  %s' % ('  ' * min(depth, 4), name[:44], box, tris, ', '.join(mats)[:90]))
    print(f'{total} triangles listed')
    print('materials:', ', '.join(f"{k}:{m.get('name', '?')}" for k, m in enumerate(materials)))


if __name__ == '__main__':
    main()
