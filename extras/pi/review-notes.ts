/**
 * Review Notes Extension
 *
 *   /review [request] - Review code and append findings as [draft] notes to the
 *                       review notes file. The request is free text (scope, ticket,
 *                       focus, blast radius); depth follows the blast radius, and
 *                       risky changes pause for a go-ahead. Default scope =
 *                       uncommitted changes when there are any, else the branch
 *                       against its MR target.
 *   /fixup [scope]    - Address the open review notes (all, or those on the given
 *                       files/directories): notes on code become fixup! commits;
 *                       handled notes are resolved with a reply; unclear ones
 *                       get a question under them instead of a chat
 *                       round-trip, as [draft]. Requires no changes to
 *                       tracked files.
 *
 * Review notes, shared with the nvim plugin (review-notes.nvim, format in
 * lua/review_notes/notes.lua): code in a git worktree is reviewed in
 * $(git rev-parse --git-path review)/<branch>.txt, which the plugin syncs with
 * the remote; any file outside git (e.g. a markdown draft) in a sibling
 * <file>.notes, local only. For a file outside git /review and /fixup take
 * the document (its path, its .notes file, or outside a repo a description of
 * it), and fixups are edits in place: there is no version control to commit to.
 *
 * Handover rule: the human and the agent take turns on the same branch, and
 * commits are the only handover, so /fixup on code refuses to start on a dirty
 * tree and never mixes its edits with uncommitted human work.
 *
 * Entries pi adds or changes in a notes file are tagged [new] when the run
 * settles (by this extension, not the model), so the editor shows what to
 * look at after a round.
 */

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";

// Same entry syntax as the nvim plugin (notes.lua): a location, or none for a
// general entry (about the whole change).
const ENTRY_RE = /^([^\s#>:\\][^\s:]*):(\d+)(?:-(\d+))?:[ \t]?(.*)$/;

interface NoteEntry {
  path?: string; // none: a general entry
  loc?: string; // "path:line" or "path:first-last", as written
  text: string; // first line without tags
  resolved: boolean;
  draft: boolean; // not approved yet: never sent, never addressed
  id?: string; // remote thread id
  body: string[]; // indented lines without their two-space indent
}

// Body lines lose exactly their two-space indent (code in a note keeps its own
// indentation); hand-written lines with another indent are trimmed. Same rule
// as notes.lua.
const dedent = (line: string): string => {
  const m = /^(?:  |\t)(.*)$/.exec(line);
  return (m ? m[1]! : line.trim()).trimEnd();
};

// Tags after the location (or at the start of a general entry), in any
// order: [resolved] [draft] [id:X] [new].
const TAG_RE = /^\[(resolved|draft|new|id:[^\]]+)\]\s*/;


export default function reviewNotes(pi: ExtensionAPI) {
  const git = (cwd: string, ...args: string[]): string | undefined => {
    try {
      return execFileSync("git", args, {
        cwd,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
    } catch {
      return undefined;
    }
  };

  // During a rebase HEAD is detached; the branch being rebased is still the
  // one whose notes apply (same fallback in git-lab and nvim).
  const getBranch = (cwd: string): string | undefined => {
    const branch = git(cwd, "branch", "--show-current");
    if (branch) return branch;
    for (const dir of ["rebase-merge", "rebase-apply"]) {
      const file = git(cwd, "rev-parse", "--path-format=absolute", "--git-path", `${dir}/head-name`);
      try {
        if (file) return readFileSync(file, "utf8").trim().replace(/^refs\/heads\//, "");
      } catch {}
    }
    return undefined;
  };

  // Commands send a prompt, which pi rejects while the agent is running.
  const requireIdle = (command: string, ctx: ExtensionCommandContext): boolean => {
    if (ctx.isIdle()) return true;
    ctx.ui.notify(`pi is busy -- run /${command} when the current run has finished.`, "warning");
    return false;
  };

  // Handover rule: commands that commit never mix their edits with uncommitted
  // human work. A rebase stop can have a clean tree, but commits made there
  // land in the middle of the rewritten history. Untracked files cannot leak
  // into commits (the agent stages by path), so only tracked changes block.
  const requireCleanTree = (cwd: string, command: string, ctx: ExtensionCommandContext): boolean => {
    const rebasing = ["rebase-merge", "rebase-apply"].some((dir) => {
      const path = git(cwd, "rev-parse", "--path-format=absolute", "--git-path", dir);
      return !!path && existsSync(path);
    });
    if (rebasing) {
      ctx.ui.notify(`/${command} commits: finish or abort the rebase first.`, "warning");
      return false;
    }
    // Untracked files inside a submodule are as harmless as at the top level.
    const dirty = git(cwd, "status", "--porcelain", "--ignore-submodules=untracked")
      ?.split("\n")
      .filter((l) => l.trim() !== "" && !l.startsWith("??"));
    if (!dirty || dirty.length === 0) return true;
    const shown = dirty.slice(0, 10).join("\n");
    const more = dirty.length > 10 ? `\n... and ${dirty.length - 10} more` : "";
    ctx.ui.notify(
      `/${command} needs a clean working tree -- commit (e.g. a fixup! or wip: ` +
        `commit) or stash your changes first:\n${shown}${more}`,
      "warning",
    );
    return false;
  };

  const getNotesPath = (cwd: string): string | undefined => {
    const dir = git(cwd, "rev-parse", "--path-format=absolute", "--git-path", "review");
    return dir ? join(dir, `${getBranch(cwd) ?? "HEAD"}.txt`) : undefined;
  };

  // ---------------------------------------------------------------------------
  // Review notes
  // ---------------------------------------------------------------------------
  const readText = (p: string): string => {
    try {
      return readFileSync(p, "utf8");
    } catch {
      return "";
    }
  };

  interface Head {
    path?: string; // none: a general entry
    loc?: string; // "path:line" or "path:first-last", as written
    tags: string[]; // "resolved", "draft", "new", "id:X", in file order
    text: string; // after the tags
    tagsEnd: number; // offset in the line where the tags end
  }

  // The head of an entry: a location line, else (*general*) any line, whose
  // leading `\\` escapes text that would read as a location or tag.
  const parseHead = (line: string, general: boolean): Head | undefined => {
    let m = ENTRY_RE.exec(line);
    // `.:0:` is the old way of writing a general entry.
    const old = m !== null && m[1] === "." && m[2] === "0" && !m[3];
    if (old && !general) return undefined;
    if (old) m = null;
    if (!m && !general) return undefined;
    let text = m ? m[4]! : old ? line.replace(/^\.:0:[ \t]?/, "") : line;
    const tags: string[] = [];
    for (let tag = TAG_RE.exec(text); tag; tag = TAG_RE.exec(text)) {
      tags.push(tag[1]!);
      text = text.slice(tag[0].length);
    }
    const tagsEnd = line.length - text.length;
    if (!m) return { tags, text: text.replace(/^\\/, ""), tagsEnd };
    const loc = `${m[1]}:${m[2]}${m[3] ? `-${m[3]}` : ""}`;
    return { path: m[1]!, loc, tags, text, tagsEnd };
  };

  // Entries with their raw body lines (indented or blank), same scan as
  // notes.lua: a `#` line ends the entry; any other unindented line starts
  // one, except that the lines of a hand-written paragraph are one general
  // note.
  const parseEntries = (text: string): { index: number; head: Head; body: string[] }[] => {
    const out: { index: number; head: Head; body: string[] }[] = [];
    let cur: (typeof out)[number] | undefined;
    let blank = false;
    text.split("\n").forEach((line, index) => {
      const located = parseHead(line, false);
      if (located) {
        cur = { index, head: located, body: [] };
        out.push(cur);
      } else if (cur && (/^\s/.test(line) || !line.trim())) {
        cur.body.push(line);
        if (!line.trim()) blank = true;
        return;
      } else if (line.startsWith("#")) {
        cur = undefined;
      } else if (cur && !cur.head.path && !cur.head.tags.some((t) => t.startsWith("id:")) && !blank && !line.startsWith("[")) {
        cur.body.push(line);
      } else {
        cur = { index, head: parseHead(line, true)!, body: [] };
        out.push(cur);
      }
      blank = false;
    });
    return out;
  };

  const readNotes = (notesFile: string): NoteEntry[] =>
    parseEntries(readText(notesFile)).map(({ head, body }) => ({
      path: head.path,
      loc: head.loc,
      text: head.text,
      resolved: head.tags.includes("resolved"),
      draft: head.tags.includes("draft"),
      id: head.tags.find((t) => t.startsWith("id:"))?.slice(3),
      body: body.filter((l) => l.trim()).map(dedent),
    }));

  // Whatever pi writes on an open entry is [draft], so a [draft] entry waits
  // for me and every other open entry is pi's: no turn tracking.
  const needsPi = (n: NoteEntry): boolean => !n.resolved && !n.draft;

  // Scope: empty = everything, otherwise whitespace-separated files or
  // directories, relative to the cwd or absolute.
  const inScope = (note: NoteEntry, scope: string, root: string, cwd: string): boolean => {
    if (!scope) return true;
    return scope.split(/\s+/).some((raw) => {
      const tok = relative(root, resolve(cwd, expandHome(raw)));
      if (note.path === undefined) return false;
      return tok === "" || note.path === tok || note.path.startsWith(tok + "/");
    });
  };

  const reportNothingForPi = (all: NoteEntry[], where: string, ctx: ExtensionCommandContext): void => {
    const drafts = all.filter((n) => !n.resolved && n.draft).length;
    const pending = drafts ? `: ${drafts} [draft] entr${drafts === 1 ? "y" : "ies"} to approve or resolve.` : ".";
    ctx.ui.notify(`Nothing for pi ${where}${pending}`, "info");
  };

  // ---------------------------------------------------------------------------
  // Prompt pieces. Prompts are for the agent: terse rules, no rationale (that
  // lives in these comments). The extension decides which notes are in a
  // /fixup round, so the agent never interprets scopes or draft rules.
  // ---------------------------------------------------------------------------
  const NOTES_FORMAT =
    "Notes format: an unindented line starts an entry; two-space-indented lines continue it. " +
    "`path:line: text` or `path:first-last: text` is about code, `path:0: text` about a whole " +
    "file; a line without a location is a general entry, about the whole change (a leading " +
    "`\\` escapes text that would read as a location or tag). Tags come first: after the " +
    "location, or at the start of a general entry, in this order: [resolved] [draft] [id:X] " +
    "[new]. Body lines starting with `>` are replies from others (the remote, or yours as " +
    "`> @pi:`); other body lines are mine (`\\>` is a literal `>`). `#` lines are comments. " +
    "Never touch [new] tags.";

  const label = (n: NoteEntry): string => n.loc ?? `general: "${n.text.slice(0, 60)}"`;

  const onlyThese = (selected: NoteEntry[]): string =>
    "Handle only these entries; leave all others as they are:\n" + selected.map((n) => `- ${label(n)}`).join("\n");

  const RESOLVE_RULES = [
    "Read every listed note and the general entries before changing anything.",
    "My lines after a `> @pi:` line are my answer, or why I reopened the note.",
    "Note handled: insert `[resolved] ` where the tags start and append `  > @pi: <what changed, one line>`.",
    "Note unclear, or you disagree: change nothing, append `  > @pi: <question>`, insert `[draft] ` where the tags start, go on. Do not ask in the chat.",
    "Keep every entry and their order.",
  ];

  const bullets = (lines: string[]): string => lines.map((l) => `- ${l}`).join("\n");

  // FIX/CHECK must say how the problem triggers: unfalsifiable "might break"
  // findings waste the human's review time.
  const findingTags = (limit: string, trigger = true): string =>
    "Tag each finding: FIX (blocking), CHECK (likely blocking, needs verification), CONSIDER " +
    "(design), QUESTION (could not determine), NIT (non-blocking). " +
    (trigger ? "FIX and CHECK name the input, path or state that triggers the problem. " : "") +
    `${limit} Skip findings without a concrete action.`;

  // [draft] keeps findings from being sent or fixed until the human approves
  // them (removes the tag) or rejects them (resolves the entry).
  const appendFindings = (notesFile: string, header: string[], path: string, rules: string[]): string =>
    `Append to \`${notesFile}\` (create it if missing). Never change existing content; skip ` +
    "findings already in it, open or resolved. Shape:\n\n```\n" +
    [...header, "# <2-3 lines of assessment>"].join("\n") +
    `\n\n${path}:<line>: [draft] <TAG>: <actionable, 1-2 sentences>\n  <optional detail, two-space indent>\n\n` +
    `${path}:<first>-<last>: [draft] <TAG>: <...>\n\n` +
    `${path}:0: [draft] <TAG>: <about the whole file>\n\n` +
    "[draft] <TAG>: <about the whole change: a general entry, no location>\n```\n\n" +
    bullets([
      ...rules,
      "A finding about the whole change is a general entry, about a whole file `<path>:0`; never only in the `#` assessment.",
      "Blank line between entries; every entry keeps [draft].",
    ]);

  const VERDICT = "<ready | minor fixes | needs changes | major concerns>";

  // ---------------------------------------------------------------------------
  // Documents outside git: sibling notes, and finding the document an argument
  // refers to.
  // ---------------------------------------------------------------------------
  const NOTES_EXT = ".notes";
  const siblingNotes = (doc: string): string => doc + NOTES_EXT;
  const docOf = (notesFile: string): string => notesFile.slice(0, -NOTES_EXT.length);

  const isFile = (path: string): boolean => {
    try {
      return statSync(path).isFile();
    } catch {
      return false;
    }
  };

  const expandHome = (p: string): string => (p === "~" || p.startsWith("~/") ? join(homedir(), p.slice(1)) : p);

  const worktreeOf = (path: string): string | undefined =>
    git(dirname(path), "rev-parse", "--show-toplevel");

  const shortPath = (cwd: string, p: string): string => {
    const rel = relative(cwd, p);
    if (!rel.startsWith("..")) return rel;
    const home = homedir();
    return p.startsWith(home + "/") ? "~" + p.slice(home.length) : p;
  };

  // Files the agent read, edited or wrote in this session, most recent first:
  // "the doc we are editing" is one of them.
  const sessionFiles = (ctx: ExtensionCommandContext): string[] => {
    const seen = new Set<string>();
    const out: string[] = [];
    const entries = ctx.sessionManager.getBranch() as any[];
    for (let i = entries.length - 1; i >= 0; i--) {
      const msg = entries[i]?.type === "message" ? entries[i].message : undefined;
      if (msg?.role !== "assistant" || !Array.isArray(msg.content)) continue;
      for (const c of msg.content) {
        const path = c?.type === "toolCall" && ["read", "edit", "write"].includes(c.name) ? c.arguments?.path : undefined;
        if (typeof path !== "string") continue;
        const abs = resolve(ctx.cwd, expandHome(path));
        if (!seen.has(abs) && isFile(abs)) {
          seen.add(abs);
          out.push(abs);
        }
      }
    }
    return out;
  };

  // The document an argument names: a path to it or to its .notes file, else a
  // description, resolved against *candidates* (asking when there are several).
  // Never guessed by the model: fixups outside git edit in place, unversioned.
  const resolveDoc = async (
    arg: string,
    candidates: string[],
    ctx: ExtensionCommandContext,
    command: string,
  ): Promise<string | undefined> => {
    const abs = resolve(ctx.cwd, expandHome(arg));
    if (isFile(abs)) return abs.endsWith(NOTES_EXT) ? docOf(abs) : abs;
    const unique = [...new Set(candidates)];
    if (unique.length === 1) return unique[0];
    if (unique.length === 0) {
      ctx.ui.notify(
        `/${command}: could not tell which document "${arg}" means -- pass its path, e.g. /${command} notes.md`,
        "warning",
      );
      return undefined;
    }
    const labels = unique.map((p) => shortPath(ctx.cwd, p));
    const choice = await ctx.ui.select(`/${command}: which document is "${arg}"?`, labels);
    const index = choice ? labels.indexOf(choice) : -1;
    return index < 0 ? undefined : unique[index];
  };

  // Documents in the cwd that have notes (doc.md for doc.md.notes).
  const notedDocsIn = (dir: string): string[] => {
    try {
      return readdirSync(dir)
        .filter((f) => f.endsWith(NOTES_EXT))
        .map((f) => docOf(join(dir, f)));
    } catch {
      return [];
    }
  };

  // ---------------------------------------------------------------------------
  // Marking what pi changed: a notes file is snapshotted before the agent can
  // touch it (when a command hands it over, or right before an edit/write tool
  // call on it) and compared when the run settles. Snapshots last one run, so
  // my own edits between runs are never mistaken for pi's. Added or changed
  // entries get [new]; moved locations alone do not count.
  // ---------------------------------------------------------------------------
  const snapshots = new Map<string, string>();

  const isNotesFile = (p: string): boolean => p.endsWith(NOTES_EXT) || /\/\.git\/(.*\/)?review\/.+\.txt$/.test(p);

  const snapshot = (p: string): void => {
    if (!snapshots.has(p)) snapshots.set(p, readText(p));
  };

  // An entry is identified across edits by its path and text without tags; it
  // changed when its state tags or body did ([new] itself does not count).
  const entryKey = (h: Head): string => `${h.path ?? ""}\0${h.text}`;
  const entrySig = (h: Head, body: string[]): string =>
    h.tags.filter((t) => t !== "new").sort().join(" ") + "\n" + body.join("\n").trimEnd();

  // Tag what changed in *p* since *before*; returns how many entries.
  const markChanges = (p: string, before: string): number => {
    const after = readText(p);
    if (after === before) return 0;
    const old = new Map<string, string[]>();
    for (const { head, body } of parseEntries(before)) {
      old.set(entryKey(head), [...(old.get(entryKey(head)) ?? []), entrySig(head, body)]);
    }
    const lines = after.split("\n");
    let changed = 0;
    for (const { index, head, body } of parseEntries(after)) {
      if (old.get(entryKey(head))?.shift() === entrySig(head, body)) continue;
      if (head.tags.includes("new")) continue;
      // Tags are written in the order [resolved] [draft] [id:X] [new].
      const line = lines[index]!;
      lines[index] = `${line.slice(0, head.tagsEnd)}[new] ${line.slice(head.tagsEnd)}`;
      changed++;
    }
    if (changed > 0) writeFileSync(p, lines.join("\n"));
    return changed;
  };

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    const path = (event.input as { path?: unknown }).path;
    if (typeof path !== "string") return;
    const abs = resolve(ctx.cwd, expandHome(path));
    if (isNotesFile(abs)) snapshot(abs);
  });

  pi.on("agent_settled", async (_event, ctx) => {
    let changed = 0;
    for (const [p, before] of snapshots) {
      try {
        changed += markChanges(p, before);
      } catch {}
    }
    snapshots.clear();
    if (changed > 0) {
      ctx.ui.notify(`Review notes: ${changed} note${changed === 1 ? "" : "s"} marked [new].`, "info");
    }
  });

  // ---------------------------------------------------------------------------
  // Document reviews (outside git)
  // ---------------------------------------------------------------------------
  // The document outside git that *arg* is about, undefined when the command
  // is about the branch (the git flow), null when it cannot go on (already
  // reported). Inside a repo only an explicit path outside the worktree
  // counts; outside a repo the argument is required and may
  // also be a description, matched against the files of this session and
  // the cwd's documents with notes. *needNotes*: only documents that have a
  // .notes file (/fixup).
  const documentTarget = async (
    arg: string,
    ctx: ExtensionCommandContext,
    command: string,
    needNotes: boolean,
  ): Promise<string | undefined | null> => {
    const inRepo = git(ctx.cwd, "rev-parse", "--show-toplevel") !== undefined;
    const outsideGit = (p: string) => !worktreeOf(p);
    const withNotes = (p: string) => !needNotes || isFile(siblingNotes(p));
    let doc: string | undefined;
    if (inRepo) {
      const abs = arg ? resolve(ctx.cwd, expandHome(arg)) : "";
      if (!arg || !isFile(abs)) return undefined;
      const target = abs.endsWith(NOTES_EXT) ? docOf(abs) : abs;
      if (!outsideGit(target)) return undefined;
      doc = target;
    } else {
      if (!arg) {
        const docs = notedDocsIn(ctx.cwd);
        ctx.ui.notify(
          `/${command} outside a git repository needs the document: a path, its .notes file, ` +
            `or a description of it` +
            (docs.length ? ` (documents with notes here: ${docs.map((d) => basename(d)).join(", ")}).` : "."),
          "warning",
        );
        return null;
      }
      const candidates = [...sessionFiles(ctx), ...notedDocsIn(ctx.cwd)].filter(
        (p) => !p.endsWith(NOTES_EXT) && outsideGit(p) && withNotes(p),
      );
      doc = await resolveDoc(arg, candidates, ctx, command);
    }
    if (!doc) return null;
    if (!isFile(doc)) {
      ctx.ui.notify(`/${command}: ${shortPath(ctx.cwd, doc)} does not exist.`, "warning");
      return null;
    }
    if (needNotes && !isFile(siblingNotes(doc))) {
      ctx.ui.notify(`/${command}: ${shortPath(ctx.cwd, doc)} has no notes (${basename(siblingNotes(doc))}).`, "warning");
      return null;
    }
    return doc;
  };

  const reviewDocument = (doc: string): void => {
    const notesFile = siblingNotes(doc);
    const name = basename(doc);
    snapshot(notesFile);
    pi.sendUserMessage(`Review the document \`${doc}\` as an editor and domain expert. Do not edit it.

1. Read it and what it references. Check claims in a design or proposal against the code.
2. Look for, in priority order: wrong or unverifiable claims, gaps and missing cases, contradictions, unclear structure or reasoning, wording. ${findingTags("At most 10 findings, highest priority first.", false)}
3. ${appendFindings(notesFile, [`# pi review (<YYYY-MM-DD HH:MM>): ${VERDICT}`], name, [
      `Path: the bare file name \`${name}\`. Verify line numbers by reading the file.`,
    ])}
4. Print the notes path and counts per tag. Stop.`);
  };

  const fixupDocument = (doc: string, ctx: ExtensionCommandContext): void => {
    const notesFile = siblingNotes(doc);
    const name = basename(doc);
    const all = readNotes(notesFile);
    const selected = all.filter(needsPi);
    if (selected.length === 0) {
      reportNothingForPi(all, `in ${basename(notesFile)}`, ctx);
      return;
    }
    snapshot(notesFile);
    pi.sendUserMessage(`Address my review notes on \`${doc}\`. Notes: \`${notesFile}\` (paths are \`${name}\`).

${onlyThese(selected)}

${NOTES_FORMAT}

The document is not versioned: edit it in place, smallest change per note, no reformatting or unrelated rewording. No git.

${bullets([
      ...RESOLVE_RULES,
      "After editing, update the line numbers of handled and open entries whose text moved.",
      "End by printing one line per note: what changed, or the question.",
    ])}`);
  };

  // ---------------------------------------------------------------------------
  // /review
  //
  // Findings are appended to the notes file as `[draft]` entries, next to the
  // human's own notes. `[draft]` means "not approved yet": pushing and /fixup
  // skip those entries until the human removes the tag (approve) or resolves
  // the entry (reject), so every finding gets read against the code.
  //
  // The argument is free text (scope, ticket, focus, blast radius), read by the
  // model. No plan: the reviewer judges the code against the problem, not
  // against the approach the author already settled on. Depth follows the
  // blast radius; a radius the human states is followed, never re-checked.
  // ---------------------------------------------------------------------------
  pi.registerCommand("review", {
    description:
      "Review code and append findings as [draft] notes to the review notes file. " +
      "The argument is free text: scope, ticket, focus, blast radius (e.g. 'last 3 commits, " +
      "see KAT-1234, core change'). Default scope = uncommitted changes when there are " +
      "any, else the branch against its MR target. A document outside git (its path, or " +
      "outside a repo a description of it) is reviewed into its sibling .notes file. " +
      "Usage: /review [request]",
    handler: async (args, ctx) => {
      if (!requireIdle("review", ctx)) return;
      const arg = args.trim();
      const doc = await documentTarget(arg, ctx, "review", false);
      if (doc === null) return;
      if (doc) {
        reviewDocument(doc);
        return;
      }
      const branch = getBranch(ctx.cwd) ?? "HEAD";
      const notesFile = getNotesPath(ctx.cwd);
      if (!notesFile) {
        ctx.ui.notify("/review needs a git repository, or a document: /review <file>.", "warning");
        return;
      }

      snapshot(notesFile);

      const request = arg ? `Request (scope, ticket, focus, depth):\n${arg}` : "Request: none.";

      pi.sendUserMessage(`Review code on branch \`${branch}\` as a strict senior engineer. Much of it is AI-generated: expect reinvented wheels, needless code, tests that check the wrong thing. Change no code; findings go to the notes file.

${request}

Scope: what the request names (git range, commits, paths); else uncommitted changes including untracked files; else the branch against \`git-lab mr target\`. Ask if unclear.

1. Intent. Read the change and enough context. Print one line per changed file, then its purpose in 1-2 sentences. Sources: a ticket in the request (read via Jira, read-only; say if it fails), the request, the code. Still unclear: stop and ask. Never infer it from branch names or commit subjects.
2. Depth. Depth stated in the request is a given: use it, do not re-check. Elsewhere, per changed area: dependents (LSP references, grep), public API, shared or core modules, persisted formats, config, build. Reach, not diff size. Always risky: security, concurrency, migrations and stored data, error and cleanup paths. Mark each area light or deep.
3. If your own estimate finds a wide or unclear radius or a risky area: stop and report the radius with evidence (e.g. "\`Parser::parse\`: 40 callers in 6 modules"), the deep/light split, and only questions that would change the review. My answer is a given. Otherwise go on.
4. Review. All areas:
- Bugs against the intent.
- Reuse: for each new function, type, constant or pattern, search the codebase, dependencies and stdlib for an equivalent (by name, concept, what it calls). A near match is a finding: use or extend it. Cite \`path:line\` and what it lacks.
- Consistency with the surrounding code and closest siblings: naming, structure, error handling, logging, ownership, test layout. Modernise only where clearly simpler or safer; never two styles for one thing in a file. Cite the pattern as \`path:line\`. NIT; CONSIDER if it adds a second way of doing something.
- Removal: dead code, checks for impossible cases, swallowed errors, unused parameters, single-use abstractions, unrequested shims, comments restating code.
- Simplicity: a simpler design meeting the current requirement (fewer layers, function over class, stdlib over custom, less generality). Name it.
- Language rules, new or changed code only; confirm in the body first; one entry per rule per file:
  - C++ const: never-modified locals, parameters, references, pointers, members; non-mutating methods; \`constexpr\` for compile-time constants. NIT.
  - C++ copies: non-trivial types copied where a reference does (read-only by-value parameters, \`for (auto x : c)\`, read-only copies of members or map values, sink parameters without \`std::move\`). Not cheap types (scalars, raw pointers, \`string_view\`, \`span\`, small trivially copyable) or needed copies. NIT; CONSIDER on hot paths.
  - Python defaults that are mutable or evaluated once (\`[]\`, \`{}\`, \`set()\`, instances, \`datetime.now()\`, dataclass fields without \`default_factory\`). FIX if mutated, stored or returned; else NIT.
- Tests: do they pin down the new behaviour? Missing proof is a finding; do not write it.
Deep areas also:
- Contracts: every dependent still holds (invariants, defaults, errors, formats, ordering).
- Missing changes: other call sites, sibling implementations, config, docs, migrations, error paths.
- Break it: boundaries, empty input, failure midway, cleanup, concurrency, reentrancy, resource ownership.
- Parallel mechanisms the change could merge with an existing one: CONSIDER, follow-up if beyond scope.
- Tests: right level (logic unit-tested, wiring integration-tested), fail if reverted, no mocking the unit under test, no asserts on implementation details, parametrize copies, beyond the happy path.
Submodule pointer changes: \`git diff --submodule=log\` over the scope. The new commit is the intended one (request, ticket), fast-forward from the old one, pushed upstream; the superproject changes it needs are in. Findings on the submodule path at line 1.
Verify by reading and by running existing relevant tests (none if unsure). No new tests.

${findingTags("Report every FIX, CHECK and QUESTION; of CONSIDER and NIT the 5 most valuable, with the number left out in the assessment.")}

5. ${appendFindings(
        notesFile,
        [
          `# pi review of <scope> (<YYYY-MM-DD HH:MM>): ${VERDICT}`,
          "# depth: <light | mixed | wide> (<stated | estimated>): <what is deep, what is light>",
        ],
        "<path>",
        [
          "The file is inside .git: never commit it.",
          "Paths repo-relative; line numbers from the working tree, verified by reading.",
          "Wording ready to post to a colleague: specific, polite, no IDs, no mention of this prompt.",
        ],
      )}
6. Print the notes path, the depth line and counts per tag. Stop: no commits, no git-lab.`);
    },
  });

  // ---------------------------------------------------------------------------
  // /fixup
  //
  // Review feedback travels as text, never as edits in the tree: notes are
  // buffered in the notes file and addressed here in one go. Notes on code
  // become fixup! commits for the commit they belong to. Handled notes are
  // resolved with a reply rather than deleted, like a GitLab thread, so
  // the human can check the claim and reopen the note.
  // ---------------------------------------------------------------------------
  pi.registerCommand("fixup", {
    description:
      "Address the open review notes: notes on code become fixup! commits, notes on a " +
      "document outside git are edited in place; both are resolved with a reply. Scope: " +
      "files/directories, or a document outside git (its path, its .notes file, or outside " +
      "a repo a description); none = all open notes of the branch. Notes on code need a " +
      "clean tree. Usage: /fixup [scope]",
    handler: async (args, ctx) => {
      if (!requireIdle("fixup", ctx)) return;
      const doc = await documentTarget(args.trim(), ctx, "fixup", true);
      if (doc === null) return;
      if (doc) {
        fixupDocument(doc, ctx);
        return;
      }
      const branch = getBranch(ctx.cwd) ?? "HEAD";
      const notesFile = getNotesPath(ctx.cwd);
      const root = git(ctx.cwd, "rev-parse", "--show-toplevel");
      if (!notesFile || !root) {
        ctx.ui.notify(
          "/fixup outside a git repository needs the document: /fixup <file>, its .notes file, " +
            "or a description of it.",
          "warning",
        );
        return;
      }

      const scope = args.trim();
      const all = readNotes(notesFile).filter((n) => inScope(n, scope, root, ctx.cwd));
      const selected = all.filter(needsPi);
      if (selected.length === 0) {
        const where = `in the review notes${scope ? ` (scope "${scope}")` : ""}`;
        reportNothingForPi(all, where, ctx);
        return;
      }
      if (!requireCleanTree(ctx.cwd, "fixup", ctx)) return;
      snapshot(notesFile);

      pi.sendUserMessage(`Address my review notes on branch \`${branch}\`. Notes: \`${notesFile}\` (inside .git, never commit it; paths repo-relative).

${onlyThese(selected)}

${NOTES_FORMAT} Entries with [id:X] are remote threads.

Per note: find the code from the note's text (line numbers drift), make the smallest fix, build and test per the project's instructions, commit as \`fixup! <subject>\` of the branch commit that introduced the code, staging only your changes (notes on one commit may share a fixup). Notes on a whole file (\`path:0\`) and general entries are fixups too: of the branch commit closest in topic, else the latest one. A note on a submodule path is about the pointer: fetch in the submodule, check out the ref it asks for (unclear: treat the note as unclear), build and test, stage the submodule path; never commit inside the submodule unless the note says so. These commits are requested; never rebase, amend, squash or push; never run git-lab.

${bullets([
        ...RESOLVE_RULES,
        "Threads ([id:X]) instead: your lines are replies to the reviewer, so no `> @pi:` lines. Handled: add a reply line (two-space indent, no `>`) saying what changed, and insert `[resolved] [draft] ` after the location. Unclear: add a reply line asking the reviewer, and insert `[draft] `.",
        "No commit SHAs in the notes (they change on squash).",
        "End with no uncommitted changes to tracked files and no new untracked files of yours.",
        "Print one line per note: fixup target commit, or the question.",
      ])}`);
    },
  });
}
