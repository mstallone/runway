# Memory Explorer

AI coding agents keep memory and instruction files on disk: Claude Code's per-project memories, Codex's `AGENTS.md`, Gemini's `GEMINI.md`, and so on. The Memory window finds every memory home on your Mac, shows what is inside, and lets you read, edit, create, and delete the files. Everything happens on your Mac. Nothing is sent anywhere.

Open it from the popover footer's **gear** menu (**Memory**), with ⌘M while the popover is showing, or by right-clicking the menu bar icon and choosing **Memory**. It opens in its own resizable window, remembers its size and position, and closes with the red close button, Esc, ⌘W, or ⌘Q. ⌘Q closes only this window. Runway keeps running in the menu bar. Like Settings, the window only exists while it is open.

Discovery does not depend on which providers you have on in Runway. If a harness left memory files on disk, they appear, even if you are logged out of that tool. Harnesses with nothing on disk do not show up. The **Refresh** button re-scans. If a scan runs out of time or some folders cannot be read, the sidebar says so instead of presenting a partial list as complete.

If you renamed a Claude or Codex account card (right-click the card in the popover → **Rename…**), the sidebar shows that name for the matching home and updates when you rename again.

## What each harness supports

| Harness | What appears | Editing |
|---|---|---|
| Claude Code | `CLAUDE.md` plus each project's memory folder (its `MEMORY.md` index and individual memory files) across every config home (`~/.claude`, `~/.claude-personal`, any `CLAUDE_CONFIG_DIR`) | Full: edit, create, and delete memories |
| Codex | `AGENTS.md` and legacy `memories/*.md` files, plus rows from its memory database (`memories_1.sqlite`) | Files are editable. Database rows are read-only |
| Gemini | `GEMINI.md` | Editable |
| Grok | Its `memory/` folder (global and per-project `MEMORY.md`), when the memory feature is enabled | Editable |

Project folders show a decoded project path where possible (for example `/Users/you/Developer/myapp`). When the path cannot be verified on disk, the raw folder name shows instead. This is display-only. The files underneath are always the real ones.

## The four states

Each source is in one of four states. The sidebar ranks them: sources with content first, then homes with nothing in them yet, then harnesses whose memory feature is off. Within each group the usual provider order applies (Claude, Codex, then alphabetical). Click a section header to collapse it. Sources with content start expanded, and so does any source with a problem to show (an unreadable file, a scan failure). The rest start collapsed, because their badge already says what is going on.

- **Ready**: memory files exist and have content. No badge.
- **Empty**: the file exists but is blank (common for a fresh `GEMINI.md`). You can start writing right away.
- **No File**: the harness's home is there but its instruction file is not, and there are no other memory files.
- **Memory Disabled**: the harness is installed but its memory feature is off (for example, Codex with `use_memories = false` in its config, or Grok without a `[memory]` section). The sidebar says which switch is off and where it lives. Runway shows the state and never turns the feature on for you. A Grok home with memory on but no files yet shows **No File** instead, with the usual create option.

An instruction file that does not exist yet can be created from the window. The **Create Instruction File** row appears whenever the file is absent, whether the source shows **No File** or is **Ready** from other memory files.

## Editing and saving

Nothing saves automatically. These files are shared with live agent processes, so changes only land when you press **Save** (⌘S). The button lights up when you have unsaved edits. Closing the window, switching documents, pressing **Refresh**, or quitting Runway with unsaved edits asks first (Save, Discard, or Cancel). Every save first checks whether the file changed or disappeared on disk. If it did, the editor shows the Reload / Overwrite banner instead of writing. Only the banner's **Overwrite** writes over a moved file.

Because an agent can write the same file while you have it open, Runway checks the file on disk before saving and whenever the window comes back to the front:

- **File changed on disk, no unsaved edits**: your view reloads to the new content.
- **File changed on disk, unsaved edits**: a banner offers **Reload** (drop your edits, load the disk version) or **Overwrite** (save your version anyway).

Saving preserves the file's existing permissions.

## Creating and deleting memories

Claude Code keeps a `MEMORY.md` index alongside its memory files, and Runway keeps the two in sync:

- **New Memory…** on a project asks for a title, description, and type, then writes the new file and adds its line to the index (creating `MEMORY.md` first if needed).
- **Delete** on a memory (with confirmation) removes the file and drops its line from the index.

Editing a memory's text does not rewrite its index line. If you change a title by hand, update the index line too.

## The read-only database view

Codex also distills memories into a local database. Runway lists those entries and shows each one's content (the raw memory and its session summary) but never writes to the database. Rows carry a Read-Only badge and have no Save or Delete.

## Agents write these files too

A running agent session can rewrite memory files at any moment. The changed-on-disk check is best-effort: it runs on save and window focus, not the instant a change happens. When an agent is actively working in a project, prefer reading over editing until it is done.
