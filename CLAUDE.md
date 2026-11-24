# Bezzle

`README.md` is the map: what is where, how to build and test, and which document has each process.

## Releases

Bezzle ships from its website alone, https://bezzle.ch/download.html, at the
version set in Xcode (`MARKETING_VERSION`); there is no App Store version (Erik, 2026-11-06).
`Scripts/release.sh` builds it with the Swift condition `BEZZLE_DIRECT`, and Sparkle keeps it up to
date (`Bezzle/App/Updates.swift`). Bezzle for Windows ships beside it at the same version, an
installer from the same page that WinSparkle keeps up to date (`Scripts/release-windows.sh`,
`Windows/README.md` › Shipping it).

Sparkle is not in the Xcode project and its `SU…` keys are not in Info.plist: `release.sh` puts the
framework, the keys and the installer's sandbox entitlements into the released copy, and the app
loads Sparkle at run time only when it is there. So builds from Xcode, tests and test copies never
look for updates.

Whenever the version is raised, or Erik asks for a release:

1. **Write the notes.** Read what changed since the last release (`git describe --tags --abbrev=0`,
   then `git log` and `git diff <tag>..HEAD -- Bezzle`) and add the version at the top of
   `RELEASE_NOTES.md`, in English, German, French and Italian, in the same commit as the version
   change. Keep to the shape in the comment at the top of that file: `Scripts/release/notes.py`
   parses it, and the release refuses a version without its entry. The notes appear in Sparkle's
   update window in each Mac's language, on the GitHub release and on the site's What's New page.
2. **Run the tests**, then push. A release is made from the pushed commit, never the working tree.
   Run them before the Windows dry run starts, or one at a time while the VM builds (`README.md` ›
   The Mac app, On a busy Mac): run together on a busy Mac, they run one another out of time.
3. **Run `Scripts/release.sh`** (about 15 minutes, 35 beside the Windows build; `--dry-run` first
   puts a notarized zip on the Desktop and publishes nothing). It notarizes with the keychain profile
   `harness-notary` when this Mac has it (it did from 1.6.1, 2026-11-11, and was gone on 2026-11-16,
   for no known reason). Without it, it takes an App Store Connect API key instead:
   `ASC_KEY_PATH=~/Documents/apps/AuthKey_P85NK4PS34.p8 ASC_KEY_ID=P85NK4PS34
   ASC_ISSUER=a4b709c7-f491-4dbe-aad0-b1643daf9bc2 Scripts/release.sh`, the key where Erik keeps it
   (2026-11-16; 1.9.3 was notarized so). Never print it or copy it elsewhere. It builds from `git archive` of the commit plus the git-ignored
   subject matte, exports with the Developer ID, adds Sparkle, signs, notarizes and staples. It then
   publishes the zip and delta updates as the GitHub release `v<version>` of mfrports/bezzle-web. It
   then commits the new feed and a copy of `RELEASE_NOTES.md` there, which rebuilds and deploys the
   site; the site's Deploy copies the zip and deltas from that GitHub release to bezzle.ch/downloads/,
   where the feed points. Once the feed is live on bezzle.ch and on GitHub Pages and bezzle.ch serves
   the zip whole, it tags the commit `v<version>`, which marks the version as released.
4. **Release Windows** with `Scripts/release-windows.sh` (a dry run, putting the installers and a
   feed on the Desktop), then `Scripts/release-windows.sh --publish`, which sends out the installers
   that dry run made of the same commit instead of building them again (`--rebuild` builds anew). It
   needs the Windows VM running with its packages built and the subject matte sent
   (`Windows/README.md`), builds the pushed commit there for x64 and Arm64 (30 to 50 minutes each,
   so more than an hour; the Mac's release can run meanwhile), signs the installers with the same
   EdDSA key, publishes them as the GitHub release `windows-v<version>` of mfrports/bezzle-web with the feed
   `public/updates/windows/appcast.xml`, waits until bezzle.ch serves them and tags the commit
   `windows-v<version>`. The site turns to "Mac and Windows" by itself once a Windows version is in
   the feed. Pull `~/Sites/bezzle-web` afterwards, since both releases commit there.
5. **Check** https://bezzle.ch/download.html, `/updates/appcast.xml` and `/updates/windows/appcast.xml`.

When a release says the website did not go live within 10 minutes, everything is already published
on GitHub; only the site's deploy is late. Look at bezzle-web's Deploy runs (`gh run list -R
mfrports/bezzle-web --workflow Deploy`): runs queue one at a time, and a newer push takes the place of
a waiting one, so the newest run carries every release's feed. Once the feeds offer the version and
bezzle.ch serves the files at their full length, tag the commit as the script's message says
(1.5.1, 2026-11-08: a deploy hung on its live check, since fixed with time limits in bezzle-web
b559a45).

How to write the notes: for the people who use Bezzle, not for developers. Say what they can do now
and why it matters, benefit first. Only what really shipped. Quiet and plain, no exclamation marks,
and no dashes as punctuation in any language. No internal names (Sparkle, CI, file names). Use the
app's own words for its controls, in each language as `Localizable.xcstrings` has them. German with
"du", written fresh rather than word for word; French and Italian with "tu", like the website. A
fix with nothing to show gets a title and a lede, no list.

### How the website copy is put together

- **Website**: https://bezzle.ch, a webspace at One.com (Erik, since 2026-11-07). Its own repository,
  mfrports/bezzle-web, locally `~/Sites/bezzle-web`, like gerty-web for Gerty. Its source (Vite,
  React and Tailwind: the pages, the words in four languages, the story's rebuilt window in
  `src/story/`, `public/img`) is edited there, and every push to its main deploys it to bezzle.ch by
  FTP (the repository's `FTP_*` secrets). GitHub Pages, mfrports.github.io/bezzle-web, where the
  site was before, then gets a redirect for every page (a link's # comes along) and the feed. Its
  README has the rest. This repository holds no part of the site.
- **Feed**: https://bezzle.ch/updates/appcast.xml, the file `public/updates/appcast.xml` in
  bezzle-web, is the `SUFeedURL` of the copies released after the move. The copies before it read
  https://mfrports.github.io/bezzle-web/updates/appcast.xml, which every deploy keeps the same file.
  Neither ever moves. It lists the newest version alone, with its deltas and its notes in every
  language. Only `release.sh` writes it.
- **Zips and deltas**: kept as the releases of the public repository mfrports/bezzle-web (never as
  releases of the app's own repository), and served from https://bezzle.ch/downloads/, where the feed points: the
  site's Deploy (its scripts/downloads.mjs) copies every enclosure there from the GitHub release, so
  `release.sh` refuses to release until that step is on the site's main (Erik, 2026-11-08; Windows'
  installers go the same way, from the releases `windows-v<version>`). `release.sh` keeps the last
  released zips in `~/Library/Caches/bezzle-release/dist`, fetching them from GitHub when missing, to
  make the deltas from. The subject matte makes a full zip about 225 MB, while a delta is small.
- **Site and release**: the site takes the version, the zip and its size from the feed, and What's New
  from its copy of the notes (`src/releases/RELEASE_NOTES.md`), so it shows only what can be
  downloaded. Edit the notes here, never that copy: the next release overwrites it.
- **Signing key**: Sparkle's EdDSA key is the one Gerty's releases use (login Keychain, account
  `ed25519`; also the `SPARKLE_PRIVATE_KEY` secret of mfrports/gerty). One key serves every app. Its
  public half is `SPARKLE_PUBLIC_KEY` in `release.sh`. Lose it, and no installed copy can be updated.
- **Links**: a shared design's link is `https://bezzle.ch/open.html#2.<secret>`; the app still takes
  the `mfrports.github.io` links made before the move (`Sharing.websites`).
- **Same app, same data**: both copies have the bundle id `com.erik.Bezzle` and the same sandbox
  container, so they open the same designs, share through the same relay (`Relay/SHARING.md`), and
  hand over to each other like two copies of one app (`HandOver`).
- **Withdrawing a version**: revert the release's commit in bezzle-web (the feed goes back to the
  version before), then `gh release delete v<version> -R mfrports/bezzle-web --cleanup-tag`. Copies that
  installed it keep it.
- **Testing the updater** without a release: build Release with
  `'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BEZZLE_DIRECT'`. Make two copies under a test
  bundle id (never `com.erik.Bezzle`, whose container holds Erik's designs), an older and a newer
  version, each with Sparkle inside and signed with Apple Development.
  Give them a throwaway CryptoKit Ed25519 key (`generate_appcast --ed-key-file`), a local
  `http://127.0.0.1` feed and `NSAllowsLocalNetworking`. Launch the older copy with `open -g -n`: it
  fetches the update within seconds. `NSRunningApplication.terminate()` quits it, and the newer
  version is in place a moment later. Done this way on 2026-11-04, with `SUAutomaticallyUpdate`,
  which releases no longer set: without it, the older copy shows Sparkle's window with the notes.

## Working in this repository

What every session here keeps to (Erik's rules, gathered from many sessions):

- **Decide, then say what was chosen.** Make the product and technical calls that follow from where
  Erik is heading, build them, and report. Ask only before publishing, pushing, spending money, a Mac
  release or a change to the file format, or where Erik has stated a taste of his own.
- **Git:** commit on `main`, with a pathspec (`git commit -- <paths>`, or check
  `git diff --cached --name-only`: other sessions stage their own files in the same tree). Push only
  when Erik says, or as a release's step. A push to bezzle-web deploys the website, and
  `Web/publish.sh` publishes the browser viewer: both only at Erik's word.
- **What is left** is in `TODO.md`. A session that leaves a gap (something not built, not checked,
  or different from the Mac) adds it there; one that closes a gap takes it out in the same commit.
- **Builds for others:** archive, sign for distribution or notarize only when Erik asks.
- **Erik's designs are never touched.** Test copies run with their own `BEZZLE_LIBRARY` and, while
  his Bezzle runs, a bundle id of their own; never `com.erik.Bezzle`'s sandbox container, which holds
  his designs. On Windows, a test install is made with `-Name 'Bezzle Test'`. A copy of one of his
  designs made for a test loses its `sharing` folder before a test copy opens it, and the test copy
  runs with `BEZZLE_LIVE_RELAY=` (empty): with the folder in it, the copy joins his design's live
  room as one more person (2026-11-13: three photo runs showed up in his window for seconds each).
- **Never take the screen from Erik.** Launch test copies with `open -g -n`, never activate or raise
  them, photograph windows with `screencapture -l <id>`, and ask before a long run of windows.
- **Words people read:** no dashes as punctuation and no exclamation marks, in any language; plain
  and quiet; the app's own words from `Localizable.xcstrings` (its French says "vous"; the website
  and the notes say "tu" and "du").
- **The Windows VM** (`Windows/README.md` › Working in the VM): its password and SSH key are in
  `~/.ssh/bezzle-windows-vm.password` and `~/.ssh/bezzle-windows-vm`; never print them.
  `Windows/VM/autounattend.xml` holds only a placeholder, so never restore a password from it. One
  session at a time uses the VM's desktop, through the lock described there.
- **Parallel agents** (Erik wants independent work spread over them): each works in a git worktree of
  its own, commits there and never pushes; the main session checks the commits and brings them onto
  `main`. In the VM each has its own source folder `C:\src\<name>` (synced into, with a junction to
  `C:\src\Bezzle\Windows\Packages`), builds with `-j 2` when several build, runs its copies with
  `BEZZLE_NO_MCP=1`, stops only its own processes, and uses the desktop only under the lock. Only one
  agent at a time runs `ParityTests`, whose log file is shared. Agents written against an older main
  add stand-ins of their own: expect duplicate declarations when merging, and keep the fuller one.
- **Shared code and the Mac:** `Bezzle/Model` is compiled into Windows and the browser too. Share only
  what tests cover, prove the Mac unchanged (`README.md` › Mac parity), and commit Mac-touching work
  apart from Windows work.
- **This repository is public** (mfrports/bezzle, MIT, since 2026-11-20): every commit and its whole
  history can be read by anyone. Never commit a secret (`gitleaks git .` scans the history), nor
  the names of the companies Erik works for or of their designs: write "one of Erik's largest
  designs" and use example.ch in tests. Its collaborators are Erik and MarcDietschi (invited
  2026-11-20 at Erik's word, after his Windows speed-ups came in from a fork; a personal
  repository gives every collaborator write access). Pull requests can be opened by collaborators
  alone (the repository's `pull_request_creation_policy`), and the ruleset `main` forbids deleting
  `main` or force-pushing to it and takes changes only through a pull request approved after its
  last push (since 2026-11-20), Erik as admin excepted, so his pushes and releases go on as before.
  A contributor's work is read, built and tried in the VM before it comes onto `main`, keeping its
  author: several pull requests merged together on a scratch branch, built and tried as one, then
  merged on GitHub with merge commits (`gh pr merge <n> --merge --admin`). A stack (a pull request
  based on another's branch) refuses that and `gh pr edit --base`: merge it bottom-most first with
  `gh api -X PUT repos/mfrports/bezzle/pulls/<n>/merge-async -H "X-GitHub-Api-Version: 2026-03-10"
  -f merge_method=merge -f merge_action=direct_merge -F bypass_rules=true`, and wait for each
  (`…/merge-async/<uuid>`) before the next (2026-11-24). A draft stays open. Issues are open to
  everyone.

