# SourCe

SourCe is a bright C++/Objective-C++ macOS code editor tuned for
SuperCollider (`.scd`, `.sc`) and ChucK (`.ck`). It renders source as a
multi-colored blocky code field with layered animated feedback trails. The
visual system is driven by the buffer itself: token kinds, characters, line
hashes, bracket structure, cursor state, dirty state, runner output, and the
app's own process memory footprint. It uses those signals to make scanline
strata, readable glyph fragments, and a live memory map in the background
layers. It also includes a live minimap and ships with a C++ highlighter so the
editor can open and colorize its own source code.

## Build

```sh
cd "/Users/user/Documents/SourCe"
cmake -S . -B build
cmake --build build
```

Run it:

```sh
cd "/Users/user/Documents/SourCe"
./build/SourCe examples/neon.scd
./build/SourCe examples/pulse.ck
./build/SourCe --self
```

## Controls

| Key | Action |
| --- | --- |
| `Command-S` | Save |
| `Command-O` | Open file |
| `Command-F` | Search |
| `Command-G` | Next search match |
| `Command-J` | Go to line |
| `Command-I` | Toggle process map |
| `Command-Z` / `Command-Shift-Z` | Undo / redo |
| `Command-A/C/X/V` | Select all / copy / cut / paste |
| `Command-K` | Toggle syntax fold |
| `Command-[` / `Command-]` | Previous / next file tab |
| `Command-E` | Evaluate selection or current line |
| `Command-B` | Evaluate current block |
| `Command-R` | Run with `sclang` or `chuck` if installed |
| `Command-T` | Stop the running sketch |
| `Command-L` | Cycle language mode |
| `Command-Y` | Open and highlight this editor's own source |
| `Command-D` | Duplicate line |
| `Command-/` | Toggle line comment |
| `Command-P` | Command palette |
| `Command-+/-` | Zoom text |

The editor includes line numbers, search highlights, bracket matching,
auto-pairs, auto-indent, mouse scrolling, file dialogs, a runner output panel,
command prompts, undo/redo, keyboard and mouse selection with clipboard
support, file tabs, find/replace via the command
palette, syntax fold markers, runner error line highlighting, evaluate
selection/current-line/current-block commands, dirty-state tracking,
insert/delete traces, self-source annotations, a `Command-I` process map,
45/90-degree source-derived video-feedback trail motion, live CPU/draw/memory
history, and colorful tokenization for SuperCollider, ChucK, and C++.

Use `Command-P` and type `replace` to enter replacements as `old => new`.
Use the tabs to move between open buffers, and `Command-J` to jump quickly
through longer live-code files.
