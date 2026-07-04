# RTL_SKILLS — hardware-first RTL design and timing-closure skills

Two Claude Code skills that teach the model to write and optimize RTL the way an
experienced FPGA engineer does: think in logic levels and wires (not lines of code),
speculate-and-select instead of serializing decisions, and drive optimization from
fitter/STA reports through a disciplined measurement loop.

Everything here is **device- and vendor-agnostic**. Device-specific numbers (LUT width,
levels-per-ns, RAM primitive timing) live in a per-project `device-notes.md` that you
fill in once per target; every procedure references those parameters, never hardcoded
values.

## Layout

```
RTL_SKILLS/
├── rtl-design/                     # fires when WRITING or MODIFYING HDL
│   ├── SKILL.md                    # cost model, hard rules, STOP gates, workflow
│   └── references/
│       ├── pattern-catalog.md      # named transformations w/ before-after code
│       ├── datasheet-to-rtl.md     # spec extraction, per-edge dataflow table
│       ├── style-conformance.md    # conventions-digest procedure
│       ├── verification-gates.md   # green-before-optimized, exact-equality gates
│       └── device-notes-template.md# per-target parameter sheet (fill in once)
└── rtl-timing/                     # fires on Fmax / timing closure / STA work
    ├── SKILL.md                    # the optimization loop, escalation ladder
    └── references/
        ├── sdc-truth.md            # constraint audit + trap list
        ├── report-literacy.md      # path anatomy, cone classes, noise floor
        ├── optimization-loop.md    # full round protocol, stopping criteria
        ├── campaign-log-template.md# per-round log the model must maintain
        └── flow-config-template.md # one-command OOC flow, per-tool recipes
```

## Installation

Claude Code discovers skills in `.claude/skills/` (project) or `~/.claude/skills/`
(user-global). Copy or symlink each skill directory:

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/RTL_SKILLS/rtl-design" ~/.claude/skills/rtl-design
ln -s "$(pwd)/RTL_SKILLS/rtl-timing" ~/.claude/skills/rtl-timing
```

## First use in a new project

1. Copy `rtl-design/references/device-notes-template.md` to the project as
   `device-notes.md` and fill in the target's parameters (datasheet + one test fit).
2. Copy `rtl-timing/references/flow-config-template.md` and script the one-command
   OOC flow for your tool.
3. The skills do the rest: they gate RTL writing on a conventions digest and a
   per-edge dataflow table, and gate optimization on an audited SDC and a measured
   noise floor.
