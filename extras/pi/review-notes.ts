/**
 * Review Notes Extension
 *
 *   /review [request] - Review code (or a document outside git) and append the
 *                       findings to the review notes as proposed comments. The
 *                       request is free text: scope, ticket, focus, blast radius.
 *   /fixup [scope]    - Address the open threads that are pi's turn: threads on
 *                       code become fixup! commits, threads on a document outside
 *                       git are edits in place; each gets a proposed reply.
 *
 * Notes files are shared with review-notes.nvim (format in
 * lua/review_notes/store.lua, rules in DESIGN.md): a branch's review lives in
 * $(git rev-parse --git-common-dir)/review/<branch>.md, a document outside git
 * in a sibling <file>.review.md.
 *
 * Everything pi writes is a `### me (proposed)` comment, which the plugin never
 * publishes until the human approves it, so a round of pi is safe at any time.
 * Approval only gates publishing: /fixup acts on pi's own findings directly.
 *
 * Commits are the only handover between the human and pi, so /fixup on code
 * refuses a dirty tree. It also refuses a peer's MR: it plays the author.
 */

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";

interface Comment {
  proposed: boolean; // `me (proposed)`: pi's, waits for approval
  private: boolean; // `me (private)`: mine, never published
  mine: boolean; // mine, not published (local or private)
  published: boolean; // a remote comment of mine
  body: string;
}

interface Thread {
  anchor: string; // "change", "path", "path:N" or "path:N-M"
  path?: string; // none: the whole change
  resolved: boolean;
  id?: string; // remote thread id
  comments: Comment[];
}

// The MR as the plugin's sidecar (<branch>.json) knows it. None: no MR yet.
interface MrRecord {
  author?: string;
  me?: string;
  ref?: string;
}

const HEADING_RE = /^(#{2,3})\s+(.*?)\s*(?:\{([^{}]*)\})?\s*$/;
const NOTES_EXT = ".review.md";
const TAG_RE = /^\s*(FIX|CHECK|CONSIDER|QUESTION|NIT)\b/;
// Mandatory first, so a round that runs out of steam drops the optional ones.
const RANK: Record<string, number> = { FIX: 0, CHECK: 1, QUESTION: 2, CONSIDER: 3, NIT: 4 };

export default function reviewNotes(pi: ExtensionAPI) {
  // ---------------------------------------------------------------------------
  // Git and files
  // ---------------------------------------------------------------------------
  const git = (cwd: string, ...args: string[]): string | undefined => {
    try {
      return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch {
      return undefined;
    }
  };

  const gitPath = (cwd: string, path: string): string | undefined =>
    git(cwd, "rev-parse", "--path-format=absolute", "--git-path", path);

  // During a rebase HEAD is detached, but the notes of the branch being
  // rebased still apply (same fallback as git-lab and the plugin).
  const getBranch = (cwd: string): string => {
    const branch = git(cwd, "branch", "--show-current");
    if (branch) return branch;
    for (const dir of ["rebase-merge", "rebase-apply"]) {
      const head = readText(gitPath(cwd, `${dir}/head-name`) ?? "").trim();
      if (head) return head.replace(/^refs\/heads\//, "");
    }
    return "HEAD";
  };

  // Under the common git dir: the review belongs to the branch, not to a worktree.
  const getNotesPath = (cwd: string): string | undefined => {
    const dir = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir");
    return dir ? join(dir, "review", `${getBranch(cwd)}.md`) : undefined;
  };

  const readText = (p: string): string => {
    try {
      return readFileSync(p, "utf8");
    } catch {
      return "";
    }
  };

  const isFile = (p: string): boolean => {
    try {
      return statSync(p).isFile();
    } catch {
      return false;
    }
  };

  const expandHome = (p: string): string => (p === "~" || p.startsWith("~/") ? join(homedir(), p.slice(1)) : p);

  const shortPath = (cwd: string, p: string): string => {
    const rel = relative(cwd, p);
    if (!rel.startsWith("..")) return rel;
    const home = homedir();
    return p.startsWith(home + "/") ? "~" + p.slice(home.length) : p;
  };

  // ---------------------------------------------------------------------------
  // Preconditions
  // ---------------------------------------------------------------------------
  // Commands send a prompt, which pi rejects while the agent is running.
  const requireIdle = (command: string, ctx: ExtensionCommandContext): boolean => {
    if (ctx.isIdle()) return true;
    ctx.ui.notify(`pi is busy -- run /${command} when the current run has finished.`, "warning");
    return false;
  };

  // Commits made at a rebase stop land in the middle of the rewritten history.
  // Untracked files cannot leak into commits (the agent stages by path).
  const requireCleanTree = (cwd: string, ctx: ExtensionCommandContext): boolean => {
    if (["rebase-merge", "rebase-apply"].some((dir) => existsSync(gitPath(cwd, dir) ?? ""))) {
      ctx.ui.notify("/fixup commits: finish or abort the rebase first.", "warning");
      return false;
    }
    const dirty = (git(cwd, "status", "--porcelain", "--ignore-submodules=untracked") ?? "")
      .split("\n")
      .filter((l) => l.trim() !== "" && !l.startsWith("??"));
    if (dirty.length === 0) return true;
    const more = dirty.length > 10 ? `\n... and ${dirty.length - 10} more` : "";
    ctx.ui.notify(
      "/fixup needs a clean working tree -- commit (e.g. a fixup! or wip: commit) or stash " +
        `your changes first:\n${dirty.slice(0, 10).join("\n")}${more}`,
      "warning",
    );
    return false;
  };

  // ---------------------------------------------------------------------------
  // Notes
  // ---------------------------------------------------------------------------
  const readMr = (notesFile: string): MrRecord | undefined => {
    try {
      const mr = JSON.parse(readText(notesFile.replace(/\.md$/, ".json"))).mr;
      return mr && typeof mr === "object" ? mr : undefined;
    } catch {
      return undefined;
    }
  };

  // Same reading as the plugin's store.lua. A remote comment is mine when
  // flagged `{mine}` or written by my user name (the flag is optional).
  const readThreads = (notesFile: string, mr: MrRecord | undefined): Thread[] => {
    const out: Thread[] = [];
    let thread: Thread | undefined;
    let comment: Comment | undefined;
    let sawStatus = false;
    const local = (body: string): Comment => ({ proposed: false, private: false, mine: true, published: false, body });
    for (const line of readText(notesFile).split("\n")) {
      const h = HEADING_RE.exec(line);
      if (h?.[1] === "##") {
        const anchor = h[2]!;
        thread = {
          anchor,
          path: anchor === "change" ? undefined : anchor.replace(/:\d+(-\d+)?$/, ""),
          resolved: false,
          id: /(?:^|\s)id=(\S+)/.exec(h[3] ?? "")?.[1],
          comments: [],
        };
        out.push(thread);
        comment = undefined;
        sawStatus = false;
      } else if (h?.[1] === "###" && thread) {
        const who = h[2]!;
        if (who === "me" || who === "me (local)") comment = local("");
        else
          comment = {
            proposed: who === "me (proposed)",
            private: who === "me (private)",
            mine: who === "me (private)",
            published: /(?:^|\s)mine(?:\s|$)/.test(h[3] ?? "") || (!!mr?.me && who === `@${mr.me}`),
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
          // Text with no `###` heading is one local comment (a hand-written thread).
          comment = local(line);
          thread.comments.push(comment);
        }
      }
    }
    for (const t of out) for (const c of t.comments) c.body = c.body.trim();
    return out;
  };

  // `me` is optional in the sidecar: without it, the MR cannot be a peer's.
  const isMyMr = (mr: MrRecord): boolean => !mr.author || !mr.me || mr.author === mr.me;

  // Whose turn (DESIGN.md, "The two loops"). Pi's when the thread is open and:
  // - it is pi's own fresh finding (a single proposed comment): no approval
  //   needed to act on it;
  // - or the last comment is private (always for pi), my unpublished comment
  //   before the MR (after, it goes to a peer), or a peer's on my own MR.
  // Pi's reply last, or my published comment last, means it waits for someone else.
  const needsPi = (t: Thread, mr: MrRecord | undefined): boolean => {
    const last = t.comments.at(-1);
    if (t.resolved || !last) return false;
    if (last.proposed) return t.comments.length === 1;
    if (last.private) return true;
    if (last.mine) return !mr;
    if (last.published) return false;
    return !mr || isMyMr(mr);
  };

  // On a peer's MR: my open threads the author answered since my last word.
  const threadsToRecheck = (threads: Thread[], mr: MrRecord | undefined): Thread[] => {
    if (!mr || isMyMr(mr)) return [];
    return threads.filter((t) => {
      const first = t.comments[0];
      const last = t.comments.at(-1);
      if (t.resolved || !t.id || !first || !last) return false;
      return (first.published || first.mine) && !last.proposed && !last.published && !last.mine;
    });
  };

  // Scope: whitespace-separated files or directories; empty = everything.
  const inScope = (t: Thread, scope: string, root: string, cwd: string): boolean =>
    !scope ||
    (t.path !== undefined &&
      scope.split(/\s+/).some((raw) => {
        const tok = relative(root, resolve(cwd, expandHome(raw)));
        return tok === "" || t.path === tok || t.path!.startsWith(tok + "/");
      }));

  const reportNothingForPi = (threads: Thread[], mr: MrRecord | undefined, where: string, ctx: ExtensionCommandContext) => {
    const waiting = threads.filter((t) => !t.resolved && !needsPi(t, mr)).length;
    const tail = waiting ? `: ${waiting} open thread${waiting === 1 ? "" : "s"} waiting for you or a peer.` : ".";
    ctx.ui.notify(`Nothing for pi ${where}${tail}`, "info");
  };

  // ---------------------------------------------------------------------------
  // Prompt pieces. Prompts are terse rules for the agent; the rationale lives
  // in these comments. The extension picks the threads of a /fixup round, so
  // the agent never applies the turn rules itself.
  // ---------------------------------------------------------------------------
  const bullets = (lines: string[]): string => lines.map((l) => `- ${l}`).join("\n");

  const NOTES_FORMAT = `Notes format (markdown):
${bullets([
  "`## <anchor>` starts a thread. Anchor: `change` (the whole change), `path` (a whole file), `path:N` or `path:N-M` (code). A trailing `{id=X}` marks a remote thread.",
  "The next line is `status: open` or `status: resolved`.",
  "`### <who>` starts a comment: `@alice` a remote comment, `me (local)` mine, not published yet, `me (private)` mine, never published (for you), `me (proposed)` yours.",
  "Only append `### me (proposed)` comments and set `status:`. Never edit other comments or `{...}` attributes.",
  "A body line starting with `#` is written with a leading `\\`.",
])}`;

  const tagOf = (t: Thread): string | undefined => {
    for (const c of t.comments) {
      const m = TAG_RE.exec(c.body);
      if (m) return m[1];
    }
    return undefined;
  };

  // The latest comment is what the thread asks now.
  const label = (t: Thread): string => {
    const tag = tagOf(t);
    const last = t.comments.at(-1)?.body.split("\n")[0] ?? "";
    return `${tag ? `[${tag}] ` : ""}${t.anchor}${last ? `: "${last.slice(0, 60)}"` : ""}`;
  };

  const onlyThese = (threads: Thread[]): string => {
    const rank = (t: Thread) => RANK[tagOf(t) ?? ""] ?? RANK.QUESTION!;
    const sorted = [...threads].sort((a, b) => rank(a) - rank(b));
    return "Handle only these threads, in this order; leave all others as they are:\n" + bullets(sorted.map(label));
  };

  // How much a thread obliges pi follows the tag /review filed it with.
  const RESOLVE_RULES = [
    "Before changing anything, read every listed thread and every open `change` thread.",
    "What a thread asks: the tag starting its first comment, unless a later comment (mine or a peer's) changes the request; the later one wins. No tag: a request, do it unless it is unclear.",
    "FIX: mandatory. Make the change. If it is wrong or impossible, say why and leave the thread open.",
    "CHECK: verify first (read the code, run the relevant tests). A real problem: fix it as for FIX. Otherwise no change; reply with the evidence.",
    "CONSIDER, NIT: optional. Do it when clearly better and cheap, else decline with a short reason. Never a reason to touch unrelated code.",
    "QUESTION: answer from the code. Change code only if the answer exposes a bug.",
    "Unclear: change nothing, append a `### me (proposed)` question, leave it open. Never ask in the chat.",
    "Every handled thread gets one `### me (proposed)` reply (1-2 lines): what you did, or why not. Done, verified or declined: set `status: resolved`. Needs my decision or could not be done: leave it open.",
    "Never delete or reorder threads, not even your own findings once fixed.",
  ];

  // FIX/CHECK must say how the problem triggers: an unfalsifiable "might
  // break" wastes the human's review time.
  const findingTags = (limit: string, trigger: boolean): string =>
    "Tag each finding: FIX (blocking), CHECK (likely blocking, needs verification), CONSIDER (design), " +
    "QUESTION (could not determine), NIT (non-blocking). " +
    (trigger ? "FIX and CHECK name the input, path or state that triggers the problem. " : "") +
    `${limit} Skip findings without a concrete action.`;

  const appendFindings = (notesFile: string, anchors: string, rules: string[]): string =>
    `Append the findings to \`${notesFile}\` (create it if missing), one thread each, a blank line between threads:

\`\`\`
## <anchor>
status: open

### me (proposed)
<TAG>: <actionable, 1-2 sentences>
<optional detail>
\`\`\`

${bullets([
  `Anchor: ${anchors}; \`change\` for the whole change.`,
  "Never change existing content; skip findings already in it, open or resolved.",
  ...rules,
  "The overall assessment goes in your final message, not in the file.",
])}`;

  const VERDICT = "<ready | minor fixes | needs changes | major concerns>";

  // ---------------------------------------------------------------------------
  // Documents outside git
  // ---------------------------------------------------------------------------
  const siblingNotes = (doc: string): string => doc + NOTES_EXT;
  const docOf = (notesFile: string): string => notesFile.slice(0, -NOTES_EXT.length);
  const outsideGit = (p: string): boolean => !git(dirname(p), "rev-parse", "--show-toplevel");

  // Files the agent read, edited or wrote in this session, most recent first:
  // "the doc we are editing" is one of them.
  const sessionFiles = (ctx: ExtensionCommandContext): string[] => {
    const out = new Set<string>();
    const entries = ctx.sessionManager.getBranch() as any[];
    for (const entry of [...entries].reverse()) {
      const msg = entry?.type === "message" ? entry.message : undefined;
      if (msg?.role !== "assistant" || !Array.isArray(msg.content)) continue;
      for (const c of msg.content) {
        const path = c?.type === "toolCall" && ["read", "edit", "write"].includes(c.name) ? c.arguments?.path : undefined;
        if (typeof path !== "string") continue;
        const abs = resolve(ctx.cwd, expandHome(path));
        if (isFile(abs)) out.add(abs);
      }
    }
    return [...out];
  };

  // Documents in *dir* that have notes.
  const notedDocsIn = (dir: string): string[] => {
    try {
      return readdirSync(dir)
        .filter((f) => f.endsWith(NOTES_EXT))
        .map((f) => docOf(join(dir, f)));
    } catch {
      return [];
    }
  };

  // A description resolved against *candidates*, asking when there are
  // several. Never guessed by the model: fixups outside git are unversioned.
  const pickDoc = async (arg: string, candidates: string[], command: string, ctx: ExtensionCommandContext) => {
    const unique = [...new Set(candidates)];
    if (unique.length <= 1) {
      if (!unique[0])
        ctx.ui.notify(`/${command}: could not tell which document "${arg}" means -- pass its path.`, "warning");
      return unique[0];
    }
    const labels = unique.map((p) => shortPath(ctx.cwd, p));
    const choice = await ctx.ui.select(`/${command}: which document is "${arg}"?`, labels);
    return choice ? unique[labels.indexOf(choice)] : undefined;
  };

  // The document outside git that *arg* is about: undefined when the command
  // is about the branch, null when it cannot go on (already reported). In a
  // repo only an explicit path outside it counts; outside a repo the argument
  // is required and may be a description. *needNotes*: /fixup needs notes.
  const documentTarget = async (
    arg: string,
    command: string,
    needNotes: boolean,
    ctx: ExtensionCommandContext,
  ): Promise<string | undefined | null> => {
    const abs = arg ? resolve(ctx.cwd, expandHome(arg)) : "";
    const path = isFile(abs) ? (abs.endsWith(NOTES_EXT) ? docOf(abs) : abs) : undefined;
    let doc: string | undefined;
    if (git(ctx.cwd, "rev-parse", "--show-toplevel") !== undefined) {
      if (!path || !outsideGit(path)) return undefined;
      doc = path;
    } else if (path) {
      doc = path;
    } else if (!arg) {
      const docs = notedDocsIn(ctx.cwd).map((d) => basename(d));
      ctx.ui.notify(
        `/${command} outside a git repository needs the document: a path, its ${NOTES_EXT} file, or a description` +
          (docs.length ? ` (documents with notes here: ${docs.join(", ")}).` : "."),
        "warning",
      );
      return null;
    } else {
      const candidates = [...sessionFiles(ctx), ...notedDocsIn(ctx.cwd)].filter(
        (p) => !p.endsWith(NOTES_EXT) && outsideGit(p) && (!needNotes || isFile(siblingNotes(p))),
      );
      doc = await pickDoc(arg, candidates, command, ctx);
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
    const name = basename(doc);
    pi.sendUserMessage(`Review the document \`${doc}\` as an editor and domain expert. Do not edit it.

1. Read it and what it references. Check claims in a design or proposal against the code.
2. Look for, in priority order: wrong or unverifiable claims, gaps and missing cases, contradictions, unclear structure or reasoning, wording. ${findingTags("At most 10 findings, highest priority first.", false)}
3. ${appendFindings(siblingNotes(doc), `\`${name}:<line>\`, \`${name}:<first>-<last>\` or \`${name}\` (the bare file name; verify line numbers by reading)`, [])}
4. Print the notes path, the verdict ${VERDICT} and counts per tag. Stop.`);
  };

  const fixupDocument = (doc: string, ctx: ExtensionCommandContext): void => {
    const notesFile = siblingNotes(doc);
    const threads = readThreads(notesFile, undefined);
    const selected = threads.filter((t) => needsPi(t, undefined));
    if (selected.length === 0) return reportNothingForPi(threads, undefined, `in ${basename(notesFile)}`, ctx);
    pi.sendUserMessage(`Address my review notes on \`${doc}\`. Notes: \`${notesFile}\` (paths are \`${basename(doc)}\`).

${onlyThese(selected)}

${NOTES_FORMAT}

The document is not versioned: edit it in place, smallest change per thread, no reformatting or unrelated rewording. No git.

${bullets([
  ...RESOLVE_RULES,
  "After editing, update the line numbers in the anchors of threads whose text moved.",
  "End by printing one line per thread: what changed, or the question.",
])}`);
  };

  // ---------------------------------------------------------------------------
  // /review
  //
  // The argument is free text read by the model. No plan: the reviewer judges
  // the code against the problem, not against the approach the author settled
  // on. Depth follows the blast radius; a radius the human states is a given.
  // ---------------------------------------------------------------------------
  const RECHECK_RULES =
    "For each: read the replies and the current code. Addressed: append a `### me (proposed)` reply saying how (one line) and set `status: resolved`. " +
    "Not addressed: append a `### me (proposed)` reply saying what is still missing, leave it open. " +
    "Then review the change as below; a finding these threads already cover is not a new finding.";

  const REVIEW_CHECKS = `All areas:
${bullets([
  "Bugs against the intent.",
  "Reuse: for each new function, type, constant or pattern, search the codebase, dependencies and stdlib for an equivalent (by name, concept, what it calls). A near match is a finding: use or extend it. Cite `path:line` and what it lacks.",
  "Consistency with the surrounding code and closest siblings: naming, structure, error handling, logging, ownership, test layout. Modernise only where clearly simpler or safer; never two styles for one thing in a file. Cite the pattern as `path:line`. NIT; CONSIDER if it adds a second way of doing something.",
  "Removal: dead code, checks for impossible cases, swallowed errors, unused parameters, single-use abstractions, unrequested shims, comments restating code.",
  "Simplicity: a simpler design meeting the current requirement (fewer layers, function over class, stdlib over custom, less generality). Name it.",
  "Language rules, new or changed code only, confirmed in the body; one finding per rule per file:\n" +
    "  - C++ const: never-modified locals, parameters, references, pointers, members; non-mutating methods; `constexpr` for compile-time constants. NIT.\n" +
    "  - C++ copies: non-trivial types copied where a reference does (read-only by-value parameters, `for (auto x : c)`, read-only copies of members or map values, sink parameters without `std::move`). Not cheap types (scalars, raw pointers, `string_view`, `span`, small trivially copyable) or needed copies. NIT; CONSIDER on hot paths.\n" +
    "  - Python defaults that are mutable or evaluated once (`[]`, `{}`, `set()`, instances, `datetime.now()`, dataclass fields without `default_factory`). FIX if mutated, stored or returned; else NIT.",
  "Tests: do they pin down the new behaviour? Missing proof is a finding; do not write it.",
])}
Deep areas also:
${bullets([
  "Contracts: every dependent still holds (invariants, defaults, errors, formats, ordering).",
  "Missing changes: other call sites, sibling implementations, config, docs, migrations, error paths.",
  "Break it: boundaries, empty input, failure midway, cleanup, concurrency, reentrancy, resource ownership.",
  "Parallel mechanisms the change could merge with an existing one: CONSIDER, follow-up if beyond scope.",
  "Tests: right level (logic unit-tested, wiring integration-tested), fail if reverted, no mocking the unit under test, no asserts on implementation details, parametrize copies, beyond the happy path.",
])}
Submodule pointer changes: \`git diff --submodule=log\` over the scope. The new commit is the intended one (request, ticket), fast-forward from the old one, pushed upstream; the superproject changes it needs are in. Findings on the submodule path at line 1.
Verify by reading and by running existing relevant tests (none if unsure). No new tests.`;

  pi.registerCommand("review", {
    description:
      "Review code and append findings as proposed comments to the review notes. The argument " +
      "is free text: scope, ticket, focus, blast radius (e.g. 'last 3 commits, see KAT-1234, core " +
      "change'). Default scope: uncommitted changes, else the branch against its MR target. A " +
      "document outside git (its path, or outside a repo a description) is reviewed into its " +
      "sibling .review.md file. Usage: /review [request]",
    handler: async (args, ctx) => {
      if (!requireIdle("review", ctx)) return;
      const arg = args.trim();
      const doc = await documentTarget(arg, "review", false, ctx);
      if (doc === null) return;
      if (doc) return reviewDocument(doc);
      const notesFile = getNotesPath(ctx.cwd);
      if (!notesFile) {
        ctx.ui.notify("/review needs a git repository, or a document: /review <file>.", "warning");
        return;
      }
      const mr = readMr(notesFile);
      const recheck = threadsToRecheck(readThreads(notesFile, mr), mr);
      const recheckStep = recheck.length
        ? `0. Re-check first: these open threads are mine and got answers or new code since I wrote them:\n${bullets(recheck.map(label))}\n${RECHECK_RULES}\n\n`
        : "";

      pi.sendUserMessage(`Review code on branch \`${getBranch(ctx.cwd)}\` as a strict senior engineer. Much of it is AI-generated: expect reinvented wheels, needless code, tests that check the wrong thing. Change no code; findings go to the notes file.

${arg ? `Request (scope, ticket, focus, depth):\n${arg}` : "Request: none."}

Scope: what the request names (git range, commits, paths); else uncommitted changes including untracked files; else the branch against \`git-lab mr target\`. Ask if unclear.

${recheckStep}1. Intent. Read the change and enough context. Print one line per changed file, then its purpose in 1-2 sentences. Sources: a ticket in the request (read via Jira, read-only; say if it fails), the request, the code. Still unclear: stop and ask. Never infer it from branch names or commit subjects.
2. Depth. A depth stated in the request is a given. Otherwise, per changed area, judge the reach (not the diff size): dependents (LSP references, grep), public API, shared or core modules, persisted formats, config, build. Always risky: security, concurrency, migrations and stored data, error and cleanup paths. Mark each area light or deep.
3. If your estimate finds a wide or unclear radius or a risky area: stop and report the radius with evidence (e.g. "\`Parser::parse\`: 40 callers in 6 modules"), the deep/light split, and only questions that would change the review. My answer is a given.
4. Review. ${REVIEW_CHECKS}

${findingTags("Report every FIX, CHECK and QUESTION; of CONSIDER and NIT the 5 most valuable, with the number left out in the assessment.", true)}

5. ${appendFindings(notesFile, "`<path>:<line>`, `<path>:<first>-<last>` or `<path>` (a whole file)", [
        "Paths repo-relative; line numbers from the working tree, verified by reading.",
        "Wording ready to post to a colleague: specific, polite, no IDs, no mention of this prompt.",
      ])}
6. Print the notes path, the verdict ${VERDICT}, the depth line (<light | mixed | wide>, <stated | estimated>, what is deep) and counts per tag. Stop: no commits (the notes file is inside .git), no git-lab.`);
    },
  });

  // ---------------------------------------------------------------------------
  // /fixup
  //
  // Feedback travels as text in the notes, never as edits in the tree, and is
  // addressed here in one go. Handled threads are resolved with a reply, not
  // deleted, so the human can check the claim and reopen.
  // ---------------------------------------------------------------------------
  pi.registerCommand("fixup", {
    description:
      "Address the open review threads that are pi's turn: threads on code become fixup! commits, " +
      "threads on a document outside git are edits in place; each gets a proposed reply. Scope: " +
      "files/directories, or a document outside git (its path, its .review.md file, or outside a " +
      "repo a description); none = the whole branch. Needs a clean tree. Usage: /fixup [scope]",
    handler: async (args, ctx) => {
      if (!requireIdle("fixup", ctx)) return;
      const scope = args.trim();
      const doc = await documentTarget(scope, "fixup", true, ctx);
      if (doc === null) return;
      if (doc) return fixupDocument(doc, ctx);
      const notesFile = getNotesPath(ctx.cwd);
      const root = git(ctx.cwd, "rev-parse", "--show-toplevel");
      if (!notesFile || !root) {
        ctx.ui.notify(`/fixup outside a git repository needs the document: a path, its ${NOTES_EXT} file, or a description.`, "warning");
        return;
      }
      const mr = readMr(notesFile);
      if (mr && !isMyMr(mr)) {
        ctx.ui.notify(
          `/fixup is for your own MR: ${mr.ref ?? "this MR"} is @${mr.author}'s. Use /review to check their fixes against your threads.`,
          "warning",
        );
        return;
      }
      const threads = readThreads(notesFile, mr).filter((t) => inScope(t, scope, root, ctx.cwd));
      const selected = threads.filter((t) => needsPi(t, mr));
      if (selected.length === 0)
        return reportNothingForPi(threads, mr, `in the review notes${scope ? ` (scope "${scope}")` : ""}`, ctx);
      if (!requireCleanTree(ctx.cwd, ctx)) return;
      const branch = getBranch(ctx.cwd);
      // The plugin's `f` diff base "since the agent's last fixup"; a ref keeps
      // the commit alive across a rebase.
      git(ctx.cwd, "update-ref", `refs/review-notes/${branch}/fixup`, "HEAD");

      pi.sendUserMessage(`Address my review notes on branch \`${branch}\`. Notes: \`${notesFile}\` (inside .git, never commit it; paths repo-relative).

${onlyThese(selected)}

${NOTES_FORMAT}

Per thread:
${bullets([
  "Find the code from the thread's text (line numbers drift), make the smallest fix, build and test per the project's instructions.",
  "Commit as `fixup! <subject>` of the branch commit that introduced the code, staging only your changes; threads on one commit may share a fixup. Whole-file and `change` threads: the branch commit closest in topic, else the latest.",
  "A thread on a submodule path is about the pointer: fetch in the submodule, check out the ref it asks for (unclear: treat the thread as unclear), build and test, stage the submodule path. Never commit inside the submodule unless the thread says so.",
  "These commits are requested. Never rebase, amend, squash or push; never run git-lab.",
])}

${bullets([
  ...RESOLVE_RULES,
  "No commit SHAs in the notes (they change on squash).",
  "End with no uncommitted changes to tracked files and no new untracked files of yours.",
  "Print one line per thread: tag, what you did (fixup target commit, evidence, or reason declined), or the question.",
])}`);
    },
  });
}
