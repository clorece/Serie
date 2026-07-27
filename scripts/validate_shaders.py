#!/usr/bin/env python3
"""Offline compile check for every Iris entry point in shaders/world0.

    python3 scripts/validate_shaders.py [--verbose] [--baseline REF]

Iris only reports the FIRST program that fails to compile, and only once the
pack is loaded in-game, so a typo in a shared header costs a full round trip
through Minecraft to find. This flattens each entry point into one translation
unit and runs glslangValidator over it, which finds the same class of error in a
couple of seconds.

Three things this has to emulate, all learned the hard way:

  1. An #include line must contain NOTHING after the closing quote. Iris takes
     the rest of the line as part of the path, so `#include "/lib/x.glsl" // why`
     silently fails to resolve at pack load. Reported here as an error.

  2. Includes dedupe per COMPILE CYCLE, not globally. Iris compiles the vertex
     and fragment stages separately with VERTEX / FRAGMENT defined, so a header
     pulled in under `#ifdef VERTEX` must still be available to the fragment
     cycle. This resolves those two symbols BEFORE deduping, which deletes the
     dead branch so a single global dedupe becomes correct. Skipping this drops
     /lib/options.glsl from the fragment cycle of every program whose vertex
     branch included it first, and reports it as a pile of undeclared-identifier
     errors nowhere near the cause.

  3. The pack declares `uniform sampler2D texture`, which shadows the GLSL
     built-in. Iris renames it at load; glslang cannot, and aborts at the first
     sample, hiding the whole rest of the program. The variable is renamed here
     so type checking actually reaches the code under test.

Known-failing programs are listed in EXPECTED_FAILURES below: they reference
uniforms Iris injects for Distant Horizons that do not exist as source. Anything
failing OUTSIDE that list is a real regression.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

INC = re.compile(r'^\s*#include\s+"([^"]*)"(.*)$')
COND = re.compile(r'^\s*#(ifdef|ifndef|else|endif|if)\b(.*)$')
# A bare `texture` NOT followed by "(" is the pack's sampler uniform, not the
# built-in function.
TEX_VAR = re.compile(r'\btexture\b(?!\s*\()')

STAGE_SYMS = {'VERTEX', 'FRAGMENT'}
STAGE_OF_EXT = {'.vsh': ('vert', 'VERTEX'),
                '.fsh': ('frag', 'FRAGMENT'),
                '.csh': ('comp', 'COMPUTE_SHADER')}

# Programs that cannot compile offline because they reference Iris-injected
# Distant Horizons uniforms / macros that have no declaration in the pack.
EXPECTED_FAILURES = {
    'world0/dh_terrain.vsh', 'world0/dh_terrain.fsh',
    'world0/dh_water.vsh', 'world0/dh_water.fsh',
    'world0/composite7.fsh',
}


class Flattener:
    def __init__(self, root, cycle):
        self.root = root
        self.cycle = cycle
        self.seen = set()
        self.bad_includes = []

    def resolve_stage(self, lines):
        """Drop the #ifdef VERTEX / #ifdef FRAGMENT branch this cycle won't see."""
        out, stack = [], []          # entries: None (leave alone) or bool (emitting)
        for line in lines:
            m = COND.match(line)
            if m:
                kw, rest = m.group(1), m.group(2).strip()
                if kw in ('ifdef', 'ifndef') and rest in STAGE_SYMS:
                    live = (rest == self.cycle) if kw == 'ifdef' else (rest != self.cycle)
                    stack.append(live)
                    continue
                if kw in ('ifdef', 'ifndef', 'if'):
                    stack.append(None)
                elif kw == 'else' and stack and stack[-1] is not None:
                    stack[-1] = not stack[-1]
                    continue
                elif kw == 'endif' and stack:
                    if stack.pop() is not None:
                        continue
            if all(s is not False for s in stack):
                out.append(line)
        return out

    def flatten(self, path, origin=None):
        try:
            src = open(path, encoding='utf-8', errors='replace').read().splitlines()
        except FileNotFoundError:
            self.bad_includes.append(f"{origin}: missing include -> {path}")
            return [f"// MISSING {path}"]

        out = []
        for ln, line in enumerate(self.resolve_stage(src), 1):
            m = INC.match(line)
            if not m:
                out.append(line)
                continue
            inc, trailing = m.group(1), m.group(2)
            if trailing.strip():
                self.bad_includes.append(
                    f"{path}:{ln}: trailing content after #include -- Iris reads it "
                    f"as part of the path and will fail to resolve: {line.strip()!r}")
            target = os.path.normpath(os.path.join(self.root, inc.lstrip('/')))
            if target in self.seen:
                out.append(f"// (already included) {inc}")
                continue
            self.seen.add(target)
            out.extend(self.flatten(target, origin=path))
        return out


def check(shaders_dir, entry, keep_dir=None):
    ext = os.path.splitext(entry)[1]
    stage, cycle = STAGE_OF_EXT[ext]

    f = Flattener(shaders_dir, cycle)
    text = "\n".join(f.flatten(os.path.join(shaders_dir, entry)))
    text = TEX_VAR.sub('mcTexture', text)

    out_dir = keep_dir or tempfile.gettempdir()
    flat_path = os.path.join(out_dir, entry.replace('/', '_') + '.' + stage)
    with open(flat_path, 'w') as fh:
        fh.write(text + "\n")

    proc = subprocess.run(['glslangValidator', '-S', stage, flat_path],
                          capture_output=True, text=True)
    errors = [l for l in (proc.stdout + proc.stderr).splitlines()
              if l.startswith('ERROR:') and 'compilation errors' not in l]
    return f.bad_includes, errors, flat_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shaders', default=None, help='path to the shaders/ directory')
    ap.add_argument('--verbose', action='store_true', help='show every error, not just the first')
    ap.add_argument('--keep', default=None, help='directory to keep flattened sources in')
    args = ap.parse_args()

    shaders = args.shaders or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'shaders')
    world = os.path.join(shaders, 'world0')
    entries = sorted('world0/' + n for n in os.listdir(world)
                     if os.path.splitext(n)[1] in STAGE_OF_EXT)

    clean = regressions = 0
    for entry in entries:
        bad_inc, errors, _ = check(shaders, entry, args.keep)
        for b in bad_inc:
            print(f"INCLUDE  {b}")
            regressions += 1
        if not errors:
            clean += 1
            if args.verbose:
                print(f"ok       {entry}")
            continue
        expected = entry in EXPECTED_FAILURES
        tag = "known   " if expected else "FAIL    "
        if not expected:
            regressions += 1
        shown = errors if args.verbose else errors[:1]
        print(f"{tag} {entry}")
        for e in shown:
            print(f"         {e}")

    print(f"\n{clean}/{len(entries)} programs compile clean "
          f"({len(EXPECTED_FAILURES)} known-failing excluded).")
    if regressions:
        print(f"{regressions} unexpected failure(s).")
    return 1 if regressions else 0


if __name__ == '__main__':
    sys.exit(main())
