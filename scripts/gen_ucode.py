#!/usr/bin/env python3
"""
gen_ucode.py - generate ikautil_sdram operation-unit microcode from first
principles, cross-checked against the interleaving research spreadsheet
(docs/ikautil_sdram.xlsx). The spreadsheet is the golden reference: any
disagreement is resolved by intersection (both must allow) and reported.

Two variants are emitted:
  DED  - dedicated DQM pins (Analogue Pocket / direct-routed FPGA boards);
         spreadsheet windows verbatim.
  SHR  - MiSTer 128MB module (DQM wired to A[12:11]); ACTIVATE additionally
         forbidden inside any op's DQM-critical window.

Usage: gen_ucode.py [--freq MHZ] [--bl0 N] [--bl1 N] [-o OUT.svh]
No third-party dependencies (xlsx parsed with zipfile + ElementTree).

Microcode word format (18 bits), address = {chip, type[1:0], rw, ctr[3:0]}:
  [2:0]  CMD        0 NOP / 1 ACT / 2 READ / 3 WRITE / 4 PRE / 5 REF
  [3]    DQ_OE      drive write data this cycle
  [4]    DQ_CAP     capture read data register this cycle
  [7:5]  BEAT       data beat index
  [8]    LAST       op ends this cycle, unit frees
  [9]    INH_COL_R_SC   \
  [10]   INH_COL_W_SC    | inhibit a candidate of this class from STARTING
  [11]   INH_ACT_R_SC    | on the NEXT cycle. SC = candidate on same chip,
  [12]   INH_ACT_W_SC    | DC = candidate on the other chip (BL of the
  [13]   INH_COL_R_DC    | other chip is used for DC windows).
  [14]   INH_COL_W_DC    |
  [15]   INH_ACT_R_DC    |
  [16]   INH_ACT_W_DC   /
  [17]   INH_CMD    command bus used on the NEXT cycle (gates PRE/REF micro-ops)

Types: 0 = col (CAS to an open row), 1 = act (ACT + CAS, bank precharged),
       2 = ref (auto refresh, occupies its chip for tRFC), 3 = unused.
Row relatch is issued by the controller as a PRE micro-op followed by a
re-arbitrated act-type op, so it needs no ucode sequence of its own.
"""

import argparse, math, re, sys, zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}

# ----------------------------------------------------------------------------
# timing (AS4C32M16SB-7 / compatible)
T_NS = dict(tRCD=21.0, tRP=21.0, tRRD=14.0, tWR=14.0,
            tRAS=42.0, tRC=63.0, tRFC=63.0)

def cyc(ns, freq):
    return math.ceil(ns * freq / 1000.0 - 1e-9)

class Timing:
    def __init__(self, freq):
        self.freq = freq
        self.CL   = 2 if freq <= 95 else 3
        for k, v in T_NS.items():
            setattr(self, k, cyc(v, freq))

# ----------------------------------------------------------------------------
# op resource model. All cycles relative to op start (= its first command).
class Op:
    def __init__(self, t, kind, rw, bl):
        cl, rcd = t.CL, t.tRCD
        self.kind, self.rw, self.bl = kind, rw, bl
        self.cmd, self.act = set(), set()
        self.rd = self.wr = None            # (first,last) DQ data windows
        self.dqm = None                     # (first,last) DQM-critical window
        if kind == 'col':
            cas = 0
            self.cmd = {0}
        elif kind == 'act':
            cas = rcd
            self.cmd = {0, rcd}
            self.act = {0}
        elif kind == 'ref':
            self.cmd = {0}
            self.length = t.tRFC
            return
        if rw == 'R':
            self.rd  = (cas + cl, cas + cl + bl - 1)
            self.dqm = (cas + cl - 2, cas + cl + bl - 3)
            # capture field lags the resource window by +3: command pin register,
            # SDRAM registration edge, and the controller's DQ capture register
            self.length = self.rd[1] + 4
        else:
            self.wr  = (cas, cas + bl - 1)
            self.dqm = self.wr
            self.length = self.wr[1] + 2

def ov(a, b):
    return a and b and a[0] <= b[1] and b[0] <= a[1]

def legal_start(t, cur, cand, s, samechip, shared_dqm):
    """may op `cand` start s cycles after op `cur` started?"""
    # command bus slots
    if any((c + s) in cur.cmd for c in cand.cmd):
        return False
    if cur.kind == 'ref':
        # refresh occupies its whole chip for tRFC
        if samechip and cand.kind in ('col', 'act') and s < cur.length:
            return False
        return True
    if cand.kind == 'ref':
        return True                          # cmd slot checked above; rest is tracker's job
    sh = lambda w: (w[0] + s, w[1] + s) if w else None
    crd, cwr, cdqm = sh(cand.rd), sh(cand.wr), sh(cand.dqm)
    # DQ bus: no overlap between any data windows
    for a in (cur.rd, cur.wr):
        for b in (crd, cwr):
            if ov(a, b):
                return False
    # read -> write turnaround: one Z cycle after the chip stops driving
    if cur.rd and cwr and cwr[0] < cur.rd[1] + 2:
        return False
    if cur.wr and crd and crd[0] < cur.wr[1] + 1:
        return False
    # a CAS on the same chip truncates an in-flight write burst: forbid while
    # write data may still be real (sheet allows earlier starts because its
    # trailing beats were assumed to be padding; v1 stays data-safe)
    if samechip and cur.wr:
        cas_c = 0 if cand.kind == 'col' else t.tRCD
        if cas_c + s <= cur.wr[1]:
            return False
    # padding beats of a write are DQM-masked at runtime; a candidate read's
    # DQM-low window must not intersect the write's data cycles (any mode)
    if cur.wr and crd and cdqm and ov(cdqm, cur.wr):
        return False
    # cross-chip read -> read driver handover needs a 1-cycle gap
    if not samechip and cur.rd and crd:
        lo, hi = min(cur.rd, crd), max(cur.rd, crd)
        if hi[0] <= lo[1] + 1:
            return False
    # tRRD between ACTs on the same chip
    if samechip:
        for e in cur.act:
            for c in cand.act:
                if abs((c + s) - e) < t.tRRD:
                    return False
    # 128MB module: ACT drives row[12:11] onto the DQM nets (both chips)
    if shared_dqm:
        if cur.dqm and any(cur.dqm[0] <= (c + s) <= cur.dqm[1] for c in cand.act):
            return False
        if cdqm and any(cdqm[0] <= e <= cdqm[1] for e in cur.act):
            return False
    return True

# ----------------------------------------------------------------------------
# spreadsheet parsing (stdlib only)
def col2idx(ref):
    m = re.match(r'([A-Z]+)(\d+)', ref)
    c = 0
    for ch in m.group(1):
        c = c * 26 + ord(ch) - 64
    return c, int(m.group(2))

def load_sheet(path):
    z = zipfile.ZipFile(path)
    shared = []
    if 'xl/sharedStrings.xml' in z.namelist():
        root = ET.fromstring(z.read('xl/sharedStrings.xml'))
        for si in root.findall('m:si', NS):
            shared.append(''.join(x.text or '' for x in si.iter(
                '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t')))
    root = ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
    cells = {}
    for c in root.iter('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c'):
        v = c.find('m:v', NS)
        if v is None:
            continue
        val = shared[int(v.text)] if c.get('t') == 's' else v.text
        cells[col2idx(c.get('r'))] = str(val).strip()
    return cells

# layout constants of ikautil_sdram.xlsx
SECT = {70: 3, 95: 29, 132: 55}             # cycle-header row per speed bin
BLK  = {1: 3, 2: 17, 4: 32, 8: 47}          # base column (cycle 0) per current-op BL

def sheet_windows(cells, r0, bl):
    """returns dict class -> {start cycle -> mark}, plus drawn grid width"""
    base = BLK[bl]
    out = {}
    def grab(rows, marks):
        res = {}
        for r in rows:
            for (c, rr), v in cells.items():
                if rr == r and v in marks and c >= base:
                    res[c - base] = v
        return res
    out['RD_act'] = grab([r0 + 4], ('R', 'RW'))
    out['RD_col'] = grab(range(r0 + 5, r0 + 12), ('ColR', 'ColRW'))
    out['WR_act'] = grab([r0 + 15], ('R', 'RW'))
    out['WR_col'] = grab(range(r0 + 16, r0 + 23), ('ColR', 'ColRW'))
    width = 0
    while (base + width, r0) in cells and cells[(base + width, r0)].isdigit():
        width += 1
    out['width'] = width
    return out

# ----------------------------------------------------------------------------
def build_tables(t, bl_self, bl_other, shared_dqm, sheet, warns, chipname):
    """returns {(type,rw) -> [word,...]} for one chip's ucode"""
    tables = {}
    for kind, tcode in (('col', 0), ('act', 1), ('ref', 2)):
        for rw in ('R', 'W'):
            if kind == 'ref' and rw == 'W':
                continue
            cur = Op(t, kind, rw, bl_self)
            words = []
            for c in range(cur.length):
                w = 0
                # ---- own command / datapath fields
                cmd = 0
                if kind == 'ref' and c == 0:
                    cmd = 5
                elif kind in ('col', 'act'):
                    cas = 0 if kind == 'col' else t.tRCD
                    if kind == 'act' and c == 0:
                        cmd = 1
                    elif c == cas:
                        cmd = 2 if rw == 'R' else 3
                    if cur.wr and cur.wr[0] <= c <= cur.wr[1]:
                        w |= 1 << 3                       # DQ_OE
                        w |= (c - cur.wr[0]) << 5         # BEAT
                    # earliest capture position; the controller delays it by
                    # its CAP_DELAY parameter to match board/clock phase
                    if cur.rd and cur.rd[0] + 1 <= c <= cur.rd[1] + 1:
                        w |= 1 << 4                       # DQ_CAP
                        w |= (c - cur.rd[0] - 1) << 5
                w |= cmd
                if c == cur.length - 1:
                    w |= 1 << 8                           # LAST
                # ---- inhibit vector for candidates starting NEXT cycle (s = c+1)
                s = c + 1
                bit = 9
                for samechip, blc in ((True, bl_self), (False, bl_other)):
                    for ck, cbit in (('col', 0), ('act', 2)):
                        for crw, rbit in (('R', 0), ('W', 1)):
                            cand = Op(t, ck, crw, blc)
                            allowed = legal_start(t, cur, cand, s, samechip, shared_dqm)
                            # golden-sheet intersection: the sheet's rows describe
                            # candidates relative to an act-type op, same chip,
                            # dedicated DQM, within the drawn grid only
                            key = f'{rw}_{ck}'
                            if (not shared_dqm) and samechip and sheet and \
                               kind == 'act' and s < sheet['width']:
                                marks = sheet.get(key, {})
                                sh_ok = (s in marks) and (crw == 'R' or marks[s] in ('RW', 'ColRW'))
                                if sh_ok != allowed:
                                    warns.append(
                                        f'{chipname} f={t.freq} BL={bl_self} cur={kind}{rw} '
                                        f'cand={ck}{crw} s={s}: derived='
                                        f'{"ok" if allowed else "no"} sheet={"ok" if sh_ok else "no"}'
                                        f' -> using intersection')
                                    allowed = allowed and sh_ok
                            if not allowed:
                                w |= 1 << (bit + cbit + rbit)
                        pass
                    bit += 4
                if s in cur.cmd or (kind == 'ref' and s == 0):
                    w |= 1 << 17                          # INH_CMD
                words.append(w)
            tables[(tcode, rw)] = words
    return tables

def emit_svh(freq, t, bls, ded, shr, out):
    """ded/shr: per-chip dicts {(type,rw)->words}"""
    L = []
    L.append('// generated by scripts/gen_ucode.py - DO NOT EDIT')
    L.append(f'// freq={freq}MHz CL={t.CL} tRCD={t.tRCD} tRP={t.tRP} tRRD={t.tRRD}'
             f' tWR={t.tWR} tRAS={t.tRAS} tRC={t.tRC} tRFC={t.tRFC} BL0={bls[0]} BL1={bls[1]}')
    L.append(f'localparam integer UC_FREQ = {freq};')
    L.append(f'localparam integer UC_CL   = {t.CL};')
    for k in ('tRCD', 'tRP', 'tRRD', 'tWR', 'tRAS', 'tRC', 'tRFC'):
        L.append(f'localparam integer UC_{k} = {getattr(t, k)};')
    L.append(f'localparam integer UC_BL0 = {bls[0]};')
    L.append(f'localparam integer UC_BL1 = {bls[1]};')
    for name, chips in (('UCODE_DED', ded), ('UCODE_SHR', shr)):
        rom = [0] * 512
        for chip in (0, 1):
            for (tcode, rw), words in chips[chip].items():
                for i, w in enumerate(words):
                    assert i < 32, 'op longer than 32 cycles'
                    a = (chip << 8) | (tcode << 6) | ((1 if rw == 'W' else 0) << 5) | i
                    rom[a] = w
        L.append(f'localparam bit [17:0] {name} [0:511] = \'{{')
        for i in range(0, 512, 8):
            row = ', '.join(f"18'h{rom[j]:05X}" for j in range(i, i + 8))
            L.append(f'    {row}{"," if i < 504 else ""}')
        L.append('};')
    Path(out).write_text('\n'.join(L) + '\n')

REPORT_LEGEND = """\
HOW TO READ THIS FILE
=====================
This is the human-readable form of the interleaving research in
docs/ikautil_sdram.xlsx as compiled into the operation-unit microcode by
scripts/gen_ucode.py. For every operation type that can be IN FLIGHT it
lists WHEN a new operation may START, in controller clock cycles relative
to the in-flight op's own start (cycle 0 = its first command: ACT for
'act' ops, the READ/WRITE CAS for 'col' ops, AREF for 'ref'). Both ops
reach the SDRAM pins through the same pipeline, so only these relative
numbers matter - the cycle scale is identical to the spreadsheet's own
cycle row.

Sections
  [DED]  dedicated DQM pins (Analogue Pocket / direct-routed chips):
         the spreadsheet windows verbatim (cross-checked cell-by-cell).
  [SHR]  MiSTer 128MB module (chip DQM pins wired to A[12:11]): ACT is
         additionally forbidden while any op needs DQM low, because an
         ACTIVATE would drive its row[12:11] bits onto the DQM nets.
  chipN (BL=x): windows for ops running on chip N with that chip's MRS
         burst length; chip0/chip1 differ when BL0 != BL1.

Current-op line: cur=<kind><R|W>  len=<n>
  colR/colW  CAS-only op to an already-open row   (CAS at cycle 0)
  actR/actW  activate + CAS, bank was precharged  (ACT at 0, CAS at tRCD)
  refR       auto refresh; occupies its whole chip for tRFC
  len        cycles the op occupies an operation unit (data + guard tail)

Candidate rows: <class>_<sc|dc> : list of ALLOWED start cycles s
  A new op of that class may issue its FIRST command s cycles after the
  current op's cycle 0. _sc = candidate on the SAME chip as the current
  op; _dc = candidate on the OTHER chip (computed with the other chip's
  BL; tRRD does not bind across chips, but a 1-cycle DQ handover gap is
  added for cross-chip read-to-read). '-' = never while this op is in
  flight. s runs 1..len; after the op retires (s > len) everything is
  allowed, subject only to the bank tracker guards (tRC/tRAS/tRP/tWR),
  which are enforced separately and NOT encoded in these windows.

A cycle is absent from a row when any of these would be violated:
  command-bus slot conflict; DQ data overlap; read->write turnaround
  (one Z cycle); same-chip CAS would truncate an in-flight write burst;
  candidate read's DQM-low window overlaps a write's (possibly padding-
  masked) data cycles; tRRD (same chip); cross-chip read->read handover;
  [SHR only] candidate ACT falls inside a DQM-critical window.

Correspondence to the spreadsheet (same chip, [DED], cur=actR/actW):
  actX_sc rows = the sheet's 'diff bank' R / RW marks
  colX_sc rows = the sheet's 'same bank col acc' ColR / ColRW marks
  (write windows are guarded slightly harder than the sheet, which
  assumed trailing write beats are padding - see gen_ucode.py header)

Note: in the ucode ROM these windows are stored one word early (word c
gates a start at cycle c+1) because the issue stage decides one cycle
ahead of the op units.
"""

def earliest(words, bit):
    for i, w in enumerate(words):
        if not (w >> bit) & 1:
            return i + 1
    return None

def report(t, bls, tables_by_mode, path):
    L = [f'ucode windows, freq={t.freq} CL={t.CL} (start cycles ALLOWED per candidate class)',
         '', REPORT_LEGEND]
    # worked example from this file's own numbers: chip0, cur=actR, [DED]
    ex = Op(t, 'act', 'R', bls[0])
    words = tables_by_mode['DED'][0][(1, 'R')]
    cyc_row = '  cycle: ' + ' '.join(f'{c:>4d}' for c in range(ex.length))
    cmd_row = '  cmd  : ' + ' '.join(f'{"ACT" if c == 0 else "READ" if c == t.tRCD else "-":>4s}'
                                     for c in range(ex.length))
    dq_row  = '  DQ   : ' + ' '.join(f'{("D" + str(c - ex.rd[0])) if ex.rd[0] <= c <= ex.rd[1] else "-":>4s}'
                                     for c in range(ex.length))
    e_act, e_col, e_cw = earliest(words, 11), earliest(words, 9), earliest(words, 10)
    L += [f'Worked example ([DED] chip0 BL={bls[0]}, cur=actR, len={ex.length}):',
          cyc_row, cmd_row, dq_row,
          f'  actR_sc starts at {e_act}: a same-chip read issues its ACT at {e_act}, its CAS',
          f'  lands at {e_act + t.tRCD} and its data at {e_act + t.tRCD + t.CL}-'
          f'{e_act + t.tRCD + t.CL + bls[0] - 1}, seamlessly after D{bls[0]-1}.',
          f'  colR_sc starts at {e_col}: an open-row read CAS at {e_col} -> data at '
          f'{e_col + t.CL}-{e_col + t.CL + bls[0] - 1}.',
          f'  colW_sc starts at {e_cw}: a write may not drive DQ until one dead cycle',
          f'  after the read data, so the earliest write CAS is {e_cw}.',
          '', '=' * 72]
    for mode, per_chip in tables_by_mode.items():
        for chip in (0, 1):
            for (tcode, rw), words in sorted(per_chip[chip].items()):
                kind = {0: 'col', 1: 'act', 2: 'ref'}[tcode]
                L.append(f'\n[{mode}] chip{chip} (BL={bls[chip]}) cur={kind}{rw} len={len(words)}')
                for lbl, base in (('colR_sc', 9), ('colW_sc', 10), ('actR_sc', 11), ('actW_sc', 12),
                                  ('colR_dc', 13), ('colW_dc', 14), ('actR_dc', 15), ('actW_dc', 16)):
                    ok = [str(i + 1) for i, w in enumerate(words) if not (w >> base) & 1]
                    L.append(f'  {lbl:8s}: {" ".join(ok) if ok else "-"}')
    Path(path).write_text('\n'.join(L) + '\n')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--freq', type=int, default=110)
    ap.add_argument('--bl0', type=int, default=4)
    ap.add_argument('--bl1', type=int, default=4)
    ap.add_argument('--xlsx', default=str(Path(__file__).parent.parent / 'docs/ikautil_sdram.xlsx'))
    ap.add_argument('-o', '--out', default=None)
    ap.add_argument('--report', default=None)
    a = ap.parse_args()
    t = Timing(a.freq)
    out = a.out or str(Path(__file__).parent.parent / f'src/ikautil_sdram_ucode_f{a.freq}.svh')

    cells = load_sheet(a.xlsx)
    # pick the sheet bin whose derived timing matches ours, else skip cross-check
    sheet_bin = None
    for f_ref, r0 in SECT.items():
        tr = Timing(f_ref)
        if (tr.CL, tr.tRCD, tr.tRRD, tr.tWR) == (t.CL, t.tRCD, t.tRRD, t.tWR):
            sheet_bin = r0
            break
    warns = []
    bls = (a.bl0, a.bl1)
    modes = {}
    for mode, shared in (('DED', False), ('SHR', True)):
        per_chip = {}
        for chip in (0, 1):
            sheet = None
            if sheet_bin is not None:
                sw = sheet_windows(cells, sheet_bin, bls[chip])
                sheet = {'R_act': sw['RD_act'], 'R_col': sw['RD_col'],
                         'W_act': sw['WR_act'], 'W_col': sw['WR_col'],
                         'width': sw['width']}
            per_chip[chip] = build_tables(t, bls[chip], bls[1 - chip], shared,
                                          sheet, warns, f'{mode}/chip{chip}')
        modes[mode] = per_chip
    emit_svh(a.freq, t, bls, modes['DED'], modes['SHR'], out)
    report(t, bls, modes, a.report or out.replace('.svh', '_windows.txt'))
    print(f'wrote {out}')
    if sheet_bin is None:
        print(f'NOTE: no sheet bin matches freq={a.freq} timing; cross-check skipped')
    if warns:
        print(f'{len(warns)} sheet/derivation difference(s):')
        for w in warns:
            print('  ' + w)
    else:
        print('sheet cross-check: derivation matches the spreadsheet exactly')

if __name__ == '__main__':
    main()
