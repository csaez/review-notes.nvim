/**
 * Review Notes Extension
 *
 *   /review [request] - Review code and append findings as proposed comments
 *                       to the review notes file. The request is free text (scope,
 *                       ticket, focus, blast radius); depth follows the blast
 *                       radius, and risky changes pause for a go-ahead. Default
 *                       scope = uncommitted changes when there are any, else the
 *                       branch against its MR target.
 *   /fixup [scope]    - Address the open review threads (all, or those on the given
 *                       files/directories): threads on code become fixup! commits;
 *                       handled threads get a proposed reply and a resolve;
 *                       unclear ones get a proposed question instead of a chat
 *                       round-trip. Requires no changes to tracked files.
 *
 * Review notes, shared with the nvim plugin (review-notes.nvim, format in
 * lua/review_notes/store.lua): code in a git worktree is reviewed in
 * $(git rev-parse --git-common-dir)/review/<branch>.md, which the plugin syncs
 * with the remote; any file outside git (e.g. a markdown draft) in a sibling
 * <file>.review.md, local only. For a file outside git /review and /fixup
 * take the document (its path, its .review.md file, or outside a repo a
 * description of it), and fixups are edits in place: there is no version
 * control to commit to.
 *
 * Everything pi writes is a `### me (proposed)` comment: the plugin never
 * publishes it until the human approves it, so a round of pi can run at any
 * time, even while peers comment. `### me (note)` is the human writing to pi
 * only; the plugin never publishes it. /fixup is for the human's own branch:
 * on a peer's MR (the sidecar's mr.author is not mr.me) it refuses. Resolving a thread is `status: resolved` on
 * it, held back by the plugin until the proposed reply is approved.
 *
 * Handover rule: the human and the agent take turns on the same branch, and
 * commits are the only handover, so /fixup on code refuses to start on a dirty
 * tree and never mixes its edits with uncommitted human work.
 */

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";

interface Comment {
  who: string; // "@alice", "me (local)", "me (proposed)", "me (note)"
  proposed: boolean; // written by a tool, waits for approval
  mine: boolean; // mine, not published yet (local or note)
  note: boolean; // mine, for the agent only: never published
  published: boolean; // a remote comment of mine ({mine}, or @<me>)
  body: string;
}

// What the plugin's sidecar (<branch>.json) knows of the MR: who wrote it,
// and my user name. No mr: the branch has no MR yet.
interface MrRecord {
  author?: string;
  me?: string;
  ref?: string;
}

interface Thread {
  anchor: string; // "change", "path", "path:N" or "path:N-M", as written
  path?: string; // none: the whole change
  resolved: boolean;
  id?: string; // remote thread id
  comments: Comment[];
}

const HEADING_RE = /^(#{2,3})\s+(.*?)\s*(?:\{([^{}]*)\})?\s*$/;

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

  // Under the common git dir, shared by every worktree: the review belongs to
  // the branch, and `git worktree remove` deletes a worktree's own git dir.
  // Same path as the plugin, which also moves notes from the old place.
  const getNotesPath = (cwd: string): string | undefined => {
    const dir = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir");
    return dir ? join(dir, "review", `${getBranch(cwd) ?? "HEAD"}.md`) : undefined;
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

  const parseThreads = (text: string): Thread[] => {
    const out: Thread[] = [];
    let thread: Thread | undefined;
    let comment: Comment | undefined;
    let sawStatus = false;
    for (const line of text.split("\n")) {
      const h = HEADING_RE.exec(line);
      if (h && h[1] === "##") {
        const anchor = h[2]!;
        const attrs = h[3] ?? "";
        thread = {
          anchor,
          path: anchor === "change" ? undefined : anchor.replace(/:\d+(-\d+)?$/, ""),
          resolved: false,
          id: /(?:^|\s)id=(\S+)/.exec(attrs)?.[1],
          comments: [],
        };
        out.push(thread);
        comment = undefined;
        sawStatus = false;
      } else if (h && h[1] === "###" && thread) {
        const who = h[2]!;
        const note = who === "me (note)";
        comment = {
          who,
          proposed: who === "me (proposed)",
          mine: note || who === "me" || who === "me (local)",
          note,
          published: /(?:^|\s)mine(?:\s|$)/.test(h[3] ?? ""),
          body: "",
        };
        thread.comments.push(comment);
      } else if (thread) {
        const status = !comment && !sawStatus ? /^status:\s*(\w+)\s*$/.exec(line) : null;
        if (status) {
          thread.resolved = status[1] === "resolved";
          sawStatus = true;
        } else if (comment) {
          comment.body += (comment.body ? "\n" : "") + line.replace(/^\\(\\*#)/, "$1");
        } else if (line.trim()) {
          // Bare text under a thread is one local comment, as in the plugin.
          comment = { who: "me (local)", proposed: false, mine: true, note: false, published: false, body: line };
          thread.comments.push(comment);
        }
      }
    }
    for (const t of out) for (const c of t.comments) c.body = c.body.trim();
    return out;
  };

  const readThreads = (notesFile: string): Thread[] => {
    const threads = parseThreads(readText(notesFile));
    const mr = readMr(notesFile);
    if (mr?.me) {
      for (const t of threads) for (const c of t.comments) if (c.who === `@${mr.me}`) c.published = true;
    }
    return threads;
  };

  const readMr = (notesFile: string): MrRecord | undefined => {
    try {
      const side = JSON.parse(readFileSync(notesFile.replace(/\.md$/, ".json"), "utf8"));
      return side && typeof side.mr === "object" && side.mr ? side.mr : undefined;
    } catch {
      return undefined;
    }
  };

  // Whose turn it is, from the thread and the MR. Pi's when the thread is open
  // and the last word that is not pi's asks it to act:
  // - a note (`me (note)`): written for pi, always;
  // - my unpublished comment: only before the MR (then it can only be for pi);
  //   after, it is going to a peer;
  // - a peer's comment: only on my own MR (*mine*), where pi plays the author.
  // My published comment last means the thread waits for the peer. A fresh
  // finding (a single proposed comment, from /review) is pi's too: it acts on
  // its own findings by severity, with no approval step. After pi answers (a
  // proposed reply last, or a resolve), the thread waits for me.
  const needsPi = (t: Thread, mr: MrRecord | undefined): boolean => {
    if (t.resolved || t.comments.length === 0) return false;
    const last = t.comments[t.comments.length - 1]!;
    if (last.proposed) return t.comments.length === 1;
    if (last.note) return true;
    if (last.mine) return !mr;
    if (last.published) return false;
    return !mr || isMyMr(mr);
  };

  // No author or user name known (an older sidecar): assume mine, as before.
  const isMyMr = (mr: MrRecord): boolean => !mr.author || !mr.me || mr.author === mr.me;

  const SEVERITY_RE = /^\s*(FIX|CHECK|CONSIDER|QUESTION|NIT)\b/;

  // The severity a thread was filed with: the first tag in the conversation.
  const severityOf = (t: Thread): string | undefined => {
    for (const c of t.comments) {
      const m = SEVERITY_RE.exec(c.body);
      if (m) return m[1];
    }
    return undefined;
  };

  // Scope: empty = everything, otherwise whitespace-separated files or
  // directories, relative to the cwd or absolute.
  const inScope = (note: Thread, scope: string, root: string, cwd: string): boolean => {
    if (!scope) return true;
    return scope.split(/\s+/).some((raw) => {
      const tok = relative(root, resolve(cwd, expandHome(raw)));
      if (note.path === undefined) return false;
      return tok === "" || note.path === tok || note.path.startsWith(tok + "/");
    });
  };

  // On a peer's MR, my open threads that the author answered since my last
  // word: /review checks each against the code before looking for new
  // findings. Mine: I started it (published, local or a note).
  const threadsToRecheck = (notesFile: string): Thread[] => {
    const mr = readMr(notesFile);
    if (!mr || isMyMr(mr)) return [];
    return readThreads(notesFile).filter((t) => {
      if (t.resolved || !t.id || t.comments.length === 0) return false;
      const first = t.comments[0]!;
      if (!(first.published || first.mine)) return false;
      const last = t.comments[t.comments.length - 1]!;
      return !last.proposed && !last.published && !last.mine;
    });
  };

  const reportNothingForPi = (
    all: Thread[],
    mr: MrRecord | undefined,
    where: string,
    ctx: ExtensionCommandContext,
  ): void => {
    const waiting = all.filter((t) => !t.resolved && !needsPi(t, mr)).length;
    const pending = waiting ? `: ${waiting} open thread${waiting === 1 ? "" : "s"} waiting for you or a peer.` : ".";
    ctx.ui.notify(`Nothing for pi ${where}${pending}`, "info");
  };

  // ---------------------------------------------------------------------------
  // Prompt pieces. Prompts are for the agent: terse rules, no rationale (that
  // lives in these comments). The extension decides which notes are in a
  // /fixup round, so the agent never interprets scopes or draft rules.
  // ---------------------------------------------------------------------------
  const NOTES_FORMAT =
    "Notes format: markdown. `## <anchor>` starts a thread: `change` is about the whole change, " +
    "`path` a whole file, `path:N` or `path:N-M` code; a `{id=X}` after the anchor is a remote " +
    "thread. The line after it is `status: open` or `status: resolved`. `### <who>` starts a " +
    "comment: `### @alice` is a remote comment, `### me (local)` is mine (the human's) and not " +
    "published yet, `### me (note)` is mine and only for you (never published), `### me (proposed)` " +
    "is yours. Never edit `@author`, `me (local)` or `me (note)` comments, or `{id=...}` " +
    "attributes. A body line that starts with `#` is written with a leading `\\`.";

  const label = (t: Thread): string => {
    const first = t.comments[t.comments.length - 1]?.body.split("\n")[0] ?? "";
    const sev = severityOf(t);
    return `${sev ? `[${sev}] ` : ""}${t.anchor}${first ? `: "${first.slice(0, 60)}"` : ""}`;
  };

  // Mandatory first, so a round that runs out of steam drops the optional ones.
  const RANK: Record<string, number> = { FIX: 0, CHECK: 1, QUESTION: 2, CONSIDER: 3, NIT: 4 };
  const byRank = (a: Thread, b: Thread): number =>
    (RANK[severityOf(a) ?? ""] ?? 2) - (RANK[severityOf(b) ?? ""] ?? 2);

  const onlyThese = (selected: Thread[]): string =>
    "Handle only these threads, in this order; leave all others as they are:\n" +
    [...selected].sort(byRank).map((t) => `- ${label(t)}`).join("\n");

  // The severity ladder of /review decides how much a thread obliges pi. The
  // findings are pi's own, and proposed comments are not published until I
  // approve them, so acting on them needs no approval.
  const RESOLVE_RULES = [
    "Read every listed thread and the `change` threads before changing anything.",
    "A thread's severity is the tag that starts its first comment; a later `me (local)` or `me (note)` comment or an `@author` reply can change what is asked, and wins. No tag (a peer's or my own comment): treat it as a request, do it unless it is unclear.",
    "FIX: mandatory. Make the change. If it is wrong or impossible, say why in the reply and leave the thread open.",
    "CHECK: verify first (read the code, run the relevant tests). A real problem: fix it as for FIX. Not a problem: no change, reply with the evidence.",
    "CONSIDER and NIT: optional, judge them. Do the change when it is clearly better and cheap; otherwise decline in the reply with a short reason. Never a reason to touch unrelated code.",
    "QUESTION: answer from the code in the reply. Change code only if the answer exposes a bug.",
    "Reporting: every thread you handle gets one `### me (proposed)` comment saying what you did or why not (one or two lines). Fixed, verified OK or declined: also set `status: resolved`. Needs a decision from me, or you could not do it: leave `status: open`.",
    "Unclear: change nothing, append a `### me (proposed)` question, leave it open. Do not ask in the chat.",
    "A thread that is only your own finding (a single `me (proposed)` comment) and is fixed: keep it, resolved, with the reply; I clear it later.",
    "Keep every thread and their order.",
  ];

  const bullets = (lines: string[]): string => lines.map((l) => `- ${l}`).join("\n");

  // FIX/CHECK must say how the problem triggers: unfalsifiable "might break"
  // findings waste the human's review time.
  const findingTags = (limit: string, trigger = true): string =>
    "Tag each finding: FIX (blocking), CHECK (likely blocking, needs verification), CONSIDER " +
    "(design), QUESTION (could not determine), NIT (non-blocking). " +
    (trigger ? "FIX and CHECK name the input, path or state that triggers the problem. " : "") +
    `${limit} Skip findings without a concrete action.`;

  // Proposed comments are never published until the human approves them
  // (`a` or `A` in the review home), or discards them, so every finding gets read against
  // the code.
  const appendFindings = (notesFile: string, path: string, rules: string[]): string =>
    `Append to \`${notesFile}\` (create it if missing). Never change existing content; skip ` +
    "findings already in it, open or resolved. One thread per finding, shape:\n\n```\n" +
    `## ${path}:<line>\nstatus: open\n\n### me (proposed)\n<TAG>: <actionable, 1-2 sentences>\n<optional detail>\n\n` +
    `## ${path}:<first>-<last>\nstatus: open\n\n### me (proposed)\n<TAG>: <...>\n\n` +
    `## ${path}\nstatus: open\n\n### me (proposed)\n<TAG>: <about the whole file>\n\n` +
    "## change\nstatus: open\n\n### me (proposed)\n<TAG>: <about the whole change>\n```\n\n" +
    bullets([
      ...rules,
      "A finding about the whole change is a `change` thread, about a whole file a `<path>` thread. The assessment goes in your final message, not in the file.",
      "Blank line between threads; every comment is `### me (proposed)`.",
    ]);

  const VERDICT = "<ready | minor fixes | needs changes | major concerns>";

  // ---------------------------------------------------------------------------
  // Documents outside git: sibling notes, and finding the document an argument
  // refers to.
  // ---------------------------------------------------------------------------
  const NOTES_EXT = ".review.md";
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

  // The document an argument names: a path to it or to its .review.md file, else a
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

  // Documents in the cwd that have notes (doc.md for doc.md.review.md).
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
  // Document reviews (outside git)
  // ---------------------------------------------------------------------------
  // The document outside git that *arg* is about, undefined when the command
  // is about the branch (the git flow), null when it cannot go on (already
  // reported). Inside a repo only an explicit path outside the worktree
  // counts; outside a repo the argument is required and may
  // also be a description, matched against the files of this session and
  // the cwd's documents with notes. *needNotes*: only documents that have a
  // .review.md file (/fixup).
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
          `/${command} outside a git repository needs the document: a path, its .review.md file, ` +
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
    pi.sendUserMessage(`Review the document \`${doc}\` as an editor and domain expert. Do not edit it.

1. Read it and what it references. Check claims in a design or proposal against the code.
2. Look for, in priority order: wrong or unverifiable claims, gaps and missing cases, contradictions, unclear structure or reasoning, wording. ${findingTags("At most 10 findings, highest priority first.", false)}
3. ${appendFindings(notesFile, name, [
      `Path: the bare file name \`${name}\`. Verify line numbers by reading the file.`,
    ])}
4. Print the notes path, the verdict ${VERDICT} and counts per tag. Stop.`);
  };

  const fixupDocument = (doc: string, ctx: ExtensionCommandContext): void => {
    const notesFile = siblingNotes(doc);
    const name = basename(doc);
    const all = readThreads(notesFile);
    const selected = all.filter((t) => needsPi(t, undefined));
    if (selected.length === 0) {
      reportNothingForPi(all, undefined, `in ${basename(notesFile)}`, ctx);
      return;
    }
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
  // Findings are appended to the notes file as threads with a proposed
  // comment, next to the human's own notes. Proposed means "not approved yet":
  // publish and /fixup skip those threads until the human approves them
  // (`a` or `A` in the review home) or discards them, so every finding gets read against
  // the code.
  //
  // The argument is free text (scope, ticket, focus, blast radius), read by the
  // model. No plan: the reviewer judges the code against the problem, not
  // against the approach the author already settled on. Depth follows the
  // blast radius; a radius the human states is followed, never re-checked.
  // ---------------------------------------------------------------------------
  pi.registerCommand("review", {
    description:
      "Review code and append findings as proposed comments to the review notes file. " +
      "The argument is free text: scope, ticket, focus, blast radius (e.g. 'last 3 commits, " +
      "see KAT-1234, core change'). Default scope = uncommitted changes when there are " +
      "any, else the branch against its MR target. A document outside git (its path, or " +
      "outside a repo a description of it) is reviewed into its sibling .review.md file. " +
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

  
      const request = arg ? `Request (scope, ticket, focus, depth):\n${arg}` : "Request: none.";
      const recheck = threadsToRecheck(notesFile);
      const recheckStep = recheck.length
        ? `0. Re-check first. These open threads are mine and got answers or new code since I wrote them:\n${recheck
            .map((t) => `- ${label(t)}`)
            .join("\n")}\nFor each: read the replies and the current code. Addressed: append a \`### me (proposed)\` reply saying how (one line) and set \`status: resolved\`. Not addressed: append a \`### me (proposed)\` reply saying what is still missing, leave it open. Never edit existing comments. Then review the change as below; a finding already covered by one of these threads is not a new finding.\n\n`
        : "";

      pi.sendUserMessage(`Review code on branch \`${branch}\` as a strict senior engineer. Much of it is AI-generated: expect reinvented wheels, needless code, tests that check the wrong thing. Change no code; findings go to the notes file.

${request}

${recheckStep}Scope: what the request names (git range, commits, paths); else uncommitted changes including untracked files; else the branch against \`git-lab mr target\`. Ask if unclear.

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
        "<path>",
        [
          "The file is inside .git: never commit it.",
          "Paths repo-relative; line numbers from the working tree, verified by reading.",
          "Wording ready to post to a colleague: specific, polite, no IDs, no mention of this prompt.",
        ],
      )}
6. Print the notes path, the verdict ${VERDICT}, the depth line (<light | mixed | wide>, <stated | estimated>, what is deep) and counts per tag. Stop: no commits, no git-lab.`);
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
      "files/directories, or a document outside git (its path, its .review.md file, or outside " +
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
          "/fixup outside a git repository needs the document: /fixup <file>, its .review.md file, " +
            "or a description of it.",
          "warning",
        );
        return;
      }

      // Fixup plays the author: on a peer's MR it would commit to their branch.
      const mr = readMr(notesFile);
      if (mr && !isMyMr(mr)) {
        ctx.ui.notify(
          `/fixup is for your own MR: ${mr.ref ?? "this MR"} is @${mr.author}'s. ` +
            "Use /review to check their fixes against your threads.",
          "warning",
        );
        return;
      }
      const scope = args.trim();
      const all = readThreads(notesFile).filter((n) => inScope(n, scope, root, ctx.cwd));
      const selected = all.filter((t) => needsPi(t, mr));
      if (selected.length === 0) {
        const where = `in the review notes${scope ? ` (scope "${scope}")` : ""}`;
        reportNothingForPi(all, mr, where, ctx);
        return;
      }
      if (!requireCleanTree(ctx.cwd, "fixup", ctx)) return;
      // A diff base for the plugin's `f`: what this round changes. Same ref
      // as the plugin's checkpoints; a ref keeps the commit after a rebase.
      git(ctx.cwd, "update-ref", `refs/review-notes/${branch}/fixup`, "HEAD");
  
      pi.sendUserMessage(`Address my review notes on branch \`${branch}\`. Notes: \`${notesFile}\` (inside .git, never commit it; paths repo-relative).

${onlyThese(selected)}

${NOTES_FORMAT} Threads with an \`id\` are remote threads.

Per note: find the code from the note's text (line numbers drift), make the smallest fix, build and test per the project's instructions, commit as \`fixup! <subject>\` of the branch commit that introduced the code, staging only your changes (notes on one commit may share a fixup). Notes on a whole file (\`path:0\`) and general entries are fixups too: of the branch commit closest in topic, else the latest one. A note on a submodule path is about the pointer: fetch in the submodule, check out the ref it asks for (unclear: treat the note as unclear), build and test, stage the submodule path; never commit inside the submodule unless the note says so. These commits are requested; never rebase, amend, squash or push; never run git-lab.

${bullets([
        ...RESOLVE_RULES,
        "No commit SHAs in the notes (they change on squash).",
        "End with no uncommitted changes to tracked files and no new untracked files of yours.",
        "Print one line per thread: severity, what you did (fixup target commit, evidence, or reason declined), or the question.",
      ])}`);
    },
  });
}
