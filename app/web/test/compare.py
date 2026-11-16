"""Compare web recognizePageData results with saved Android results (not deployed).

  python apps/choir_mobile/web/test/compare.py [--web work/web-parity/out/web300]
      [--android work/parity-exp/speed/emu/android300] [songs...] [--verbose]

Per page: staff count, token edit distance per staff, crops/lines, warnings,
systems, dropped staves, and token places (count, snapped agreement, max
coordinate difference over tokens that align between the two decodes).
"""
from __future__ import annotations

import argparse
import difflib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


def edit_distance(a: list, b: list) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]


def tokens(staff: dict) -> list[tuple]:
    return [tuple(s[:6]) for s in staff['symbols']]


def place_diff(a, b) -> float:
    """Max |difference| over x, y and line heights of two places."""
    m = 0.0
    for k in [0, 1] + list(range(4, max(len(a), len(b)))):
        va = a[k] if k < len(a) else None
        vb = b[k] if k < len(b) else None
        if va is None and vb is None:
            continue
        if va is None or vb is None:
            return float('inf')
        m = max(m, abs(va - vb))
    return m


def match_staves(web: dict, ref: dict) -> list[tuple[int, int]]:
    """Pairs (web index, android index) of staves whose top lines are within half a staff."""
    pairs, used = [], set()
    for i, ws in enumerate(web['staves']):
        for j, rs in enumerate(ref['staves']):
            sp = (rs['lines'][4] - rs['lines'][0]) / 4
            if j not in used and abs(ws['lines'][0] - rs['lines'][0]) <= 2 * sp:
                pairs.append((i, j)); used.add(j)
                break
    return pairs


def mapped_systems(web: dict, pairs: list[tuple[int, int]]) -> list:
    """Web systems with staff indices renamed to the matching Android staves (unmatched removed)."""
    to_ref = dict(pairs)
    out = []
    for s in web.get('systems', []):
        staves = [to_ref[i] for i in s['staves'] if i in to_ref]
        if staves:
            out.append({**s, 'staves': staves})
    return out


def compare_page(web: dict, ref: dict, verbose: bool) -> dict:
    out = {'staves': (len(web['staves']), len(ref['staves']))}
    pairs = match_staves(web, ref)
    dist, total = [], 0
    geo = 0.0
    crops = 0
    places = {'web': 0, 'ref': 0, 'aligned': 0, 'snap_diff': 0, 'max': 0.0, 'over2': 0}
    for i, j in pairs:
        ws, rs = web['staves'][i], ref['staves'][j]
        tw, tr = tokens(ws), tokens(rs)
        dist.append(edit_distance(tw, tr))
        total += len(tr)
        geo = max(geo, abs(ws['left'] - rs['left']), abs(ws['right'] - rs['right']),
                  *(abs(a - b) for a, b in zip(ws['lines'], rs['lines'])))
        crops += ws['crop'] != rs['crop']
        if 'places' in web and 'places' in ref:
            pw, pr = web['places'][i], ref['places'][j]
            places['web'] += sum(p is not None for p in pw)
            places['ref'] += sum(p is not None for p in pr)
            for block in difflib.SequenceMatcher(a=tw, b=tr, autojunk=False).get_matching_blocks():
                for k in range(block.size):
                    a, b = pw[block.a + k], pr[block.b + k]
                    if a is None or b is None:
                        continue
                    places['aligned'] += 1
                    places['snap_diff'] += a[3] != b[3]
                    d = place_diff(a, b)
                    places['max'] = max(places['max'], d)
                    if d > 2:
                        places['over2'] += 1
                        if verbose:
                            print(f'      staff {i} token {block.a + k} {tw[block.a + k][:2]} web {a} android {b}')
    to_ref = dict(pairs)
    exact = len(pairs) == len(web['staves']) == len(ref['staves'])
    systems_same = web.get('systems') == ref.get('systems') if exact else mapped_systems(web, pairs) == ref.get('systems')
    dropped_web = sorted(to_ref[i] for i in web['layout']['dropped_staves'] if i in to_ref)
    out.update(dist=dist, tokens=total, geo=geo, crops=crops, places=places, matched=len(pairs),
               systems=systems_same,
               dropped=dropped_web == ref['layout']['dropped_staves'],
               warnings=web['warnings'] == ref['warnings'], height=(web['height'], ref['height']))
    if verbose and not out['systems']:
        print('      systems web', web.get('systems'), '\n      systems and', ref.get('systems'))
    if verbose and not out['warnings']:
        print('      warnings web', web['warnings'], '\n      warnings and', ref['warnings'])
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('songs', nargs='*')
    parser.add_argument('--web', type=Path, default=ROOT / 'work/web-parity/out/web300')
    parser.add_argument('--android', type=Path, default=ROOT / 'work/parity-exp/speed/emu/android300')
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()
    songs = args.songs or sorted(p.name for p in args.web.iterdir() if p.is_dir())
    grand = {'pages': 0, 'tokens': 0, 'dist': 0, 'systems': 0, 'dropped': 0}
    for song in songs:
        ref_pages = json.loads((args.android / song / 'recognized-pages.json').read_text(encoding='utf-8'))
        for n, ref in enumerate(ref_pages, 1):
            path = args.web / song / f'page-{n}.json'
            if not path.exists():
                continue
            web = json.loads(path.read_text(encoding='utf-8'))
            r = compare_page(web, ref, args.verbose)
            p = r['places']
            print(f"{song:12s} p{n:<2d} h={r['height'][0]}/{r['height'][1]} staves={r['staves'][0]}/{r['staves'][1]}"
                  f"{'' if r['matched'] == r['staves'][0] == r['staves'][1] else ' matched=%d' % r['matched']} "
                  f"edit={sum(r['dist'])}/{r['tokens']} {r['dist']} geoΔ={r['geo']:.2f} crops≠{r['crops']} "
                  f"systems={'ok' if r['systems'] else 'DIFF'} dropped={'ok' if r['dropped'] else 'DIFF'} "
                  f"warnings={'ok' if r['warnings'] else 'DIFF'} "
                  f"places={p['web']}/{p['ref']} aligned={p['aligned']} snap≠{p['snap_diff']} max={p['max']:.1f} >2px={p['over2']}")
            grand['pages'] += 1
            grand['tokens'] += r['tokens']
            grand['dist'] += sum(r['dist'])
            grand['systems'] += r['systems']
            grand['dropped'] += r['dropped']
    print(f"TOTAL pages={grand['pages']} edit={grand['dist']}/{grand['tokens']} "
          f"systems ok={grand['systems']}/{grand['pages']} dropped ok={grand['dropped']}/{grand['pages']}")


if __name__ == '__main__':
    main()
